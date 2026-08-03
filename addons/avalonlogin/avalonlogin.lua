addon.name    = 'avalonlogin';
addon.author  = 'Aeshur';
addon.version = '1.1';
addon.desc    = 'Bridges the local character name to the AvalonXI launcher and misc. tips to characters.';
addon.link    = 'https://avalonxi.com/';

require('common');
local chat     = require('chat');
local settings = require('settings');

local addon_directory = (debug.getinfo(1, 'S').source or ''):match('^@(.+[\\/])[^\\/]+$') or '';

local default_settings = T{
    welcomed = false,
};

local state = T{
    settings = settings.load(default_settings),
};

-- Ashita loads from <root>/addons/ or <root>/config/addons/; strip either.
local function resolve_ashita_root()
    if (addon_directory == '') then
        return nil;
    end
    return addon_directory:match('^(.-)[\\/]config[\\/]addons[\\/]')
        or addon_directory:match('^(.-)[\\/]addons[\\/]');
end

-- Launcher localIdentity.ts reads <Ashita>/config/avalonlogin.json.
local function identity_path()
    local root = resolve_ashita_root();
    if (root == nil) then
        return nil;
    end
    return root .. '\\config\\avalonlogin.json';
end

local function json_string(value)
    local s = tostring(value or '');
    s = s:gsub('[%c%z]', '');
    s = s:gsub('[\\"]', '\\%0');
    return '"' .. s .. '"';
end

local function strip_nulls(value)
    if (value == nil) then
        return '';
    end
    return (tostring(value):gsub('%z', ''));
end

-- Party index 0 is the local player; valid only once active with a server id.
local function player_is_ready()
    local party = AshitaCore:GetMemoryManager():GetParty();
    return party:GetMemberIsActive(0) ~= 0 and party:GetMemberServerId(0) ~= 0;
end

local function current_character_name()
    local name = strip_nulls(AshitaCore:GetMemoryManager():GetParty():GetMemberName(0));
    return name:match('^%s*(.-)%s*$') or '';
end

local function current_zone_name()
    local zone_id = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
    if (zone_id == nil or zone_id == 0) then
        return '';
    end
    local ok, name = pcall(function ()
        return AshitaCore:GetResourceManager():GetString('zones.names', zone_id);
    end);
    if (ok and type(name) == 'string') then
        return strip_nulls(name);
    end
    return '';
end

-- Job abbreviation (e.g. 'WAR') for a job id, or '' when none/unknown.
local function job_abbr(job_id)
    if (job_id == nil or job_id == 0) then
        return '';
    end
    local ok, name = pcall(function ()
        return AshitaCore:GetResourceManager():GetString('jobs.names_abbr', job_id);
    end);
    if (ok and type(name) == 'string') then
        return strip_nulls(name);
    end
    return '';
end

-- Return empty until job data populates so the launcher preserves its /chars value.
local function current_job_string()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    local main = job_abbr(player:GetMainJob());
    local main_level = player:GetMainJobLevel();
    if (main == '' or main_level == nil or main_level <= 0) then
        return '';
    end
    local result = main .. tostring(main_level);
    local sub = job_abbr(player:GetSubJob());
    local sub_level = player:GetSubJobLevel();
    if (sub ~= '' and sub_level ~= nil and sub_level > 0) then
        result = result .. '/' .. sub .. tostring(sub_level);
    end
    return result;
end

-- Return true only after a complete write so transient failures remain retryable.
local function write_identity(name, zone, job)
    if (name == '') then
        return false;
    end

    local path = identity_path();
    if (path == nil) then
        return false;
    end

    local payload = ('{"character":%s,"zone":%s,"job":%s,"seenAt":%d}'):fmt(
        json_string(name),
        json_string(zone),
        json_string(job),
        os.time()
    );

    local file = io.open(path, 'w');
    if (file == nil) then
        return false;
    end
    -- Retry write or flush failures so cached state reflects disk.
    local wrote = file:write(payload);
    local closed = file:close();
    if (not wrote or not closed) then
        return false;
    end
    return true;
end

-- Greet a brand-new character (still level 1) once.
local function maybe_welcome()
    if (state.settings.welcomed) then
        return;
    end

    local main_level = AshitaCore:GetMemoryManager():GetPlayer():GetMainJobLevel();
    -- Party readiness can precede the level read; wait for a real level.
    if (main_level == nil or main_level <= 0) then
        return;
    end

    if (main_level == 1) then
        print(chat.header(addon.name)
            :append(chat.message('Welcome to AvalonXI! If you need any assistance don\'t be afraid to ask in the server linkshell. Type '))
            :append(chat.color1(6, '/wiki'))
            :append(chat.message(' to search the AvalonXI wiki.')));
        print(chat.header(addon.name)
            :append(chat.message('Beta: Type '))
            :append(chat.color1(6, '/beta'))
            :append(chat.message(' to open the AvalonXI Beta command panel and jump into the testing!')));
    end

    state.settings.welcomed = true;
    settings.save();
end

local last_written = T{ name = nil, zone = nil, job = nil };
local next_poll = 0;

-- Poll instead of handling 0x000A because party memory repopulates after it.
local function poll()
    local now = os.clock();
    if (now < next_poll) then
        return;
    end
    next_poll = now + 1.0;

    if (not player_is_ready()) then
        return;
    end

    local name = current_character_name();
    if (name == '') then
        return;
    end
    local zone = current_zone_name();
    local job = current_job_string();

    if (name ~= last_written.name or zone ~= last_written.zone or job ~= last_written.job) then
        local ok, wrote = pcall(write_identity, name, zone, job);
        if (ok and wrote) then
            last_written.name = name;
            last_written.zone = zone;
            last_written.job = job;
        end
    end

    pcall(maybe_welcome);
end

-- Reset the write cache on character switch so the new identity is written.
local function update_settings(s)
    if (s ~= nil) then
        state.settings = s;
    end
    if (state.settings.welcomed == nil) then
        state.settings.welcomed = false;
    end
    last_written.name = nil;
    last_written.zone = nil;
    last_written.job = nil;
    settings.save();
end
settings.register('settings', 'settings_update', update_settings);

ashita.events.register('d3d_present', 'avalonlogin_present', function ()
    poll();
end);

ashita.events.register('unload', 'avalonlogin_unload', function ()
    settings.save();
end);
