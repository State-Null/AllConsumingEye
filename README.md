# AllConsumingEye (`ACE`) — FFXI Multi-Bag Consumable Stock Tracker

An ultra-lightweight, zero-idle-overhead **Windower 4** addon for **Final Fantasy XI** that automatically reports in your FFXI chat log how many consumables remain across your **Inventory**, **Mog Satchel**, **Mog Case**, and **Mog Sack** every time you consume an item.

![AllConsumingEye In-Game Preview](preview.png)

```text
[ACE] Remedy: 34 remaining (Satchel: 34)
[ACE] Prism Powder: 20 remaining (Satchel: 20)
[ACE] Panacea: 35 remaining (Inv: 11 | Satchel: 24)
[ACE] Angon: 48 remaining (Wardrobe 3: 48)
[ACE] Silent Oil: 2 remaining (Satchel: 2) [LOW!]
```

---

## Key Features
* **Automatic Multi-Bag Consumable Readout (`Inventory` + `Mog Satchel` + `Mog Case` + `Mog Sack`)**:
  Whenever you finish using any consumable item (`Prism Powder`, `Silent Oil`, `Remedy`, `Panacea`, `Holy Water`, `Echo Drops`, `Icarus Wing`, `Food`, `Reraisers`, etc.), `ACE` prints your exact remaining total and per-bag breakdown directly to FFXI chat.
* **Color-Coded Stock Severity**:
  * **Neon Green (`> 12`)**: Healthy stock
  * **Amber / Gold (`4–12`)**: Moderate stock
  * **Coral Red (`1–3`)**: Appends `[LOW!]`
  * **Bright Red (`0`)**: Appends `[OUT OF STOCK!]`
* **Toolbag, Ammo Pouch & Card Case Reserve Awareness**:
  * Automatically checks `Inventory`, `Satchel`, `Case`, and `Sack` for matching unopened **Toolbags**, **Bullet Pouches**, and **Card Cases** (`[+7 Toolbags]`, `[+1 Pouch]`, `[+17 Cases]`).
  * When you unpack a Toolbag, Bullet Pouch, or Card Case, it reports **both** how many reserve bags remain **and** the new total of the unpacked item (`Unpacked -> Shihei: 137 remaining`).
* **Isolated Equippable JA Ammo Check (`Angon` & `Thr. Tomahawk` across `Wardrobe 1–8`)**:
  * Because `Angon` (DRG) and `Thr. Tomahawk` (WAR) are equippable `Weapon`-category ammo often stored in `Mog Wardrobe 1–8`, `ACE` provides a separate, optional 12-bag check (`Inv`, `Satchel`, `Case`, `Sack`, and `Wardrobe 1–8`).
  * Defaults to `OFF` so players who don't use those JAs never touch `Wardrobe 1–8`. Once toggled on via `//ace ja`, it saves permanently to `data/settings.xml` and tracks `Angon` & `Thr. Tomahawk` full-time across JA uses and `//ace` audits.
* **Corsair Quick Draw & Optional Ninjutsu Tracking**:
  * Reports remaining `Trump Cards` (`+Cases`) after Corsair Quick Draw (`ON` by default).
  * Optional per-cast Ninja Tool tracking (`OFF` by default to avoid Utsusemi/wheel spam; toggleable via `//ace nin`), while cracking a **Toolbag** always reports your remaining Toolbags and unpacked tool total.
* **Cross-Box Multibox IPC Support (Default `OFF`, Toggleable & Auto-Synced)**:
  * Enable with `//ace ipc` (or `//ace ipc 5`) to receive low-stock alerts (`[ACE:PlayerTwo] Silent Oil: 2 remaining [LOW!]`) across your multibox clients, or run `//ace party <item>` to query all logged-in characters at once.

---

## Performance & Optimization Architecture
1. **Zero `prerender` & Zero GearSwap Packet Hooks**: No 60 FPS loop and no hooks on `0x01F`/`0x020` inventory packets (which fire ~48 times per spell cast during GearSwap). Idle CPU usage is `0%`.
2. **2-Nanosecond Raw 4-Byte Actor Filter**: Reads the 32-bit little-endian `actor_id` directly from bytes `6..9` of incoming `0x028` action chunks before calling `windower.packets.parse_action`, ignoring 99%+ of monster/alliance battle packets with zero Lua table allocations.
3. **Isolated Two-Tier Bag Scanner**: Standard consumables scan only the 4 general bags (`320` max slots) and never touch the `640` equipment slots in `Mog Wardrobe 1–8`. The 12-bag Wardrobe scan is strictly isolated to `Angon` (`JA 170`) and `Tomahawk` (`JA 150`).
4. **Pre-Use Snapshot + Post-Use Verification**: Captures `pending_pre_total` on `Category 9` (Item Use Begin) and verifies post-consumption stock on `Category 5` (Item Use Finish), eliminating the classic FFXI off-by-one bug when `0x028` arrives ahead of `0x020`.

---

## Installation
1. Click **Code** $\rightarrow$ **Download ZIP** (or clone this repository).
2. Extract into `Windower4/addons/AllConsumingEye/` so `Windower4/addons/AllConsumingEye/AllConsumingEye.lua` exists.
3. Load in-game:
   ```text
   //lua l allconsumingeye
   ```
   *(To auto-load on startup, add `lua l AllConsumingEye;` to `Windower4/scripts/init.txt`.)*

---

## Commands (`//ace`, `//eye`, or `//allconsumingeye`)

| Command | Description |
| :--- | :--- |
| `//ace` | Prints a full alphabetized audit of all consumables across `Inv`, `Satchel`, `Case`, and `Sack` *(+ `Wardrobe 1–8` for `Angon`/`Tomahawk`)* |
| `//ace low [N]` | Lists only consumables at or below the warning threshold *(default `<= 12`)* |
| `//ace <name>` | Instant substring search *(e.g. `//ace prism`, `//ace oil`, `//ace angon`, `//ace tomahawk`)* |
| `//ace party <query>` | Queries all logged-in characters over IPC *(e.g. `//ace party prism`, `//ace party low`)* |
| `//ace ipc [on\|off\|N]` | Toggles Cross-Box IPC low-stock alerts ON/OFF or sets threshold *(default `OFF`, `<= 5`)*; auto-syncs across clients |
| `//ace ipcall` | Toggles broadcasting **every** consumable use over IPC vs. low-stock only |
| `//ace bags` | Toggles the `(Inv: X \| Satchel: Y \| Case: Z \| Sack: W)` breakdown on/off |
| `//ace ja [on\|off]` | Toggles full-time `Angon` & `Thr. Tomahawk` (`Wardrobe 1–8`) tracking *(default `OFF`; saved permanently once toggled `ON`)* |
| `//ace nin` / `//ace qd` | Toggles Ninjutsu tool *(default `OFF`)* or Corsair Quick Draw card *(default `ON`)* announcements |
| `//ace help` | Displays the in-game command summary |
