-- SarmatDTC: generates DTC cartridges from the SARMAT live map (https://baikalprimestudio.com/map.html)
-- when connected to a multiplayer server whose name contains "SARMAT".
-- Loaded from Scripts/Hooks/SarmatDTC-hook.lua (DCS GUI environment).
--
-- Flow: mission loaded on a SARMAT server -> map data is downloaded in background (fetch.vbs -> fetch.cmd -> curl.exe);
-- player takes a slot -> cartridges are written for the slot's coalition (and rewritten when
-- the fresh download finishes). Files: Saved Games/DCS.openbeta/DTC/SARMAT_<type>.dtc
-- One cartridge per module in Scripts/SarmatDTC/aircraft/*.lua (see aircraft/_template.lua).

local lfs = require('lfs')

local CONFIG = {
    SERVER_MATCH  = "sarmat",      -- case-insensitive substring of the server name
    SITE          = "https://baikalprimestudio.com/",
    DATA_PATH     = { Syria = "data/", Caucasus = "k/data/" },
    FILE_PREFIX   = "SARMAT_",
    REFETCH_SEC   = 60,            -- reuse downloaded data if younger than this
    FETCH_TIMEOUT = 150,
    SHOW_CHAT     = true,          -- local-only chat notification after writing cartridges
    LOG_SLOT      = true,          -- write own slot details (group, start airbase/FARP, position) to dcs.log
    -- Per-aircraft overrides of module `options` (aircraft/<type>.lua); `enabled = false` skips a module.
    -- Examples: ['AH-64D_BLK_II'] = { CTRLM_FARPS = 15 },  ['F-14BU'] = { enabled = false },
    AIRCRAFT      = {
    },
}

local LOG_TAG   = 'SARMAT.DTC'
local BASE_DIR  = lfs.writedir() .. 'Scripts\\SarmatDTC\\'
local CACHE_DIR = BASE_DIR .. 'cache'
local DTC_DIR   = lfs.writedir() .. 'DTC\\'

local core = dofile(BASE_DIR .. 'SarmatDTC_core.lua')
local JSON = dofile('Scripts/JSON.lua')
local Terrain = nil

local function info(msg)  log.write(LOG_TAG, log.INFO, msg) end
local function warn(msg)  log.write(LOG_TAG, log.WARNING, msg) end

local function loadAircraft()
    local dir = BASE_DIR .. 'aircraft\\'
    local files = {}
    local ok, err = pcall(function()
        for f in lfs.dir(dir) do files[#files + 1] = f end
    end)
    if not ok then warn('cannot list ' .. dir .. ': ' .. tostring(err)) end
    local modules, errors = core.loadAircraft(dir, files)
    for _, e in ipairs(errors) do warn('aircraft module skipped: ' .. e) end
    local types = {}
    for i, m in ipairs(modules) do types[i] = m.type end
    info('aircraft modules: ' .. table.concat(types, ', '))
    return modules
end
local aircraft = loadAircraft()

local state = {}

local function resetState()
    state = {
        active     = false,
        theatre    = nil,
        side       = nil,     -- "red" / "blue" of own slot
        fetching   = false,
        fetchStart = 0,
        fetchedAt  = nil,     -- real time of last successful download
        nextPoll   = 0,
    }
end
resetState()

local function now()
    return DCS.getRealTime()
end

local function fileExists(path)
    return lfs.attributes(path, 'mode') == 'file'
end

local function readFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('*a')
    f:close()
    return s
end

local function writeFileAtomic(path, content)
    local tmp = path .. '.tmp'
    local f, err = io.open(tmp, 'wb')
    if not f then return false, err end
    f:write(content)
    f:close()
    os.remove(path)
    return os.rename(tmp, path)
end

local function chat(msg)
    if CONFIG.SHOW_CHAT then pcall(net.recv_chat, msg) end
end

------------------------------------------------------------------------------
-- environment queries
------------------------------------------------------------------------------

local function getTerrain()
    if not Terrain then
        local ok, t = pcall(require, 'terrain')
        if ok then Terrain = t end
    end
    return Terrain
end

local function terrainId()
    local t = getTerrain()
    if t then
        local ok, id = pcall(t.GetTerrainConfig, 'id')
        if ok and id then return id end
    end
    local ok, mission = pcall(DCS.getCurrentMission)
    if ok and mission and mission.mission then return mission.mission.theatre end
    return nil
end

local function serverName()
    local ok, settings = pcall(net.get_server_settings)
    if ok and type(settings) == 'table' and settings.name then return settings.name end
    return ''
end

local function mySide()
    local ok, side = pcall(net.get_player_info, net.get_my_player_id(), 'side')
    if ok then
        if side == 1 then return 'red' elseif side == 2 then return 'blue' end
    end
    return nil
end

-- Slot ids of multicrew seats look like "unitId_seat".
local function slotUnitId(id)
    id = tostring(id or '')
    return string.match(id, '^(.+)_%d+$') or id
end

-- Own slot details: aircraft, group and start base (airfield, or FARP/ship) with its map position.
-- Same sources as the slot selection UI (Scripts/UI/MultiplayerSelectRoleMap).
local function slotInfo(side)
    local result = { id = '' }
    local ok, slotId = pcall(net.get_player_info, net.get_my_player_id(), 'slot')
    if not ok or not slotId or slotId == '' then return result end
    result.id = tostring(slotId)
    local okS, slots = pcall(DCS.getAvailableSlots, side)
    for _, s in pairs(okS and slots or {}) do
        if slotUnitId(s.unitId) == slotUnitId(result.id) then
            result.type, result.group, result.takeOff = s.type, s.groupName, s.takeOffType
            result.airdromeId, result.helipadId = s.airdromeId, s.helipadId
            break
        end
    end
    if result.helipadId then
        local okF, data = pcall(DCS.getFarpsAndCarriersMissionData)
        local u = okF and type(data) == 'table'
            and ((data.farps or {})[result.helipadId] or (data.carriers or {})[result.helipadId])
        if u then result.base, result.x, result.z = u.name, u.x, u.y end
    elseif result.airdromeId then
        local t = getTerrain()
        local okA, airdromes = pcall(t and t.GetTerrainConfig, 'Airdromes')
        local a = okA and type(airdromes) == 'table' and airdromes[result.airdromeId]
        if a then
            result.base = a.display_name or (a.names and a.names.en)
            if a.reference_point then result.x, result.z = a.reference_point.x, a.reference_point.y end
        end
    end
    return result
end

local function logSlot(side)
    local s = slotInfo(side)
    local parts = {}
    for _, k in ipairs({ 'id', 'type', 'group', 'takeOff', 'airdromeId', 'helipadId', 'base', 'x', 'z' }) do
        if s[k] ~= nil then parts[#parts + 1] = k .. '=' .. tostring(s[k]) end
    end
    info('own slot (' .. side .. '): ' .. table.concat(parts, ' '))
end

------------------------------------------------------------------------------
-- cartridge generation
------------------------------------------------------------------------------

local function generate()
    if not (state.active and state.side) then return end
    local statusTxt = readFile(CACHE_DIR .. '\\status.json')
    local unitsTxt  = readFile(CACHE_DIR .. '\\units.json')
    if not (statusTxt and unitsTxt) then return end

    local ok, status = pcall(JSON.decode, JSON, statusTxt)
    local ok2, units = pcall(JSON.decode, JSON, unitsTxt)
    if not (ok and ok2 and type(status) == 'table' and type(units) == 'table') then
        warn('cannot parse downloaded map data')
        return
    end
    if status.theatre and status.theatre ~= state.theatre then
        warn('map data is for ' .. tostring(status.theatre) .. ', mission terrain is ' .. tostring(state.theatre))
        return
    end

    local t = getTerrain()
    local env = {
        terrain   = state.theatre,
        getHeight = t and t.GetHeight,
        toLatLon  = t and t.convertMetersToLatLon,
    }
    local okBuild, cartridges, errors = pcall(core.build, status, units, state.side, env, aircraft, CONFIG.AIRCRAFT)
    if not okBuild then
        warn('build failed: ' .. tostring(cartridges))
        return
    end
    for _, e in ipairs(errors) do warn('cartridge failed: ' .. e) end

    lfs.mkdir(DTC_DIR)
    local summary = {}
    for _, c in ipairs(cartridges) do
        local text = JSON:encode_pretty({ data = c.data, name = '', type = c.type })
        local path = DTC_DIR .. CONFIG.FILE_PREFIX .. c.type .. '.dtc'
        local okW, err = writeFileAtomic(path, text)
        if okW then
            local parts = {}
            for k, v in pairs(c.stats) do parts[#parts + 1] = k .. '=' .. v end
            table.sort(parts)
            summary[#summary + 1] = c.type .. ' (' .. table.concat(parts, ' ') .. ')'
        else
            warn('cannot write ' .. path .. ': ' .. tostring(err))
        end
    end
    info('cartridges written for ' .. state.side .. ': ' .. table.concat(summary, ', '))
    chat('SarmatDTC: DTC updated for ' .. string.upper(state.side) .. ' - ' .. table.concat(summary, ', '))
end

------------------------------------------------------------------------------
-- background download
------------------------------------------------------------------------------

local function startFetch()
    if state.fetching then return end
    if state.fetchedAt and now() - state.fetchedAt < CONFIG.REFETCH_SEC then
        generate()
        return
    end
    local path = CONFIG.DATA_PATH[state.theatre or '']
    if not path then
        warn('no SARMAT map data for terrain ' .. tostring(state.theatre))
        return
    end
    lfs.mkdir(CACHE_DIR)
    os.remove(CACHE_DIR .. '\\done.flag')
    -- fetch.vbs starts fetch.cmd (curl.exe) in a hidden window and returns at once; it writes
    -- into CACHE_DIR. DCS's os.execute silently drops commands longer than ~256 chars.
    local cmd = string.format('wscript.exe //B //Nologo "%sfetch.vbs" "%s"', BASE_DIR, CONFIG.SITE .. path)
    if #cmd > 250 then warn('download command may be too long for os.execute (' .. #cmd .. ' chars)') end
    local ok, err = pcall(os.execute, cmd)
    if not ok then
        warn('cannot start download: ' .. tostring(err))
        return
    end
    state.fetching = true
    state.fetchStart = now()
    info('downloading ' .. CONFIG.SITE .. path)
end

local function pollFetch()
    if not state.fetching then return end
    local flag = CACHE_DIR .. '\\done.flag'
    if fileExists(flag) then
        state.fetching = false
        local result = readFile(flag) or ''
        if string.find(result, 'ok') then
            state.fetchedAt = now()
            info('map data downloaded')
            generate()
        else
            warn('download failed, using previous data if any')
            generate()
        end
    elseif now() - state.fetchStart > CONFIG.FETCH_TIMEOUT then
        state.fetching = false
        warn('download timed out')
    end
end

------------------------------------------------------------------------------
-- DCS callbacks
------------------------------------------------------------------------------

local callbacks = {}

function callbacks.onMissionLoadEnd()
    resetState()
    if not DCS.isMultiplayer() then return end
    local name = serverName()
    local mission = DCS.getMissionName() or ''
    if not string.find(string.lower(name), CONFIG.SERVER_MATCH, 1, true) then
        return
    end
    state.active = true
    state.theatre = terrainId()
    info('SARMAT server detected: "' .. name .. '", mission "' .. mission .. '", terrain ' .. tostring(state.theatre))
    state.side = mySide()
    startFetch()
end

function callbacks.onPlayerChangeSlot(id)
    if not state.active or id ~= net.get_my_player_id() then return end
    local side = mySide()
    if not side then return end   -- spectators
    state.side = side
    if CONFIG.LOG_SLOT then
        local ok, err = pcall(logSlot, side)
        if not ok then warn('slot info failed: ' .. tostring(err)) end
    end
    if not (state.fetchedAt and now() - state.fetchedAt < CONFIG.REFETCH_SEC) then
        generate()                -- right away from the older cache, fresh data follows
    end
    startFetch()                  -- fresh data: generates now; otherwise when the download is done
end

function callbacks.onSimulationFrame()
    if state.fetching and now() >= state.nextPoll then
        state.nextPoll = now() + 1
        pollFetch()
    end
end

function callbacks.onSimulationStop()
    resetState()
end

DCS.setUserCallbacks(callbacks)
info('loaded')
