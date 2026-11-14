<p align="center"><img src="Media/ScanShare_400.png" width="128" alt="ScanShare icon"></p>

<h1 align="center">ScanShare</h1>

Share [Auctionator](https://www.curseforge.com/wow/addons/auctionator) auction house prices between players in **World of Warcraft: Forever** — so everyone's price data stays fresh even on days they don't scan.

When anyone running ScanShare scans the AH, other users on the same realm and faction can pull those prices into their own Auctionator database automatically. Everything travels over WoW's hidden addon-message system; nothing appears in chat.

## Features

- **Choose who you sync with**
  - *Everyone* – a hidden realm/faction channel finds other users automatically;
  - *Guild only* – announcements over the guild addon channel, guild members only;
  - *Partner & trusted only* – no channel; talks directly to your partner and trusted list.
  Your partner and trusted characters are always included.
- **Partner mode** – optionally sync directly with one character (e.g. your bank alt).
- **Pauses in instances** – in dungeons, raids, battlegrounds, arenas and scenarios it stops listening and sending entirely (on by default).
- **Delta, compressed transfers** – only items seen since your newest data are sent (LibDeflate).
- **Your scans win** – an incoming price is written only if it is newer than what you already have, dated to the day it was actually scanned.
- **Neutral AH aware** – scans are tagged faction or neutral (goblin) AH; choose which you accept.
- **Data poisoning protection**
- **Rate limited** – throttle-aware send queue, request queueing and flood limits on the channel.
- **Options page** – *Options → AddOns → ScanShare* (or `/scanshare`), with EllesmereUI styling when installed.

## Install

Copy the `ScanShare` folder into `World of Warcraft\_forever_\Interface\AddOns\` and restart the game. Requires Auctionator.

## Commands

| Command | |
|---|---|
| `/scanshare` | Open the options page |
| `/scanshare status` | Channel, scan age, last sync, transfer progress |
| `/scanshare sync` | Ask for newer data now |
| `/scanshare scope public\|guild\|trusted` | Who to sync with |
| `/scanshare ah faction\|neutral\|any` | Which AH's data to accept |
| `/scanshare instances` | Toggle pausing in dungeons / raids / battlegrounds |
| `/scanshare partner [name\|clear]` | Direct sync partner (or target them) |
| `/scanshare trust` / `untrust` `[name]` | Skip price checks for a player |
| `/scanshare block` / `unblock` `[name]` | Never accept data from a player |
| `/scanshare debug` | Show the channel and log every message |

## How it works

| Message | Sent on | Meaning |
|---|---|---|
| `Q:<have>` | channel / guild / whisper | "Anyone have data newer than this?" (on login / Sync now) |
| `N:<scan>:<day>:<ah>` | channel / guild / whisper | "I have data from this scan" (after a scan, or answering a query on the same medium) |
| `H` / `A` | whisper | Partner hello / answer |
| `R:<since>` | whisper | Request items seen since a day |
| `W:<pos>` | whisper | You're queued |
| `D<i>/<n><enc><data>` | whisper | Compressed data chunk |
| `E:<scan>:<count>` | whisper | End of transfer |

Only one player answers a query (others stay quiet once an equal or newer scan has been announced), and data always goes by whisper, never over the shared channel.

## License

ScanShare is free software under the [GNU General Public License v3.0](LICENSE).

## Credits

- [LibDeflate](https://github.com/SafeteeWoW/LibDeflate) by Haoqian He — zlib License (see `Libs/LibDeflate/LICENSE.txt`).
