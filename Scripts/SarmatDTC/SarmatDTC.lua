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
    FETCH_TIMEOUT = 240,           -- above fetch.cmd's worst case (~200 s), or runs could overlap
    STALE_SEC     = 600,           -- cached map data older than this: its age is shown in the chat
    MAX_AGE_SEC   = 3 * 3600,      -- cached map data older than this is not used
    SHOW_CHAT     = true,          -- local-only chat notification after writing cartridges
    LOG_SLOT      = true,          -- write own slot details (group, start airbase/FARP, position) to dcs.log
}
-- Which aircraft get cartridges and per-aircraft options: Scripts/SarmatDTC/config.lua,
-- user changes in config.user.lua (see readConfig)

local VERSION   = '1.1.0'          -- in dcs.log: which version a player runs
local LOG_TAG   = 'SARMAT.DTC'
local BASE_DIR  = lfs.writedir() .. 'Scripts\\SarmatDTC\\'
local CACHE_DIR = BASE_DIR .. 'cache'

-- not dofile: it cannot open UTF-8 paths (Cyrillic user name), io.open can (see core.loadFile)
local function loadFile(path)
    local f = assert(io.open(path, 'rb'))
    local text = f:read('*a')
    f:close()
    return assert(loadstring(text, '@' .. path))()
end
local core = loadFile(BASE_DIR .. 'SarmatDTC_core.lua')
local JSON = dofile('Scripts/JSON.lua')   -- relative to the DCS install
local Terrain = nil

local function info(msg)  log.write(LOG_TAG, log.INFO, msg) end
local function warn(msg)  log.write(LOG_TAG, log.WARNING, msg) end

local settings = { OPTIONS = {} }   -- config.lua
local aircraft = {}                 -- selected aircraft modules

local function fileExists(path)
    return lfs.attributes(path, 'mode') == 'file'
end

-- config.lua (shipped defaults) with the optional config.user.lua over it: the user's AIRCRAFT
-- list replaces the shipped one, BASE_DTC[type] and OPTIONS[type] entries replace per type.
-- config.user.lua is not shipped, so a mod update keeps the user's settings.
local function readConfig()
    local okC, cfg = pcall(core.loadFile, BASE_DIR .. 'config.lua')
    if not okC or type(cfg) ~= 'table' then
        warn('cannot load config.lua (' .. tostring(cfg) .. '), using all aircraft modules')
        cfg = {}
    end
    local merged = { AIRCRAFT = cfg.AIRCRAFT, OPTIONS = {}, BASE_DTC = {} }
    local user = {}
    if fileExists(BASE_DIR .. 'config.user.lua') then
        local okU, u = pcall(core.loadFile, BASE_DIR .. 'config.user.lua')
        if okU and type(u) == 'table' then
            user = u
            info('config.user.lua loaded')
        else
            warn('cannot load config.user.lua (' .. tostring(u) .. '), using config.lua only')
        end
    end
    if type(user.AIRCRAFT) == 'table' then merged.AIRCRAFT = user.AIRCRAFT end
    for _, src in ipairs({ cfg, user }) do
        if src.DTC_DIR ~= nil then
            if type(src.DTC_DIR) == 'string' and string.match(src.DTC_DIR, '%S') then
                merged.DTC_DIR = src.DTC_DIR
            else
                warn('DTC_DIR must be a folder path, got ' .. tostring(src.DTC_DIR) .. ', ignored')
            end
        end
    end
    for _, section in ipairs({ 'OPTIONS', 'BASE_DTC' }) do
        for _, src in ipairs({ cfg[section], user[section] }) do
            for k, v in pairs(type(src) == 'table' and src or {}) do merged[section][k] = v end
        end
    end
    return merged
end

-- Reads the settings and aircraft/*.lua. Called on load and on every mission start,
-- so edits apply without restarting DCS.
local function loadSettings()
    settings = readConfig()

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
    if settings.DTC_DIR then info('cartridge folder (DTC_DIR): ' .. settings.DTC_DIR) end
end
loadSettings()

local state = {}

local function resetState()
    state = {
        active     = false,
        theatre    = nil,
        side       = nil,     -- "red" / "blue" of own slot
        fetching   = false,
        fetchId    = nil,     -- id of the running download, its result is cache/done-<id>.flag
        fetchStart = 0,
        fetchedAt  = nil,     -- real time of last successful download
        nextPoll   = 0,
        spawn      = nil,     -- {x, z, name} of own slot's start base, if known
        lastKey    = nil,     -- input of the cartridges on disk (inputKey), nil after a failed write
        lastFiles  = {},      -- their paths
    }
end
resetState()

local function now()
    return DCS.getRealTime()
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
    dir = string.gsub(dir or 'DTC', '%%([%w_()]+)%%', function(k) return os.getenv(k) or ('%' .. k .. '%') end)
    dir = string.gsub(dir, '/', '\\')
    if not (string.match(dir, '^%a:\\') or string.match(dir, '^\\\\')) then dir = lfs.writedir() .. dir end
    if string.sub(dir, -1) ~= '\\' then dir = dir .. '\\' end
    return dir
end

-- Returns the last lfs.mkdir error (nil when every part already existed or was created).
local function mkdirs(dir)
    local path = string.match(dir, '^\\\\') and '\\\\' or ''
    local lastErr
    for part in string.gmatch(dir, '[^\\]+') do
        path = path .. part .. '\\'
        if not string.match(part, ':$') then
            local ok, err = lfs.mkdir(path)
            if not ok and lfs.attributes(string.gsub(path, '\\$', ''), 'mode') ~= 'directory' then
                lastErr = path .. ': ' .. tostring(err)
            end
        end
    end
    return lastErr
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

-- Writes via path.tmp; the previous file is moved aside first and put back if the new one
-- cannot take its place (e.g. the file is locked), so a failed write never loses it.
-- The error names the failed step: the io/os functions in DCS may fail without a message.
local function writeFileAtomic(path, content)
    local tmp, bak = path .. '.tmp', path .. '.bak'
    local f, err = io.open(tmp, 'wb')
    if not f then return false, 'cannot create .tmp (' .. tostring(err) .. ')' end
    local okW, errW = f:write(content)
    local okC, errC = f:close()
    if not (okW and okC) then
        os.remove(tmp)
        return false, (okW and 'cannot close .tmp (' or 'cannot write .tmp (') .. tostring(errW or errC) .. ')'
    end
    os.remove(bak)
    local moved, errB = false, nil
    if fileExists(path) then moved, errB = os.rename(path, bak) end
    local ok, errR = os.rename(tmp, path)
    if not ok then
        local msg = 'cannot rename .tmp to the cartridge (' .. tostring(errR) .. ')'
        if errB or (fileExists(path) and not moved) then
            msg = msg .. ', old file not moved to .bak (' .. tostring(errB) .. ')'
        end
        if moved and not os.rename(bak, path) then msg = msg .. ', old file left as .bak' end
        os.remove(tmp)
        return false, msg
    end
    if moved then os.remove(bak) end
    return true
end

-- dcs.log details for a failed write: state of the folder, the file and its .tmp/.bak,
-- and whether any new file can be created in the folder.
local function describePath(p)
    local a = lfs.attributes(p)
    if type(a) ~= 'table' then return 'missing' end
    local s = tostring(a.mode)
    if a.mode == 'file' then s = s .. ' ' .. tostring(a.size) .. ' bytes' end
    if a.permissions then s = s .. ' ' .. tostring(a.permissions) end
    return s
end

local function writeDiagnostics(dir, path)
    local probe = dir .. CONFIG.FILE_PREFIX .. 'probe.tmp'
    local f, err = io.open(probe, 'wb')
    local probeText = 'cannot create (' .. tostring(err) .. ')'
    if f then
        local okW = f:write('probe')
        f:close()
        probeText = okW and 'ok' or 'created, cannot write'
        if not os.remove(probe) then probeText = probeText .. ', cannot delete' end
    end
    return 'folder ' .. describePath(string.gsub(dir, '\\$', '')) .. ', file ' .. describePath(path)
        .. ', .tmp ' .. describePath(path .. '.tmp') .. ', .bak ' .. describePath(path .. '.bak')
        .. ', new file in folder: ' .. probeText
end

-- config.lua BASE_DTC: { [type] = file name in Saved Games\DCS.openbeta\DTC or absolute path }.
-- The DCS DTC editor saves there, so a DTC_DIR elsewhere does not move the base files.
-- Decoded files are cached by path and modification time.
local baseCache = {}

local function loadBases()
    local bases = {}
    for unitType, name in pairs(settings.BASE_DTC or {}) do
        local path = string.gsub(tostring(name), '/', '\\')
        if not (string.match(path, '^%a:\\') or string.match(path, '^\\\\')) then
            path = lfs.writedir() .. 'DTC\\' .. path
        end
        local own = resolveDir(settings.DTC_DIR) .. CONFIG.FILE_PREFIX .. unitType .. '.dtc'
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
    local ok, srv = pcall(net.get_server_settings)
    if ok and type(srv) == 'table' and srv.name then return srv.name end
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

-- Age of the cached map data [s] by the file time of cache/status.json, nil without cache.
local function cacheAge()
    local t = lfs.attributes(CACHE_DIR .. '\\status.json', 'modification')
    return t and math.max(0, os.time() - t) or nil
end

local function ageText(sec)
    if sec < 5400 then return math.floor(sec / 60 + 0.5) .. ' min' end
    return math.floor(sec / 3600 + 0.5) .. ' h'
end

-- Cached map data as text: { status, units, age } or nil, reason.
local function loadCache()
    local statusTxt = readFile(CACHE_DIR .. '\\status.json')
    local unitsTxt  = readFile(CACHE_DIR .. '\\units.json')
    if not (statusTxt and unitsTxt) then return nil, 'no map data' end
    local age = cacheAge()
    if age and age > CONFIG.MAX_AGE_SEC then return nil, 'map data too old (' .. ageText(age) .. ')' end
    return { status = statusTxt, units = unitsTxt, age = age }
end

-- Decoded map data of the mission's map: { status, units } or nil, reason.
local function decodeCache(cache)
    local ok, status = pcall(JSON.decode, JSON, cache.status)
    local ok2, units = pcall(JSON.decode, JSON, cache.units)
    if not (ok and ok2 and type(status) == 'table' and type(units) == 'table') then
        return nil, 'cannot parse map data'
    end
    if status.theatre and status.theatre ~= state.theatre then
        return nil, 'map data is for ' .. tostring(status.theatre) .. ', mission map is ' .. tostring(state.theatre)
    end
    return { status = status, units = units }
end

-- Everything the cartridges are made from (after loadBases): the same key gives the same files.
local function inputKey(cache)
    local s = state.spawn
    local spawn = s and table.concat({ tostring(s.x), tostring(s.z), tostring(s.name) }, ',') or ''
    local stamps = {}
    for unitType, c in pairs(baseCache) do stamps[#stamps + 1] = unitType .. '=' .. tostring(c.stamp) end
    table.sort(stamps)
    return table.concat({ state.side, spawn, table.concat(stamps, ' '), cache.status, cache.units }, '\n')
end

local function allExist(paths)
    for _, p in ipairs(paths) do
        if not fileExists(p) then return false end
    end
    return true
end

local function statsText(stats)
    local parts = {}
    for k, v in pairs(stats) do parts[#parts + 1] = k .. '=' .. tostring(v) end
    table.sort(parts)
    return '(' .. table.concat(parts, ' ') .. ')'
end

-- Encodes and writes the core.build results. Returns log summary parts, short aircraft names
-- for the chat (e.g. "AH-64D"), number of failed writes, written paths.
local function writeOutputs(files)
    local summary, written, seen, paths, failed = {}, {}, {}, {}, 0
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
            local okW, err, mkdirErr = false, text, nil
            if okE and type(text) == 'string' then
                mkdirErr = mkdirs(dir)
                okW, err = writeFileAtomic(path, text)
            end
            if okW then
                paths[#paths + 1] = path
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
                if okE then
                    local _, diag = pcall(writeDiagnostics, dir, path)
                    warn('  ' .. tostring(diag) .. (mkdirErr and (', mkdir: ' .. mkdirErr) or ''))
                end
                failed = failed + 1
            end
        end
    end
    return summary, written, failed, paths
end

-- dcs.log line with the details and a short chat line: side, spawn base, written aircraft and
-- notes (download problem, data age, errors). ms: GUI thread time of decoding, building and writing.
local function report(summary, written, failed, problem, age, ms)
    local old = age and age > CONFIG.STALE_SEC and ('map data ' .. ageText(age) .. ' old') or nil
    local around = state.spawn and (' around ' .. tostring(state.spawn.name or 'spawn')) or ''
    info('cartridges written for ' .. state.side .. around .. ' in ' .. ms .. ' ms'
        .. (old and (', ' .. old) or '') .. ': ' .. table.concat(summary, ', '))
    local where = state.spawn and state.spawn.name and (' (' .. state.spawn.name .. ')') or ''
    local msg = 'SarmatDTC: ' .. string.upper(state.side) .. ' DTC ready' .. where .. ': '
        .. (#written > 0 and table.concat(written, ', ') or 'none')
    local notes = {}
    notes[#notes + 1] = problem
    notes[#notes + 1] = old
    if failed > 0 then notes[#notes + 1] = failed .. ' error(s), see dcs.log' end
    if #notes > 0 then msg = msg .. ' - ' .. table.concat(notes, ', ') end
    chat(msg)
end

-- final: no download follows this attempt, so the player is told when nothing is written
-- (an attempt from the old cache before a download stays silent). problem: why the data
-- may be outdated ("download failed"), shown in the chat.
local function generate(final, problem)
    if not (state.active and state.side) then return end
    local function fail(msg)
        if not final then
            info(msg .. ', waiting for the download')
            return
        end
        warn(msg)
        chat('SarmatDTC: ' .. (problem and (problem .. ', ') or '') .. msg .. ', no DTC written')
    end

    local cache, why = loadCache()
    if not cache then return fail(why) end
    local bases = loadBases()
    local key = inputKey(cache)
    -- same input as the cartridges on disk (e.g. a download that confirms the cache): no second
    -- build and write, no chat. A download problem is news for the player, so it is not skipped.
    if not problem and key == state.lastKey and allExist(state.lastFiles) then
        info('map data unchanged, cartridges kept')
        return
    end
    local started = os.clock()
    local data, whyNot = decodeCache(cache)
    if not data then return fail(whyNot) end

    local t = getTerrain()
    local env = {
        terrain   = state.theatre,
        getHeight = t and t.GetHeight,
        toLatLon  = t and t.convertMetersToLatLon,
        spawn     = state.spawn,
    }
    local okBuild, files, errors, warnings = pcall(core.build, data.status, data.units, state.side, env, aircraft,
        settings.OPTIONS, bases, { dir = settings.DTC_DIR, prefix = CONFIG.FILE_PREFIX })
    if not okBuild then
        warn('build failed: ' .. tostring(files))
        return fail('build failed, see dcs.log')
    end
    for _, w in ipairs(warnings) do warn(w) end
    for _, e in ipairs(errors) do warn('cartridge failed: ' .. e) end

    local summary, written, writeFailed, paths = writeOutputs(files)
    -- a failed write may succeed next time (locked file), so it is not remembered as done
    state.lastKey, state.lastFiles = writeFailed == 0 and key or nil, paths
    report(summary, written, #errors + writeFailed, problem, cache.age, math.floor((os.clock() - started) * 1000 + 0.5))
end

------------------------------------------------------------------------------
-- background download
------------------------------------------------------------------------------

local fetchSeq = 0   -- not reset with the state: ids stay unique for the whole DCS session

local function flagPath(id)
    return CACHE_DIR .. '\\done-' .. id .. '.flag'
end

-- Result flags and downloaded parts of earlier fetches (and done.flag of old versions) are removed
-- before a new one; a part a late fetch still writes is locked and stays until the next time.
local function removeLeftovers()
    pcall(function()
        for f in lfs.dir(CACHE_DIR) do
            if string.match(f, '^done.*%.flag$') or string.match(f, '%.part$') then
                os.remove(CACHE_DIR .. '\\' .. f)
            end
        end
    end)
end

-- Puts the pair downloaded by fetch `id` in place of cache/status.json + units.json. Done here, on
-- the GUI thread, so the pair is never read half-updated and a late earlier fetch never replaces it.
local function promoteParts(id)
    local names = { 'status', 'units' }
    for _, n in ipairs(names) do
        if not fileExists(CACHE_DIR .. '\\' .. n .. '-' .. id .. '.part') then return false, n .. '.json missing' end
    end
    for _, n in ipairs(names) do
        local target = CACHE_DIR .. '\\' .. n .. '.json'
        os.remove(target)
        local ok, err = os.rename(CACHE_DIR .. '\\' .. n .. '-' .. id .. '.part', target)
        if not ok then return false, tostring(err) end
    end
    return true
end

local CURL_ERRORS = { [6] = 'host not found', [7] = 'cannot connect', [22] = 'HTTP error', [28] = 'timeout',
    [35] = 'TLS error', [60] = 'bad certificate', [63] = 'file too big' }

-- "fail units.json 28" -> "units.json: curl exit 28, timeout"
local function failText(result)
    local file, rc = string.match(result, '^fail (%S+) (%d+)')
    if not file then return 'no details' end
    local known = CURL_ERRORS[tonumber(rc)]
    return file .. ': curl exit ' .. rc .. (known and (', ' .. known) or '')
end

local function startFetch()
    if state.fetching then return end
    if state.fetchedAt and now() - state.fetchedAt < CONFIG.REFETCH_SEC then
        generate(true)
        return
    end
    local path = CONFIG.DATA_PATH[state.theatre or '']
    if not path then
        warn('no SARMAT map data for terrain ' .. tostring(state.theatre))
        if state.side then chat('SarmatDTC: no SARMAT map data for terrain ' .. tostring(state.theatre)) end
        return
    end
    lfs.mkdir(CACHE_DIR)
    removeLeftovers()
    fetchSeq = fetchSeq + 1
    local id = os.time() .. '-' .. fetchSeq
    -- fetch.vbs starts fetch.cmd (curl.exe) in a hidden window and returns at once; it writes
    -- into CACHE_DIR. DCS's os.execute silently drops commands longer than ~256 chars.
    local cmd = string.format('wscript.exe //B //Nologo "%sfetch.vbs" "%s" %s', BASE_DIR, CONFIG.SITE .. path, id)
    if #cmd > 250 then warn('download command may be too long for os.execute (' .. #cmd .. ' chars)') end
    local ok, err = pcall(os.execute, cmd)
    if not ok then
        warn('cannot start download: ' .. tostring(err))
        return
    end
    state.fetching = true
    state.fetchId = id
    state.fetchStart = now()
    info('downloading ' .. CONFIG.SITE .. path)
end

local function pollFetch()
    if not state.fetching then return end
    local flag = flagPath(state.fetchId)
    if fileExists(flag) then
        state.fetching = false
        local result = readFile(flag) or ''
        os.remove(flag)
        local ok, why = false, failText(result)
        if string.match(result, '^ok') then
            ok, why = promoteParts(state.fetchId)
            why = why and ('cannot put the data in place: ' .. why)
        end
        if ok then
            state.fetchedAt = now()
            info('map data downloaded')
            generate(true)
        else
            warn('download failed (' .. why .. '), using previous data if any')
            generate(true, 'download failed')
        end
    elseif now() - state.fetchStart > CONFIG.FETCH_TIMEOUT then
        state.fetching = false
        warn('download timed out, using previous data if any')
        generate(true, 'download timed out')
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
        generate(false)           -- right away from the older cache, fresh data follows
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

-- An error in a callback must not reach the game GUI; each distinct one is logged once
-- (onSimulationFrame would repeat it every frame).
local reported = {}
local safeCallbacks = {}
for name, fn in pairs(callbacks) do
    safeCallbacks[name] = function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            local msg = name .. ' failed: ' .. tostring(err)
            if not reported[msg] then
                reported[msg] = true
                log.write(LOG_TAG, log.ERROR, msg)
            end
        end
    end
end

DCS.setUserCallbacks(safeCallbacks)
info('loaded, version ' .. VERSION)
