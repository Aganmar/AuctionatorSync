# Changelog

## 0.7.3
- No more freeze when someone requests your prices: data is compressed with the game's built-in compression (near-instant) instead of in Lua, and the price list is built over several frames. Still compatible with earlier 0.7 versions.

## 0.7.2
- Fixed: price data went out in one burst instead of being paced, which could disconnect you after a scan. Sending is now limited to 2 messages a second, so a full sync takes about a minute.

## 0.7.1
- A scan is only shared once Auctionator has finished it. Before, other players could sync while your scan was still running and get your old prices marked with the new scan's time.
- Auctionator's full (replicate) scans now count as scans too.
- Price data is held while Auctionator is scanning and resumes when the scan ends, to avoid disconnects during scans. Your own scans also don't start pulling data from others.
- Sends at half the previous rate (about 0.5 KB/s).

## 0.7.0
- New message channel and saved-settings format. Earlier versions don't sync with 0.7.0, so update every character.

## 0.6.0
- **Sync with:** everyone (realm channel), guild only, or partner & trusted only. Your partner and trusted characters are always included.
- **Pauses in instances:** dungeons, raids, battlegrounds, arenas and scenarios (on by default). While paused it neither listens nor sends.
- Answers arrive on the same channel the question was asked on (fixes guild-only mode).
- Options page: sync scope and instance pause settings.
- Add-on icon in the in-game AddOns list.
- Licensed under GPL-3.0.

## 0.5.0
- Options page (*Options → AddOns → ScanShare*, or `/scanshare`) with status, settings, partner, trusted and blocked lists.
- EllesmereUI styling when installed.

## 0.4.0
- Neutral (goblin) AH support: scans are tagged faction or neutral; choose which you accept.
- Data poisoning protection with automatic blocking.

## 0.3.0
- Trust and block lists.

## 0.2.0
- Public channel: other users are found automatically; one answer per query; queued transfers.
- `/scanshare debug` shows the channel and logs every message.

## 0.1.0
- First version: partner sync of the full Auctionator price database, compressed delta transfers.
