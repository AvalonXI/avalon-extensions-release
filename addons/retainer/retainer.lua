addon.name      = 'retainer';
addon.author    = 'Otamarai';
addon.version   = '2.2';
addon.desc      = 'Storage panel for AvalonXI retainer system.';
addon.link      = 'https://ashitaxi.com/';

require('common');
local bit      = require('bit');
local chat     = require('chat');
local imgui    = require('imgui');
local settings = require('settings');

-- Absolute path to this addon's folder, for loadfile on data/ regardless of cwd.
local addon_directory = (debug.getinfo(1, 'S').source or ''):match('^@(.+[\\/])[^\\/]+$') or '';

local default_settings = T{
    cache    = T{},
    storable = T{},
    ui = T{
        visible         = false,
        locked          = false,  -- LOCKED = fixed overlay (no move/resize/collapse, no [X])
        filter          = '',
        group_by_craft  = true,
        hide_dump_lines = true,   -- suppress the raw dump spam from chat during a sync
        view            = 'stored',
        window_pos_x    = 200,
        window_pos_y    = 200,
        window_size_w   = 470,
        window_size_h   = 560,
    },
};

local retainer = T{
    settings       = settings.load(default_settings),
    retainer_name  = nil,
    status_text    = 'No retainer data yet. Click Sync near your retainer.',
};

-- Transient UI scratch (not persisted directly; mirrored to settings.ui).
local ui = {
    visible      = { false },
    filter       = { '' },
    filter_size  = 256,
    group        = { true },
    view         = 'stored',          -- 'stored' | 'deposit'
    selected_key = nil,
    next_layout_save = 0,
};

local function trim(s)
    if (s == nil) then
        return '';
    end
    return (s:gsub('^%s+', ''):gsub('%s+$', ''));
end

local function norm(s)
    return trim(tostring(s or '')):lower();
end

-- Strip FFXI colour codes (0x1E xx / 0x1F xx) and stray nulls but keep the
-- high-byte SJIS arrow (0x81 0xA8) intact so we can split craft -> type.
local function clean_line(s)
    if (s == nil) then
        return '';
    end
    s = s:gsub('\30.', ''):gsub('\31.', ''):gsub('%z', '');
    return trim(s);
end

local function print_status(message)
    print(chat.header(addon.name):append(chat.message(message)));
end

local function print_error(message)
    print(chat.header(addon.name):append(chat.error(message)));
end

local function set_status(msg)
    retainer.status_text = msg;
end

local function ensure_settings()
    if (retainer.settings.cache == nil) then
        retainer.settings.cache = T{};
    end
    if (retainer.settings.storable == nil) then
        retainer.settings.storable = T{};
    end
    if (retainer.settings.ui == nil) then
        retainer.settings.ui = T{};
    end
    local d = default_settings.ui;
    for key, value in pairs(d) do
        if (retainer.settings.ui[key] == nil) then
            retainer.settings.ui[key] = value;
        end
    end
    -- Pin 'locked' explicitly so an old settings file without it is never left nil.
    if (retainer.settings.ui.locked == nil) then
        retainer.settings.ui.locked = false;
    end
end

local function sync_ui_from_settings()
    ensure_settings();
    ui.visible[1] = retainer.settings.ui.visible == true;
    ui.filter[1]  = trim(tostring(retainer.settings.ui.filter or ''):gsub('%z', ''));
    ui.group[1]   = retainer.settings.ui.group_by_craft ~= false;
    ui.view       = retainer.settings.ui.view or 'stored';
end

local function persist_ui_state(force)
    ensure_settings();
    retainer.settings.ui.visible        = ui.visible[1];
    retainer.settings.ui.filter         = trim(tostring(ui.filter[1] or ''):gsub('%z', ''));
    retainer.settings.ui.group_by_craft = ui.group[1];
    retainer.settings.ui.view           = ui.view;

    if (force or os.clock() >= ui.next_layout_save) then
        settings.save();
        ui.next_layout_save = os.clock() + 0.5;
    end
end

-- Forward-declared; defined later but referenced by update_settings.
local rebuild_storable_set;
local cancel_sync;

local function update_settings(s)
    if (s ~= nil) then
        retainer.settings = s;
    end
    ensure_settings();
    sync_ui_from_settings();
    if (rebuild_storable_set ~= nil) then
        rebuild_storable_set();
    end
    -- Character switch: cancel any in-flight sync so its dump can't commit into the new char's cache.
    if (cancel_sync ~= nil) then
        cancel_sync();
    end
    settings.save();
end

settings.register('settings', 'settings_update', update_settings);

ensure_settings();
sync_ui_from_settings();

-- Cache entries are keyed 'id:<n>'/'nm:<name>': { id, quantity, name_dump, craft, type, retainer, last_seen }.
local function cache()
    ensure_settings();
    return retainer.settings.cache;
end

local function entry_key(e)
    if (e.id ~= nil) then
        return 'id:' .. e.id;
    end
    return 'nm:' .. norm(e.name_dump);
end

local function cache_count()
    local n = 0;
    for _ in pairs(cache()) do
        n = n + 1;
    end
    return n;
end

local function save_cache()
    settings.save();
end

local storable_set      = {};   -- [itemID] = true  (committed, complete catalog)
local storable_loaded   = false;
local storable_expected = 0;    -- size of the committed set (for the completeness check)
-- Staging buffer: the live set keeps filtering until a refresh fully arrives, so a partial dump never shrinks it.
local storable_incoming          = nil;
local storable_incoming_expected = 0;

local function load_shipped_storable()
    if (addon_directory == '') then
        return nil;
    end
    local chunk = loadfile(addon_directory .. 'data/storable.lua');
    if (chunk == nil) then
        return nil;
    end
    local ok, data = pcall(chunk);
    if (ok and type(data) == 'table') then
        return data;
    end
    return nil;
end

rebuild_storable_set = function()
    storable_set = {};
    storable_loaded = false;
    storable_expected = 0;

    -- Catalog is server-wide identical, so larger == more complete: prefer persisted only if >= shipped.
    local shipped = load_shipped_storable();
    local saved   = retainer.settings.storable;
    local shipped_n = (type(shipped) == 'table') and #shipped or 0;
    local saved_n   = (type(saved) == 'table') and #saved or 0;

    local ids = shipped;
    if (saved_n > 0 and saved_n >= shipped_n) then
        ids = saved;
    end

    local n = 0;
    if (type(ids) == 'table') then
        for _, id in ipairs(ids) do
            local num = tonumber(id);
            if (num ~= nil) then
                storable_set[num] = true;
                n = n + 1;
            end
        end
    end

    if (n > 0) then
        storable_loaded = true;
        storable_expected = n;
    end
end

local function storable_count()
    local n = 0;
    for _ in pairs(storable_set) do
        n = n + 1;
    end
    return n;
end

-- Persist into per-char settings (harmless server-wide duplication) to avoid writing back into data/.
local function save_storable()
    local ids = T{};
    for id in pairs(storable_set) do
        ids:append(id);
    end
    table.sort(ids);
    retainer.settings.storable = ids;
    settings.save();
end

rebuild_storable_set();

-- Ashita's IItem.Name is a 1-indexed userdata array (NOT a Lua table); the English singular is Name[1].
local function resource_item(id)
    if (id == nil) then
        return nil;
    end
    return AshitaCore:GetResourceManager():GetItemById(id);
end

local function item_full_name(id)
    local res = resource_item(id);
    if (res == nil) then
        return nil;
    end
    local nm = res.Name;
    -- Some bindings hand back a bare string; cover both shapes.
    if (type(nm) == 'string') then
        return (nm ~= '') and nm or nil;
    end
    local v = nm and nm[1];
    if (type(v) == 'string' and v ~= '') then
        return v;
    end
    return nil;
end

local function display_name(e)
    local full = e.id and item_full_name(e.id);
    if (full ~= nil and full ~= '') then
        return full;
    end
    return e.name_dump or ('Item#' .. tostring(e.id or '?'));
end

local function stack_size(id)
    local res = resource_item(id);
    local s = res and res.StackSize;
    if (type(s) == 'number' and s > 0) then
        return s;
    end
    return 99;
end

-- Main inventory is container 0; slots are 1-indexed and empty slots report Id == 0.
local function inventory()
    return AshitaCore:GetMemoryManager():GetInventory();
end

local function inventory_usage()
    local inv = inventory();
    if (inv == nil) then
        return 0, 80;
    end
    local used = inv:GetContainerCount(0) or 0;
    local max  = inv:GetContainerCountMax(0) or 80;
    if (max <= 0) then
        max = 80;
    end
    return used, max;
end

-- Withdrawals land in a NEW free slot first (never top off a partial stack), so room = free_slots * stack.
local function withdraw_capacity(e)
    if (e == nil or e.id == nil) then
        return 0, 0;
    end
    local inv = inventory();
    if (inv == nil) then
        return 0, 0;
    end
    local id    = e.id;
    local stack = stack_size(id);
    local used, max = inventory_usage();
    local have = 0;
    for i = 1, max do
        local slot = inv:GetContainerItem(0, i);
        if (slot ~= nil and slot.Id == id and (slot.Count or 0) > 0) then
            have = have + slot.Count;
        end
    end
    local free = math.max(0, max - used);
    local fit  = free * stack;
    return have, math.min(fit, e.quantity or fit);
end

local function aggregate_inventory()
    local rows = {};
    local inv  = inventory();
    if (inv ~= nil) then
        local _, max = inventory_usage();
        for i = 1, max do
            local slot = inv:GetContainerItem(0, i);
            if (slot ~= nil and slot.Id ~= 0 and (slot.Count or 0) > 0) then
                local id = slot.Id;
                if ((not storable_loaded) or storable_set[id]) then
                    local r = rows[id];
                    if (r == nil) then
                        r = { id = id, count = 0, name = item_full_name(id) or ('Item#' .. id) };
                        rows[id] = r;
                    end
                    r.count = r.count + (slot.Count or 0);
                end
            end
        end
    end
    local list = {};
    for _, r in pairs(rows) do
        list[#list + 1] = r;
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end);
    return list;
end

-- Send via the chat manager so typed-chat and server permission rules apply.
local function send_to_server(cmd)
    AshitaCore:GetChatManager():QueueCommand(1, cmd);
end

-- Ashita has no coroutine.schedule; run deferred actions from d3d_present.
local pending = {};
local function schedule(delay, fn)
    pending[#pending + 1] = { at = os.clock() + delay, fn = fn };
end
local function run_due_timers()
    if (#pending == 0) then
        return;
    end
    local now = os.clock();
    local i = 1;
    while (i <= #pending) do
        if (now >= pending[i].at) then
            local fn = pending[i].fn;
            table.remove(pending, i);
            local ok, err = pcall(fn);
            if (not ok) then
                print_error('Deferred action failed: ' .. tostring(err));
            end
        else
            i = i + 1;
        end
    end
end

-- Sync collects dump lines until the header's N lands or a timeout fires; cache is replaced only on an authoritative dump.
local SYNC_COOLDOWN = 10;        -- matches the server-side per-player guard
local SYNC_IDLE     = 3.0;       -- finalise this long after the last dump line
local SYNC_HARD     = 15.0;      -- absolute ceiling for a single sync

local sync = {
    active        = false,
    buffer        = {},          -- key -> entry
    expected      = nil,         -- from header, if seen
    collected     = 0,
    authoritative = false,       -- header seen or explicit-empty seen
    idle_deadline = 0,
    hard_deadline = 0,
};
local last_sync_request = -math.huge;

local function begin_sync()
    sync.active        = true;
    sync.buffer        = {};
    sync.expected      = nil;
    sync.collected     = 0;
    sync.authoritative = false;
    sync.idle_deadline = os.clock() + SYNC_IDLE;
    sync.hard_deadline = os.clock() + SYNC_HARD;
end

cancel_sync = function()
    sync.active = false;
    sync.buffer = {};
end

local function commit_sync()
    if (sync.authoritative or next(sync.buffer) ~= nil) then
        local fresh = T{};
        for k, v in pairs(sync.buffer) do
            fresh[k] = v;
        end
        retainer.settings.cache = fresh;
        save_cache();
        set_status(('Synced %d stored materials.'):fmt(cache_count()));
    else
        -- Nothing authoritative arrived: keep the old cache rather than blanking the panel.
        set_status('Sync returned no data -- previous list kept.');
    end
    sync.active = false;
    sync.buffer = {};
end

local function request_sync()
    local now = os.clock();
    local wait = SYNC_COOLDOWN - (now - last_sync_request);
    if (wait > 0) then
        set_status(('Sync on cooldown (%ds).'):fmt(math.ceil(wait)));
        return;
    end
    last_sync_request = now;
    begin_sync();
    set_status('Requesting full list...');
    send_to_server('!retainer list');
end

-- `!retainer store` sweeps all storable mats into the retainer; resync once cooldown allows is the source of truth.
local function store_all()
    send_to_server('!retainer store');
    set_status('Storing all crafting materials from inventory...');
    local waited = SYNC_COOLDOWN - (os.clock() - last_sync_request);
    local delay  = (waited > 0) and (waited + 0.5) or 2.0;
    schedule(delay, request_sync);
end

-- Ask the server for the storable-item catalog (one-off; cached to settings).
local function request_storable()
    -- Reset staging so a new refresh starts clean; the live set stays until it completes.
    storable_incoming = nil;
    storable_incoming_expected = 0;
    send_to_server('!retainer storable');
    set_status('Requesting storable catalog...');
end

-- Deposit a specific item: `!retainer store <id> <qty>` (qty<=0 = all of it).
local function store_item(id, qty)
    if (id == nil) then
        return;
    end
    qty = qty and math.floor(qty) or 0;
    if (qty > 0) then
        send_to_server('!retainer store ' .. id .. ' ' .. qty);
    else
        send_to_server('!retainer store ' .. id);
    end
    set_status('Storing item...');
    local waited = SYNC_COOLDOWN - (os.clock() - last_sync_request);
    local delay  = (waited > 0) and (waited + 0.5) or 2.0;
    schedule(delay, request_sync);
end

local function withdraw(e, amount)
    if (e.id == nil) then
        set_status('Run Sync first so this item has an ID to withdraw by.');
        return;
    end
    amount = math.floor(amount);
    if (amount < 1) then
        return;
    end
    -- Clamp to what the bags can receive; the server drops the overflow but the cache would wrongly zero out.
    local _, fit = withdraw_capacity(e);
    if (fit <= 0) then
        set_status('Inventory full -- make room before withdrawing.');
        return;
    end
    local clamped = amount > fit;
    if (clamped) then
        amount = fit;
    end
    send_to_server('!retainer ' .. e.id .. ' ' .. amount);
    -- Optimistic decrement: cooldown blocks an auto-resync, so the user re-Syncs to reconcile a refusal.
    e.quantity = math.max(0, (e.quantity or 0) - amount);
    if (e.quantity <= 0) then
        cache()[entry_key(e)] = nil;
    end
    save_cache();
    if (clamped) then
        set_status(('Only %d fit in your bags -- withdrawing that many %s...'):fmt(amount, display_name(e)));
    else
        set_status(('Withdrawing %d %s...'):fmt(amount, display_name(e)));
    end
end

local ARROW = string.char(0x81) .. string.char(0xA8); -- SJIS right-arrow used by the server

local function split_craft_type(details)
    local c, t = details:match('^(.-)%s*' .. ARROW .. '%s*(.-)$');
    if (c) then
        return trim(c), trim(t);
    end
    -- Defensive fallbacks if the arrow ever comes through transliterated.
    c, t = details:match('^(.-)%s*%->%s*(.-)$');
    if (c) then
        return trim(c), trim(t);
    end
    c, t = details:match('^(.-)%s*|%s*(.-)$');
    if (c) then
        return trim(c), trim(t);
    end
    return trim(details), '';
end

local function add_dump_entry(id, qty, name_dump, craft, itype, rname)
    local e = {
        id        = id,
        quantity  = qty,
        name_dump = name_dump,
        craft     = craft,
        type      = itype,
        retainer  = rname,
        last_seen = os.time(),
    };
    sync.buffer[entry_key(e)] = e;
    sync.collected = sync.collected + 1;
    sync.idle_deadline = os.clock() + SYNC_IDLE;
end

-- Returns true for dump lines (hidden when hide_dump_lines is on); status replies return false to stay visible.
local function handle_incoming(original)
    local body = clean_line(original);
    if (body == '') then
        return false;
    end
    -- Never re-parse our own chat output (avoids any feedback loop).
    if (body:sub(1, #('[' .. addon.name .. ']')) == ('[' .. addon.name .. ']')) then
        return false;
    end

    -- Header: "<R> : Listing N stored materials."
    local hr, hn = body:match('^(.-)%s*:%s*Listing%s+(%d+)%s+stored materials%.?$');
    if (hn) then
        retainer.retainer_name = trim(hr);
        if (not sync.active) then
            begin_sync();
        end
        sync.expected      = tonumber(hn);
        sync.authoritative = true;
        set_status(('Receiving %s items...'):fmt(hn));
        return true;
    end

    -- Storable catalog dump: header then chunked CSV ID lines, staged and only swapped when complete.
    local slist_n = body:match(':%s*Storable list:%s*(%d+)%s+item types');
    if (slist_n) then
        storable_incoming = {};
        storable_incoming_expected = tonumber(slist_n) or 0;
        set_status('Receiving storable catalog (' .. slist_n .. ')...');
        return true;
    end
    local idcsv = body:match(':%s*Storable IDs:%s*([%d%s,]+)$');
    if (idcsv) then
        -- Stage even if the header was lost, so chunks aren't unioned onto the previous catalog.
        if (storable_incoming == nil) then
            storable_incoming = {};
        end
        for idstr in idcsv:gmatch('%d+') do
            storable_incoming[tonumber(idstr)] = true;
        end
        local have = 0;
        for _ in pairs(storable_incoming) do have = have + 1; end
        -- No end-of-dump marker: commit once staged count hits the header total; without it, keep staging.
        if (storable_incoming_expected > 0 and have >= storable_incoming_expected) then
            storable_set     = storable_incoming;
            storable_loaded  = true;
            storable_expected = storable_incoming_expected;
            storable_incoming = nil;
            save_storable();
            set_status(('Storable catalog ready (%d items).'):fmt(storable_count()));
        elseif (storable_incoming_expected > 0) then
            set_status(('Receiving storable catalog (%d/%d)...'):fmt(have, storable_incoming_expected));
        else
            -- Header was lost, so the total is unknown; show raw progress.
            set_status(('Receiving storable catalog (%d received)...'):fmt(have));
        end
        return true;
    end

    -- Material line: "<R> : I have <qty> <item>. (<craft> -> <type>) #<id>"
    local rn, qty, iname, details, idstr =
        body:match('^(.-)%s*:%s*I have%s+(%d+)%s+(.-)%s*%((.+)%)%s*#?(%d*)%s*$');
    if (qty) then
        retainer.retainer_name = trim(rn);
        local id = tonumber(idstr);
        iname = trim((iname:gsub('%.%s*$', '')));
        local craft, itype = split_craft_type(details);
        if (id) then
            if (not sync.active) then
                begin_sync();
            end
            add_dump_entry(id, tonumber(qty) or 0, iname, craft, itype, retainer.retainer_name);
            if (sync.expected and sync.collected >= sync.expected) then
                commit_sync();
            end
            return true;
        end
        -- No id: a lookup or post-withdraw echo (reports pre-withdraw qty); don't touch the cache.
        set_status(('%s: %s x%s'):fmt(retainer.retainer_name, iname, qty));
        return false;
    end

    -- Status replies matched on exact server phrasing; sync control only acts while a sync is in flight.
    if (sync.active and body:find('Please wait a moment before requesting the full list again', 1, true)) then
        set_status('Server says: full list on cooldown, try again shortly.');
        cancel_sync();
        return false;
    end
    if (sync.active and body:find('I am not holding any materials for you', 1, true)) then
        sync.authoritative = true;
        commit_sync();
        set_status('Retainer is holding no materials.');
        return false;
    end
    if (body:find('I do not recognize that item', 1, true)) then
        set_status('Server did not recognise the requested item.');
        return false;
    end
    if (body:find('Please finish your current retainer conversation first', 1, true)) then
        set_status('Finish your current retainer conversation first.');
        return false;
    end
    if (body:find('near a Call Retainer to withdraw items', 1, true)) then
        set_status('Withdraw only works in your Mog House or near a Call Retainer.');
        return false;
    end
    if (body:find('You do not have Nomad access', 1, true)) then
        set_status('No Nomad access -- buy it at a Retainer Services office to withdraw remotely.');
        return false;
    end
    -- Withdraw refusal: our optimistic decrement may now be wrong, so schedule a reconciling resync.
    if (body:find('You cannot remove', 1, true) or body:find('You can only remove', 1, true)) then
        set_status('Withdraw refused by server -- re-syncing to correct the cached count...');
        local waited = SYNC_COOLDOWN - (os.clock() - last_sync_request);
        local delay  = (waited > 0) and (waited + 0.5) or 1.0;
        schedule(delay, request_sync);
        return false;
    end

    return false;
end

local function matches_filter(e, f)
    if (f == '') then
        return true;
    end
    f = f:lower();
    return (display_name(e):lower():find(f, 1, true)
        or (e.name_dump or ''):lower():find(f, 1, true)
        or (e.craft or ''):lower():find(f, 1, true)
        or (e.type or ''):lower():find(f, 1, true)
        or (e.id and tostring(e.id):find(f, 1, true))) ~= nil;
end

-- Filtered then grouped by craft; returns ordered { craft, rows={entries...}, total=<sum qty> }.
local function build_groups()
    local f = norm(ui.filter[1]);
    local by_craft = {};
    for _, e in pairs(cache()) do
        if (matches_filter(e, f)) then
            local key = (ui.group[1] and (e.craft ~= '' and e.craft)) or 'All Materials';
            key = key or 'Misc';
            local g = by_craft[key];
            if (g == nil) then
                g = { craft = key, rows = {}, total = 0 };
                by_craft[key] = g;
            end
            g.rows[#g.rows + 1] = e;
            g.total = g.total + (e.quantity or 0);
        end
    end
    local groups = {};
    for _, g in pairs(by_craft) do
        table.sort(g.rows, function(a, b) return display_name(a):lower() < display_name(b):lower() end);
        groups[#groups + 1] = g;
    end
    table.sort(groups, function(a, b) return a.craft:lower() < b.craft:lower() end);
    return groups;
end

local function draw_action_row(e)
    imgui.Indent();
    local q = e.quantity or 0;
    if (e.id == nil) then
        imgui.TextColored({ 1.0, 0.8, 0.4, 1.0 }, '(Run Sync to enable withdraw)');
    else
        -- Full pulls the entire stored amount (server delivers across multiple stacks), not capped to one stack.
        local stack     = stack_size(e.id);
        local have, fit = withdraw_capacity(e);
        imgui.TextColored({ 0.6, 0.7, 0.9, 1.0 },
            ('In bags: %d    Room to withdraw: %d'):fmt(have, fit));
        if (fit <= 0) then
            imgui.TextColored({ 1.0, 0.8, 0.4, 1.0 }, 'Inventory full -- make room to withdraw.');
        else
            imgui.Text('Withdraw:');
            imgui.SameLine();
            if (imgui.SmallButton('1###w1_' .. e.id)) then withdraw(e, 1); end
            if (q > 1) then
                -- Stack button only when more than a stack is stored (else Full already covers it).
                if (stack > 1 and q > stack) then
                    imgui.SameLine();
                    if (imgui.SmallButton(('Stack (%d)###ws_%d'):fmt(stack, e.id))) then withdraw(e, stack); end
                end
                local half = math.ceil(q / 2);
                imgui.SameLine();
                if (imgui.SmallButton(('Half (%d)###wh_%d'):fmt(half, e.id))) then withdraw(e, half); end
                imgui.SameLine();
                if (imgui.SmallButton(('Full (%d)###wf_%d'):fmt(q, e.id))) then withdraw(e, q); end
            end
        end
    end
    imgui.Unindent();
end

local function draw_row(e)
    local key   = entry_key(e);
    local label = ('%s   x%d'):fmt(display_name(e), e.quantity or 0);
    if (not ui.group[1] and (e.craft or '') ~= '') then
        label = label .. '   (' .. e.craft .. (e.type ~= '' and (' / ' .. e.type) or '') .. ')';
    elseif ((e.type or '') ~= '') then
        label = label .. '   (' .. e.type .. ')';
    end
    local selected = (ui.selected_key == key);
    if (imgui.Selectable(label .. '###row_' .. key, selected)) then
        ui.selected_key = selected and nil or key;
    end
    if (selected) then
        draw_action_row(e);
    end
end

local function draw_deposit()
    if (storable_loaded) then
        local have = storable_count();
        if (storable_expected > 0 and have < storable_expected) then
            imgui.TextColored({ 1.0, 0.8, 0.4, 1.0 }, ('Storable catalog: %d / %d (incomplete -- click Refresh)'):fmt(have, storable_expected));
        else
            imgui.TextColored({ 0.6, 0.7, 0.9, 1.0 }, ('Storable catalog: %d items'):fmt(have));
        end
    else
        imgui.TextColored({ 1.0, 0.8, 0.4, 1.0 }, 'Storable catalog not loaded (showing all inventory).');
    end
    if (imgui.SmallButton('Refresh catalog###ret_fetchstorable')) then request_storable(); end

    local f     = norm(ui.filter[1]);
    local list  = aggregate_inventory();
    local shown = 0;

    for _, r in ipairs(list) do
        if (f == '' or r.name:lower():find(f, 1, true) or tostring(r.id):find(f, 1, true)) then
            shown = shown + 1;
            local key      = 'inv:' .. r.id;
            local selected = (ui.selected_key == key);
            if (imgui.Selectable(('%s   x%d###deprow_%d'):fmt(r.name, r.count, r.id), selected)) then
                ui.selected_key = selected and nil or key;
            end
            if (selected) then
                imgui.Indent();
                local stack = stack_size(r.id);
                imgui.Text('Store:');
                imgui.SameLine();
                if (imgui.SmallButton('1###dep1_' .. r.id)) then store_item(r.id, 1); end
                if (r.count > 1) then
                    if (stack > 1 and r.count > stack) then
                        imgui.SameLine();
                        if (imgui.SmallButton(('Stack (%d)###deps_%d'):fmt(stack, r.id))) then store_item(r.id, stack); end
                    end
                    local half = math.ceil(r.count / 2);
                    imgui.SameLine();
                    if (imgui.SmallButton(('Half (%d)###deph_%d'):fmt(half, r.id))) then store_item(r.id, half); end
                    imgui.SameLine();
                    if (imgui.SmallButton(('All (%d)###depa_%d'):fmt(r.count, r.id))) then store_item(r.id, 0); end
                end
                imgui.Unindent();
            end
        end
    end

    if (shown == 0) then
        imgui.Text(storable_loaded and '(no storable materials in your inventory)'
                                     or '(inventory empty or no matches)');
    end
end

-- Persist window pos/size when the user drags / resizes (throttled).
local function maybe_save_layout()
    local pos_x, pos_y   = imgui.GetWindowPos();
    local size_x, size_y = imgui.GetWindowSize();
    ensure_settings();

    local changed =
        retainer.settings.ui.window_pos_x ~= pos_x or
        retainer.settings.ui.window_pos_y ~= pos_y or
        retainer.settings.ui.window_size_w ~= size_x or
        retainer.settings.ui.window_size_h ~= size_y;

    if (changed) then
        retainer.settings.ui.window_pos_x  = pos_x;
        retainer.settings.ui.window_pos_y  = pos_y;
        retainer.settings.ui.window_size_w = size_x;
        retainer.settings.ui.window_size_h = size_y;
        persist_ui_state(false);
    end
end

local function view_button(label, mode)
    local tinted = (ui.view == mode);
    if (tinted) then
        imgui.PushStyleColor(ImGuiCol_Button,        { 0.30, 0.50, 0.80, 1.0 });
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.40, 0.60, 0.90, 1.0 });
        imgui.PushStyleColor(ImGuiCol_ButtonActive,  { 0.50, 0.70, 1.00, 1.0 });
    end
    if (imgui.Button(label)) then
        if (ui.view ~= mode) then
            ui.selected_key = nil;
        end
        ui.view = mode;
        persist_ui_state(true);
        if (mode == 'deposit' and not storable_loaded) then
            request_storable();
        end
    end
    if (tinted) then
        imgui.PopStyleColor(3);
    end
end

local function draw_menu()
    if (not ui.visible[1]) then
        return;
    end

    imgui.PushStyleColor(ImGuiCol_WindowBg,      { 0.08, 0.08, 0.10, 0.90 });
    imgui.PushStyleColor(ImGuiCol_TitleBg,       { 0.10, 0.10, 0.12, 0.85 });
    imgui.PushStyleColor(ImGuiCol_TitleBgActive, { 0.14, 0.14, 0.18, 0.95 });
    imgui.PushStyleColor(ImGuiCol_Border,        { 0.35, 0.35, 0.40, 0.60 });
    imgui.PushStyleColor(ImGuiCol_Header,        { 0.20, 0.24, 0.30, 0.70 });
    imgui.PushStyleColor(ImGuiCol_HeaderHovered, { 0.24, 0.28, 0.34, 0.85 });
    imgui.PushStyleColor(ImGuiCol_HeaderActive,  { 0.28, 0.32, 0.38, 0.95 });
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 8, 8 });
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing,   { 6, 4 });
    imgui.SetNextWindowPos({ retainer.settings.ui.window_pos_x, retainer.settings.ui.window_pos_y }, ImGuiCond_Appearing);
    imgui.SetNextWindowSize({ retainer.settings.ui.window_size_w, retainer.settings.ui.window_size_h }, ImGuiCond_Appearing);

    -- Locked = fixed overlay (NoTitleBar/NoMove/NoResize). p_open MUST stay non-nil or imgui.Begin ignores flags.
    local flags    = ImGuiWindowFlags_NoSavedSettings;
    local open_ref = ui.visible;
    if (retainer.settings.ui.locked) then
        flags = bit.bor(flags, ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoMove, ImGuiWindowFlags_NoResize);
    end

    if (imgui.Begin('Retainer###retainer_panel', open_ref, flags)) then
        -- Drop a stale stored selection withdrawn/re-synced away; deposit ('inv:<id>') keys live in inventory.
        if (ui.view == 'stored' and ui.selected_key ~= nil
            and tostring(ui.selected_key):sub(1, 4) ~= 'inv:'
            and cache()[ui.selected_key] == nil) then
            ui.selected_key = nil;
        end

        local wait = SYNC_COOLDOWN - (os.clock() - last_sync_request);
        local sync_label = wait > 0 and ('Sync (%ds)###ret_sync'):fmt(math.ceil(wait)) or 'Sync###ret_sync';
        if (imgui.Button(sync_label)) then request_sync(); end
        imgui.SameLine();
        if (imgui.Button('Hide###ret_hide')) then
            ui.visible[1] = false;
            persist_ui_state(true);
        end
        imgui.SameLine();
        if (imgui.Button('Store All Mats###ret_store')) then store_all(); end
        imgui.Text(('%d items  |  Retainer: %s'):fmt(cache_count(), retainer.retainer_name or '-'));

        -- Always-visible bag fill: a full bag can't receive a withdrawal.
        local inv_used, inv_max = inventory_usage();
        if (inv_used >= inv_max) then
            imgui.TextColored({ 1.0, 0.45, 0.45, 1.0 }, ('Inventory: %d/%d (FULL)'):fmt(inv_used, inv_max));
        else
            imgui.TextColored({ 0.6, 0.8, 0.6, 1.0 }, ('Inventory: %d/%d'):fmt(inv_used, inv_max));
        end

        imgui.TextColored({ 0.7, 0.8, 1.0, 1.0 }, retainer.status_text);
        imgui.Separator();

        view_button('Stored###ret_view_stored', 'stored');
        imgui.SameLine();
        view_button('Deposit###ret_view_deposit', 'deposit');

        imgui.Text('Filter:');
        imgui.SameLine();
        if (imgui.InputText('###ret_filter', ui.filter, ui.filter_size)) then
            persist_ui_state(false);
        end
        if (ui.view == 'stored') then
            if (imgui.Checkbox('Group by craft###ret_group', ui.group)) then
                persist_ui_state(true);
            end
        end

        imgui.Separator();

        if (ui.view == 'deposit') then
            draw_deposit();
        else
            local groups = build_groups();
            if (#groups == 0) then
                if (cache_count() == 0) then
                    imgui.Text('(no materials cached -- click Sync near your retainer)');
                else
                    imgui.Text('(no items match the filter)');
                end
            elseif (ui.group[1]) then
                for _, g in ipairs(groups) do
                    local header = ('%s   (%d items, %d total)###grp_%s'):fmt(
                        g.craft, #g.rows, g.total, g.craft);
                    if (imgui.CollapsingHeader(header)) then
                        imgui.Indent();
                        for _, e in ipairs(g.rows) do draw_row(e); end
                        imgui.Unindent();
                    end
                end
            else
                for _, g in ipairs(groups) do
                    for _, e in ipairs(g.rows) do draw_row(e); end
                end
            end
        end

        maybe_save_layout();
    end

    imgui.End();
    imgui.PopStyleVar(2);
    imgui.PopStyleColor(7);

    -- Persist every frame (throttled) so a title-bar [X] close (flips ui.visible inside Begin) is remembered too.
    persist_ui_state(false);
end

local function toggle_ui()
    ui.visible[1] = not ui.visible[1];
    persist_ui_state(true);
    print_status('Panel ' .. (ui.visible[1] and 'shown' or 'hidden') .. '.');
end

local function print_help()
    print_status('=== AvalonXI Retainer ===');
    local commands = T{
        { '/retainer',                  'toggle the panel (alias /ret)' },
        { '/retainer show|hide|toggle', 'explicit show / hide / toggle' },
        { '/retainer sync',             'fetch the full stored list (!retainer list)' },
        { '/retainer store',            'deposit ALL storable crafting mats from inventory' },
        { '/retainer deposit',          'open the per-item Deposit view' },
        { '/retainer storable',         'fetch the storable-item catalog (Deposit filter)' },
        { '/retainer group [on|off]',   'group stored items by craft' },
        { '/retainer lock [on|off]',    'lock the window as a fixed overlay (no move/resize/[X])' },
        { '/retainer clear',            'wipe the local cache for this character' },
        { '/retainer hidelines [on|off]', 'hide the raw dump spam during sync' },
        { '/retainer query <item|id>',  'one-off !retainer lookup (no cache)' },
        { '/retainer reload',           'reload settings from disk' },
        { '/retainer reset',            'reset settings (incl. cache) to defaults' },
        { '/retainer help',             'this list' },
    };
    commands:ieach(function (entry)
        print(chat.header(addon.name):append(chat.error('Usage: ')):append(chat.message(entry[1]):append(' - ')):append(chat.color1(6, entry[2])));
    end);
    print_status('Tip: open it near a Call Retainer or in your Mog House to withdraw.');
end

local function on_off(arg, current)
    local a = (arg or ''):lower();
    if (a == 'on' or a == 'true' or a == '1') then
        return true;
    elseif (a == 'off' or a == 'false' or a == '0') then
        return false;
    end
    return not current;
end

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or (args[1] ~= '/retainer' and args[1] ~= '/ret')) then
        return;
    end

    e.blocked = true;

    local cmd = (args[2] and args[2]:lower()) or '';

    if (cmd == '' or cmd == 'toggle') then
        toggle_ui();
        return;
    end

    if (cmd == 'show') then
        ui.visible[1] = true;
        persist_ui_state(true);
        print_status('Panel shown.');
        return;
    end

    if (cmd == 'hide') then
        ui.visible[1] = false;
        persist_ui_state(true);
        return;
    end

    if (cmd == 'sync' or cmd == 'refresh' or cmd == 'list') then
        request_sync();
        print_status(retainer.status_text);
        return;
    end

    if (cmd == 'store' or cmd == 'storeall') then
        store_all();
        print_status(retainer.status_text);
        return;
    end

    if (cmd == 'deposit') then
        ui.visible[1] = true;
        ui.view = 'deposit';
        ui.selected_key = nil;
        if (not storable_loaded) then request_storable(); end
        persist_ui_state(true);
        return;
    end

    if (cmd == 'storable') then
        request_storable();
        print_status(retainer.status_text);
        return;
    end

    if (cmd == 'group') then
        ui.group[1] = on_off(args[3], ui.group[1]);
        persist_ui_state(true);
        print_status('Group by craft ' .. (ui.group[1] and 'ON' or 'OFF') .. '.');
        return;
    end

    if (cmd == 'lock') then
        retainer.settings.ui.locked = on_off(args[3], retainer.settings.ui.locked);
        persist_ui_state(true);
        print_status(retainer.settings.ui.locked and 'Window locked.' or 'Window unlocked.');
        return;
    end

    if (cmd == 'clear') then
        retainer.settings.cache = T{};
        ui.selected_key = nil;
        save_cache();
        set_status('Local cache cleared.');
        print_status('Local cache cleared.');
        return;
    end

    if (cmd == 'hidelines') then
        retainer.settings.ui.hide_dump_lines = on_off(args[3], retainer.settings.ui.hide_dump_lines);
        persist_ui_state(true);
        print_status('Hide dump lines ' .. (retainer.settings.ui.hide_dump_lines and 'ON' or 'OFF') .. '.');
        return;
    end

    if (cmd == 'query') then
        local q = trim(table.concat(args, ' ', 3));
        if (q == '') then
            print_error('Provide an item name or id, e.g. /retainer query 4096');
            return;
        end
        send_to_server('!retainer ' .. q);
        set_status('Queued !retainer ' .. q);
        print_status(retainer.status_text);
        return;
    end

    if (cmd == 'reload' or cmd == 'rl') then
        settings.reload();
        ensure_settings();
        sync_ui_from_settings();
        rebuild_storable_set();
        set_status('Settings reloaded from disk.');
        print_status(retainer.status_text);
        return;
    end

    if (cmd == 'reset') then
        settings.reset();
        ensure_settings();
        sync_ui_from_settings();
        rebuild_storable_set();
        ui.selected_key = nil;
        set_status('Settings reset to defaults.');
        print_status(retainer.status_text);
        return;
    end

    if (cmd == 'help') then
        print_help();
        return;
    end

    print_error('Unknown command -- try /retainer help');
end);

ashita.events.register('text_in', 'text_in_cb', function (e)
    -- Skip our own injected output and lines another addon/chat filter already blocked.
    if (e.injected or e.blocked) then
        return;
    end
    local block = handle_incoming(e.message);
    if (block and retainer.settings.ui.hide_dump_lines) then
        e.blocked = true;
    end
end);

ashita.events.register('d3d_present', 'present_cb', function ()
    -- Run deferred resyncs + sync timeouts even when the window is hidden.
    run_due_timers();
    if (sync.active) then
        local now = os.clock();
        if (now >= sync.hard_deadline or now >= sync.idle_deadline) then
            commit_sync();
        end
    end
    draw_menu();
end);

ashita.events.register('load', 'load_cb', function ()
    ensure_settings();
    sync_ui_from_settings();
    rebuild_storable_set();
end);

ashita.events.register('unload', 'unload_cb', function ()
    settings.save();
end);
