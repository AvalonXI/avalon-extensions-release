addon.name      = 'charmchance';
addon.author    = 'Aeshur';
addon.version   = '1.5';
addon.desc      = 'Estimates charm success for your current target.';
addon.link      = 'https://ashitaxi.com/';

require('common');
local bit = require('bit');
local chat = require('chat');
local imgui = require('imgui');
local settings = require('settings');

local addon_directory = (debug.getinfo(1, 'S').source or ''):match('^@(.+[\\/])[^\\/]+$') or '';

local function load_lua_table(file_path)
    local chunk, load_error = loadfile(file_path);
    if (chunk ~= nil) then
        return chunk(), file_path;
    end

    return nil, load_error;
end

local function require_generated_module(primary_relative_path, fallback_relative_path, fallback_module_name)
    local attempts = T{};

    if (addon_directory ~= '') then
        local primary_result, primary_meta = load_lua_table(addon_directory .. primary_relative_path);
        if (primary_result ~= nil) then
            return primary_result, primary_meta;
        end
        attempts:append(tostring(primary_meta));

        if (fallback_relative_path ~= nil) then
            local fallback_result, fallback_meta = load_lua_table(addon_directory .. fallback_relative_path);
            if (fallback_result ~= nil) then
                return fallback_result, fallback_meta;
            end
            attempts:append(tostring(fallback_meta));
        end
    end

    if (fallback_module_name ~= nil) then
        local ok_fallback, fallback_result = pcall(require, fallback_module_name);
        if (ok_fallback) then
            return fallback_result, fallback_module_name;
        end
        attempts:append(tostring(fallback_result));
    end

    error(('charmchance: could not load generated data file "%s". The addon\'s data/ subfolder must contain the generated lookup tables.\nAttempts:\n  %s'):fmt(
        primary_relative_path,
        table.concat(attempts, '\n  ')
    ));
end

local charm_data = nil;
local charm_data_module_name = nil;
charm_data, charm_data_module_name = require_generated_module('data/charm_data.lua', 'charm_data.lua', 'charm_data');

local JOB_BST = 9;
local MOB_SPAWN_FLAG = 0x10;
local PET_SPAWN_FLAG = 0x100;
local PARTY_MEMBER_SPAWN_FLAG = 0x04;
local ALLIANCE_MEMBER_SPAWN_FLAG = 0x08;

-- Inventory pointer-chain offset to the merit-table header; tied to the Ashita v4 client build.
local MERIT_TABLE_OFFSET = 0x28A44;

-- Fixed panel colours kept OUT of settings: a pre-1.4 d3dcolor-integer settings file would collide with this {r,g,b,a} form on merge.
local PANEL_COLORS = {
    good  = { 0.37, 0.84, 0.37, 1.0 },
    warn  = { 0.96, 0.84, 0.37, 1.0 },
    bad   = { 0.92, 0.36, 0.36, 1.0 },
    muted = { 0.76, 0.76, 0.76, 1.0 },
    label = { 0.90, 0.90, 0.94, 1.0 },
};

local function make_default_hud_settings()
    return T{
        visible = true,
        locked = false,
        window_pos_x = 40,
        window_pos_y = 140,
        window_size_w = 200,
        window_size_h = 88,
    };
end

local default_settings = T{
    enabled = true,
    hud = make_default_hud_settings(),
};

local merit_cache = {};
local charm_lookup = nil;
local charm_lookup_module_name = nil;

local charm = T{
    settings = settings.load(default_settings),
    current = T{
        value = '',                       -- the % string ('85%', '0%') or '' when unresolved
        value_color = PANEL_COLORS.muted,
        has_mob = false,                   -- a displayable enemy mob is targeted (controls visibility)
        target_index = 0,
        target_server_id = 0,
    },
    last_target_index = 0,
    last_target_server_id = 0,
    last_refresh_at = 0,
};

local function ensure_settings()
    if (charm.settings == nil) then
        charm.settings = settings.load(default_settings);
    end

    if (charm.settings.enabled == nil) then
        charm.settings.enabled = true;
    end

    if (charm.settings.hud == nil) then
        charm.settings.hud = make_default_hud_settings();
    end

    local defaults = make_default_hud_settings();
    for key, value in pairs(defaults) do
        if (charm.settings.hud[key] == nil) then
            charm.settings.hud[key] = value;
        end
    end
end

local function clear_current()
    ensure_settings();
    charm.current.value = '';
    charm.current.value_color = PANEL_COLORS.muted;
    charm.current.target_index = 0;
    charm.current.target_server_id = 0;
    charm.current.has_mob = false;
end

local function update_settings(s)
    if (s ~= nil) then
        charm.settings = s;
    end

    ensure_settings();
    settings.save();
end

settings.register('settings', 'settings_update', update_settings);

local function print_status(message)
    print(chat.header(addon.name):append(chat.message(message)));
end

local function print_error(message)
    print(chat.header(addon.name):append(chat.error(message)));
end

local function print_help(is_error)
    if (is_error) then
        print_error('Invalid command syntax.');
    else
        print_status('Available commands:');
    end

    local commands = T{
        { '/charm', 'Toggle the charm % panel (also /charm toggle).' },
        { '/charm chance', 'Estimate charm success for the current monster target in chat.' },
        { '/charm lock [on|off]', 'Lock the panel as a fixed overlay (no move/resize/close).' },
        { '/charm reload', 'Reload the addon settings from disk.' },
        { '/charm reset', 'Reset the addon settings to defaults.' },
        { '/charm help', 'Display this help text.' },
    };

    commands:ieach(function (entry)
        print(chat.header(addon.name):append(chat.error('Usage: ')):append(chat.message(entry[1]):append(' - ')):append(chat.color1(6, entry[2])));
    end);
end

local function clamp(value, min_value, max_value)
    if (value < min_value) then
        return min_value;
    end

    if (value > max_value) then
        return max_value;
    end

    return value;
end

local function sanitize_name(name)
    if (name == nil) then
        return '';
    end

    return tostring(name):gsub('%z', '');
end

local function normalize_name(name)
    local sanitized = sanitize_name(name):lower();
    sanitized = sanitized:gsub('[^%w]+', ' ');
    sanitized = sanitized:gsub('%s+', ' ');
    return sanitized:match('^%s*(.-)%s*$') or '';
end

local function player_is_ready()
    local party = AshitaCore:GetMemoryManager():GetParty();
    return party:GetMemberIsActive(0) ~= 0 and party:GetMemberServerId(0) ~= 0;
end

local function get_current_zone_id()
    return AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
end

local function get_target()
    if (not player_is_ready()) then
        return nil, 0;
    end

    local target_index = AshitaCore:GetMemoryManager():GetTarget():GetTargetIndex(0);
    if (target_index == 0) then
        return nil, 0;
    end

    local target = GetEntity(target_index);
    if (target == nil) then
        return nil, target_index;
    end

    if (bit.band(target.SpawnFlags or 0, MOB_SPAWN_FLAG) == 0) then
        return nil, target_index;
    end

    return target, target_index;
end

local function get_target_display_name(target, target_index)
    local name = sanitize_name(target ~= nil and target.Name or nil);
    if (name ~= '') then
        return name;
    end

    local entity_manager = AshitaCore:GetMemoryManager():GetEntity();
    name = sanitize_name(entity_manager:GetName(target_index));
    if (name ~= '') then
        return name;
    end

    return 'Target';
end

local function is_pet_like_target(target_index)
    if (target_index < 0x700) then
        return false;
    end

    local entity_manager = AshitaCore:GetMemoryManager():GetEntity();
    return entity_manager:GetTrustOwnerTargetIndex(target_index) ~= 0;
end

local function is_displayable_enemy_mob(target, target_index)
    if (target == nil) then
        return false;
    end

    local spawn_flags = target.SpawnFlags or 0;
    if (bit.band(spawn_flags, MOB_SPAWN_FLAG) == 0) then
        return false;
    end

    if (bit.band(spawn_flags, PET_SPAWN_FLAG) ~= 0) then
        return false;
    end

    if (bit.band(spawn_flags, PARTY_MEMBER_SPAWN_FLAG) ~= 0) then
        return false;
    end

    if (bit.band(spawn_flags, ALLIANCE_MEMBER_SPAWN_FLAG) ~= 0) then
        return false;
    end

    return not is_pet_like_target(target_index);
end

local function load_charm_lookup()
    if (charm_lookup ~= nil) then
        return charm_lookup;
    end

    charm_lookup, charm_lookup_module_name = require_generated_module('data/charm_lookup.lua', 'charm_lookup.lua', 'charm_lookup');
    return charm_lookup;
end

local function initialize_merits()
    local inventory_pointer = AshitaCore:GetPointerManager():Get('inventory');
    if (inventory_pointer == 0) then
        return;
    end

    local pointer = ashita.memory.read_uint32(inventory_pointer);
    if (pointer == 0) then
        return;
    end

    pointer = ashita.memory.read_uint32(pointer);
    if (pointer == 0) then
        return;
    end

    pointer = pointer + MERIT_TABLE_OFFSET;
    local count = ashita.memory.read_uint16(pointer + 2);
    local merit_pointer = ashita.memory.read_uint32(pointer + 4);

    merit_cache = {};
    if (count == 0) then
        return;
    end

    for index = 1, count do
        local merit_id = ashita.memory.read_uint16(merit_pointer + 0);
        local merit_upgrades = ashita.memory.read_uint8(merit_pointer + 3);
        merit_cache[merit_id] = merit_upgrades;
        merit_pointer = merit_pointer + 4;
    end
end

local function get_merit_count(merit_id)
    if (merit_cache[merit_id] == nil) then
        initialize_merits();
    end

    return merit_cache[merit_id] or 0;
end

local function get_attribute_merit_value(merit_id, main_level)
    local raw_count = get_merit_count(merit_id);
    local cap_table = charm_data.constants.attribute_merit_cap;
    local capped = cap_table[main_level] or 0;
    if (raw_count > capped) then
        return capped;
    end
    return raw_count;
end

local function get_item_level(item_id)
    local resource = AshitaCore:GetResourceManager():GetItemById(item_id);
    if (resource ~= nil and resource.Level ~= nil) then
        return resource.Level;
    end

    return 0;
end

local function get_equipment_mod_totals(main_level)
    local inventory = AshitaCore:GetMemoryManager():GetInventory();
    local total_chr = 0;
    local total_charm_chance = 0;

    for slot = 0, 15 do
        local equipped_item = inventory:GetEquippedItem(slot);
        local item_index = bit.band(equipped_item.Index, 0x00FF);
        if (item_index > 0) then
            local container_id = bit.rshift(equipped_item.Index, 8);
            local item = inventory:GetContainerItem(container_id, item_index);
            if (item ~= nil and item.Id ~= 0 and item.Count ~= 0) then
                local item_level = get_item_level(item.Id);
                if (main_level >= item_level) then
                    local mods = charm_data.items[item.Id];
                    if (mods ~= nil) then
                        total_chr = total_chr + (mods[1] or 0);
                        total_charm_chance = total_charm_chance + (mods[2] or 0);
                    end
                end
            end
        end
    end

    return total_chr, total_charm_chance;
end

local function get_race_bucket(race_id)
    if (race_id == 1 or race_id == 2) then
        return 0;
    end

    if (race_id == 3 or race_id == 4) then
        return 1;
    end

    if (race_id == 5 or race_id == 6) then
        return 2;
    end

    if (race_id == 7) then
        return 3;
    end

    if (race_id == 8) then
        return 4;
    end

    return 0;
end

local function get_job_chr_grade(job_id)
    return charm_data.constants.job_chr_grades[job_id] or 0;
end

local function get_stat_scale_total(rank, level)
    local scales = charm_data.constants.stat_scale[rank] or charm_data.constants.stat_scale[0];
    local level_up_to_60 = math.min(math.max(level - 1, 0), 59);
    local level_over_60 = math.max(math.min(level - 60, 15), 0);
    local level_over_75 = math.max(level - 75, 0);

    local total = scales[1] + (scales[2] * level_up_to_60);
    if (level_over_60 > 0) then
        total = total + (scales[3] * level_over_60);
        if (level_over_75 > 0) then
            total = total + (scales[4] * level_over_75) - 0.01;
        end
    end

    return total;
end

local function build_player_state()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    local player_entity = GetPlayerEntity();
    if (player == nil or player_entity == nil) then
        return nil;
    end

    local main_job = player:GetMainJob();
    local sub_job = player:GetSubJob();
    local main_level = player:GetMainJobLevel();
    local sub_level = player:GetSubJobLevel();
    local bst_level = player:GetJobLevel(JOB_BST) or 0;
    local race_bucket = get_race_bucket(player_entity.Race or 1);
    local race_grade = charm_data.constants.race_chr_grades[race_bucket] or 0;
    local sub_grade = get_job_chr_grade(sub_job);

    local race_chr = get_stat_scale_total(race_grade, main_level);
    local main_chr = get_stat_scale_total(get_job_chr_grade(main_job), main_level);
    local sub_chr = 0;
    if (sub_level > 0) then
        local sub_scales = charm_data.constants.stat_scale[sub_grade] or charm_data.constants.stat_scale[0];
        sub_chr = (sub_scales[1] + (sub_scales[2] * math.max(sub_level - 1, 0))) / 2;
    end

    local merit_chr = get_attribute_merit_value(charm_data.constants.merit_chr_id, main_level);
    local base_chr = math.floor(race_chr + main_chr + sub_chr + merit_chr);
    local gear_chr, charm_chance_mod = get_equipment_mod_totals(main_level);

    return {
        active_bst = (main_job == JOB_BST) or (sub_job == JOB_BST),
        base_chr = base_chr,
        bst_level = bst_level,
        charm_chance_mod = charm_chance_mod,
        chr = base_chr + gear_chr,
        gear_chr = gear_chr,
        main_job = main_job,
        main_level = main_level,
        merit_chr = merit_chr,
        sub_job = sub_job,
        sub_level = sub_level,
    };
end

local function base_to_rank(rank, level)
    if (rank == 1) then
        return 5 + math.floor(((level - 1) * 50) / 100);
    elseif (rank == 2) then
        return 4 + math.floor(((level - 1) * 45) / 100);
    elseif (rank == 3) then
        return 4 + math.floor(((level - 1) * 40) / 100);
    elseif (rank == 4) then
        return 3 + math.floor(((level - 1) * 35) / 100);
    elseif (rank == 5) then
        return 3 + math.floor(((level - 1) * 30) / 100);
    elseif (rank == 6) then
        return 2 + math.floor(((level - 1) * 25) / 100);
    elseif (rank == 7) then
        return 2 + math.floor(((level - 1) * 20) / 100);
    end

    return 0;
end

local function get_subjob_stat(rank, level, stat)
    local result = stat / 2;

    if (rank == 1) then
        if (level <= 30) then
            result = math.max(math.floor(stat / (4.0 - (0.225 * (level - 30)))), 2.0);
        elseif (level <= 40) then
            result = math.floor(stat / (3.25 - (0.073 * (level - 30))));
        elseif (level <= 46) then
            result = math.floor(stat / (2.55 - (0.001 * (level - 41))));
        else
            result = math.floor(stat / (2.7 - (0.001 * (level - 45))));
        end
    elseif (rank == 2) then
        if (level <= 30) then
            result = math.max(math.floor(stat / (3.1 - (0.075 * (level - 32)))), 2.0);
        elseif (level <= 40) then
            result = math.floor(stat / (3.1 - (0.075 * (level - 32))));
        elseif (level <= 45) then
            result = math.floor(stat / (2.5 - (0.025 * (level - 40))));
        else
            result = math.floor(stat / (2.35 - (0.04 * (level - 44))));
        end
    elseif (rank == 3) then
        if (level <= 30) then
            result = math.max(math.floor(stat / (4.5 - (0.15 * (level - 26)))), 2.0);
        elseif (level <= 40) then
            result = math.floor(stat / (3.28 - (0.001 * (level - 30))));
        elseif (level <= 45) then
            result = math.floor(stat / (2.6 - (0.025 * (level - 40))));
        else
            result = math.floor(stat / (2.1 - (0.2 * (level - 49))));
        end
    elseif (rank == 4) then
        if (level <= 30) then
            result = math.max(math.floor(stat / (5.0 - (0.05 * (level - 21)))), 1.0);
        elseif (level <= 40) then
            result = math.floor(stat / (3.2 - (0.001 * (level - 29))));
        elseif (level <= 45) then
            result = math.floor(stat / (3.5 - (0.08 * (level - 32))));
        else
            result = math.floor(stat / (3.25 - (0.045 * (level - 32))));
        end
    elseif (rank == 5) then
        if (level <= 30) then
            result = math.max(math.floor(stat / (3.8 - (0.1 * (level - 32)))), 1.0);
        elseif (level <= 40) then
            result = math.floor(stat / (3.8 - (0.15 * (level - 32))));
        elseif (level <= 45) then
            result = math.floor(stat / (2.7 - (0.075 * (level - 40))));
        else
            result = math.floor(stat / (2.7 - (0.05 * (level - 45))));
        end
    elseif (rank == 6) then
        if (level <= 30) then
            result = math.max(math.floor(stat / (4.0 - (0.15 * (level - 35)))), 1.0);
        elseif (level <= 40) then
            result = math.floor(stat / (4.0 - (0.15 * (level - 30))));
        elseif (level <= 46) then
            result = math.floor(stat / (3.0 - (0.1125 * (level - 40))));
        else
            result = math.floor(stat / (3.0 - (0.07 * (level - 40))));
        end
    elseif (rank == 7) then
        if (level <= 30) then
            result = math.max(math.floor(stat / (4.0 - (0.15 * (level - 35)))), 1.0);
        elseif (level <= 40) then
            result = math.floor(stat / (4.0 - (0.2 * (level - 31))));
        elseif (level <= 46) then
            result = math.floor(stat / (2.5 - (0.09 * (level - 40))));
        else
            result = math.floor(stat / 2);
        end
    end

    return math.floor(result);
end

local function get_target_chr(pool_entry, zone_id, level)
    local family_chr = base_to_rank(pool_entry[2] or 0, level);
    local main_chr = base_to_rank(get_job_chr_grade(pool_entry[3] or 0), level);
    local sub_grade = get_job_chr_grade(pool_entry[4] or 0);
    local sub_base = base_to_rank(sub_grade, level);
    local sub_chr = 0;

    if ((pool_entry[4] or 0) ~= 0) then
        if (charm_data.constants.original_subjob_zones[zone_id] == true and level < 50) then
            sub_chr = get_subjob_stat(sub_grade, level, sub_base);
        else
            sub_chr = math.floor(sub_base / 2);
        end
    end

    return family_chr + main_chr + sub_chr;
end

local function apply_light_resistance(chance, light_rank)
    if (light_rank <= -3) then
        return chance * 1.5;
    elseif (light_rank <= -2) then
        return chance * 1.4;
    elseif (light_rank <= -1) then
        return chance * 1.2;
    elseif (light_rank > 0) then
        return chance / 2;
    end

    return chance;
end

local function compute_charm_chance(player_state, pool_entry, zone_id, level)
    if ((pool_entry[1] or 0) == 0) then
        return 0, get_target_chr(pool_entry, zone_id, level);
    end

    local chance = 50 - (pool_entry[6] or 0);
    if (player_state.bst_level < level) then
        local delta = level - player_state.bst_level;
        if (level < 51) then
            chance = chance - (delta * 3);
        elseif (level < 71) then
            chance = chance - (delta * 5);
        else
            chance = chance - (delta * 10);
        end
    end

    chance = apply_light_resistance(chance, pool_entry[5] or 0);
    chance = chance + player_state.charm_chance_mod;

    local target_chr = get_target_chr(pool_entry, zone_id, level);
    chance = chance + (player_state.chr - target_chr);
    chance = clamp(chance, 0, 95);
    return chance, target_chr;
end

local function round_to_tenth(value)
    return math.floor((value * 10) + 0.5) / 10;
end

local function format_percent(value)
    local rounded = round_to_tenth(value);
    if (math.abs(rounded - math.floor(rounded)) < 0.001) then
        return ('%d%%'):fmt(math.floor(rounded));
    end

    return ('%.1f%%'):fmt(rounded);
end

local function get_job_abbr(job_id)
    local resource = AshitaCore:GetResourceManager():GetString('jobs.names_abbr', job_id);
    if (resource ~= nil and resource ~= '') then
        return resource;
    end

    return tostring(job_id);
end

local function summarize_candidates(candidates, player_state)
    local min_chance = nil;
    local max_chance = nil;
    local min_level = nil;
    local max_level = nil;
    local min_target_chr = nil;
    local max_target_chr = nil;
    local any_charmable = false;

    for _, candidate in ipairs(candidates) do
        local pool_entry = charm_data.pools[candidate.pool_id] or charm_data.pools[0] or { 0, 0, 0, 0, 0, 0 };
        if (pool_entry ~= nil and (pool_entry[1] or 0) ~= 0) then
            any_charmable = true;
        end

        for level = candidate.min_level, candidate.max_level do
            local chance, target_chr = compute_charm_chance(player_state, pool_entry, candidate.zone_id, level);

            if (min_chance == nil or chance < min_chance) then
                min_chance = chance;
            end
            if (max_chance == nil or chance > max_chance) then
                max_chance = chance;
            end

            if (min_level == nil or level < min_level) then
                min_level = level;
            end
            if (max_level == nil or level > max_level) then
                max_level = level;
            end

            if (min_target_chr == nil or target_chr < min_target_chr) then
                min_target_chr = target_chr;
            end
            if (max_target_chr == nil or target_chr > max_target_chr) then
                max_target_chr = target_chr;
            end
        end
    end

    return {
        any_charmable = any_charmable,
        max_chance = max_chance or 0,
        max_level = max_level or 0,
        max_target_chr = max_target_chr or 0,
        min_chance = min_chance or 0,
        min_level = min_level or 0,
        min_target_chr = min_target_chr or 0,
    };
end

local function resolve_target_candidates(target, target_index)
    local zone_id = get_current_zone_id();
    local zone_lookup = load_charm_lookup()[zone_id];
    if (zone_lookup == nil) then
        return nil, 'zone not exported';
    end

    local key = normalize_name(target.Name);
    if (key == '') then
        local entity_manager = AshitaCore:GetMemoryManager():GetEntity();
        key = normalize_name(entity_manager:GetName(target_index));
    end

    if (key == '') then
        return nil, 'missing target name';
    end

    local lookup_candidates = zone_lookup[key];
    if (lookup_candidates == nil) then
        return nil, 'no zone/name match';
    end

    local candidates = {};
    for _, candidate in ipairs(lookup_candidates) do
        table.insert(candidates, {
            max_level = candidate[3],
            min_level = candidate[2],
            pool_id = candidate[1],
            zone_id = zone_id,
        });
    end

    if (#candidates == 0) then
        return nil, 'no exported candidates';
    end

    return candidates, ('compact zone/name estimate (%d candidates)'):fmt(#candidates);
end

local function build_estimate(player_state, target, target_index)
    local target_name = get_target_display_name(target, target_index);
    local target_server_id = target.ServerId or 0;

    if (is_pet_like_target(target_index)) then
        return {
            candidate_count = 0,
            kind = 'pet',
            player_state = player_state,
            resolution = 'pet target',
            summary = {
                any_charmable = false,
                max_chance = 0,
                max_level = 0,
                max_target_chr = 0,
                min_chance = 0,
                min_level = 0,
                min_target_chr = 0,
            },
            target_index = target_index,
            target_name = target_name,
            target_server_id = target_server_id,
        };
    end

    local candidates, resolution = resolve_target_candidates(target, target_index);
    if (candidates == nil) then
        -- The lookup holds every charmable mob, so an absent enemy is uncharmable, not "no data"; only a name-read failure is a real error.
        if (resolution == 'missing target name') then
            return nil, resolution;
        end
        return {
            candidate_count = 0,
            kind = 'uncharmable',
            player_state = player_state,
            resolution = resolution,
            summary = {
                any_charmable = false,
                max_chance = 0,
                max_level = 0,
                max_target_chr = 0,
                min_chance = 0,
                min_level = 0,
                min_target_chr = 0,
            },
            target_index = target_index,
            target_name = target_name,
            target_server_id = target_server_id,
        };
    end

    return {
        candidate_count = #candidates,
        kind = 'estimate',
        player_state = player_state,
        resolution = resolution,
        summary = summarize_candidates(candidates, player_state),
        target_index = target_index,
        target_name = target_name,
        target_server_id = target_server_id,
    };
end

local function estimate_current_target()
    local player_state = build_player_state();
    if (player_state == nil) then
        return nil, 'Player data is not ready yet.';
    end

    if (player_state.bst_level <= 0) then
        return nil, 'Stored BST level is 0 on this character; charm is unavailable.';
    end

    local target, target_index = get_target();
    if (target == nil) then
        return nil, 'Select a monster target first.';
    end

    local estimate, resolution = build_estimate(player_state, target, target_index);
    if (estimate == nil) then
        return nil, ('Could not resolve target data (%s).'):fmt(resolution);
    end

    return estimate;
end

local function format_summary_fields(summary)
    local chance_text = format_percent(summary.min_chance);
    if (math.abs(summary.max_chance - summary.min_chance) > 0.01) then
        chance_text = chance_text .. ' to ' .. format_percent(summary.max_chance);
    end

    local level_text = tostring(summary.min_level);
    if (summary.max_level ~= summary.min_level) then
        level_text = ('%d-%d'):fmt(summary.min_level, summary.max_level);
    end

    local chr_text = tostring(summary.min_target_chr);
    if (summary.max_target_chr ~= summary.min_target_chr) then
        chr_text = ('%d-%d'):fmt(summary.min_target_chr, summary.max_target_chr);
    end

    return chance_text, level_text, chr_text;
end

local function build_overlay_value(result)
    if (result.kind == 'pet' or result.kind == 'uncharmable') then
        return '0%';
    end

    return format_percent(result.summary.min_chance);
end

local function get_overlay_color(result)
    if (result == nil) then
        return PANEL_COLORS.muted;
    end

    if (result.kind == 'pet') then
        return PANEL_COLORS.bad;
    end

    local chance_floor = result.summary.min_chance or 0;
    if (chance_floor >= 60) then
        return PANEL_COLORS.good;
    elseif (chance_floor >= 25) then
        return PANEL_COLORS.warn;
    end

    return PANEL_COLORS.bad;
end

local function set_current_display(target_index, target_server_id, value, color)
    charm.current.target_index = target_index or 0;
    charm.current.target_server_id = target_server_id or 0;
    charm.current.value = value or '';
    charm.current.value_color = color or PANEL_COLORS.muted;
    charm.current.has_mob = true;
end

-- Same-target throttle: recompute the estimate at most this often when the target is
-- unchanged, so live gear / merit changes are picked up without retargeting.
local SAME_TARGET_REFRESH_SEC = 1.0;

local function refresh_current_estimate(force)
    local target, target_index = get_target();
    -- Panel stays hidden unless a displayable enemy mob is targeted: clear_current() drops has_mob, and d3d_present skips drawing without it.
    if (target == nil or not is_displayable_enemy_mob(target, target_index)) then
        clear_current();
        charm.last_target_index = 0;
        charm.last_target_server_id = 0;
        return;
    end

    local target_server_id = target.ServerId or 0;
    local target_changed = target_index ~= charm.last_target_index or target_server_id ~= charm.last_target_server_id;
    -- Recompute on target change, and periodically for the SAME target so live gear /
    -- merit changes (which feed the estimate via build_player_state) are reflected.
    local stale = (os.clock() - charm.last_refresh_at) >= SAME_TARGET_REFRESH_SEC;
    if (not force and not target_changed and not stale) then
        return;
    end

    charm.last_target_index = target_index;
    charm.last_target_server_id = target_server_id;
    charm.last_refresh_at = os.clock();

    -- Resolve the %; leave it blank otherwise so the box keeps its label-sized footprint.
    local player_state = build_player_state();
    if (player_state == nil or player_state.bst_level <= 0) then
        set_current_display(target_index, target_server_id, '', PANEL_COLORS.muted);
        return;
    end

    local result = build_estimate(player_state, target, target_index);
    if (result ~= nil) then
        set_current_display(
            result.target_index,
            result.target_server_id,
            build_overlay_value(result),
            get_overlay_color(result)
        );
        return;
    end

    set_current_display(target_index, target_server_id, '', PANEL_COLORS.muted);
end

local function print_result(result)
    local summary = result.summary;
    local player_state = result.player_state;
    local chance_text, level_text, chr_text = format_summary_fields(summary);

    print_status(('Target: %s | Estimated charm chance: %s'):fmt(result.target_name, chance_text));
    print_status(('Lookup: %s | Target level: %s | Target CHR: %s'):fmt(result.resolution, level_text, chr_text));

    local player_job_text = ('%s%d/%s%d'):fmt(
        get_job_abbr(player_state.main_job),
        player_state.main_level,
        get_job_abbr(player_state.sub_job),
        player_state.sub_level
    );
    print_status(('Player CHR: %d (base %d, merits %d, gear %d) | BST level: %d | Charm+: %d | Jobs: %s'):fmt(
        player_state.chr,
        player_state.base_chr,
        player_state.merit_chr,
        player_state.gear_chr,
        player_state.bst_level,
        player_state.charm_chance_mod,
        player_job_text
    ));

    local notes = T{
        'Approximate zone/name estimate; exact mobid matching is intentionally omitted in the compact export.',
        'Excludes temporary buffs, food, and augment stats.',
    };
    if (not player_state.active_bst) then
        notes:append(('Current jobs are not BST; using stored BST level %d so the estimate reflects your Beastmaster.'):fmt(player_state.bst_level));
    end
    if (not summary.any_charmable) then
        notes:append('Resolved target data is marked uncharmable, so the estimate stays at 0%.');
    end

    for _, note in ipairs(notes) do
        print_status(('Note: %s'):fmt(note));
    end
end

local function handle_charm_chance()
    local estimate, error_message = estimate_current_target();
    if (estimate == nil) then
        print_error(error_message);
        return;
    end

    if (estimate.kind == 'pet') then
        print_status('Target is controlled by another entity, so charm chance is 0%.');
        return;
    end

    if (estimate.kind == 'uncharmable') then
        print_status(('%s is uncharmable (not in the charmable data), so charm chance is 0%%.'):fmt(estimate.target_name));
        return;
    end

    print_result(estimate);
end

ashita.events.register('load', 'charm_chance_load_cb', function ()
    ensure_settings();
    clear_current();
    initialize_merits();
end);

ashita.events.register('unload', 'charm_chance_unload_cb', function ()
    package.loaded['data.charm_data'] = nil;
    package.loaded['charm_data'] = nil;
    package.loaded['data.charm_lookup'] = nil;
    package.loaded['charm_lookup'] = nil;
    charm_data = nil;
    charm_lookup = nil;
    charm_lookup_module_name = nil;
    charm_data_module_name = nil;
    settings.save();
end);

ashita.events.register('packet_in', 'charm_chance_packet_in_cb', function (e)
    if (e.id == 0x00A) then
        merit_cache = {};
        return;
    end

    if (e.id ~= 0x08C) then
        return;
    end

    local merit_count = struct.unpack('B', e.data, 0x04 + 1);
    for index = 1, merit_count do
        local merit_id = struct.unpack('H', e.data, 0x04 + (4 * index) + 1);
        local count = struct.unpack('B', e.data, 0x04 + (4 * index) + 4);
        merit_cache[merit_id] = count;
    end
end);

ashita.events.register('command', 'charm_chance_command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or args[1] ~= '/charm') then
        return;
    end

    e.blocked = true;

    -- Bare /charm (or /charm toggle) flips the % panel on / off.
    if (#args == 1 or (#args == 2 and args[2]:any('toggle'))) then
        charm.settings.hud.visible = not charm.settings.hud.visible;
        update_settings();
        print_status(('Panel %s.'):fmt(charm.settings.hud.visible and 'shown' or 'hidden'));
        return;
    end

    if (#args == 2 and args[2] == 'chance') then
        handle_charm_chance();
        return;
    end

    if (args[2] ~= nil and args[2]:any('lock')) then
        if (#args >= 3 and args[3]:any('on')) then
            charm.settings.hud.locked = true;
        elseif (#args >= 3 and args[3]:any('off')) then
            charm.settings.hud.locked = false;
        else
            charm.settings.hud.locked = not charm.settings.hud.locked;
        end
        update_settings();
        print_status(charm.settings.hud.locked and 'Window locked.' or 'Window unlocked.');
        return;
    end

    if (#args == 2 and args[2]:any('reload', 'rl')) then
        settings.reload();
        clear_current();
        print_status('Settings reloaded from disk.');
        return;
    end

    if (#args == 2 and args[2]:any('reset')) then
        settings.reset();
        clear_current();
        print_status('Settings reset to defaults.');
        return;
    end

    if (#args == 2 and args[2]:any('help')) then
        print_help(false);
        return;
    end

    print_help(true);
end);

-- Title-bar [X] open-state ref; ImGui flips it to false inside Begin when [X] is clicked.
local panel_open = { true };

local next_layout_save = 0;
local layout_dirty = false;
local function maybe_save_layout()
    local pos_x, pos_y = imgui.GetWindowPos();
    local size_x, size_y = imgui.GetWindowSize();
    local hud = charm.settings.hud;

    if (hud.window_pos_x ~= pos_x or hud.window_pos_y ~= pos_y
        or hud.window_size_w ~= size_x or hud.window_size_h ~= size_y) then
        hud.window_pos_x = pos_x;
        hud.window_pos_y = pos_y;
        hud.window_size_w = size_x;
        hud.window_size_h = size_y;
        layout_dirty = true;
    end

    -- Throttled flush so a final drag inside the window still reaches disk promptly, not only on unload.
    if (layout_dirty and os.clock() >= next_layout_save) then
        settings.save();
        layout_dirty = false;
        next_layout_save = os.clock() + 0.5;
    end
end

ashita.events.register('d3d_present', 'charm_chance_present_cb', function ()
    refresh_current_estimate(false);

    if (not charm.settings.hud.visible) then
        return;
    end

    if (not charm.current.has_mob) then
        return;
    end

    local hud = charm.settings.hud;

    imgui.PushStyleColor(ImGuiCol_WindowBg,      { 0.08, 0.08, 0.10, 0.55 });
    imgui.PushStyleColor(ImGuiCol_TitleBg,       { 0.10, 0.10, 0.12, 0.85 });
    imgui.PushStyleColor(ImGuiCol_TitleBgActive, { 0.14, 0.14, 0.18, 0.95 });
    imgui.PushStyleColor(ImGuiCol_Border,        { 0.35, 0.35, 0.40, 0.60 });
    imgui.SetNextWindowPos({ hud.window_pos_x, hud.window_pos_y }, ImGuiCond_Appearing);
    imgui.SetNextWindowSize({ hud.window_size_w, hud.window_size_h }, ImGuiCond_Appearing);

    -- p_open MUST stay non-nil or Ashita's imgui.Begin silently ignores the flags argument.
    local flags = bit.bor(ImGuiWindowFlags_NoSavedSettings,
                          ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoResize,
                          ImGuiWindowFlags_AlwaysAutoResize);
    if (charm.settings.hud.locked) then
        flags = bit.bor(flags, ImGuiWindowFlags_NoMove);
    end

    if (imgui.Begin('Charm Chance###charm_panel', panel_open, flags)) then
        local content_w = imgui.GetWindowSize() - (2 * imgui.GetStyle().WindowPadding.x);
        local function centered(text, color)
            local tw = ({ imgui.CalcTextSize(text) })[1];
            imgui.SetCursorPosX(imgui.GetCursorPosX() + math.max(0, (content_w - tw) * 0.5));
            imgui.TextColored(color, text);
        end

        centered('Charm Chance', PANEL_COLORS.label);
        local val = charm.current.value or '';
        if (val ~= '') then
            centered(val, charm.current.value_color);
        else
            imgui.Text(' ');                            -- reserve the number row (keeps box size fixed)
        end
        maybe_save_layout();
    end

    imgui.End();
    imgui.PopStyleColor(4);
end);
