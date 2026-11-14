-- ScanShare options page (Settings > AddOns > ScanShare, or /scanshare)
local _, ns = ...

local panel = CreateFrame("Frame")
panel.name = "ScanShare"
panel:Hide()

local skin
local widgets = { buttons = {}, checks = {}, boxes = {}, fonts = {} }
local function font(fs) widgets.fonts[#widgets.fonts + 1] = fs; if skin then skin.Font(fs) end; return fs end

local function text(parent, template, x, y, str)
  local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
  fs:SetPoint("TOPLEFT", x, y); fs:SetJustifyH("LEFT")
  if str then fs:SetText(str) end
  return font(fs)
end

local function button(parent, label, w, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w or 90, 22); b:SetText(label)
  b:SetScript("OnClick", onClick)
  widgets.buttons[#widgets.buttons + 1] = b
  if skin then skin.Button(b) end
  return b
end

local function check(parent, label, x, y, get, set)
  local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  cb:SetSize(24, 24); cb:SetPoint("TOPLEFT", x, y)
  local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  fs:SetPoint("LEFT", cb, "RIGHT", 2, 1); fs:SetText(label); font(fs)
  cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false); panel.Refresh() end)
  cb.get = get
  widgets.checks[#widgets.checks + 1] = cb
  if skin then skin.Checkbox(cb) end
  return cb
end

local function editbox(parent, w)
  local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  eb:SetSize(w or 160, 20); eb:SetAutoFocus(false)
  eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  widgets.boxes[#widgets.boxes + 1] = eb
  if skin then skin.EditBox(eb) end
  return eb
end

-- ---------------------------------------------------------------- layout
local L, C = 16, 330          -- left / right column x
local y = -16

text(panel, "GameFontNormalLarge", L, y, "ScanShare"); y = y - 22
text(panel, "GameFontDisableSmall", L, y, "Shares Auctionator prices with other players over a hidden channel. Your own newer scans are never overwritten."); y = y - 26

-- Status
text(panel, "GameFontNormal", L, y, "Status"); y = y - 20
local statusLines = {}
for i = 1, 5 do statusLines[i] = text(panel, "GameFontHighlightSmall", L + 8, y - (i - 1) * 16) end
local yStatus = y
y = y - 5 * 16 - 6
local syncBtn = button(panel, "Sync now", 100, function() ns.SyncNow(); C_Timer.After(0.5, panel.Refresh) end)
syncBtn:SetPoint("TOPLEFT", L + 8, y)
local clearHeld = button(panel, "Clear held", 100, function() ns.ClearHeld(); panel.Refresh() end)
clearHeld:SetPoint("LEFT", syncBtn, "RIGHT", 8, 0)
y = y - 36

-- Settings
text(panel, "GameFontNormal", L, y, "Settings"); y = y - 22
check(panel, "Public channel (find other players automatically)", L + 4, y, function() return ns.GetDB().public ~= false end, ns.SetPublic); y = y - 26
check(panel, "Debug (show the channel and log every message in chat)", L + 4, y, function() return ns.GetDB().debug end, ns.SetDebug); y = y - 32

text(panel, "GameFontHighlight", L + 8, y - 4, "Accept AH data from:")
local ahChecks = {}
for i, opt in ipairs({ { "faction", "Faction AH" }, { "neutral", "Neutral AH" }, { "any", "Any" } }) do
  ahChecks[i] = check(panel, opt[2], L + 150 + (i - 1) * 110, y, function() return (ns.GetDB().ahPref or "faction") == opt[1] end,
    function() ns.SetAH(opt[1]) end)
end
y = y - 36

-- Partner
text(panel, "GameFontNormal", L, y, "Partner"); y = y - 18
text(panel, "GameFontDisableSmall", L + 8, y, "Optional: one character you always sync with directly (e.g. your bank alt)."); y = y - 20
local partnerBox = editbox(panel, 160); partnerBox:SetPoint("TOPLEFT", L + 14, y)
local pSet = button(panel, "Set", 60, function() ns.SetPartner(partnerBox:GetText()); partnerBox:SetText(""); partnerBox:ClearFocus(); panel.Refresh() end)
pSet:SetPoint("LEFT", partnerBox, "RIGHT", 8, 0)
local pTarget = button(panel, "Use target", 90, function() ns.SetPartner(nil); panel.Refresh() end)
pTarget:SetPoint("LEFT", pSet, "RIGHT", 6, 0)
local pClear = button(panel, "Clear", 60, function() ns.SetPartner(false); panel.Refresh() end)
pClear:SetPoint("LEFT", pTarget, "RIGHT", 6, 0)
local partnerText = text(panel, "GameFontHighlightSmall", L + 8, y - 26)
y = y - 52

-- Lists (two columns)
local MAXROWS = 8
local function listBlock(x, y0, title, hint, list)
  local block = { rows = {} }
  text(panel, "GameFontNormal", x, y0, title)
  text(panel, "GameFontDisableSmall", x + 8, y0 - 18, hint)
  local eb = editbox(panel, 130); eb:SetPoint("TOPLEFT", x + 14, y0 - 38)
  local add = button(panel, "Add", 50, function() ns.SetListed(list, eb:GetText(), true); eb:SetText(""); eb:ClearFocus(); panel.Refresh() end)
  add:SetPoint("LEFT", eb, "RIGHT", 8, 0)
  local tgt = button(panel, "Target", 60, function() ns.SetListed(list, nil, true); panel.Refresh() end)
  tgt:SetPoint("LEFT", add, "RIGHT", 4, 0)
  for i = 1, MAXROWS do
    local r = CreateFrame("Frame", nil, panel)
    r:SetSize(290, 20); r:SetPoint("TOPLEFT", x + 8, y0 - 64 - (i - 1) * 22)
    r.label = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); r.label:SetPoint("LEFT", 0, 0); font(r.label)
    r.remove = button(r, "Remove", 70, function() ns.SetListed(list, r.name, false); panel.Refresh() end)
    r.remove:SetPoint("RIGHT", 0, 0)
    block.rows[i] = r
  end
  block.more = text(panel, "GameFontDisableSmall", x + 8, y0 - 64 - MAXROWS * 22)
  block.empty = text(panel, "GameFontDisableSmall", x + 8, y0 - 66, "None")
  return block
end
local trustedBlock = listBlock(L, y, "Trusted", "Skip price checks (your own characters).", "trusted")
local blockedBlock = listBlock(C, y, "Blocked", "Never accepted. Auto-blocks expire after 30 days.", "blocked")

-- ---------------------------------------------------------------- refresh
local function fillList(block, entries, describe)
  for i, r in ipairs(block.rows) do
    local e = entries[i]
    if e then r.name = e.name; r.label:SetText(describe(e)); r:Show() else r:Hide() end
  end
  block.empty:SetShown(#entries == 0)
  block.more:SetText(#entries > MAXROWS and ("and " .. (#entries - MAXROWS) .. " more") or "")
end

function panel.Refresh()
  local DB = ns.GetDB and ns.GetDB()
  if not DB or not panel:IsShown() then return end
  local st = ns.Status()
  local ls = st.lastSync
  statusLines[1]:SetText("Channel: " .. (st.channel and ("|cff40c040joined|r (#" .. st.channel .. ")") or "|cff808080off|r"))
  statusLines[2]:SetText("Your last scan: " .. ns.Age(st.ownScan) .. (st.ownScan > 0 and (" · " .. (st.scanAH == "N" and "neutral" or "faction") .. " AH") or ""))
  statusLines[3]:SetText("Last sync: " .. (ls and (ns.Age(ls.at) .. " from " .. ls.from .. " · " .. ls.written .. " prices") or "never"))
  statusLines[4]:SetText("Transfer: " .. st.state)
  statusLines[5]:SetText("Held for confirmation: " .. st.held .. " prices")
  clearHeld:SetEnabled(st.held > 0)
  partnerText:SetText("Current partner: " .. (st.partner or "|cff808080none|r"))
  for _, cb in ipairs(widgets.checks) do cb:SetChecked(cb.get() and true or false) end

  local trusted, blocked, strikes = ns.Lists()
  fillList(trustedBlock, trusted, function(e) return e.name end)
  -- show strikes for not-yet-blocked senders in the blocked list too
  local isBlocked = {}
  for _, e in ipairs(blocked) do isBlocked[e.name] = true end
  local rows = {}
  for _, e in ipairs(blocked) do rows[#rows + 1] = e end
  for _, e in ipairs(strikes) do if not isBlocked[e.name] then rows[#rows + 1] = { name = e.name, strike = e.info } end end
  fillList(blockedBlock, rows, function(e)
    if e.strike then return e.name .. " |cffffd100(" .. e.strike.n .. " strike, " .. ns.Age(e.strike.last) .. ")|r" end
    if type(e.info) == "table" and e.info.auto then
      local left = math.max(0, math.ceil((e.info.at + 30 * 86400 - time()) / 86400))
      return e.name .. " |cffff6060(auto, " .. left .. "d left)|r"
    end
    return e.name .. " |cff808080(manual)|r"
  end)
end

local ticker
panel:SetScript("OnShow", function()
  panel.Refresh()
  if not ticker then ticker = C_Timer.NewTicker(1, panel.Refresh) end
end)
panel:SetScript("OnHide", function() if ticker then ticker:Cancel(); ticker = nil end end)

-- ---------------------------------------------------------------- register
if Settings and Settings.RegisterCanvasLayoutCategory then
  local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
  Settings.RegisterAddOnCategory(category)
  ns.OpenOptions = function() Settings.OpenToCategory(category:GetID()) end
elseif InterfaceOptions_AddCategory then
  InterfaceOptions_AddCategory(panel)
  ns.OpenOptions = function() InterfaceOptionsFrame_OpenToCategory(panel); InterfaceOptionsFrame_OpenToCategory(panel) end
end

-- EllesmereUI look, if installed
if EllesmereUI and EllesmereUI.RegisterSkin then
  EllesmereUI.RegisterSkin("ScanShare", function(S)
    skin = S
    for _, b in ipairs(widgets.buttons) do S.Button(b) end
    for _, c in ipairs(widgets.checks) do S.Checkbox(c) end
    for _, e in ipairs(widgets.boxes) do S.EditBox(e) end
    for _, f in ipairs(widgets.fonts) do S.Font(f) end
  end)
end
