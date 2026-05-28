addon.name    = 'avalonlogin';
addon.author  = 'Aeshur';
addon.version = '1.0';
addon.desc    = 'Bridges the local character name to the AvalonXI launcher and misc. tips to characters.';
addon.link    = 'https://avalonxi.com/';

require('common');
local chat     = require('chat');
local settings = require('settings');

-- This addon's own folder, used to resolve the Ashita root.
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

-- <Ashita>/config/avalonlogin.json - the launcher's identity-bridge contract
-- (localIdentity.ts reads the same filename on the launcher side).
local function identity_path()
    local root = resolve_ashita_root();
    if (root == nil) then
        return nil;
    end
    return root .. '\\config\\avalonlogin.json';
end

-- Minimal JSON string encoder.
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

-- Live "main/sub" job summary, e.g. 'WAR75/NIN37' (no sub -> just 'WAR75'). ''
-- until the player's job data is populated, so the launcher card keeps the public
-- /chars value rather than flashing an empty job.
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

-- Write the identity file. Returns true only on a completed write so the poll's
-- change cache advances solely on success (a transient file lock retries).
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
    file:write(payload);
    file:close();
    return true;
end

-- Greet a brand-new character (still level 1) once.
local function maybe_welcome()
    if (state.settings.welcomed) then
        return;
    end

    local main_level = AshitaCore:GetMemoryManager():GetPlayer():GetMainJobLevel();
    -- Player data can lag a frame or two behind party readiness; wait for a real
    -- level read before deciding, so the one-shot flag isn't burned on a 0/nil.
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

-- Last (name, zone, job) successfully written, so the file is only rewritten when
-- one of them actually changes. nil until the first write.
local last_written = T{ name = nil, zone = nil, job = nil };
-- os.clock() gate for the throttle below.
local next_poll = 0;

-- Poll the live party memory on a ~1s cadence and write when name|zone changes.
-- The zone-in packet (0x000A) fires BEFORE the party memory repopulates for the
-- new zone, so the old synchronous on-packet write captured only the FIRST zone
-- (the rest were skipped by player_is_ready()). Polling reads the settled values
-- every zone, mirroring how the other Avalon addons drive work off d3d_present.
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

-- Backfill the flag on character switch so it never reads as nil, and reset the
-- write cache so the newly-loaded character's identity is re-written promptly.
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
