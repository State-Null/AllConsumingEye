--[[
    The All Consuming Eye (AllConsumingEye.lua) - v1.2.0
    Ultra-Low-Overhead Consumable & Multi-Bag Stock Tracker for FFXI (Windower 4)

    Automatically announces in FFXI chat how many consumables remain across:
      - Inventory   (Bag 0)
      - Mog Satchel (Bag 5)
      - Mog Case    (Bag 7)
      - Mog Sack    (Bag 6)
    whenever you use a consumable item (Prism Powder, Silent Oil, Remedy, Panacea,
    Holy Water, Echo Drops, Food, Icarus Wing, Reraisers, Toolbags, Ammo Pouches, etc.),
    plus optional Corsair Quick Draw Trump Card, Ninjutsu tool, DRG Angon / WAR Tomahawk
    (including Mog Wardrobes 1..8), and Cross-Box IPC alerts.

    Performance & Optimization Architecture:
      1. Zero-Cost Idle (No 60 FPS prerender loop, no 0x01F/0x020 gearswap packet hooks).
      2. 2-Nanosecond Raw 4-Byte Actor Filter on 0x028: Reads `actor_id` directly from
         bytes 6..9 of incoming 0x028 chunks before invoking `parse_action`, ignoring
         99%+ of monster/alliance battle packets with zero table allocations.
      3. Pre-Use Snapshot + Post-Use Verification: Captures pre-consumption stock on
         Category 9 (Item Use Begin) and verifies post-consumption stock after Category 5
         (Item Use Finish), eliminating 0x028-vs-0x020 packet ordering off-by-one bugs.
      4. Isolated Two-Tier Bag Scanner:
         - Standard consumables scan ONLY the 4 general bags (Inv, Satchel, Case, Sack),
           never touching the 640 equipment slots in Mog Wardrobes 1..8.
         - Equippable JA Ammo (DRG `Angon` & WAR `Thr. Tomahawk`) uses a dedicated,
           optional 12-bag check (Inv, Satchel, Case, Sack + Wardrobe 1..8) triggered
           strictly on JA IDs 150/170 (`//ace ja` to toggle).
      5. Cross-Box IPC Alerts (Default OFF, Toggleable & Configurable): Synchronizes
         low-stock alerts and on-demand `//ace party <item>` audits across multibox clients
         using pure-ASCII IPC frames formatted with native FFXI 0x1E/0x1F chat color bytes.

    Strictly read-only packet inspection (Invariant 1 compliant).
]]

_addon.name     = 'AllConsumingEye'
_addon.author   = 'State-Null'
_addon.version  = '1.2.2'
_addon.commands = {'ace', 'allconsumingeye', 'eye', 'consumables'}

require('luau')
local bit    = require('bit')
local config = require('config')
local res    = require('resources')

-- Localize hot standard library, BitOp & Windower C-API functions into upvalues
local b_band         = bit.band
local b_rshift       = bit.rshift
local s_byte         = string.byte
local s_char         = string.char
local s_format       = string.format
local s_lower        = string.lower
local s_find         = string.find
local s_sub          = string.sub
local t_concat       = table.concat
local t_sort         = table.sort
local tonumber       = tonumber
local tostring       = tostring
local math_max       = math.max
local os_clock       = os.clock
local add_to_chat    = windower.add_to_chat
local send_ipc       = windower.send_ipc_message
local get_items      = windower.ffxi.get_items
local get_bag_info   = windower.ffxi.get_bag_info
local get_player     = windower.ffxi.get_player
local parse_action   = windower.packets.parse_action

-- -----------------------------------------------------------------------------
-- Default Settings (Saved to addons/AllConsumingEye/data/settings.xml)
-- -----------------------------------------------------------------------------
local defaults = {
    show_bag_breakdown = true,  -- Show (Inv: X | Satchel: Y | Case: Z | Sack: W)
    show_containers    = true,  -- Append [+N Toolbag/Pouch/Case] when reserve bags exist
    track_ninjutsu     = false, -- Report remaining Ninja Tools after Ninjutsu casts (Default OFF)
    track_quickdraw    = true,  -- Report remaining Trump Cards after Quick Draw (Default ON)
    track_ja_ammo      = false, -- Report Angon / Thr. Tomahawk across Inv..Sack + Wardrobe 1..8 (Default OFF; persistent full-time once toggled ON)
    ipc_alerts         = false, -- Cross-box IPC low-stock alerts (Default OFF)
    ipc_all_uses       = false, -- Broadcast every consumable use over IPC (Default OFF)
    ipc_threshold      = 5,     -- Remaining count threshold that triggers an IPC alert
    warn_threshold     = 12,    -- Amber warning threshold
    low_threshold      = 3,     -- Coral Red [LOW!] alert threshold
    chat_color         = 207,   -- Windower chat mode color
}

local settings = config.load(defaults)

-- -----------------------------------------------------------------------------
-- Two-Tier Bag Definitions:
--   1..4  (NUM_STD_BAGS = 4):  Inventory (0), Satchel (5), Case (7), Sack (6)
--   5..12 (NUM_ALL_BAGS = 12): Wardrobe (8), Wardrobe 2..8 (10..16)
-- Standard consumables ONLY scan 1..4; Equippable JA Ammo scans 1..12.
-- -----------------------------------------------------------------------------
local ALL_BAGS = {
    -- Tier 1: General Consumable Bags (1..4)
    { id = 0,  label = 'Inv'        },
    { id = 5,  label = 'Satchel'    },
    { id = 7,  label = 'Case'       },
    { id = 6,  label = 'Sack'       },
    -- Tier 2: Equippable Wardrobe Bags (5..12) - Only scanned for Angon / Tomahawk
    { id = 8,  label = 'Wardrobe'   },
    { id = 10, label = 'Wardrobe 2' },
    { id = 11, label = 'Wardrobe 3' },
    { id = 12, label = 'Wardrobe 4' },
    { id = 13, label = 'Wardrobe 5' },
    { id = 14, label = 'Wardrobe 6' },
    { id = 15, label = 'Wardrobe 7' },
    { id = 16, label = 'Wardrobe 8' },
}
local NUM_STD_BAGS = 4
local NUM_ALL_BAGS = #ALL_BAGS

-- Authentic FFXI Chat Log Control Bytes (0x1F / 0x1E) for `windower.add_to_chat`
local COL_RESET  = s_char(0x1E, 0x01)
local COL_HEADER = s_char(0x1F, 207) -- Cyan/Sky Blue [ACE]
local COL_IPC    = s_char(0x1F, 219) -- Lavender/Violet [ACE:Char]
local COL_ITEM   = s_char(0x1F, 1)   -- Crisp White item name
local COL_GOOD   = s_char(0x1E, 2)   -- Neon Green (color 258) for > 12 remaining
local COL_WARN   = s_char(0x1E, 3)   -- Amber/Gold (color 259) for 4..12 remaining
local COL_LOW    = s_char(0x1F, 167) -- Coral Red (color 167) for 1..3 remaining
local COL_ZERO   = s_char(0x1F, 167) -- Bright Red (color 167) for 0 remaining
local COL_BAG    = s_char(0x1F, 160) -- Soft Silver/Grey for (Satchel: X)
local COL_POUCH  = s_char(0x1F, 207) -- Cyan for [+N Toolbags]

-- -----------------------------------------------------------------------------
-- O(1) Container / Toolbag / Pouch Lookup Tables
-- -----------------------------------------------------------------------------
local ITEM_TO_CONTAINER = {
    -- Ninja Tools -> Toolbags
    [1161] = { id = 5308, label = 'Toolbag' }, -- Uchitake -> Toolbag (Uchi)
    [1164] = { id = 5309, label = 'Toolbag' }, -- Tsurara -> Toolbag (Tsura)
    [1167] = { id = 5310, label = 'Toolbag' }, -- Kawahori-Ogi -> Toolbag (Kawa)
    [1170] = { id = 5311, label = 'Toolbag' }, -- Makibishi -> Toolbag (Maki)
    [1173] = { id = 5312, label = 'Toolbag' }, -- Hiraishin -> Toolbag (Hira)
    [1176] = { id = 5313, label = 'Toolbag' }, -- Mizu-Deppo -> Toolbag (Mizu)
    [1179] = { id = 5314, label = 'Toolbag' }, -- Shihei -> Toolbag (Shihe)
    [1182] = { id = 5315, label = 'Toolbag' }, -- Jusatsu -> Toolbag (Jusa)
    [1185] = { id = 5316, label = 'Toolbag' }, -- Kagina-Kuri -> Toolbag (Kagi)
    [1188] = { id = 5317, label = 'Toolbag' }, -- Sairui-Ran -> Toolbag (Sai)
    [1191] = { id = 5318, label = 'Toolbag' }, -- Kodoku -> Toolbag (Kodo)
    [1194] = { id = 5319, label = 'Toolbag' }, -- Shinobi-Tabi -> Toolbag (Shino)
    [2553] = { id = 5417, label = 'Toolbag' }, -- Sanjaku-Tenugui -> Toolbag (Sanja)
    [2555] = { id = 5734, label = 'Toolbag' }, -- Soshi -> Toolbag (Soshi)
    [2642] = { id = 5863, label = 'Toolbag' }, -- Kabura-Ya -> Toolbag (Kabu)
    [2643] = { id = 5864, label = 'Toolbag' }, -- Jinko -> Toolbag (Jinko)
    [2644] = { id = 5865, label = 'Toolbag' }, -- Ryuno -> Toolbag (Ryuno)
    [2970] = { id = 5866, label = 'Toolbag' }, -- Mokujin -> Toolbag (Moku)
    [8803] = { id = 6265, label = 'Toolbag' }, -- Ranka -> Toolbag (Ranka)
    [8804] = { id = 6266, label = 'Toolbag' }, -- Furusumi -> Toolbag (Furu)
    -- Universal Ninja Tools -> Toolbags
    [2971] = { id = 5867, label = 'Toolbag' }, -- Inoshishinofuda -> Toolbag (Ino)
    [2972] = { id = 5868, label = 'Toolbag' }, -- Shikanofuda -> Toolbag (Shika)
    [2973] = { id = 5869, label = 'Toolbag' }, -- Chonofuda -> Toolbag (Cho)
    -- Corsair Cards -> Card Cases
    [2974] = { id = 5870, label = 'Case'    }, -- Trump Card -> Trump Card Case
    [2176] = { id = 5408, label = 'Case'    }, -- Fire Card -> Fire Card Case
    [2177] = { id = 5409, label = 'Case'    }, -- Ice Card -> Ice Card Case
    [2178] = { id = 5410, label = 'Case'    }, -- Wind Card -> Wind Card Case
    [2179] = { id = 5411, label = 'Case'    }, -- Earth Card -> Earth Card Case
    [2180] = { id = 5412, label = 'Case'    }, -- Thunder Card -> Thunder Card Case
    [2181] = { id = 5413, label = 'Case'    }, -- Water Card -> Water Card Case
    [2182] = { id = 5414, label = 'Case'    }, -- Light Card -> Light Card Case
    [2183] = { id = 5415, label = 'Case'    }, -- Dark Card -> Dark Card Case
    -- REMA Bullets -> Waist Pouches
    [21324] = { id = 26350, label = 'Pouch'  }, -- Chrono Bullet -> Chr. Bul. Pouch
    [21323] = { id = 26348, label = 'Pouch'  }, -- Living Bullet -> Liv. Bul. Pouch
    [21322] = { id = 26349, label = 'Pouch'  }, -- Devastating Bullet -> Dev. Bul. Pouch
    [21321] = { id = 26347, label = 'Pouch'  }, -- Eradicating Bullet -> Era. Bul. Pouch
}

-- Ninjutsu Spell ID -> { specific_tool_id, universal_tool_id }
local NINJUTSU_TOOLS = {
    [320] = { 1161, 2971 }, [321] = { 1161, 2971 }, [322] = { 1161, 2971 },
    [323] = { 1164, 2971 }, [324] = { 1164, 2971 }, [325] = { 1164, 2971 },
    [326] = { 1167, 2971 }, [327] = { 1167, 2971 }, [328] = { 1167, 2971 },
    [329] = { 1170, 2971 }, [330] = { 1170, 2971 }, [331] = { 1170, 2971 },
    [332] = { 1173, 2971 }, [333] = { 1173, 2971 }, [334] = { 1173, 2971 },
    [335] = { 1176, 2971 }, [336] = { 1176, 2971 }, [337] = { 1176, 2971 },
    [338] = { 1179, 2972 }, [339] = { 1179, 2972 }, [340] = { 1179, 2972 },
    [341] = { 1182, 2973 }, [342] = { 1182, 2973 }, [343] = { 1182, 2973 },
    [344] = { 1185, 2973 }, [345] = { 1185, 2973 }, [346] = { 1185, 2973 },
    [347] = { 1188, 2973 }, [348] = { 1188, 2973 }, [349] = { 1188, 2973 },
    [350] = { 1191, 2973 }, [351] = { 1191, 2973 }, [352] = { 1191, 2973 },
    [353] = { 1194, 2972 }, [354] = { 1194, 2972 }, [355] = { 1194, 2972 },
    [318] = { 2553, 2972 },
    [319] = { 2555, 2973 },
    [507] = { 2642, 2972 },
    [508] = { 2643, 2973 },
    [509] = { 2644, 2972 },
    [510] = { 2970, 2972 },
    [505] = { 8803, 2972 },
    [506] = { 8804, 2972 },
}

-- Corsair Quick Draw Job Ability IDs (195..202) -> Card ID (General Bags 1..4)
local QUICK_DRAW_CARDS = {
    [195] = 2176, -- Fire Shot -> Fire Card
    [196] = 2177, -- Ice Shot -> Ice Card
    [197] = 2178, -- Wind Shot -> Wind Card
    [198] = 2179, -- Earth Shot -> Earth Card
    [199] = 2180, -- Thunder Shot -> Thunder Card
    [200] = 2181, -- Water Shot -> Water Card
    [201] = 2182, -- Light Shot -> Light Card
    [202] = 2183, -- Dark Shot -> Dark Card
}
local TRUMP_CARD_ID = 2974

-- Equippable Job Ability Ammo: JA ID -> Item ID (Scanned across General + Wardrobe 1..8)
local JA_EQUIP_AMMO = {
    [150] = 18258, -- WAR Tomahawk -> Thr. Tomahawk (18258)
    [170] = 18259, -- DRG Angon    -> Angon (18259)
}

-- O(1) Set of Equippable Consumable Ammo IDs that can reside in Mog Wardrobes 1..8
local IS_WARDROBE_AMMO = {
    [18258] = true, -- Thr. Tomahawk
    [18259] = true, -- Angon
}

-- -----------------------------------------------------------------------------
-- Player Identity Cache, Live Packet Slot Overlay (0x01E/0x01F/0x020), & Pre-Use State
--   In Windower 4, `windower.ffxi.get_items(bag_id)` reads the client's committed item
--   buffer, which only updates from the staging buffer once `0x01D` (Finish Inventory)
--   flushes the bag. When `itemizer` moves 1 item from Satchel/Case/Sack into Inventory
--   and immediately uses it (or right after zoning), `get_items(5)` can still report the
--   stale pre-move Satchel count while `get_items(0)` reports `1 -> 0`.
--   Tracking `0x01E` (Modify Inventory), `0x01F` (Item Assign), and `0x020` (Item Updates)
--   in `live_slot_cache` ensures instant, authoritative slot counts across all bags.
-- -----------------------------------------------------------------------------
local TRACKED_BAG_SET = {}
for b = 1, NUM_ALL_BAGS do
    TRACKED_BAG_SET[ALL_BAGS[b].id] = true
end

local player_id         = nil
local player_name       = nil
local pending_item_id   = nil
local pending_pre_total = nil
local pending_at        = 0
local live_slot_cache   = {}
local last_stock_total  = {}
local last_01e_clock    = 0

local function get_player_identity()
    if not player_id or not player_name then
        local p = get_player()
        if p then
            player_id   = p.id
            player_name = p.name
        end
    end
    return player_id, player_name
end

windower.register_event('login', 'logout', function()
    player_id         = nil
    player_name       = nil
    pending_item_id   = nil
    pending_pre_total = nil
    live_slot_cache   = {}
    last_stock_total  = {}
end)

windower.register_event('zone change', function()
    player_id         = nil
    player_name       = nil
    pending_item_id   = nil
    pending_pre_total = nil
    live_slot_cache   = {}
end)

-- -----------------------------------------------------------------------------
-- Two-Tier Single-Pass Multi-Bag Item + Reserve Container Counters
-- 1. `count_item_across_bags`: Fast 4-bag scan (Inv, Satchel, Case, Sack)
-- 2. `count_item_with_wardrobes`: Isolated 12-bag scan (+ Wardrobe 1..8) for Angon/Tomahawk
-- Merges `get_items(bag_id)` with `live_slot_cache[bag_id]`, counts both the target item
-- AND any matching Toolbag/Pouch/Case in ONE pass, and skips empty/disabled bags.
-- -----------------------------------------------------------------------------
local function is_usable_consumable(item_id)
    local item_res = res.items[item_id]
    return item_res ~= nil and (item_res.category == 'Usable' or ITEM_TO_CONTAINER[item_id] ~= nil)
end

local function count_item_in_tier(target_id, max_bag_idx)
    local total       = 0
    local pouch_total = 0
    local by_bag      = {}
    local cont        = settings.show_containers and ITEM_TO_CONTAINER[target_id] or nil
    local cont_id     = cont and cont.id or nil

    for b = 1, max_bag_idx do
        local bag_id    = ALL_BAGS[b].id
        local bag_info  = get_bag_info(bag_id)
        local bag_cache = live_slot_cache[bag_id]
        local bag_sum   = 0
        -- Skip unsubscribed Wardrobes (`enabled == false`) and empty bags (`count == 0`)
        -- unless `live_slot_cache` has pending slot updates for that bag.
        if bag_cache or not bag_info or (bag_info.enabled ~= false and (not bag_info.count or bag_info.count > 0)) then
            local bag_data = get_items(bag_id)
            if bag_data or bag_cache then
                local max_slots  = (bag_data and bag_data.max) or 80
                local scan_pouch = (cont_id ~= nil and b <= NUM_STD_BAGS)
                for slot = 1, max_slots do
                    local entry = bag_data and bag_data[slot]
                    local ovr   = bag_cache and bag_cache[slot]
                    local eid, cnt
                    if ovr then
                        cnt = ovr.count
                        if cnt and cnt > 0 then
                            eid = ovr.id or (entry and entry.id)
                            if not ovr.id and eid and eid > 0 then
                                ovr.id = eid
                            end
                        end
                    elseif entry then
                        eid = entry.id
                        cnt = entry.count
                    end
                    if cnt and cnt > 0 and eid then
                        if eid == target_id then
                            bag_sum = bag_sum + cnt
                        elseif scan_pouch and eid == cont_id then
                            pouch_total = pouch_total + cnt
                        end
                    end
                end
            end
        end
        by_bag[b] = bag_sum
        total = total + bag_sum
    end

    return total, by_bag, pouch_total
end

local function count_item_across_bags(target_id)
    return count_item_in_tier(target_id, NUM_STD_BAGS)
end

local function count_item_with_wardrobes(target_id)
    return count_item_in_tier(target_id, NUM_ALL_BAGS)
end

-- Formats the stock count with native FFXI 0x1E/0x1F chat colors and per-bag breakdown
local function format_stock_line(item_id, total, by_bag, prefix_note, char_tag, override_pouch_cnt)
    local item_res = res.items[item_id]
    local name = (item_res and item_res.en) or ('Item #' .. tostring(item_id))

    local col = COL_GOOD
    local alert = ''
    if total <= 0 then
        col = COL_ZERO
        alert = ' ' .. COL_ZERO .. '[OUT OF STOCK!]' .. COL_RESET
    elseif total <= (tonumber(settings.low_threshold) or 3) then
        col = COL_LOW
        alert = ' ' .. COL_LOW .. '[LOW!]' .. COL_RESET
    elseif total <= (tonumber(settings.warn_threshold) or 12) then
        col = COL_WARN
    end

    local bag_str = ''
    if settings.show_bag_breakdown and total > 0 and by_bag then
        local parts = {}
        local n_bags = #by_bag
        for b = 1, n_bags do
            local cnt = by_bag[b]
            if cnt and cnt > 0 and ALL_BAGS[b] then
                parts[#parts + 1] = ALL_BAGS[b].label .. ': ' .. tostring(cnt)
            end
        end
        if #parts > 0 then
            bag_str = ' ' .. COL_BAG .. '(' .. t_concat(parts, ' | ') .. ')' .. COL_RESET
        end
    end

    local pouch_str = ''
    if settings.show_containers then
        local cont = ITEM_TO_CONTAINER[item_id]
        if cont then
            local c_total = override_pouch_cnt
            if c_total == nil then
                c_total = count_item_across_bags(cont.id)
            end
            if c_total and c_total > 0 then
                pouch_str = ' ' .. COL_POUCH .. '[+' .. tostring(c_total) .. ' ' .. cont.label .. (c_total > 1 and 's' or '') .. ']' .. COL_RESET
            end
        end
    end

    local lead = (prefix_note and prefix_note ~= '') and (prefix_note .. ' ') or ''
    local header = char_tag
        and (COL_IPC .. '[ACE:' .. char_tag .. ']' .. COL_RESET)
        or  (COL_HEADER .. '[ACE]' .. COL_RESET)

    return s_format(
        '%s %s%s%s%s: %s%d remaining%s%s%s%s',
        header,
        lead,
        COL_ITEM, name, COL_RESET,
        col, total, COL_RESET,
        bag_str,
        pouch_str,
        alert
    )
end

-- Packs item stock into a pure-ASCII IPC frame (supports both 4-bag and 12-bag arrays)
local function pack_ipc_stock(kind, target_or_sender, char_name, item_id, total, by_bag, prefix_note, override_pouch_cnt)
    local c_total = override_pouch_cnt
    if c_total == nil then
        local cont = ITEM_TO_CONTAINER[item_id]
        c_total = cont and count_item_across_bags(cont.id) or 0
    end
    local bag_csv = by_bag and t_concat(by_bag, ',') or '0,0,0,0'
    return s_format(
        '%s|%s|%s|%d|%d|%s|%d|%s',
        kind,
        target_or_sender or '',
        char_name or '',
        item_id or 0,
        total or 0,
        bag_csv,
        c_total or 0,
        prefix_note or ''
    )
end

-- Broadcasts a cross-box IPC alert if enabled and threshold met
local function maybe_broadcast_ipc(item_id, total, by_bag, prefix_note, pouch_cnt)
    if not settings.ipc_alerts then return end
    local ipc_lim = tonumber(settings.ipc_threshold) or 5
    if not settings.ipc_all_uses and total > ipc_lim then
        return
    end
    local _, my_name = get_player_identity()
    if not my_name or my_name == '' then return end
    send_ipc(pack_ipc_stock('ace_alert', my_name, my_name, item_id, total, by_bag, prefix_note, pouch_cnt))
end

local function report_and_ipc(item_id, total, by_bag, prefix_note, pouch_cnt)
    add_to_chat(settings.chat_color, format_stock_line(item_id, total, by_bag, prefix_note, nil, pouch_cnt))
    maybe_broadcast_ipc(item_id, total, by_bag, prefix_note, pouch_cnt)
end

local function announce_item_stock(item_id, pre_total, attempt, unpacked_id)
    attempt = attempt or 1
    local total, by_bag, pouch_cnt = count_item_across_bags(item_id)

    -- Guard against `itemizer` split-transfer inflation (where Inventory temporarily has +1
    -- before Satchel/Case/Sack flushes -1) AND 0x028 arriving before 0x01E/0x020/0x01D.
    local expected_max = pre_total
    local prev_total   = last_stock_total[item_id]
    if prev_total and (not expected_max or prev_total < expected_max) and total <= prev_total + 1 then
        expected_max = prev_total
    end

    if expected_max and total >= expected_max and total > 0 then
        if attempt == 1 then
            coroutine.schedule(function()
                announce_item_stock(item_id, expected_max, 2, unpacked_id)
            end, 0.18)
            return
        else
            -- Deterministic fallback if server 0x01E/0x020 or 0x01D flush is still in flight
            local new_total = math_max(0, expected_max - 1)
            local drop      = total - new_total
            total           = new_total
            for b = 1, #by_bag do
                if by_bag[b] > 0 and drop > 0 then
                    local take = (by_bag[b] >= drop) and drop or by_bag[b]
                    by_bag[b]  = by_bag[b] - take
                    drop       = drop - take
                end
            end
        end
    end

    last_stock_total[item_id] = total

    if is_usable_consumable(item_id) then
        report_and_ipc(item_id, total, by_bag, nil, pouch_cnt)
    end

    -- If the used item was a Toolbag, Ammo Pouch, or Card Case that unpacked items,
    -- also announce the new total of the unpacked item!
    if unpacked_id and unpacked_id > 0 and unpacked_id ~= item_id and res.items[unpacked_id] then
        local u_total, u_bags, u_pouch = count_item_across_bags(unpacked_id)
        last_stock_total[unpacked_id]  = u_total
        report_and_ipc(unpacked_id, u_total, u_bags, 'Unpacked ->', u_pouch)
    end
end

-- -----------------------------------------------------------------------------
-- Ultra-Fast Raw Packet Inspection:
--   - 0x01E (Modify Inventory), 0x01F (Item Assign), 0x020 (Item Updates):
--     Updates `live_slot_cache` in ~15ns via raw `string.byte` without waiting for `0x01D`
--     to copy the FFXI client's staging item buffer into `windower.ffxi.get_items()`.
--   - 0x028 (Action Packet):
--     Pre-filters BOTH `actor_id` (bytes 6..9) AND 4-bit `Category` (byte 11, bits 2..5)
--     BEFORE calling `windower.packets.parse_action(data)`.
-- -----------------------------------------------------------------------------
windower.register_event('incoming chunk', function(id, data, modified, injected, blocked)
    if injected then return end

    -- 0x01E: Modify Inventory (Count @ 5..8, Bag @ 9, Slot @ 10)
    if id == 0x01E then
        if #data < 10 then return end
        local b5, b6, b7, b8, bag_id, slot = s_byte(data, 5, 10)
        if TRACKED_BAG_SET[bag_id] and slot >= 1 and slot <= 80 then
            local count = b5 + b6 * 256 + b7 * 65536 + b8 * 16777216
            if bag_id == 5 or bag_id == 6 or bag_id == 7 then
                last_01e_clock = os_clock()
            end
            local bag_cache = live_slot_cache[bag_id]
            if not bag_cache then
                bag_cache = {}
                live_slot_cache[bag_id] = bag_cache
            end
            local prev = bag_cache[slot]
            if count == 0 then
                bag_cache[slot] = { id = 0, count = 0 }
            elseif prev then
                prev.count = count
            else
                bag_cache[slot] = { id = nil, count = count }
            end
        end
        return
    end

    -- 0x01F: Item Assign (Count @ 5..8, Item @ 9..10, Bag @ 11, Slot @ 12)
    if id == 0x01F then
        if #data < 12 then return end
        local b5, b6, b7, b8, b9, b10, bag_id, slot = s_byte(data, 5, 12)
        if TRACKED_BAG_SET[bag_id] and slot >= 1 and slot <= 80 then
            local count   = b5 + b6 * 256 + b7 * 65536 + b8 * 16777216
            local item_id = b9 + b10 * 256
            local bag_cache = live_slot_cache[bag_id]
            if not bag_cache then
                bag_cache = {}
                live_slot_cache[bag_id] = bag_cache
            end
            if count == 0 or item_id == 0 then
                bag_cache[slot] = { id = 0, count = 0 }
            else
                bag_cache[slot] = { id = item_id, count = count }
                -- Clear monotonic guard if a stack > 1 was added or if +1 was obtained outside an itemizer transfer
                if count > 1 or (bag_id == 0 and (os_clock() - last_01e_clock) > 1.0) then
                    last_stock_total[item_id] = nil
                end
            end
        end
        return
    end

    -- 0x020: Item Updates (Count @ 5..8, Item @ 13..14, Bag @ 15, Slot @ 16)
    if id == 0x020 then
        if #data < 16 then return end
        local b5, b6, b7, b8     = s_byte(data, 5, 8)
        local b13, b14, bag_id, slot = s_byte(data, 13, 16)
        if TRACKED_BAG_SET[bag_id] and slot >= 1 and slot <= 80 then
            local count   = b5 + b6 * 256 + b7 * 65536 + b8 * 16777216
            local item_id = b13 + b14 * 256
            local bag_cache = live_slot_cache[bag_id]
            if not bag_cache then
                bag_cache = {}
                live_slot_cache[bag_id] = bag_cache
            end
            if count == 0 or item_id == 0 then
                bag_cache[slot] = { id = 0, count = 0 }
            else
                bag_cache[slot] = { id = item_id, count = count }
            end
        end
        return
    end

    if id ~= 0x028 or #data < 12 then return end

    local my_id = get_player_identity()
    if not my_id then return end

    -- Single C-call extracts actor_id bytes (6..9) and Category byte (11)
    local b6, b7, b8, b9, _, b11 = s_byte(data, 6, 11)
    local actor_id = b6 + b7 * 256 + b8 * 65536 + b9 * 16777216
    if actor_id ~= my_id then return end

    -- Extract 4-bit Action Category at bit offset 82..85 (byte 11, bits 2..5)
    local cat = b_band(b_rshift(b11, 2), 0x0F)
    if cat ~= 5 and cat ~= 9 then
        if cat == 6 then
            if not settings.track_quickdraw and not settings.track_ja_ammo then return end
        elseif cat == 4 then
            if not settings.track_ninjutsu then return end
        else
            return
        end
    end

    local act = parse_action(data)
    if not act then return end

    -- Category 9: Item Use Begin (param 24931) -> Snapshot pre-use count for Usable items only
    if cat == 9 then
        if act.param == 24931 then
            local t1 = act.targets and act.targets[1]
            local a1 = t1 and t1.actions and t1.actions[1]
            local item_id = a1 and a1.param
            if item_id and item_id > 0 and is_usable_consumable(item_id) then
                local raw_pre, pre_bags = count_item_across_bags(item_id)
                local prev_tot          = last_stock_total[item_id]
                -- If `itemizer` just pulled +1 into Inventory while the source bag hasn't flushed -1 yet,
                -- clamp `pending_pre_total` to `prev_tot` so `raw_pre` isn't inflated by +1.
                if prev_tot and raw_pre == prev_tot + 1 and (pre_bags[1] or 0) >= 1 then
                    raw_pre = prev_tot
                end
                pending_item_id   = item_id
                pending_pre_total = raw_pre
                pending_at        = os_clock()
            end
        elseif act.param == 28787 then
            pending_item_id   = nil
            pending_pre_total = nil
        end
        return
    end

    -- Category 5: Item Use Finish (act.param = consumed item_id)
    if cat == 5 then
        local item_id = act.param
        if not item_id or item_id == 0 then return end

        local t1 = act.targets and act.targets[1]
        local a1 = t1 and t1.actions and t1.actions[1]
        local action_param = a1 and a1.param
        local action_msg   = a1 and a1.message

        -- Detect if using this item unpacked another item (e.g. Toolbag, Bullet Pouch, Card Case)
        local unpacked_id = nil
        if action_param and action_param > 0 and action_param ~= item_id then
            local u_res = res.items[action_param]
            if u_res and (action_msg == 584 or ITEM_TO_CONTAINER[action_param] ~= nil or (u_res.stack and u_res.stack > 1)) then
                unpacked_id = action_param
            end
        end

        -- Skip enchantment gear (e.g. Warp Ring / Echad Ring) that neither consumes a stack nor unpacks an item
        if not unpacked_id and not is_usable_consumable(item_id) then
            pending_item_id   = nil
            pending_pre_total = nil
            return
        end

        local pre_total = nil
        if pending_item_id == item_id and (os_clock() - pending_at) < 15.0 then
            pre_total = pending_pre_total
        end
        pending_item_id   = nil
        pending_pre_total = nil

        coroutine.schedule(function()
            announce_item_stock(item_id, pre_total, 1, unpacked_id)
        end, 0.12)
        return
    end

    -- Category 4: Spell Cast Finish -> Optional Ninjutsu Tool Tracking
    if cat == 4 then
        local spell_id = act.param
        local tools = spell_id and NINJUTSU_TOOLS[spell_id]
        if tools then
            coroutine.schedule(function()
                local spec_id, univ_id = tools[1], tools[2]
                local spec_tot, spec_bags, spec_pouch = count_item_across_bags(spec_id)
                local p = get_player()
                local is_main_nin = p and p.main_job == 'NIN'

                if spec_tot > 0 or not is_main_nin then
                    report_and_ipc(spec_id, spec_tot, spec_bags, nil, spec_pouch)
                else
                    local univ_tot, univ_bags, univ_pouch = count_item_across_bags(univ_id)
                    report_and_ipc(univ_id, univ_tot, univ_bags, nil, univ_pouch)
                end
            end, 0.15)
        end
        return
    end

    -- Category 6: Job Ability -> Quick Draw Cards (4-bag) OR Angon/Tomahawk (12-bag Wardrobe check)
    if cat == 6 then
        local ja_id = act.param

        -- 1. Isolated Equippable JA Ammo Check (DRG Angon / WAR Tomahawk across General + Wardrobe 1..8)
        if settings.track_ja_ammo then
            local ja_ammo_id = ja_id and JA_EQUIP_AMMO[ja_id]
            if ja_ammo_id then
                coroutine.schedule(function()
                    local tot, bags, pouch = count_item_with_wardrobes(ja_ammo_id)
                    report_and_ipc(ja_ammo_id, tot, bags, nil, pouch)
                end, 0.15)
                return
            end
        end

        -- 2. Corsair Quick Draw Card Tracking (4-bag General scan)
        if settings.track_quickdraw then
            local elem_card_id = ja_id and QUICK_DRAW_CARDS[ja_id]
            if elem_card_id then
                coroutine.schedule(function()
                    local elem_tot, elem_bags, elem_pouch = count_item_across_bags(elem_card_id)
                    if elem_tot > 0 then
                        report_and_ipc(elem_card_id, elem_tot, elem_bags, nil, elem_pouch)
                    else
                        local trump_tot, trump_bags, trump_pouch = count_item_across_bags(TRUMP_CARD_ID)
                        report_and_ipc(TRUMP_CARD_ID, trump_tot, trump_bags, nil, trump_pouch)
                    end
                end, 0.15)
            end
        end
        return
    end
end)

-- -----------------------------------------------------------------------------
-- On-Demand Full Audit & Search Across Inventory, Satchel, Case, Sack
-- (+ Isolated Wardrobe 1..8 check strictly for Angon / Thr. Tomahawk)
-- -----------------------------------------------------------------------------
local EXTRA_TRACKED_IDS = {
    [1179] = true, -- Shihei
    [2971] = true, -- Inoshishinofuda
    [2972] = true, -- Shikanofuda
    [2973] = true, -- Chonofuda
    [2974] = true, -- Trump Card
}

local function scan_all_consumables(filter_query, only_low)
    local aggregated  = {}
    local raw_counts  = {}
    local rejected    = {}
    local q = filter_query and s_lower(filter_query) or nil

    -- Only touch Wardrobe 1..8 if track_ja_ammo is ON or the user explicitly searched for angon/tomahawk
    local check_wardrobes = settings.track_ja_ammo
        or (q ~= nil and (s_find('angon', q, 1, true) ~= nil or s_find('throwing tomahawk', q, 1, true) ~= nil or s_find('thr. tomahawk', q, 1, true) ~= nil))
    local max_bag_idx = check_wardrobes and NUM_ALL_BAGS or NUM_STD_BAGS

    for b = 1, max_bag_idx do
        local is_wardrobe = (b > NUM_STD_BAGS)
        local bag_id      = ALL_BAGS[b].id
        local bag_info    = get_bag_info(bag_id)
        local bag_cache   = live_slot_cache[bag_id]
        if bag_cache or not bag_info or (bag_info.enabled ~= false and (not bag_info.count or bag_info.count > 0)) then
            local bag_data = get_items(bag_id)
            if bag_data or bag_cache then
                local max_slots = (bag_data and bag_data.max) or 80
                for slot = 1, max_slots do
                    local entry = bag_data and bag_data[slot]
                    local ovr   = bag_cache and bag_cache[slot]
                    local iid, cnt
                    if ovr then
                        cnt = ovr.count
                        if cnt and cnt > 0 then
                            iid = ovr.id or (entry and entry.id)
                            if not ovr.id and iid and iid > 0 then
                                ovr.id = iid
                            end
                        end
                    elseif entry then
                        iid = entry.id
                        cnt = entry.count
                    end
                    if iid and iid > 0 and cnt and cnt > 0 then
                        if not is_wardrobe then
                            raw_counts[iid] = (raw_counts[iid] or 0) + cnt
                        end
                        -- Fast-path for Wardrobes 1..8: O(1) skip for 99.9% of gear; only process Angon / Thr. Tomahawk
                        if not is_wardrobe or IS_WARDROBE_AMMO[iid] then
                            local rec = aggregated[iid]
                            if rec then
                                -- O(1) fast-accumulate for additional stacks of an already-matched item
                                rec.total     = rec.total + cnt
                                rec.by_bag[b] = (rec.by_bag[b] or 0) + cnt
                            elseif not rejected[iid] then
                                local item_res = res.items[iid]
                                if item_res then
                                    local is_consumable = (item_res.category == 'Usable')
                                        or EXTRA_TRACKED_IDS[iid]
                                        or (settings.track_ja_ammo and IS_WARDROBE_AMMO[iid])
                                        or (ITEM_TO_CONTAINER[iid] ~= nil)
                                    local matches_query = true
                                    if q then
                                        local name_l = s_lower(item_res.en or '')
                                        local log_l  = s_lower(item_res.enl or '')
                                        matches_query = (s_find(name_l, q, 1, true) ~= nil) or (s_find(log_l, q, 1, true) ~= nil)
                                    end

                                    if (q and matches_query) or (not q and is_consumable) then
                                        local n_slots = IS_WARDROBE_AMMO[iid] and NUM_ALL_BAGS or NUM_STD_BAGS
                                        local init_bags = {}
                                        for k = 1, n_slots do init_bags[k] = 0 end
                                        init_bags[b] = cnt
                                        aggregated[iid] = {
                                            id     = iid,
                                            name   = item_res.en or ('Item #' .. tostring(iid)),
                                            total  = cnt,
                                            by_bag = init_bags,
                                        }
                                    else
                                        rejected[iid] = true
                                    end
                                else
                                    rejected[iid] = true
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local list = {}
    local warn_lim = tonumber(settings.warn_threshold) or 12
    for iid, rec in pairs(aggregated) do
        if not only_low or rec.total <= warn_lim then
            local cont = ITEM_TO_CONTAINER[iid]
            rec.pouch_cnt = (cont and raw_counts[cont.id]) or 0
            list[#list + 1] = rec
        end
    end

    t_sort(list, function(a, b)
        return s_lower(a.name) < s_lower(b.name)
    end)

    return list
end

-- Unpacks a pure-ASCII IPC stock frame and formats it locally with native FFXI chat colors
local function render_ipc_stock_parts(parts)
    local char_name  = parts[3]
    local item_id    = tonumber(parts[4]) or 0
    local total      = tonumber(parts[5]) or 0
    local bag_csv    = parts[6] or '0,0,0,0'
    local pouch_cnt  = tonumber(parts[7]) or 0
    local note       = parts[8]
    if note == '' then note = nil end

    local b_parts = bag_csv:split(',')
    local by_bag = {}
    for i = 1, #b_parts do
        by_bag[i] = tonumber(b_parts[i]) or 0
    end
    return format_stock_line(item_id, total, by_bag, note, char_name, pouch_cnt)
end

-- -----------------------------------------------------------------------------
-- Cross-Box IPC Message Handler (Low-Stock Alerts, Settings Sync & Party Query)
-- -----------------------------------------------------------------------------
windower.register_event('ipc message', function(msg)
    if not msg then return end

    -- 1. Incoming Low-Stock Alert from another local character
    if s_sub(msg, 1, 10) == 'ace_alert|' then
        if not settings.ipc_alerts then return end
        local parts = msg:split('|')
        local sender = parts[2]
        local _, my_name = get_player_identity()
        if sender and sender ~= my_name then
            add_to_chat(settings.chat_color, render_ipc_stock_parts(parts))
        end
        return
    end

    -- 2. Synchronize IPC Settings across all running instances
    if s_sub(msg, 1, 9) == 'ace_sync|' then
        local parts = msg:split('|')
        if parts[2] == 'ipc' then
            settings.ipc_alerts    = (parts[3] == 'true')
            settings.ipc_threshold = tonumber(parts[4]) or settings.ipc_threshold
            settings.ipc_all_uses  = (parts[5] == 'true')
            config.save(settings)
        end
        return
    end

    -- 3. Cross-box Party Query (`//ace party <query>` or `//ace party low`)
    if s_sub(msg, 1, 10) == 'ace_query|' then
        local parts = msg:split('|')
        local requester = parts[2]
        local mode      = parts[3]
        local query     = parts[4] or ''
        local _, my_name = get_player_identity()
        if not my_name or my_name == '' or my_name == requester then return end

        local list
        if mode == 'low' then
            list = scan_all_consumables(nil, true)
        else
            list = scan_all_consumables(query, false)
        end

        if #list == 0 then
            if mode == 'search' then
                send_ipc(s_format('ace_zero|%s|%s|%s', requester, my_name, query))
            end
        else
            for i = 1, #list do
                local rec = list[i]
                send_ipc(pack_ipc_stock('ace_reply', requester, my_name, rec.id, rec.total, rec.by_bag, '', rec.pouch_cnt))
            end
        end
        return
    end

    -- 4. Reply to Cross-box Party Query
    if s_sub(msg, 1, 10) == 'ace_reply|' then
        local parts = msg:split('|')
        local target = parts[2]
        local _, my_name = get_player_identity()
        if my_name == target then
            add_to_chat(settings.chat_color, render_ipc_stock_parts(parts))
        end
        return
    end

    -- 5. Zero-stock Reply to Cross-box Party Query
    if s_sub(msg, 1, 9) == 'ace_zero|' then
        local parts = msg:split('|')
        local target    = parts[2]
        local char_name = parts[3] or '?'
        local query     = parts[4] or ''
        local _, my_name = get_player_identity()
        if my_name == target then
            add_to_chat(settings.chat_color, s_format(
                '%s[ACE:%s]%s %s"%s"%s: %s0 remaining [OUT OF STOCK!]%s',
                COL_IPC, char_name, COL_RESET, COL_ITEM, query, COL_RESET, COL_ZERO, COL_RESET
            ))
        end
        return
    end
end)

-- -----------------------------------------------------------------------------
-- Console / Chat Commands (//ace)
-- -----------------------------------------------------------------------------
windower.register_event('addon command', function(cmd, ...)
    local args = {...}
    local sub = cmd and s_lower(cmd) or 'list'

    if sub == 'help' then
        add_to_chat(settings.chat_color, COL_HEADER .. '[ACE] The All Consuming Eye — Commands:' .. COL_RESET)
        add_to_chat(settings.chat_color, '  //ace                 - List all consumables across Inv, Satchel, Case, Sack')
        add_to_chat(settings.chat_color, '  //ace low [N]         - Show consumables <= warning threshold (default ' .. tostring(settings.warn_threshold) .. ')')
        add_to_chat(settings.chat_color, '  //ace <item name>     - Search specific item (e.g. //ace prism, //ace oil, //ace angon)')
        add_to_chat(settings.chat_color, '  //ace ipc [on|off|N]  - Toggle cross-box IPC alerts or set threshold (default OFF, <= ' .. tostring(settings.ipc_threshold) .. ')')
        add_to_chat(settings.chat_color, '  //ace ipcall          - Toggle broadcasting ALL item uses over IPC vs low-stock only')
        add_to_chat(settings.chat_color, '  //ace party <query>   - Query all logged-in characters via IPC (e.g. //ace party prism, //ace party low)')
        add_to_chat(settings.chat_color, '  //ace bags            - Toggle per-bag breakdown display')
        add_to_chat(settings.chat_color, '  //ace ja [on|off]     - Toggle full-time Angon & Tomahawk Wardrobe 1..8 tracking (default OFF)')
        add_to_chat(settings.chat_color, '  //ace nin / //ace qd  - Toggle Ninjutsu tool or Quick Draw card tracking')
        return

    elseif sub == 'ipc' then
        local arg1 = args[1] and s_lower(args[1]) or nil
        if arg1 == 'on' or arg1 == 'true' then
            settings.ipc_alerts = true
        elseif arg1 == 'off' or arg1 == 'false' then
            settings.ipc_alerts = false
        elseif arg1 and tonumber(arg1) then
            settings.ipc_threshold = tonumber(arg1)
            settings.ipc_alerts = true
        else
            settings.ipc_alerts = not settings.ipc_alerts
        end
        if args[2] and tonumber(args[2]) then
            settings.ipc_threshold = tonumber(args[2])
        end
        config.save(settings)
        send_ipc(s_format('ace_sync|ipc|%s|%d|%s',
            tostring(settings.ipc_alerts),
            tonumber(settings.ipc_threshold) or 5,
            tostring(settings.ipc_all_uses)))
        add_to_chat(settings.chat_color, s_format(
            '%s[ACE]%s Cross-Box IPC Alerts (synced across all clients): %s (Threshold: <= %d%s)',
            COL_HEADER, COL_RESET,
            settings.ipc_alerts and (COL_GOOD .. 'ON' .. COL_RESET) or (COL_LOW .. 'OFF' .. COL_RESET),
            settings.ipc_threshold,
            settings.ipc_all_uses and ', Mode: ALL USES' or ', Mode: LOW STOCK ONLY'
        ))
        return

    elseif sub == 'ipcall' then
        settings.ipc_all_uses = not settings.ipc_all_uses
        if settings.ipc_all_uses then
            settings.ipc_alerts = true
        end
        config.save(settings)
        send_ipc(s_format('ace_sync|ipc|%s|%d|%s',
            tostring(settings.ipc_alerts),
            tonumber(settings.ipc_threshold) or 5,
            tostring(settings.ipc_all_uses)))
        add_to_chat(settings.chat_color, s_format(
            '%s[ACE]%s Cross-Box IPC Broadcast Mode (synced): %s',
            COL_HEADER, COL_RESET,
            settings.ipc_all_uses and 'ALL CONSUMABLE USES' or ('LOW STOCK ONLY (<= ' .. tostring(settings.ipc_threshold) .. ')')
        ))
        return

    elseif sub == 'party' or sub == 'boxes' then
        local _, my_name = get_player_identity()
        my_name = my_name or 'Self'
        local query_str = (#args > 0) and t_concat(args, ' ') or 'low'
        local is_low = (s_lower(query_str) == 'low')
        local list = is_low and scan_all_consumables(nil, true) or scan_all_consumables(query_str, false)

        if #list == 0 then
            if not is_low then
                add_to_chat(settings.chat_color, s_format('%s[ACE:%s]%s %s"%s"%s: %s0 remaining [OUT OF STOCK!]%s',
                    COL_IPC, my_name, COL_RESET, COL_ITEM, query_str, COL_RESET, COL_ZERO, COL_RESET))
            end
        else
            for i = 1, #list do
                local rec = list[i]
                add_to_chat(settings.chat_color, format_stock_line(rec.id, rec.total, rec.by_bag, nil, my_name, rec.pouch_cnt))
            end
        end
        send_ipc(s_format('ace_query|%s|%s|%s', my_name, is_low and 'low' or 'search', query_str))
        return

    elseif sub == 'bags' then
        settings.show_bag_breakdown = not settings.show_bag_breakdown
        config.save(settings)
        add_to_chat(settings.chat_color, COL_HEADER .. '[ACE]' .. COL_RESET .. ' Per-bag breakdown: ' .. (settings.show_bag_breakdown and 'ON' or 'OFF'))
        return

    elseif sub == 'ja' or sub == 'jaammo' then
        local arg1 = args[1] and s_lower(args[1]) or nil
        if arg1 == 'on' or arg1 == 'true' then
            settings.track_ja_ammo = true
        elseif arg1 == 'off' or arg1 == 'false' then
            settings.track_ja_ammo = false
        else
            settings.track_ja_ammo = not settings.track_ja_ammo
        end
        config.save(settings)
        add_to_chat(settings.chat_color, s_format(
            '%s[ACE]%s Full-time Angon & Tomahawk (Wardrobe 1..8) tracking (saved): %s',
            COL_HEADER, COL_RESET,
            settings.track_ja_ammo and (COL_GOOD .. 'ON' .. COL_RESET) or (COL_LOW .. 'OFF' .. COL_RESET)
        ))
        return

    elseif sub == 'nin' or sub == 'ninjutsu' then
        settings.track_ninjutsu = not settings.track_ninjutsu
        config.save(settings)
        add_to_chat(settings.chat_color, COL_HEADER .. '[ACE]' .. COL_RESET .. ' Ninjutsu tool tracking: ' .. (settings.track_ninjutsu and 'ON' or 'OFF'))
        return

    elseif sub == 'qd' or sub == 'quickdraw' then
        settings.track_quickdraw = not settings.track_quickdraw
        config.save(settings)
        add_to_chat(settings.chat_color, COL_HEADER .. '[ACE]' .. COL_RESET .. ' Quick Draw card tracking: ' .. (settings.track_quickdraw and 'ON' or 'OFF'))
        return

    elseif sub == 'low' or sub == 'warn' then
        if args[1] and tonumber(args[1]) then
            settings.warn_threshold = tonumber(args[1])
            config.save(settings)
        end
        local list = scan_all_consumables(nil, true)
        add_to_chat(settings.chat_color, s_format('%s[ACE] Low Consumables (<= %d):%s', COL_HEADER, settings.warn_threshold, COL_RESET))
        if #list == 0 then
            add_to_chat(settings.chat_color, '  All tracked consumables are well stocked!')
        else
            for i = 1, #list do
                local rec = list[i]
                add_to_chat(settings.chat_color, format_stock_line(rec.id, rec.total, rec.by_bag, nil, nil, rec.pouch_cnt))
            end
        end
        return

    elseif sub == 'list' or sub == 'all' or sub == 'check' then
        local list = scan_all_consumables(nil, false)
        add_to_chat(settings.chat_color, s_format('%s[ACE] Consumables Remaining: %d items%s', COL_HEADER, #list, COL_RESET))
        for i = 1, #list do
            local rec = list[i]
            add_to_chat(settings.chat_color, format_stock_line(rec.id, rec.total, rec.by_bag, nil, nil, rec.pouch_cnt))
        end
        return

    else
        local full_query = cmd
        if #args > 0 then
            full_query = cmd .. ' ' .. t_concat(args, ' ')
        end
        local list = scan_all_consumables(full_query, false)
        if #list == 0 then
            add_to_chat(settings.chat_color, s_format('%s[ACE]%s %s"%s"%s: %s0 remaining [OUT OF STOCK!]%s', COL_HEADER, COL_RESET, COL_ITEM, full_query, COL_RESET, COL_ZERO, COL_RESET))
        else
            for i = 1, #list do
                local rec = list[i]
                add_to_chat(settings.chat_color, format_stock_line(rec.id, rec.total, rec.by_bag, nil, nil, rec.pouch_cnt))
            end
        end
    end
end)
