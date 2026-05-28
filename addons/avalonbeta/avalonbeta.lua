addon.name      = 'avalonbeta';
addon.author    = 'Aeshur';
addon.version   = '1.3';
addon.desc      = 'Panel that displays AvalonXI dev/beta test commands.';
addon.link      = 'https://ashitaxi.com/';

require('common');
local bit = require('bit');
local chat = require('chat');
local imgui = require('imgui');
local settings = require('settings');

local default_settings = T{
    ui = T{
        visible = false,
        locked = false,
        setup_done = false,
        window_pos_x = 200,
        window_pos_y = 200,
        window_size_w = 580,
        window_size_h = 360,
    },
};

local dev = T{
    settings = settings.load(default_settings),
};

local cbtest_presets = T{ 'phys', 'magic', 'haste', 'acc', 'racc', 'songs', 'rolls', 'custom' };

-- Dropdown lists mirror the server's loadouts / prema args; a near-miss falls back to the in-game menu.
local JOBS           = T{ 'WAR','MNK','WHM','BLM','RDM','THF','PLD','DRK','BST','BRD','RNG','SAM','NIN','DRG','SMN','BLU','COR','PUP','DNC','SCH','GEO','RUN' };
local TIERS          = T{ '75','60','50','40','30','20','10' };
local WEAPON_TYPES   = T{ 'Hand-to-Hand','Dagger','Sword','Great Sword','Axe','Great Axe','Scythe','Polearm','Katana','Great Katana','Club','Staff','Archery','Marksmanship' };
local PREMA_CATS     = T{ 'Armor','Weapon' };
local ARMOR_CLASSES  = T{ 'Artifact','Relic','Empyrean' };
local WEAPON_CLASSES = T{ 'Relic','Mythic','Empyrean' };
local VARIANTS       = T{ 'Normal','+1' };

local function combo_str(list)
    return table.concat(list, '\0') .. '\0\0';
end

local JOBS_STR     = combo_str(JOBS);
local TIERS_STR    = combo_str(TIERS);
local WTYPES_STR   = combo_str(WEAPON_TYPES);
local PCATS_STR    = combo_str(PREMA_CATS);
local ACLASS_STR   = combo_str(ARMOR_CLASSES);
local WCLASS_STR   = combo_str(WEAPON_CLASSES);
local VARIANTS_STR = combo_str(VARIANTS);

local ui = {
    visible = { false },
    input_size = 128,
    inputs = {
        nms = { '' },
        hnms = { '' },
        missions_area = { '' },
        missions_id = { '' },
        quests_area = { '' },
        quests_id = { '' },
    },
    -- Combo indices are 0-based (0 == first item); armor/weapon keep separate refs so toggling category drops no stale index.
    combos = {
        lo_main   = { 0 },
        lo_sub    = { 1 },   -- MNK (not WAR -- a WAR/WAR default would error on Apply)
        lo_tier   = { 0 },
        pr_cat    = { 0 },
        pr_job    = { 0 },
        pr_wtype  = { 0 },
        pr_aclass = { 0 },
        pr_wclass = { 0 },
        pr_atier  = { 0 },
        pr_avar   = { 0 },
        pr_wtier  = { 0 },
    },
    next_layout_save = 0,
};

local function trim(s)
    if (s == nil) then
        return '';
    end

    return s:gsub('^%s+', ''):gsub('%s+$', '');
end

local function clean_input(value)
    return trim(tostring(value or ''):gsub('%z', ''));
end

local function ensure_ui_settings()
    if (dev.settings.ui == nil) then
        dev.settings.ui = T{};
    end
    for key, value in pairs(default_settings.ui) do
        if (dev.settings.ui[key] == nil) then
            dev.settings.ui[key] = value;
        end
    end
end

local function sync_ui_from_settings()
    ensure_ui_settings();
    ui.visible[1] = dev.settings.ui.visible == true;
end

local function persist_ui_state(force)
    ensure_ui_settings();
    dev.settings.ui.visible = ui.visible[1];

    if (force or os.clock() >= ui.next_layout_save) then
        settings.save();
        ui.next_layout_save = os.clock() + 0.5;
    end
end

local function update_settings(s)
    if (s ~= nil) then
        dev.settings = s;
    end

    ensure_ui_settings();
    sync_ui_from_settings();
    settings.save();
end

settings.register('settings', 'settings_update', update_settings);

ensure_ui_settings();
sync_ui_from_settings();

local function print_status(message)
    print(chat.header(addon.name):append(chat.message(message)));
end

local function print_error(message)
    print(chat.header(addon.name):append(chat.error(message)));
end

local function send_command(cmd)
    AshitaCore:GetChatManager():QueueCommand(1, cmd);
end

local function fire_bare(cmd_name)
    send_command('!' .. cmd_name);
end

local function fire_with_args(cmd_name, ...)
    local parts = T{ '!' .. cmd_name };
    for _, arg in ipairs({...}) do
        local cleaned = clean_input(arg);
        if (cleaned ~= '') then
            parts:append(cleaned);
        end
    end
    send_command(table.concat(parts, ' '));
end

local function toggle_ui()
    ui.visible[1] = not ui.visible[1];
    persist_ui_state(true);
end

local function maybe_save_layout()
    local pos_x, pos_y = imgui.GetWindowPos();
    local size_x, size_y = imgui.GetWindowSize();

    ensure_ui_settings();

    local changed =
        dev.settings.ui.window_pos_x ~= pos_x or
        dev.settings.ui.window_pos_y ~= pos_y or
        dev.settings.ui.window_size_w ~= size_x or
        dev.settings.ui.window_size_h ~= size_y;

    if (changed) then
        dev.settings.ui.window_pos_x = pos_x;
        dev.settings.ui.window_pos_y = pos_y;
        dev.settings.ui.window_size_w = size_x;
        dev.settings.ui.window_size_h = size_y;
        persist_ui_state(false);
    end
end

local function section_header(text)
    imgui.Spacing();
    imgui.TextColored({ 0.62, 0.82, 1.0, 1.0 }, text);
    imgui.Separator();
end

local function bare_button(label, cmd_name, width)
    if (imgui.Button(label, { width or 110, 0 })) then
        fire_bare(cmd_name);
    end
end

-- imgui.Combo is 0-based but Lua lists are 1-based, so add 1.
local function draw_combo(id, ref, items_str, list, width)
    imgui.PushItemWidth(width or 90);
    imgui.Combo(id, ref, items_str);
    imgui.PopItemWidth();
    local i = (ref[1] or 0) + 1;
    if (i < 1) then
        i = 1;
    elseif (i > #list) then
        i = #list;
    end
    return list[i];
end

local function param_command(label, cmd_name, input_ref, hint)
    if (imgui.Button(label, { 110, 0 })) then
        fire_with_args(cmd_name, input_ref[1]);
    end
    imgui.SameLine();
    imgui.PushItemWidth(220);
    imgui.InputText('##' .. cmd_name, input_ref, ui.input_size);
    imgui.PopItemWidth();
    if (hint ~= nil and hint ~= '') then
        imgui.SameLine();
        imgui.TextDisabled(hint);
    end
end

local function draw_loadouts_row()
    imgui.Text('Loadouts');
    imgui.SameLine();
    local main = draw_combo('##lo_main', ui.combos.lo_main, JOBS_STR, JOBS, 58);
    imgui.SameLine();
    local sub = draw_combo('##lo_sub', ui.combos.lo_sub, JOBS_STR, JOBS, 58);
    imgui.SameLine();
    local tier = draw_combo('##lo_tier', ui.combos.lo_tier, TIERS_STR, TIERS, 50);
    imgui.SameLine();
    if (imgui.Button('Apply##lo', { 58, 0 })) then
        send_command(('!loadouts %s %s %s'):fmt(main, sub, tier));
    end
    imgui.SameLine();
    if (imgui.Button('Menu##lo', { 56, 0 })) then
        fire_bare('loadouts');
    end
end

local function draw_prema_row()
    imgui.Text('Prema   ');
    imgui.SameLine();
    local cat = draw_combo('##pr_cat', ui.combos.pr_cat, PCATS_STR, PREMA_CATS, 84);
    imgui.SameLine();

    if (cat == 'Armor') then
        local job = draw_combo('##pr_job', ui.combos.pr_job, JOBS_STR, JOBS, 58);
        imgui.SameLine();
        local class = draw_combo('##pr_aclass', ui.combos.pr_aclass, ACLASS_STR, ARMOR_CLASSES, 100);
        imgui.SameLine();
        local tail;
        if (class == 'Empyrean') then
            tail = draw_combo('##pr_atier', ui.combos.pr_atier, TIERS_STR, TIERS, 50);
        else
            tail = draw_combo('##pr_avar', ui.combos.pr_avar, VARIANTS_STR, VARIANTS, 84);
        end
        imgui.SameLine();
        if (imgui.Button('Apply##pr', { 58, 0 })) then
            local cmd = ('!prema armor %s %s'):fmt(job, class);
            if (class == 'Empyrean') then
                cmd = cmd .. ' ' .. tail;
            elseif (tail == '+1') then
                cmd = cmd .. ' +1';
            end
            send_command(cmd);
        end
    else
        local wtype = draw_combo('##pr_wtype', ui.combos.pr_wtype, WTYPES_STR, WEAPON_TYPES, 124);
        imgui.SameLine();
        local class = draw_combo('##pr_wclass', ui.combos.pr_wclass, WCLASS_STR, WEAPON_CLASSES, 100);
        imgui.SameLine();
        local tail;
        if (class == 'Empyrean') then
            tail = draw_combo('##pr_wtier', ui.combos.pr_wtier, TIERS_STR, TIERS, 50);
            imgui.SameLine();
        end
        if (imgui.Button('Apply##pr', { 58, 0 })) then
            local cmd = ('!prema weapon %s %s'):fmt(wtype, class);
            if (class == 'Empyrean' and tail ~= nil) then
                cmd = cmd .. ' ' .. tail;
            end
            send_command(cmd);
        end
    end

    imgui.SameLine();
    if (imgui.Button('Menu##pr', { 56, 0 })) then
        fire_bare('prema');
    end
end

local function draw_dev_panel()
    if (not ui.visible[1]) then
        return;
    end

    imgui.PushStyleColor(ImGuiCol_WindowBg, { 0.08, 0.08, 0.10, 0.90 });
    imgui.PushStyleColor(ImGuiCol_TitleBg, { 0.10, 0.10, 0.12, 0.85 });
    imgui.PushStyleColor(ImGuiCol_TitleBgActive, { 0.14, 0.14, 0.18, 0.95 });
    imgui.PushStyleColor(ImGuiCol_Border, { 0.35, 0.35, 0.40, 0.60 });
    imgui.PushStyleColor(ImGuiCol_Button, { 0.18, 0.22, 0.28, 0.85 });
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.26, 0.32, 0.40, 0.95 });
    imgui.PushStyleColor(ImGuiCol_ButtonActive, { 0.30, 0.38, 0.50, 1.00 });
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 8, 8 });
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { 6, 4 });
    imgui.SetNextWindowPos({ dev.settings.ui.window_pos_x, dev.settings.ui.window_pos_y }, ImGuiCond_Appearing);
    imgui.SetNextWindowSize({ dev.settings.ui.window_size_w, dev.settings.ui.window_size_h }, ImGuiCond_Appearing);

    -- p_open MUST stay non-nil: Ashita's imgui.Begin ignores flags when it is nil.
    local flags = ImGuiWindowFlags_NoSavedSettings;
    local open_ref = ui.visible;
    if (dev.settings.ui.locked) then
        flags = bit.bor(flags, ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoMove, ImGuiWindowFlags_NoResize);
    end

    if (imgui.Begin('AvalonXI Beta###avalonbeta', open_ref, flags)) then
        -- !setup is a one-time bootstrap: once run from this panel it is hidden for
        -- good (persisted via dev.settings.ui.setup_done) so the panel stops nagging.
        if (not dev.settings.ui.setup_done) then
            section_header('Bootstrap');
            if (imgui.Button('!setup', { 110, 0 })) then
                fire_bare('setup');
                dev.settings.ui.setup_done = true;
                settings.save();
            end
        end

        section_header('Gear');
        draw_loadouts_row();
        draw_prema_row();

        section_header('Combat Test');
        bare_button('!cbtest', 'cbtest', 110);
        for i, preset in ipairs(cbtest_presets) do
            if (i > 1) then
                imgui.SameLine();
            end
            if (imgui.Button(preset, { 62, 0 })) then
                fire_with_args('cbtest', preset);
            end
        end

        section_header('Content');
        if (imgui.Button('!missions', { 110, 0 })) then
            fire_with_args('missions', ui.inputs.missions_area[1], ui.inputs.missions_id[1]);
        end
        imgui.SameLine();
        imgui.PushItemWidth(70);
        imgui.InputText('area##miss', ui.inputs.missions_area, ui.input_size);
        imgui.SameLine();
        imgui.InputText('id##miss', ui.inputs.missions_id, ui.input_size);
        imgui.PopItemWidth();

        if (imgui.Button('!quests', { 110, 0 })) then
            fire_with_args('quests', ui.inputs.quests_area[1], ui.inputs.quests_id[1]);
        end
        imgui.SameLine();
        imgui.PushItemWidth(70);
        imgui.InputText('area##qu', ui.inputs.quests_area, ui.input_size);
        imgui.SameLine();
        imgui.InputText('id##qu', ui.inputs.quests_id, ui.input_size);
        imgui.PopItemWidth();

        bare_button('!battlefields', 'battlefields', 130);
        imgui.SameLine();
        bare_button('!instances', 'instances', 130);
        imgui.SameLine();
        bare_button('!events', 'events', 130);

        bare_button('!zones', 'zones', 130);

        section_header('Spawning');
        param_command('!nms', 'nms', ui.inputs.nms, 'name or zone');
        param_command('!hnms', 'hnms', ui.inputs.hnms, 'name | zone | confront');

        maybe_save_layout();
    end

    imgui.End();
    imgui.PopStyleVar(2);
    imgui.PopStyleColor(7);
    persist_ui_state(false);
end

local function print_help(is_error)
    if (is_error) then
        print_error('Invalid command syntax.');
    else
        print_status('Available commands:');
    end

    local commands = T{
        { '/beta', 'Toggles the dev panel.' },
        { '/beta show|hide|toggle', 'Controls dev panel visibility.' },
        { '/beta lock [on|off]', 'Locks/unlocks the window (fixed overlay).' },
        { '/beta help', 'Displays the addon help.' },
        { '/beta reload', 'Reloads settings from disk.' },
        { '/beta reset', 'Resets settings to defaults.' },
    };

    commands:ieach(function (entry)
        print(chat.header(addon.name):append(chat.error('Usage: ')):append(chat.message(entry[1]):append(' - ')):append(chat.color1(6, entry[2])));
    end);
end

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or args[1] ~= '/beta') then
        return;
    end

    e.blocked = true;

    if (#args == 1) then
        toggle_ui();
        return;
    end

    if (#args == 2 and args[2] == 'show') then
        ui.visible[1] = true;
        persist_ui_state(true);
        return;
    end

    if (#args == 2 and args[2] == 'hide') then
        ui.visible[1] = false;
        persist_ui_state(true);
        return;
    end

    if (#args == 2 and args[2] == 'toggle') then
        toggle_ui();
        return;
    end

    if (args[2]:any('lock')) then
        if (args[3] ~= nil and args[3]:any('on')) then
            dev.settings.ui.locked = true;
        elseif (args[3] ~= nil and args[3]:any('off')) then
            dev.settings.ui.locked = false;
        else
            dev.settings.ui.locked = not (dev.settings.ui.locked == true);
        end
        persist_ui_state(true);
        if (dev.settings.ui.locked) then
            print_status('Window locked.');
        else
            print_status('Window unlocked.');
        end
        return;
    end

    if (#args == 2 and args[2]:any('help')) then
        print_help(false);
        return;
    end

    if (#args == 2 and args[2]:any('reload', 'rl')) then
        settings.reload();
        ensure_ui_settings();
        sync_ui_from_settings();
        print_status('Settings reloaded from disk.');
        return;
    end

    if (#args == 2 and args[2]:any('reset')) then
        settings.reset();
        ensure_ui_settings();
        sync_ui_from_settings();
        print_status('Settings reset to defaults.');
        return;
    end

    print_help(true);
end);

ashita.events.register('load', 'load_cb', function ()
    ensure_ui_settings();
    sync_ui_from_settings();
end);

ashita.events.register('d3d_present', 'present_cb', function ()
    draw_dev_panel();
end);

ashita.events.register('unload', 'unload_cb', function ()
    settings.save();
end);
