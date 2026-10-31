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
}
-- Which aircraft get cartridges and per-aircraft options: Scripts/SarmatDTC/config.lua

local LOG_TAG   = 'SARMAT.DTC'
local BASE_DIR  = lfs.writedir() .. 'Scripts\\SarmatDTC\\'
local CACHE_DIR = BASE_DIR .. 'cache'

local core = dofile(BASE_DIR .. 'SarmatDTC_core.lua')
core.FILE_PREFIX = CONFIG.FILE_PREFIX
local JSON = dofile('Scripts/JSON.lua')
local Terrain = nil

local function info(msg)  log.write(LOG_TAG, log.INFO, msg) end
local function warn(msg)  log.write(LOG_TAG, log.WARNING, msg) end

local settings = { OPTIONS = {} }   -- config.lua
local aircraft = {}                 -- selected aircraft modules

-- Reads config.lua and aircraft/*.lua. Called on load and on every mission start,
-- so edits apply without restarting DCS.
local function loadSettings()
    local okC, cfg = pcall(dofile, BASE_DIR .. 'config.lua')
    if not okC or type(cfg) ~= 'table' then
        warn('cannot load config.lua (' .. tostring(cfg) .. '), using all aircraft modules')
        cfg = {}
    end
    settings = { AIRCRAFT = cfg.AIRCRAFT, OPTIONS = cfg.OPTIONS or {}, BASE_DTC = cfg.BASE_DTC or {} }

    local dir = BASE_DIR .. 'aircraft\\'
    local files = {}
    local ok, err = pcall(function()
        for f in lfs.dir(dir) do files[#files + 1] = f end
    end)
    if not ok then warn('cannot list ' .. dir .. ': ' .. tostring(err)) end
    local modules, errors = core.loadAircraft(dir, files)
    for _, e in ipairs(errors) do warn('aircraft module skipped: ' .. e) end

    local missing
    aircraft, missing = core.selectModules(modules, settings.AIRCRAFT)
    for _, t in ipairs(missing) do warn('config.lua lists ' .. t .. ', but there is no aircraft module for it') end
    local types = {}
    for i, m in ipairs(aircraft) do types[i] = m.type end
    info('aircraft modules: ' .. table.concat(types, ', '))
end
loadSettings()

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
        spawn      = nil,     -- {x, z, name} of own slot's start base, if known
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

-- Output dir: absolute ("C:\...", "\\server\..."), with %ENV% variables, or relative to Saved Games.
local function resolveDir(dir)
    dir = string.gsub(dir or 'DTC', '%%(%w+)%%', function(k) return os.getenv(k) or ('%' .. k .. '%') end)
    dir = string.gsub(dir, '/', '\\')
    if not (string.match(dir, '^%a:\\') or string.match(dir, '^\\\\')) then dir = lfs.writedir() .. dir end
    if string.sub(dir, -1) ~= '\\' then dir = dir .. '\\' end
    return dir
end

local function mkdirs(dir)
    local path = string.match(dir, '^\\\\') and '\\\\' or ''
    for part in string.gmatch(dir, '[^\\]+') do
        path = path .. part .. '\\'
        if not string.match(part, ':$') then lfs.mkdir(path) end
    end
end

-- Serializers for module outputs (see SarmatDTC_core.lua header).
local ENCODERS = {
    ['dcs-dtc'] = function(content, unitType)
        return JSON:encode_pretty({ data = content, name = '', type = unitType })
    end,
    json = function(content) return JSON:encode_pretty(content) end,
    lua  = function(content) return 'return ' .. core.toLua(content) .. '\n' end,
    text = function(content) return tostring(content) end,
}

local function writeFileAtomic(path, content)
    local tmp = path .. '.tmp'
    local f, err = io.open(tmp, 'wb')
    if not f then return false, err end
    f:write(content)
    f:close()
    os.remove(path)
    return os.rename(tmp, path)
end

-- config.lua BASE_DTC: { [type] = file name in Saved Games\DCS.openbeta\DTC or absolute path }.
-- Decoded files are cached by path and modification time.
local baseCache = {}

local function loadBases()
    local bases = {}
    for unitType, name in pairs(settings.BASE_DTC or {}) do
        local path = string.gsub(tostring(name), '/', '\\')
        if not (string.match(path, '^%a:\\') or string.match(path, '^\\\\')) then
            path = lfs.writedir() .. 'DTC\\' .. path
        end
        local own = lfs.writedir() .. 'DTC\\' .. core.FILE_PREFIX .. unitType .. '.dtc'
        local stamp = lfs.attributes(path, 'modification')
        if string.lower(path) == string.lower(own) then
            warn('BASE_DTC for ' .. unitType .. ' is the generated file itself, ignored')
        elseif not stamp then
            warn('BASE_DTC for ' .. unitType .. ' not found: ' .. path)
        else
            local cached = baseCache[unitType]
            if not (cached and cached.path == path and cached.stamp == stamp) then
                local ok, decoded = pcall(JSON.decode, JSON, readFile(path) or '')
                cached = { path = path, stamp = stamp }
                if not (ok and type(decoded) == 'table' and type(decoded.data) == 'table') then
                    warn('BASE_DTC for ' .. unitType .. ' is not a DTC file: ' .. path)
                elseif decoded.type ~= unitType then
                    warn('BASE_DTC for ' .. unitType .. ' is a ' .. tostring(decoded.type) .. ' cartridge, ignored')
                else
                    cached.data = decoded.data
                end
                baseCache[unitType] = cached
            end
            bases[unitType] = cached.data
        end
    end
    return bases
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

local function logSlot(side, s)
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
        spawn     = state.spawn,
    }
    local okBuild, files, errors = pcall(core.build, status, units, state.side, env, aircraft, settings.OPTIONS,
        loadBases())
    if not okBuild then
        warn('build failed: ' .. tostring(files))
        return
    end
    for _, e in ipairs(errors) do warn('cartridge failed: ' .. e) end
    local failed = #errors

    local summary = {}
    local written, seen = {}, {}   -- short aircraft names for the chat, e.g. "AH-64D"
    local function statsText(stats)
        local parts = {}
        for k, v in pairs(stats) do parts[#parts + 1] = k .. '=' .. tostring(v) end
        table.sort(parts)
        return '(' .. table.concat(parts, ' ') .. ')'
    end
    for _, f in ipairs(files) do
        local vtag = f.variant and ('[' .. f.variant .. ']') or ''
        if f.skip then
            summary[#summary + 1] = f.type .. vtag .. '/' .. f.id .. ' not written ' .. statsText(f.stats)
        else
            local encode = ENCODERS[f.format]
            local okE, text = false, 'unknown format ' .. tostring(f.format)
            if encode then okE, text = pcall(encode, f.content, f.type) end
            local dir = resolveDir(f.dir)
            local path = dir .. f.file
            local okW, err = false, text
            if okE and type(text) == 'string' then
                mkdirs(dir)
                okW, err = writeFileAtomic(path, text)
            end
            if okW then
                local label = f.type .. vtag .. (f.id == core.NATIVE_OUTPUT and '' or ('/' .. f.id))
                if f.base then
                    label = label .. ' +base'
                    if #f.dropped > 0 then
                        warn(f.type .. ': base DTC is for another map, not used: ' .. table.concat(f.dropped, ', '))
                    end
                end
                summary[#summary + 1] = label .. ' ' .. statsText(f.stats)
                local short = (string.match(f.type, '^([^_]+)') or f.type)
                    .. (f.defaultVariant == false and vtag or '')   -- non-default variant only
                if not seen[short] then
                    seen[short] = true
                    written[#written + 1] = short
                end
            else
                warn('cannot write ' .. path .. ': ' .. tostring(err))
                failed = failed + 1
            end
        end
    end
    local around = state.spawn and (' around ' .. tostring(state.spawn.name or 'spawn')) or ''
    info('cartridges written for ' .. state.side .. around .. ': ' .. table.concat(summary, ', '))
    -- short chat line, details are in dcs.log
    local where = state.spawn and state.spawn.name and (' (' .. state.spawn.name .. ')') or ''
    local msg = 'SarmatDTC: ' .. string.upper(state.side) .. ' DTC ready' .. where .. ': '
        .. (#written > 0 and table.concat(written, ', ') or 'none')
    if failed > 0 then msg = msg .. ' - ' .. failed .. ' error(s), see dcs.log' end
    chat(msg)
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
    loadSettings()
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
    -- spawn base position: modules may prioritise objects around it
    local ok, slot = pcall(slotInfo, side)
    if not ok then warn('slot info failed: ' .. tostring(slot)) end
    state.spawn = (ok and slot.x and slot.z) and { x = slot.x, z = slot.z, name = slot.base } or nil
    if ok and CONFIG.LOG_SLOT then logSlot(side, slot) end
    if not (state.fetchedAt and now() - state.fetchedAt < CONFIG.REFETCH_SEC) then
        generate()                -- right away from the older cache, fresh data follows
    end
    startFetch()                  -- fresh data: generates now; otherwise when the download is done
end

function callbacks.onSimulationFrame()
    if not state.active then return end
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
