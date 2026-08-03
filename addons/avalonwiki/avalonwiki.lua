addon.name      = 'avalonwiki';
addon.author    = 'Aeshur';
addon.version   = '1.0';
addon.desc      = 'Opens the AvalonXI Miraheze wiki from an in-game slash command.';
addon.link      = 'https://ashitaxi.com/';

require('common');
local chat = require('chat');

local wiki_home_url = 'https://avalonxi.miraheze.org/wiki/Main_Page';
local wiki_search_url = 'https://avalonxi.miraheze.org/w/index.php?title=Special:Search&go=Go&search=';

local function trim(value)
    if (value == nil) then
        return '';
    end

    return tostring(value):gsub('^%s+', ''):gsub('%s+$', '');
end

local function print_status(message)
    print(chat.header(addon.name):append(chat.message(message)));
end

local function url_encode(value)
    value = tostring(value or '');
    return (value:gsub('([^%w%-_%.~])', function (c)
        return ('%%%02X'):fmt(string.byte(c));
    end));
end

local function open_url(url, status_message)
    ashita.misc.open_url(url);
    print_status(status_message);
end

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or args[1] ~= '/wiki') then
        return;
    end

    e.blocked = true;

    if (#args == 1) then
        open_url(wiki_home_url, 'Opening AvalonXI wiki main page.');
        return;
    end

    local query = trim(table.concat(args, ' ', 2));
    if (query == '') then
        open_url(wiki_home_url, 'Opening AvalonXI wiki main page.');
        return;
    end

    open_url(
        wiki_search_url .. url_encode(query),
        ('Opening AvalonXI wiki for "%s".'):fmt(query)
    );
end);
