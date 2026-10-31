-- Integration test of SarmatDTC.lua with stubbed DCS GUI API (DCS, net, log, lfs, terrain).
-- The download really runs (wscript -> fetch.cmd -> curl.exe) against a file:// copy of the fixtures.
-- usage: luae.exe test_hook.lua <fake writedir without trailing \> <file:// base url of data dir>
-- Keep writedir short: DCS's os.execute drops commands longer than ~256 chars.
-- The mod runs from a Cyrillic subfolder of it (UTF-8, like lfs.writedir() of a Cyrillic user name);
-- the path is made here because luae.exe gets its arguments in the ANSI code page.
local writedir, fileBase = arg[1] .. '\\Пилот\\', arg[2]
os.execute('mkdir "' .. writedir .. '" && move "' .. arg[1] .. '\\Scripts" "' .. writedir .. 'Scripts" >nul')

-- dofile cannot open UTF-8 paths, io.open can
local function loadFile(path)
    local f = assert(io.open(path, 'rb'))
    local text = f:read('*a')
    f:close()
    return assert(loadstring(text, '@' .. path))()
end

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

local mtime = {}       -- [path] = fake modification time set by a test case
local firstSeen = {}   -- otherwise: time of the first query, stable like a real file time
package.loaded['lfs'] = {
    writedir = function() return writedir end,
    mkdir = function(p) os.execute('mkdir "' .. p .. '" 2>nul') return true end,
    attributes = function(p, key)
        if not exists(p) then
            -- renaming a folder to itself succeeds, a missing path fails
            if not os.rename(p, p) then return nil end
            if key == nil then return { mode = 'directory' } end
            return key == 'mode' and 'directory' or nil
        end
        if key == 'modification' then
            firstSeen[p] = firstSeen[p] or os.time()
            return mtime[p] or firstSeen[p]
        end
        if key == nil then return { mode = 'file', size = 0 } end
        return 'file'
    end,
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
-- download: 'ok' (fixtures), 'fail' (missing file:// folder), 'none' (no process: never finishes)
local download = 'ok'
local realExecute = os.execute
os.execute = function(cmd)
    if string.find(cmd, 'fetch.vbs', 1, true) then
        if download == 'none' then return 0 end
        local base = download == 'fail' and (fileBase .. 'missing/') or fileBase
        cmd = cmd:gsub('https://baikalprimestudio%.com/data/', (base:gsub('%%', '%%%%')))
        check(#cmd <= 256, 'os.execute command longer than 256 chars (' .. #cmd .. ')')
    end
    return realExecute(cmd)
end

local cacheDir = writedir .. 'Scripts\\SarmatDTC\\cache\\'
local dtcDir = writedir .. 'DTC\\'
local types = { 'AH-64D_BLK_II', 'F-16C_50', 'FA-18C_hornet' }   -- F-14BU is commented out in config.lua

local function logged(pattern, from)
    for i = (from or 0) + 1, #logs do if string.find(logs[i], pattern) then return true end end
    return false
end

-- Runs simulation frames (1 s each) until the download started before reports its result.
local function frames(seconds)
    local from = #logs
    for _ = 1, seconds do
        clock = clock + 1
        DCS.cb.onSimulationFrame()
        if logged('^map data downloaded', from) or logged('^download ', from) then return true end
        local t = os.time()
        while os.time() - t < 1 do end
    end
    return false
end

local function listDir(dir)
    local files = {}
    local h = io.popen('dir /b "' .. dir .. '" 2>nul')
    for line in h:lines() do files[#files + 1] = line end
    h:close()
    return files
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
    BASE_DTC = {
        ["AH-64D_BLK_II"] = "MyApache.dtc",          -- valid base
        ["F-16C_50"]      = "MyApache.dtc",          -- wrong cartridge type
        ["FA-18C_hornet"] = "SARMAT_FA-18C_hornet.dtc", -- the generated file itself
        ["F-14BU"]        = "replaced by config.user.lua",
    },
}
]])
-- config.user.lua over config.lua: per-type BASE_DTC entry replaced, the others kept
writeFile(writedir .. 'Scripts\\SarmatDTC\\config.user.lua', [[
return { BASE_DTC = { ["F-14BU"] = "missing.dtc" } }
]])
os.execute('mkdir "' .. writedir .. 'DTC" 2>nul')
writeFile(writedir .. 'DTC\\MyApache.dtc', dofile('Scripts/JSON.lua'):encode_pretty({ name = '', type = 'AH-64D_BLK_II',
    data = { type = 'AH-64D_BLK_II', name = 'MY', terrain = 'Syria', Radios = { VHF = 121.5 },
        NAV = { Mission_1 = { Points = { WPTHZ = { isEnabled = true, POINTS = { { num = 1, text = 'W01' } } } } } } } }))
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

loadFile(writedir .. 'Scripts\\SarmatDTC\\SarmatDTC.lua')
local cb = DCS.cb
check(logged('aircraft modules: AH%-64D_BLK_II, F%-16C_50, FA%-18C_hornet, ZZ_TEST'), 'config.lua selection not applied')
check(logged('config.lua lists NOPE'), 'unknown type in config.lua not reported')
check(logged('^config.user.lua loaded'), 'config.user.lua not loaded')

print('-- non-SARMAT server is ignored')
server = 'Some Other Server'
cb.onMissionLoadEnd()
mySideNum, mySlot = 2, '101'
cb.onPlayerChangeSlot(7)
check(#chats == 0 and not exists(dtcDir .. 'SARMAT_F-14BU.dtc'), 'acted on a non-SARMAT server')

print('-- result flags of other fetches are not taken for ours')
server = '[RU] SARMAT | Syria PvP'
mySideNum, mySlot = 0, ''
os.execute('mkdir "' .. cacheDir .. '" 2>nul')
writeFile(cacheDir .. 'done.flag', 'ok')
writeFile(cacheDir .. 'done-1-1.flag', 'ok')
writeFile(cacheDir .. 'status-1-1.part', '{}')
writeFile(cacheDir .. 'units-1-1.part', '{}')
download = 'none'
cb.onMissionLoadEnd()
clock = clock + 1
cb.onSimulationFrame()
check(not logged('map data downloaded'), 'took a flag of another fetch')
check(not exists(cacheDir .. 'done.flag') and not exists(cacheDir .. 'done-1-1.flag'), 'old flags not removed')
check(not exists(cacheDir .. 'status-1-1.part') and not exists(cacheDir .. 'status.json'),
    'parts of another fetch not removed or put in place')
cb.onSimulationStop()

print('-- SARMAT server: download on mission load')
download = 'ok'
cb.onMissionLoadEnd()
check(frames(30), 'download did not finish')
check(logged('map data downloaded'), 'download not reported as ok')
check(exists(cacheDir .. 'status.json') and exists(cacheDir .. 'units.json'), 'downloaded pair not put in place')
for _, f in ipairs(listDir(cacheDir)) do check(not string.match(f, '%.part$'), 'part left in the cache: ' .. f) end

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
check(chats[1] == 'SarmatDTC: BLUE DTC ready (Hatay): AH-64D, F-16C, FA-18C, ZZ',
    'chat message: ' .. tostring(chats[1]))
check(logged('base=Hatay'), 'airfield slot not resolved')
check(logged('cartridges written for blue around Hatay in %d+ ms: '), 'spawn base or build time not logged')
check(logged('^loaded, version %d+%.%d+%.%d+$'), 'version not logged')
local blue = readAH64()

print('-- base DTC from config.lua')
check(logged('AH%-64D_BLK_II%[sortie%] %+base'), 'AH-64 base DTC not used')
check(string.find(blue, '121.5', 1, true) and string.find(blue, '"W01"', 1, true), 'AH-64 base fields missing in the cartridge')
check(logged('BASE_DTC for F%-16C_50 is a AH%-64D_BLK_II cartridge'), 'wrong base type not reported')
check(logged('BASE_DTC for FA%-18C_hornet is the generated file itself'), 'own output as base not rejected')
check(logged('BASE_DTC for F%-14BU not found: .*missing%.dtc'), 'missing base not reported (config.user.lua entry)')

print('-- extra outputs: text (relative + {side}), lua (absolute), json (%TEMP%)')
local txtPath = writedir .. 'Exports\\blue\\ZZ_TEST.txt'
local tf = io.open(txtPath, 'rb')
check(tf and string.find(tf:read('*a'), '^front=%d+ side=blue$'), 'text output missing or wrong')
if tf then tf:close() end
local okLua, luaOut = pcall(loadFile, writedir .. 'Abs\\ZZ_TEST.lua')
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

local statusPath = cacheDir .. 'status.json'
local ah64Path = dtcDir .. 'SARMAT_AH-64D_BLK_II.dtc'
-- own blue slot again after REFETCH_SEC: cartridges from the cache at once, then a download
local function retake()
    mySideNum, mySlot = 2, '101'
    clock = clock + 120
    local n = #chats
    cb.onPlayerChangeSlot(7)
    return n
end

print('-- download failed: old cache used, its age in the chat')
mtime[statusPath] = os.time() - 2 * 3600
download = 'fail'
local n = retake()
check(#chats == n + 1 and chats[#chats] == 'SarmatDTC: BLUE DTC ready (Hatay): AH-64D, F-16C, FA-18C, ZZ - map data 2 h old',
    'stale cache chat: ' .. tostring(chats[#chats]))
check(frames(30) and logged('^download failed %(status%.json: curl exit %d+'), 'failed download not reported with the curl code')
check(chats[#chats] == 'SarmatDTC: BLUE DTC ready (Hatay): AH-64D, F-16C, FA-18C, ZZ - download failed, map data 2 h old',
    'failed download chat: ' .. tostring(chats[#chats]))

print('-- cache too old: nothing written, the player is told once no download follows')
mtime[statusPath] = os.time() - 10 * 3600
os.remove(ah64Path)
n = retake()
check(#chats == n, 'chat before the download finished: ' .. tostring(chats[#chats]))
check(frames(30), 'download did not finish')
check(#chats == n + 1 and chats[#chats] == 'SarmatDTC: download failed, map data too old (10 h), no DTC written',
    'too old chat: ' .. tostring(chats[#chats]))
check(not exists(ah64Path), 'cartridge written from too old data')

print('-- cached data of another map: the player is told')
mtime[statusPath] = nil
local fixtureStatus = assert(io.open(statusPath, 'rb')):read('*a')
writeFile(statusPath, '{"theatre": "Caucasus", "front": []}')
n = retake()
check(frames(30), 'download did not finish')
check(#chats == n + 1 and chats[#chats] == 'SarmatDTC: download failed, map data is for Caucasus, mission map is Syria, no DTC written',
    'other map chat: ' .. tostring(chats[#chats]))
writeFile(statusPath, fixtureStatus)

print('-- download timed out: cache used, the player is told')
download = 'none'
n = retake()
check(#chats == n + 1, 'no cartridges from the cache before the download')
clock = clock + 300
cb.onSimulationFrame()
check(logged('^download timed out'), 'timeout not logged')
check(#chats == n + 2 and chats[#chats] == 'SarmatDTC: BLUE DTC ready (Hatay): AH-64D, F-16C, FA-18C, ZZ - download timed out',
    'timeout chat: ' .. tostring(chats[#chats]))

print('-- download confirms the cache: no second build and write, no chat')
download = 'ok'
local stamp = io.popen('dir /T:W "' .. ah64Path .. '" | find "SARMAT"'):read('*a')
n = retake()
check(#chats == n, 'unchanged input written again: ' .. tostring(chats[#chats]))
check(frames(30) and logged('^map data downloaded'), 'download did not finish')
check(#chats == n and logged('^map data unchanged, cartridges kept'), 'confirmed cache not skipped')
check(io.popen('dir /T:W "' .. ah64Path .. '" | find "SARMAT"'):read('*a') == stamp, 'cartridge rewritten')

print('-- a deleted cartridge is written again')
os.remove(ah64Path)
n = retake()
check(#chats == n + 1 and exists(ah64Path), 'deleted cartridge not written again')
check(frames(30), 'download did not finish')
check(#chats == n + 1, 'second write after a confirming download')

print('-- an error in a callback stays in the hook and is logged once')
local realId = net.get_my_player_id
net.get_my_player_id = function() error('api broken') end
local okCb = pcall(cb.onPlayerChangeSlot, 7) and pcall(cb.onPlayerChangeSlot, 7)
net.get_my_player_id = realId
local errLogs = 0
for _, l in ipairs(logs) do if string.find(l, '^onPlayerChangeSlot failed: .*api broken') then errLogs = errLogs + 1 end end
check(okCb and errLogs == 1, 'callback error escaped or not logged once (' .. errLogs .. ')')

print('-- a failed write names the step and logs the folder state')
os.remove(ah64Path)
os.execute('mkdir "' .. ah64Path .. '"')   -- a folder in place of the cartridge: rename fails
local from = #logs
retake()
check(frames(30), 'download did not finish')
check(logged('^cannot write .*SARMAT_AH%-64D_BLK_II%.dtc: cannot rename %.tmp to the cartridge', from),
    'failed write step not logged')
check(logged('^  folder directory.*, file directory.*, %.tmp missing, %.bak missing, new file in folder: ok', from),
    'failed write diagnostics not logged')
os.execute('rmdir "' .. ah64Path .. '"')

print('-- no temporary files left next to the cartridges')
for _, f in ipairs(listDir(dtcDir)) do
    check(not string.match(f, '%.tmp$') and not string.match(f, '%.bak$'), 'left over: ' .. f)
end

if failures > 0 then
    print(failures .. ' check(s) failed')
    os.exit(1)
end
print('hook: all checks passed')
