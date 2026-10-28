-- Integration test of SarmatDTC.lua with stubbed DCS GUI API (DCS, net, log, lfs, terrain).
-- The download really runs (wscript -> fetch.cmd -> curl.exe) against a file:// copy of the fixtures.
-- usage: luae.exe test_hook.lua <fake writedir without trailing \> <file:// base url of data dir>
-- Keep writedir short: DCS's os.execute drops commands longer than ~256 chars.
local writedir, fileBase = arg[1] .. '\\', arg[2]

local failures = 0
local function check(cond, msg)
    if not cond then
        failures = failures + 1
        print('FAIL: ' .. msg)
    end
end

local function exists(p)
    local f = io.open(p, 'rb')
    if f then f:close() return true end
    return false
end

package.loaded['lfs'] = {
    writedir = function() return writedir end,
    mkdir = function(p) os.execute('mkdir "' .. p .. '" 2>nul') end,
    attributes = function(p) return exists(p) and 'file' or nil end,
    dir = function(p)
        local files = {}
        local h = io.popen('dir /b "' .. p .. '"')
        for line in h:lines() do files[#files + 1] = line end
        h:close()
        local i = 0
        return function() i = i + 1 return files[i] end
    end,
}
package.loaded['terrain'] = {
    GetTerrainConfig = function(k)
        if k == 'id' then return 'Syria' end
        if k == 'Airdromes' then
            return { [12] = { display_name = 'Hatay', reference_point = { x = 147000, y = 42000 } } }
        end
    end,
    GetHeight = function(x, z) return 250.6 end,
    convertMetersToLatLon = function(x, z) return 35.0 + x / 111000, 39.0 + z / 91000 end,
}

local clock = 0
local server = ''
local mySideNum, mySlot = 0, ''
local chats, logs = {}, {}
log = {
    INFO = 'INFO', WARNING = 'WARN', ERROR = 'ERR',
    write = function(tag, lvl, msg)
        logs[#logs + 1] = msg
        print('  [' .. lvl .. '] ' .. msg)
    end,
}
DCS = {
    getRealTime = function() return clock end,
    isMultiplayer = function() return true end,
    getMissionName = function() return 'SARMAT - Syria' end,
    getCurrentMission = function() return { mission = { theatre = 'Syria' } } end,
    setUserCallbacks = function(cb) DCS.cb = cb end,
    getAvailableSlots = function(side)
        if side == 'blue' then
            return { { unitId = '101', type = 'AH-64D_BLK_II', groupName = 'Hatay AH-64 #1', airdromeId = 12, takeOffType = 'From Parking Area' } }
        end
        return { { unitId = '202_1', type = 'AH-64D_BLK_II', groupName = 'FARP 9-1 Apache', helipadId = 7, takeOffType = 'From Ground Area' } }
    end,
    getFarpsAndCarriersMissionData = function()
        return { farps = { [7] = { name = 'FARP 9-1', x = 44381, y = 82547 } } }
    end,
}
net = {
    get_server_settings = function() return { name = server } end,
    get_my_player_id = function() return 7 end,
    get_player_info = function(id, key)
        if key == 'side' then return mySideNum end
        if key == 'slot' then return mySlot end
    end,
    recv_chat = function(msg) chats[#chats + 1] = msg end,
}
local realExecute = os.execute
os.execute = function(cmd)
    local patched = cmd:gsub('https://baikalprimestudio%.com/data/', (fileBase:gsub('%%', '%%%%')))
    check(#patched <= 256, 'os.execute command longer than 256 chars (' .. #patched .. ')')
    return realExecute(patched)
end

local cacheFlag = writedir .. 'Scripts\\SarmatDTC\\cache\\done.flag'
local dtcDir = writedir .. 'DTC\\'
local types = { 'AH-64D_BLK_II', 'F-16C_50', 'FA-18C_hornet' }   -- F-14BU is commented out in config.lua

local function frames(seconds)
    for _ = 1, seconds do
        clock = clock + 1
        DCS.cb.onSimulationFrame()
        local t = os.time()
        while os.time() - t < 1 do end
        if exists(cacheFlag) then
            clock = clock + 1
            DCS.cb.onSimulationFrame()
            return true
        end
    end
    return false
end

local function logged(pattern)
    for _, l in ipairs(logs) do if string.find(l, pattern) then return true end end
    return false
end

local function readAH64()
    local f = io.open(dtcDir .. 'SARMAT_AH-64D_BLK_II.dtc', 'rb')
    if not f then return '' end
    local s = f:read('*a')
    f:close()
    return s
end

-- config.lua with F-14 commented out, an unknown type and a test module that has only extra outputs
local function writeFile(path, text)
    local f = assert(io.open(path, 'wb'))
    f:write(text)
    f:close()
end
local envDir = os.getenv('TEMP') .. '\\sdtc_env_' .. os.time()
writeFile(writedir .. 'Scripts\\SarmatDTC\\config.lua', [[
return {
    AIRCRAFT = {
        "AH-64D_BLK_II",
        "F-16C_50",
        "FA-18C_hornet",
        -- "F-14BU",
        "ZZ_TEST",
        "NOPE",
    },
    OPTIONS = { ZZ_TEST = { outputs = { env = { dir = "%TEMP%\\]] .. string.match(envDir, '[^\\]+$') .. [[" } } } },
}
]])
writeFile(writedir .. 'Scripts\\SarmatDTC\\aircraft\\ZZ_TEST.lua', [[
return {
    type = "ZZ_TEST",
    outputs = {
        { id = "txt", format = "text", dir = "Exports\\{side}", file = "{type}.txt",
          build = function(s) return "front=" .. #s.front .. " side=" .. s.side, { n = 1 } end },
        { id = "luafile", format = "lua", dir = ]] .. string.format('%q', writedir .. 'Abs') .. [[, file = "{type}.lua",
          build = function(s, lib, opt, built) return { side = s.side, txt = built.txt } end },
        { id = "env", format = "json", dir = "unused", file = "z.json",
          build = function(s) return { farps = #s.farps } end },
    },
}
]])

dofile(writedir .. 'Scripts\\SarmatDTC\\SarmatDTC.lua')
local cb = DCS.cb
check(logged('aircraft modules: AH%-64D_BLK_II, F%-16C_50, FA%-18C_hornet, ZZ_TEST'), 'config.lua selection not applied')
check(logged('config.lua lists NOPE'), 'unknown type in config.lua not reported')

print('-- non-SARMAT server is ignored')
server = 'Some Other Server'
cb.onMissionLoadEnd()
mySideNum, mySlot = 2, '101'
cb.onPlayerChangeSlot(7)
check(#chats == 0 and not exists(dtcDir .. 'SARMAT_F-14BU.dtc'), 'acted on a non-SARMAT server')

print('-- SARMAT server: download on mission load')
server = '[RU] SARMAT | Syria PvP'
mySideNum, mySlot = 0, ''
cb.onMissionLoadEnd()
check(frames(30), 'download did not finish')
check(logged('map data downloaded'), 'download not reported as ok')

print('-- other player changes slot: ignored')
mySideNum = 2
cb.onPlayerChangeSlot(3)
check(#chats == 0, 'reacted to another player')

print('-- own slot blue (airfield)')
mySlot = '101'
cb.onPlayerChangeSlot(7)
for _, t in ipairs(types) do check(exists(dtcDir .. 'SARMAT_' .. t .. '.dtc'), 'missing cartridge ' .. t) end
check(not exists(dtcDir .. 'SARMAT_F-14BU.dtc'), 'F-14BU written although commented out in config.lua')
check(not exists(dtcDir .. 'SARMAT_ZZ_TEST.dtc'), 'native cartridge written for a module without build')
check(#chats == 1, 'expected one chat message, got ' .. #chats)
check(logged('base=Hatay'), 'airfield slot not resolved')
check(logged('cartridges written for blue around Hatay'), 'spawn base not used for generation')
local blue = readAH64()

print('-- extra outputs: text (relative + {side}), lua (absolute), json (%TEMP%)')
local txtPath = writedir .. 'Exports\\blue\\ZZ_TEST.txt'
local tf = io.open(txtPath, 'rb')
check(tf and string.find(tf:read('*a'), '^front=%d+ side=blue$'), 'text output missing or wrong')
if tf then tf:close() end
local okLua, luaOut = pcall(dofile, writedir .. 'Abs\\ZZ_TEST.lua')
check(okLua and type(luaOut) == 'table' and luaOut.side == 'blue' and string.find(luaOut.txt or '', 'side=blue'),
    'lua output missing or not loadable')
local JSON = dofile('Scripts/JSON.lua')
local jf = io.open(envDir .. '\\z.json', 'rb')
local okJ, jsonOut = pcall(function() return JSON:decode(jf:read('*a')) end)
check(jf and okJ and type(jsonOut) == 'table' and type(jsonOut.farps) == 'number', 'json output in %TEMP% missing or invalid')
if jf then jf:close() end
os.remove(envDir .. '\\z.json')
os.execute('rd "' .. envDir .. '" 2>nul')
check(logged('ZZ_TEST/txt %(n=1%)'), 'extra output not in the summary')

print('-- own slot red (FARP, multicrew seat id)')
mySideNum, mySlot = 1, '202'
clock = clock + 5
cb.onPlayerChangeSlot(7)
check(#chats == 2, 'expected two chat messages, got ' .. #chats)
check(logged('base=FARP 9%-1'), 'FARP slot not resolved')
check(readAH64() ~= blue, 'cartridge not rewritten for the other side')

print('-- spectators: nothing happens')
mySideNum, mySlot = 0, ''
cb.onPlayerChangeSlot(7)
check(#chats == 2, 'reacted to spectator slot')

if failures > 0 then
    print(failures .. ' check(s) failed')
    os.exit(1)
end
print('hook: all checks passed')
