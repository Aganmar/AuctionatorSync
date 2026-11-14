-- ScanShare: shares Auctionator's price database between your characters over hidden addon whispers.
-- The side with the newer scan sends every item seen since the other side's newest data (compressed);
-- the receiver writes an item only if it is newer than what it already has, dated to the day it was seen.
local ADDON, ns = ...
local PREFIX = "ScanShr1"
local CHANNEL = "ScanShare"
local CHUNK = 230
local MAX_CHUNKS = 400          -- reject transfers larger than this
local OUTLIER = 10              -- x higher/lower than your own price = suspicious
local CONFIRM_MATCH = 0.25      -- a second sender within 25% confirms a held price
local POISON_SHARE = 0.20       -- >20% outliers from one sender = reject whole transfer
local MAX_PRICE = 1e10          -- 1,000,000 gold
local REF_DAYS = 14             -- only your own prices from the last 14 days count as a reference
local MIN_COMPARED = 50         -- need this many comparable prices before judging a sender
local STRIKES = 2               -- rejected transfers within STRIKE_WINDOW before auto-block
local STRIKE_WINDOW = 7 * 86400
local AUTOBLOCK_TIME = 30 * 86400

local DB
local function P(msg) DEFAULT_CHAT_FRAME:AddMessage("|cff4fc3f7ScanShare|r: " .. tostring(msg)) end
local KIND = { W = "queued", H = "hello", A = "answer", R = "request", D = "data", E = "end", N = "announce", Q = "query" }
local function describe(msg)
  local k = msg:sub(1, 1)
  if k == "D" then return "data " .. (msg:match("^D(%d+/%d+)") or "") end
  return (KIND[k] or k) .. " " .. msg:sub(3, 40)
end
local function L(dir, where, who, msg)
  if not (DB and DB.debug) then return end
  if msg:sub(1, 1) == "D" then
    local i, t = msg:match("^D(%d+)/(%d+)"); i, t = tonumber(i), tonumber(t)
    if i and t and i ~= 1 and i ~= t and i % 25 ~= 0 then return end
  end
  DEFAULT_CHAT_FRAME:AddMessage(("|cff808080[scanshare] %s %s %s %s|r"):format(dir, where, who or "", describe(msg)))
end

-- ---------------------------------------------------------------- Auctionator access
local function priceDB()
  return Auctionator and Auctionator.Database and Auctionator.Database.db
end

local function scanTime()
  return (AUCTIONATOR_SAVEDVARS and tonumber(AUCTIONATOR_SAVEDVARS.TimeOfLastBrowseScan)) or 0
end

local function entry(db, key)
  local e = db[key]
  if type(e) == "string" and C_EncodingUtil and C_EncodingUtil.DeserializeCBOR then
    local ok, t = pcall(C_EncodingUtil.DeserializeCBOR, e)
    if ok and type(t) == "table" then db[key] = t; e = t end
  end
  return type(e) == "table" and e or nil
end

local function lastDay(e)
  local best
  for d in pairs(e.h or {}) do d = tonumber(d); if d and (not best or d > best) then best = d end end
  return best
end

local function newestDay(db)
  local best = 0
  for key in pairs(db) do
    local e = type(db[key]) == "table" and db[key]
    if e then local d = lastDay(e); if d and d > best then best = d end end
  end
  return best
end

-- Write one price as Auctionator would for a scan on `day`.
local function writePrice(db, key, price, day)
  local e = entry(db, key)
  local dayKey = tostring(day)
  if not e then e = { l = {}, h = {}, a = {}, m = price }; db[key] = e end
  e.h = e.h or {}; e.l = e.l or {}
  local own = lastDay(e)
  if not own or day >= own then e.m = price end
  local hi = e.h[dayKey]
  if hi == nil or price > hi then e.h[dayKey] = price; hi = price end
  if price < hi and (e.l[dayKey] == nil or price < e.l[dayKey]) then e.l[dayKey] = price end
end

-- ---------------------------------------------------------------- encoding
local DIG = "0123456789abcdefghijklmnopqrstuvwxyz"
local function b36(n)
  n = math.floor(n); if n == 0 then return "0" end
  local s = ""; while n > 0 do local d = n % 36; s = DIG:sub(d + 1, d + 1) .. s; n = math.floor(n / 36) end
  return s
end

local LD = LibStub and LibStub("LibDeflate", true)

local function pack(text)
  if LD then return "L", LD:EncodeForWoWAddonChannel(LD:CompressDeflate(text, { level = 9 })) end
  if C_EncodingUtil and C_EncodingUtil.CompressString and C_EncodingUtil.EncodeBase64 then
    local ok, z = pcall(function() return C_EncodingUtil.EncodeBase64(C_EncodingUtil.CompressString(text)) end)
    if ok and z then return "Z", z end
  end
  return "R", text
end

local function unpack(kind, data)
  if kind == "Z" then return C_EncodingUtil.DecompressString(C_EncodingUtil.DecodeBase64(data)) end
  if kind == "L" then return LD:DecompressDeflate(LD:DecodeForWoWAddonChannel(data)) end
  return data
end

-- ---------------------------------------------------------------- send queue (throttle-aware)
local queue, ticker = {}, nil
local recentSent = {}   -- channel messages we sent recently (for echo detection)
local function pump()
  local m = queue[1]
  if not m then if ticker then ticker:Cancel(); ticker = nil end; return end
  local chan, target = "WHISPER", m[2]
  if target == "#channel" then
    local id = GetChannelName(CHANNEL)
    if not id or id == 0 then table.remove(queue, 1); return end
    chan, target = "CHANNEL", id
  end
  local r = C_ChatInfo.SendAddonMessage(PREFIX, m[1], chan, target)
  if r == nil or r == true or r == 0 then
    table.remove(queue, 1)
    if chan == "CHANNEL" then recentSent[m[1]] = GetTime() end
    L("->", chan == "CHANNEL" and "CH" or "W", chan == "CHANNEL" and "" or m[2], m[1])
    if m[3] then m[3]() end
  end
end
local function send(msg, target, onSent)
  -- control messages jump ahead of queued data chunks
  if msg:sub(1, 1) ~= "D" and msg:sub(1, 1) ~= "E" then table.insert(queue, 1, { msg, target, onSent })
  else queue[#queue + 1] = { msg, target, onSent } end
  if not ticker then pump(); if queue[1] then ticker = C_Timer.NewTicker(0.2, pump) end end
end

-- ---------------------------------------------------------------- protocol
-- H:<scan>:<newestDay>  hello        A:<scan>:<newestDay>  answer
-- R:<sinceDay>          request      D<seq>/<total><kind><data>  chunk      E:<scan>:<count>  end
local peers, incoming, sending = {}, nil, false

local function short(n) return (Ambiguate(n, "none") or n):lower() end

local sessionBlocked = {}
local function trusted(name)
  local s = short(name)
  return (DB.partner and short(DB.partner) == s) or (DB.trusted and DB.trusted[s]) or false
end
local function blocked(name)
  local s = short(name)
  return sessionBlocked[s] or (DB.blocked and DB.blocked[s] and true) or false
end

-- AH type of the last scan: "F" = your faction's AH, "N" = neutral (goblin) AH.
local currentAH
local function myAH() return DB.scanAH or "F" end
local function wantAH(t)
  t = (t == "N") and "N" or "F"
  local pref = DB.ahPref or "faction"
  return pref == "any" or (pref == "faction" and t == "F") or (pref == "neutral" and t == "N")
end
local function today()
  local day0 = Auctionator and Auctionator.Constants and Auctionator.Constants.SCAN_DAY_0
  return day0 and math.floor((time() - day0) / 86400) or nil
end

-- Own reference price: median of this account's recent daily highs, else the last price.
local function reference(e)
  if not e then return nil end
  local t = today()
  local vals = {}
  for d, p in pairs(e.h or {}) do
    d = tonumber(d)
    if type(p) == "number" and p > 0 and (not t or (d and d >= t - REF_DAYS)) then vals[#vals + 1] = p end
  end
  if #vals == 0 then return nil end
  table.sort(vals)
  return vals[math.floor((#vals + 1) / 2)]
end

local function haveTime() return math.max(scanTime(), DB.lastSync and DB.lastSync.scan or 0) end
local function isMe(name, msg)
  local me, s = short(UnitName("player") or ""), short(name)
  if s == me then return true end
  -- Forever names can carry a surname ("Mung Bean"); treat it as us only if it echoes our own message
  if s:sub(1, #me + 1) == me .. " " and msg and recentSent[msg] and GetTime() - recentSent[msg] < 10 then return true end
  return false
end

local function announce()
  local db = priceDB()
  if db and scanTime() > 0 then send(("N:%d:%d:%s"):format(scanTime(), newestDay(db), myAH()), "#channel") end
end

local function hello(target, answer)
  local db = priceDB()
  if not (target and db) then return end
  send(("%s:%d:%d:%s"):format(answer and "A" or "H", scanTime(), newestDay(db), myAH()), target)
end

local waiting = {}   -- requests queued while a transfer is running
local served = {}    -- short name -> last time we served them
local function sendData(target, since)
  local db = priceDB()
  if not db then return end
  if served[short(target)] and GetTime() - served[short(target)] < 120 then return end
  if sending then
    for _, w in ipairs(waiting) do if short(w[1]) == short(target) then return end end
    if #waiting >= 5 then return end
    waiting[#waiting + 1] = { target, since }
    send("W:" .. #waiting, target)
    return
  end
  local lines, n = {}, 0
  for key in pairs(db) do
    local e = type(key) == "string" and entry(db, key)
    if e and type(e.m) == "number" and e.m > 0 then
      local d = lastDay(e)
      if d and d >= since then
        lines[#lines + 1] = key .. "\t" .. b36(e.m) .. "\t" .. b36(d); n = n + 1
      end
    end
  end
  if n == 0 then
    send(("E:%d:0"):format(scanTime()), target)
    local nxt = table.remove(waiting, 1)
    if nxt then sendData(nxt[1], nxt[2]) end
    return
  end
  served[short(target)] = GetTime()
  local kind, data = pack(table.concat(lines, "\n"))
  local total = math.ceil(#data / CHUNK)
  sending = true
  P(("Sending %d prices to %s (%d messages)"):format(n, Ambiguate(target, "none"), total))
  for i = 1, total do
    send(("D%d/%d%s%s"):format(i, total, kind, data:sub((i - 1) * CHUNK + 1, i * CHUNK)), target)
  end
  send(("E:%d:%d"):format(scanTime(), n), target, function()
    sending = false
    local nxt = table.remove(waiting, 1)
    if nxt then sendData(nxt[1], nxt[2]) end
  end)
end

local function apply(text, scan, sender, ah)
  local db = priceDB()
  if not db then return 0, 0, 0 end
  local myScan, now = scanTime(), time()
  local isTrusted = trusted(sender)
  local t = today()
  DB.pending = DB.pending or {}

  -- parse + basic sanity
  local items = {}
  for key, m36, d36 in text:gmatch("([^\t\n]+)\t(%w+)\t(%w+)") do
    local price, day = tonumber(m36, 36), tonumber(d36, 36)
    if price and day and price > 0 and price < MAX_PRICE and #key < 64
       and (not t or (day <= t + 1 and day >= t - 60)) then
      items[#items + 1] = { key, price, day }
    end
  end

  -- poisoning guard: too many wild prices from one stranger -> reject everything.
  -- Only judged like-for-like: a neutral-AH scan is never compared against faction-AH prices.
  if not isTrusted and (ah or "F") == myAH() then
    local compared, wild = 0, 0
    for _, it in ipairs(items) do
      local ref = reference(entry(db, it[1]))
      if ref then
        compared = compared + 1
        local r = it[2] / ref
        if r > OUTLIER or r < 1 / OUTLIER then wild = wild + 1 end
      end
    end
    if compared >= MIN_COMPARED and wild / compared > POISON_SHARE then
      local s, now = short(sender), time()
      sessionBlocked[s] = true
      DB.strikes = DB.strikes or {}
      local st = DB.strikes[s]
      if not st or now - st.last > STRIKE_WINDOW then st = { n = 0 } end
      st.n, st.last = st.n + 1, now
      DB.strikes[s] = st
      if st.n >= STRIKES then
        DB.blocked[s] = { auto = true, at = now }
        P(("Auto-blocked %s for 30 days: %d bad transfers (%d of %d prices wrong). /scanshare unblock to undo"):format(Ambiguate(sender, "none"), st.n, wild, compared))
      else
        P(("Rejected data from %s: %d of %d prices look wrong (strike %d/%d)"):format(Ambiguate(sender, "none"), wild, compared, st.n, STRIKES))
      end
      return nil
    end
  end

  local written, skipped, held = 0, 0, 0
  local from = short(sender)
  for _, it in ipairs(items) do
    local key, price, day = it[1], it[2], it[3]
    local e = entry(db, key)
    local own = e and lastDay(e)
    if own and not (day > own or (day == own and scan > myScan)) then
      skipped = skipped + 1
    else
      local ok = isTrusted
      if not ok then
        local ref = reference(e)
        if ref then
          local r = price / ref
          ok = r <= OUTLIER and r >= 1 / OUTLIER
        end
        if not ok then
          -- held until a second, different sender reports a similar price
          local p = DB.pending[key]
          if p and p.from ~= from and now - p.at < 86400 and math.abs(price - p.price) <= CONFIRM_MATCH * p.price then
            ok = true; DB.pending[key] = nil
          else
            DB.pending[key] = { price = price, day = day, from = from, at = now }
            held = held + 1
          end
        end
      end
      if ok then writePrice(db, key, price, day); written = written + 1 end
    end
  end
  return written, skipped, held
end

local function requestFrom(sender, ah)
  if incoming then return end
  local db = priceDB()
  incoming = { from = sender, ah = (ah == "N") and "N" or "F", chunks = {}, got = 0, total = nil, started = GetTime(), active = GetTime(), patience = 45 }
  local mine = incoming
  send("R:" .. (db and newestDay(db) or 0), sender)
  local function check()
    if incoming ~= mine then return end
    if GetTime() - mine.active > mine.patience then
      incoming = nil
      P("Transfer from " .. Ambiguate(sender, "none") .. " stalled - /scanshare sync to retry")
    else
      C_Timer.After(10, check)
    end
  end
  C_Timer.After(10, check)
end

-- Public channel: N = "I have data from <scan>", Q = "anyone newer than <have>?"
local lastAnnounceSeen = 0
local lastHeard, lastAnswered = {}, 0
local function onChannel(msg, sender)
  if blocked(sender) then return end
  local kind = msg:sub(1, 1)
  local s = short(sender) .. kind
  if lastHeard[s] and GetTime() - lastHeard[s] < 60 then return end
  lastHeard[s] = GetTime()
  if kind == "N" then
    local their = tonumber(msg:match("^N:(%d+)")) or 0
    if their > time() + 3600 then return end
    local theirAH = msg:match("^N:%d+:%d+:(%a)")
    if not wantAH(theirAH) then return end
    if their > lastAnnounceSeen then lastAnnounceSeen = their end
    if their > haveTime() and not incoming then
      C_Timer.After(0.5 + math.random() * 2, function()
        if not incoming and their > haveTime() then requestFrom(sender, theirAH) end
      end)
    end
  elseif kind == "Q" then
    local their = tonumber(msg:match("^Q:(%d+)")) or 0
    if scanTime() > their and GetTime() - lastAnswered > 30 then
      lastAnswered = GetTime()
      local mine = scanTime()
      lastAnnounceSeen = 0
      C_Timer.After(1 + math.random() * 3, function()
        if lastAnnounceSeen < mine then announce() end   -- someone with equal/newer data already answered
      end)
    end
  end
end

local function onMessage(msg, sender)
  if blocked(sender) then return end
  local kind = msg:sub(1, 1)
  if kind == "H" or kind == "A" then
    peers[short(sender)] = sender
    local their, theirDay = msg:match("^%a:(%d+):(%d+)")
    their = tonumber(their) or 0
    if their > time() + 3600 then return end
    if kind == "H" then hello(sender, true) end
    local theirAH = msg:match("^%a:%d+:%d+:(%a)")
    if their > haveTime() and wantAH(theirAH) then requestFrom(sender, theirAH) end
  elseif kind == "W" then
    if incoming and short(incoming.from) == short(sender) then
      incoming.active = GetTime(); incoming.patience = 600
      if DB.debug then P("Queued at " .. Ambiguate(sender, "none") .. " (#" .. (msg:match("W:(%d+)") or "?") .. ")") end
    end
  elseif kind == "R" then
    sendData(sender, tonumber(msg:match("^R:(%d+)")) or 0)
  elseif kind == "D" then
    if not (incoming and short(incoming.from) == short(sender)) then return end
    local i, total, enc, data = msg:match("^D(%d+)/(%d+)(%a)(.*)$")
    i, total = tonumber(i), tonumber(total)
    if not i or total > MAX_CHUNKS or i > total then
      if total and total > MAX_CHUNKS then incoming = nil; P("Ignored oversized transfer from " .. Ambiguate(sender, "none")) end
      return
    end
    if not incoming.chunks[i] then incoming.got = incoming.got + 1 end
    incoming.active, incoming.patience = GetTime(), 45
    incoming.chunks[i], incoming.total, incoming.kind = data, total, enc
    if total >= 20 and i % 50 == 0 then P(("Receiving %d/%d"):format(incoming.got, total)) end
  elseif kind == "E" then
    if not (incoming and short(incoming.from) == short(sender)) then return end
    local scan, count = msg:match("^E:(%d+):(%d+)")
    scan, count = tonumber(scan), tonumber(count)
    if scan and scan > time() + 3600 then incoming = nil; return end
    local inc = incoming; incoming = nil
    if count == 0 then P("Already up to date"); return end
    if not inc.total or inc.got < inc.total then P(("Sync incomplete (%d/%d) - try /scanshare sync"):format(inc.got, inc.total or 0)); return end
    local ok, text = pcall(unpack, inc.kind, table.concat(inc.chunks))
    if not ok or not text then P("Couldn't decode data"); return end
    local written, skipped, held = apply(text, scan, sender, inc.ah)
    if not written then return end
    DB.lastSync = { from = Ambiguate(sender, "none"), at = time(), scan = scan, written = written }
    P(("Synced from %s: %d updated, %d already newer%s"):format(Ambiguate(sender, "none"), written, skipped,
      held > 0 and (", " .. held .. " held for confirmation") or ""))
  end
end

-- ---------------------------------------------------------------- events
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("CHAT_MSG_ADDON")
pcall(f.RegisterEvent, f, "AUCTION_HOUSE_SHOW")
pcall(f.RegisterEvent, f, "AUCTION_HOUSE_CLOSED")
f:SetScript("OnEvent", function(_, ev, a1, a2, a3, a4)
  if ev == "ADDON_LOADED" and a1 == ADDON then
    ScanShareDB = ScanShareDB or {}
    DB = ScanShareDB
    DB.trusted, DB.blocked, DB.pending = DB.trusted or {}, DB.blocked or {}, DB.pending or {}
    local cutoff = time() - 86400
    for k, p in pairs(DB.pending) do if p.at < cutoff then DB.pending[k] = nil end end
    for k, b in pairs(DB.blocked) do if type(b) == "table" and b.auto and time() - b.at > AUTOBLOCK_TIME then DB.blocked[k] = nil end end
    DB.strikes = DB.strikes or {}
    for k, st in pairs(DB.strikes) do if time() - st.last > STRIKE_WINDOW then DB.strikes[k] = nil end end
  elseif ev == "PLAYER_LOGIN" then
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    C_Timer.After(10, function() if DB.partner then hello(DB.partner) end end)
    if DB.public ~= false then
      C_Timer.After(6, function()
        JoinTemporaryChannel(CHANNEL)
        C_Timer.After(2, function()
          for i = 1, NUM_CHAT_WINDOWS or 10 do
            local cf = _G["ChatFrame" .. i]
            if cf and not DB.debug and ChatFrame_RemoveChannel then ChatFrame_RemoveChannel(cf, CHANNEL) end
          end
          if DB.debug and ChatFrame_AddChannel then ChatFrame_AddChannel(DEFAULT_CHAT_FRAME, CHANNEL) end
          send("Q:" .. haveTime(), "#channel")
        end)
      end)
    end
    local A = Auctionator and Auctionator.API and Auctionator.API.v1
    if A and A.RegisterForDBUpdate then
      pcall(A.RegisterForDBUpdate, "ScanShare", function()
        if incoming then return end   -- our own writes don't trigger a push
        if currentAH then DB.scanAH = currentAH end
        C_Timer.After(3, function()
          local sent = {}
          if DB.public ~= false then announce() end
          if DB.partner then hello(DB.partner); sent[short(DB.partner)] = true end
          for s, full in pairs(peers) do if not sent[s] then hello(full) end end
        end)
      end)
    end
  elseif ev == "AUCTION_HOUSE_SHOW" then
    local fac = UnitFactionGroup("npc")
    currentAH = (fac == "Alliance" or fac == "Horde") and "F" or "N"
  elseif ev == "AUCTION_HOUSE_CLOSED" then
    currentAH = nil
  elseif ev == "CHAT_MSG_ADDON" and a1 == PREFIX and a4 and not isMe(a4, a2) then
    if a3 == "WHISPER" then L("<-", "W", a4, a2); onMessage(a2, a4)
    elseif a3 == "CHANNEL" then L("<-", "CH", a4, a2); onChannel(a2, a4) end
  end
end)

-- Hide "No player named X is currently playing" caused by pinging an offline partner.
if ChatFrame_AddMessageEventFilter and ERR_CHAT_PLAYER_NOT_FOUND_S then
  ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", function(_, _, msg)
    if DB and DB.partner and msg == ERR_CHAT_PLAYER_NOT_FOUND_S:format(Ambiguate(DB.partner, "none")) then return true end
  end)
end

-- ---------------------------------------------------------------- slash
-- ---------------------------------------------------------------- API (slash + options panel)
local function age(t)
  if not t or t == 0 then return "never" end
  local m = math.floor((time() - t) / 60)
  if m < 1 then return "just now" elseif m < 60 then return m .. "m ago" elseif m < 1440 then return math.floor(m / 60) .. "h ago" end
  return math.floor(m / 1440) .. "d ago"
end
ns.Age = age
ns.GetDB = function() return DB end

function ns.Status()
  local id = GetChannelName(CHANNEL)
  local ls = DB.lastSync
  local held = 0
  for _ in pairs(DB.pending or {}) do held = held + 1 end
  return {
    channel = (id and id > 0) and id or nil,
    partner = DB.partner,
    ownScan = scanTime(),
    scanAH = myAH(),
    lastSync = ls,
    held = held,
    state = incoming and ("receiving " .. incoming.got .. "/" .. (incoming.total or "?") .. " from " .. Ambiguate(incoming.from, "none"))
      or (#queue > 0 and ("sending, " .. #queue .. " messages left")) or "idle",
  }
end

function ns.SyncNow()
  if DB.public ~= false then send("Q:" .. haveTime(), "#channel") end
  if DB.partner then hello(DB.partner) end
end

function ns.SetDebug(on)
  DB.debug = on and true or false
  if DB.debug then if ChatFrame_AddChannel then ChatFrame_AddChannel(DEFAULT_CHAT_FRAME, CHANNEL) end
  elseif ChatFrame_RemoveChannel then ChatFrame_RemoveChannel(DEFAULT_CHAT_FRAME, CHANNEL) end
end

function ns.SetPublic(on)
  DB.public = on and true or false
  if DB.public then JoinTemporaryChannel(CHANNEL) else LeaveChannelByName(CHANNEL) end
end

function ns.SetAH(pref) if pref == "faction" or pref == "neutral" or pref == "any" then DB.ahPref = pref end end

local function targetName(withRealm)
  if not (UnitExists("target") and UnitIsPlayer("target")) then return nil end
  local n, realm = UnitName("target")
  return (withRealm and realm and realm ~= "") and (n .. "-" .. realm) or n
end
ns.TargetName = targetName

function ns.SetPartner(name)
  if name == false then DB.partner = nil; return end
  name = (name and name ~= "") and name or targetName(true)
  if not name then return nil end
  DB.partner = name; hello(name)
  return name
end

-- list = "trusted" | "blocked"
function ns.SetListed(list, name, on)
  name = (name and name ~= "") and name or targetName(false)
  if not name then return nil end
  local s = short(name)
  DB[list][s] = on and true or nil
  if list == "blocked" and not on then sessionBlocked[s] = nil; DB.strikes[s] = nil end
  return Ambiguate(name, "none")
end

function ns.Lists()
  local function sorted(t) local r = {} for k, v in pairs(t or {}) do r[#r + 1] = { name = k, info = v } end table.sort(r, function(a, b) return a.name < b.name end) return r end
  return sorted(DB.trusted), sorted(DB.blocked), sorted(DB.strikes)
end

function ns.ClearHeld() DB.pending = {} end

-- ---------------------------------------------------------------- slash
SLASH_SCANSHARE1 = "/scanshare"
SlashCmdList.SCANSHARE = function(msg)
  local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)$")
  cmd = cmd:lower()
  if cmd == "" or cmd == "options" or cmd == "opt" then
    if ns.OpenOptions then ns.OpenOptions() end
  elseif cmd == "partner" then
    if rest:lower() == "clear" then ns.SetPartner(false); P("Partner cleared"); return end
    local n = ns.SetPartner(rest)
    P(n and ("Partner " .. n) or "Target your other character, then /scanshare partner")
  elseif cmd == "sync" then
    ns.SyncNow(); P("Checking for newer data")
  elseif cmd == "trust" or cmd == "untrust" or cmd == "block" or cmd == "unblock" then
    local list = (cmd == "trust" or cmd == "untrust") and "trusted" or "blocked"
    local n = ns.SetListed(list, rest, cmd == "trust" or cmd == "block")
    if not n then P("/scanshare " .. cmd .. " <name> (or target them)"); return end
    P(n .. " " .. (cmd == "trust" and "trusted" or cmd == "untrust" and "no longer trusted" or cmd == "block" and "blocked" or "unblocked"))
  elseif cmd == "ah" then
    ns.SetAH(rest)
    P("Accepting " .. (DB.ahPref or "faction") .. " AH data · your last scan: " .. (myAH() == "N" and "neutral" or "faction") .. " AH")
  elseif cmd == "debug" then
    ns.SetDebug(not DB.debug); P("Debug " .. (DB.debug and "on - channel shown, messages logged" or "off"))
  elseif cmd == "public" then
    ns.SetPublic(DB.public == false); P("Public channel " .. (DB.public and "on" or "off"))
  elseif cmd == "status" then
    local st = ns.Status()
    P(("channel %s · partner %s · own scan %s · last sync %s%s · %s"):format(st.channel and ("#" .. st.channel) or "off",
      st.partner or "none", age(st.ownScan), st.lastSync and age(st.lastSync.at) or "never",
      st.lastSync and (" from " .. st.lastSync.from .. " (" .. st.lastSync.written .. ")") or "", st.state))
  else
    P("/scanshare (options) · status · sync · ah faction/neutral/any · debug · public · partner [name|clear] · trust/untrust · block/unblock")
  end
end
