-- F/A-18C: configurable SA FAOR/FLOT lines and CORRIDORS, enemy SAM threats as SA MEZ
-- THRTS rings, and configurable map objects as GPS WYPT tables.
-- Format: CoreMods/aircraft/FA-18C/DTC/SA/*.lua, GPS WYPT/*.lua, ALR67/CMDS_defs.lua.
--
-- What the cartridge holds:
--   SA.CORRIDORS  seven independently assignable corridors (up to CORRIDOR_PTS points each)
--   SA.FAOR_FLOT  three FAOR and three FLOT lines (up to 7 points each)
--                 Every slot can hold the front, an active/own/enemy/any sector boundary,
--                 or stay empty. FLOT also accepts the western/central/eastern third
--                 of the front. Repeated sector assignments consume successive sectors.
--   GPS_WYPT      independently configurable tables 1 (numbers 1-100) and 2 (101-200):
--                 sources, side, distance from the front, order and point limit. By default
--                 table 1 holds airfields/FARPs of both sides in sectors crossed by the front,
--                 and table 2 holds enemy strongpoints/strongholds, closest to the front first.
--                 text = 5-char label, note = name.
--   SA.MEZ_THRTS  enemy SAM rings (THREATS = 0 keeps the mission's own threats instead)
--   SA defaults   Default_CORRIDORS_Point / Default_FAOR_Line / Default_FLOT_Line /
--                 Default_MEZ_THRTS_Level (the "Default" combos of the DTC SA pages)
--   ALR67.CMDS    CMDS program presets (opt.CMDS, from config.user.lua only; absent = the
--                 base DTC's / aircraft's own programs are kept)
-- Unassigned FAOR/FLOT/corridor slots stay empty. setData copies mirror_MEZ_THRTS as is,
-- so it is always written: false = our threats, true = the mission's.

local TYPE = "FA-18C_hornet"

local CMDS_PROGRAMS = { "MAN_1", "MAN_2", "MAN_3", "MAN_4", "MAN_5", "MAN_6",
    "AUTO_1", "AUTO_2", "AUTO_3", "BYP" }

-- 5-char GPS waypoint label: "FARP 25-1" -> "F25-1", "FOB BLUE-7" -> "B" + number,
-- "STRONGHOLD 4" -> "STRO4", "OPHH RED-24" -> "OPH24", plain airfield name -> first 5 chars.
local function gpsLabel(lib, name)
    local s = string.gsub(lib.asciiUpper(name), "%s+", "")
    local num = string.match(s, "^FARP(.+)$")
    if num then return string.sub("F" .. num, 1, 5) end
    num = string.match(s, "^FOB(.+)$")
    if num then return string.sub("B" .. num, 1, 5) end
    local digits = string.match(s, "(%d+)$")
    if digits then
        local head = string.gsub(s, "[%d%-]+$", "")
        return string.sub(head, 1, 5 - #digits) .. digits
    end
    return string.sub(s, 1, 5)
end

-- opt.CMDS = { delay = 0..10, MAN_1 = { chaffQ, chaffR, chaffI, flareQ, other1Q, other2Q },
-- ... } -> ALR67.CMDS.CMDSProgramSettings; only the fields present are written (the base
-- DTC keeps the rest). nil when CMDS is not configured at all.
local function cmdsNode(c)
    if type(c) ~= "table" then return nil end
    local out = {}
    if type(c.delay) == "number" then
        out.delay_between_programs = math.max(0, math.min(10, math.floor(c.delay + 0.5)))
    end
    local function qty(v) return type(v) == "number" and math.max(0, math.min(99, math.floor(v + 0.5))) or nil end
    for _, name in ipairs(CMDS_PROGRAMS) do
        local p = c[name]
        if type(p) == "table" then
            local chaff, prog = {}, {}
            chaff.Quantity = qty(p.chaffQ)
            chaff.Repeat = qty(p.chaffR)
            if type(p.chaffI) == "number" then
                chaff.Interval = math.max(0.25, math.min(5, math.floor(p.chaffI / 0.25 + 0.5) * 0.25))
            end
            if next(chaff) then prog.Chaff = chaff end
            local flare = qty(p.flareQ)
            if flare then prog.Flare = { Quantity = flare } end
            local o1 = qty(p.other1Q)
            if o1 then prog.Other1 = { Quantity = o1 } end
            local o2 = qty(p.other2Q)
            if o2 then prog.Other2 = { Quantity = o2 } end
            if next(prog) then out[name] = prog end
        end
    end
    return next(out) and out or nil
end

local function mapPoints(s, lib, sourceText, side, rangeNm, order, filter)
    local sourceLists = {
        { "AIRFIELDS", s.airfields }, { "FARPS", s.farps },
        { "STRONGPOINTS", s.strongpoints }, { "STRONGHOLDS", s.strongholds },
    }
    local sources = "," .. string.upper(tostring(sourceText or "")):gsub("%s", "") .. ","
    side = string.upper(tostring(side or "ALL"))
    local selected = {}
    for _, entry in ipairs(sourceLists) do
        if string.find(sources, "," .. entry[1] .. ",", 1, true) then
            for _, p in ipairs(entry[2]) do
                local sideOk = side == "ALL" or (side == "OWN" and p.friendly)
                    or (side == "ENEMY" and not p.friendly)
                local inRange = rangeNm <= 0 or lib.distToPolyline(p.x, p.z, s.front) <= rangeNm * 1852
                if sideOk and inRange and (filter == nil or filter(p)) then
                    selected[#selected + 1] = p
                end
            end
        end
    end
    order = string.upper(tostring(order or "FRONT"))
    if order == "MAP" then return selected end
    if order == "FRONT" then return lib.byFront(selected, s.front) end
    if order == "FRONT_FAR" then
        return lib.byScore(selected, function(p) return -lib.distToPolyline(p.x, p.z, s.front) end)
    end
    local ordered = {}
    for i, p in ipairs(selected) do ordered[i] = p end
    if order == "NAME" then
        table.sort(ordered, function(a, b) return a.name < b.name end)
    else
        local axis = (order == "NORTH_SOUTH" or order == "SOUTH_NORTH") and "x" or "z"
        local descending = order == "EAST_WEST" or order == "NORTH_SOUTH"
        table.sort(ordered, function(a, b)
            if a[axis] ~= b[axis] then
                if descending then return a[axis] > b[axis] end
                return a[axis] < b[axis]
            end
            return a.name < b.name
        end)
    end
    return ordered
end

local function closedRing(ring)
    local out = {}
    for i, p in ipairs(ring) do out[i] = p end
    local first, last = out[1], out[#out]
    if first and last and (first.x ~= last.x or first.z ~= last.z) then out[#out + 1] = first end
    return out
end

local FRONT_BANDS = {
    FRONT_WEST = { 0, 1, "WEST FRONT" },
    FRONT_CENTER = { 1, 2, "CENTRAL FRONT" },
    FRONT_EAST = { 2, 3, "EAST FRONT" },
}

-- Clip the front to one third of its west-east span. Interpolated cut points make
-- adjacent bands meet exactly. If a winding front crosses a band more than once,
-- use its longest continuous fragment rather than inventing a connecting segment.
local function frontBand(front, band)
    if #front < 2 then return nil end
    local minZ, maxZ = front[1].z, front[1].z
    for i = 2, #front do
        minZ = math.min(minZ, front[i].z)
        maxZ = math.max(maxZ, front[i].z)
    end
    if maxZ <= minZ then return nil end
    local span = maxZ - minZ
    local lo, hi = minZ + span * band[1] / 3, minZ + span * band[2] / 3
    local runs, current = {}, {}
    local function add(p)
        local last = current[#current]
        if not last or last.x ~= p.x or last.z ~= p.z then current[#current + 1] = p end
    end
    local function finish()
        if #current >= 2 then runs[#runs + 1] = current end
        current = {}
    end
    local function interpolate(a, b, t)
        return { x = a.x + (b.x - a.x) * t, z = a.z + (b.z - a.z) * t }
    end
    for i = 1, #front - 1 do
        local a, b = front[i], front[i + 1]
        local dz = b.z - a.z
        if dz == 0 then
            if a.z >= lo and a.z <= hi then
                add(a)
                add(b)
            else
                finish()
            end
        else
            local ta, tb = (lo - a.z) / dz, (hi - a.z) / dz
            local t0, t1 = math.max(0, math.min(ta, tb)), math.min(1, math.max(ta, tb))
            if t0 <= t1 then
                add(interpolate(a, b, t0))
                add(interpolate(a, b, t1))
            else
                finish()
            end
        end
    end
    finish()
    local best, bestLength = nil, -1
    for _, run in ipairs(runs) do
        local length = 0
        for i = 2, #run do
            length = length + math.sqrt((run[i].x - run[i - 1].x) ^ 2 + (run[i].z - run[i - 1].z) ^ 2)
        end
        if length > bestLength then best, bestLength = run, length end
    end
    return best
end

-- Build one numbered DTC family. Sector assignments of the same kind consume successive
-- matching sectors; front assignments may deliberately be repeated. Empty slots keep
-- their DTC numbers. The three geographic front bands are available only to FLOT.
local function assignedLines(s, lib, opt, prefix, idPrefix, count, maxPts, activeSectors)
    local out, used, pools, built = {}, {}, {}, 0
    local function pool(source)
        if pools[source] then return pools[source] end
        local list = {}
        if source == "ACTIVE_SECTORS" then
            list = activeSectors or {}
        elseif source == "OWN_SECTORS" or source == "ENEMY_SECTORS" or source == "ALL_SECTORS" then
            for _, sec in ipairs(s.sectors) do
                if source == "ALL_SECTORS"
                    or (source == "OWN_SECTORS" and sec.owner == s.side)
                    or (source == "ENEMY_SECTORS" and sec.owner ~= s.side) then
                    list[#list + 1] = sec
                end
            end
        end
        pools[source] = list
        return list
    end
    for slot = 1, count do
        local source = string.upper(tostring(opt[prefix .. "_" .. slot] or "NONE"))
        local line, note
        if source == "FRONT" then
            line = s.front
            note = prefix == "CORRIDOR" and "FLOT" or "FRONT"
        elseif prefix == "FLOT" and FRONT_BANDS[source] then
            local band = FRONT_BANDS[source]
            line = frontBand(s.front, band)
            note = band[3]
        elseif source ~= "NONE" then
            used[source] = (used[source] or 0) + 1
            local sec = pool(source)[used[source]]
            if sec then
                line = closedRing(sec.ring)
                note = sec.name ~= "" and sec.name or source
            end
        end
        if line and #line >= 2 then
            local points = {}
            for j, p in ipairs(lib.simplify(line, maxPts)) do
                points[j] = { id = idPrefix .. "_" .. slot .. "_PT_" .. j,
                    x = lib.round(p.x), y = lib.round(p.z) }
            end
            out[slot] = { id = idPrefix .. "_" .. slot, num = slot, note = note, points = points }
            built = built + 1
        end
    end
    return out, built
end

return {
    type = TYPE,
    base = { terrainPaths = { "WYPT", "GPS_WYPT", "TCN", "SA.CAP_PTS", "SA.CORRIDORS", "SA.FAOR_FLOT", "SA.MEZ_THRTS" } },
    options = {
        THREATS      = 40,      -- MEZ THRTS (0 = keep the mission's threats)
        MIN_RANGE    = 6000,    -- [m] skip short-range AD (AAA, MANPADS, SA-9/13, Avenger)
        DEDUP_M      = 5000,    -- one ring per threat type within this distance
        THREAT_LEVEL = 1,       -- 1..3
        CORRIDOR_PTS = 14,      -- points per corridor (the DTC takes at most 14)
        FAOR_1 = "NONE", FAOR_2 = "NONE", FAOR_3 = "NONE",
        FLOT_1 = "NONE", FLOT_2 = "NONE", FLOT_3 = "NONE",
        CORRIDOR_1 = "FRONT", CORRIDOR_2 = "NONE", CORRIDOR_3 = "NONE",
        CORRIDOR_4 = "NONE", CORRIDOR_5 = "NONE", CORRIDOR_6 = "NONE", CORRIDOR_7 = "NONE",
        -- Common sources: NONE | FRONT | ACTIVE_SECTORS | OWN_SECTORS | ENEMY_SECTORS | ALL_SECTORS
        -- FLOT only: FRONT_WEST | FRONT_CENTER | FRONT_EAST (geographic thirds, joined at cuts)
        GPS1_MAX     = 100,     -- GPS WYPT table 1: point limit (0 = none)
        GPS2_MAX     = 100,     -- GPS WYPT table 2: point limit (0 = none)
        GPS1_NM      = 0,       -- maximum distance from the front [NM], 0 = unlimited
        GPS2_NM      = 0,
        GPS1_SOURCES = "AIRFIELDS,FARPS",
        GPS2_SOURCES = "STRONGPOINTS,STRONGHOLDS",
        GPS1_SIDE    = "ALL",   -- OWN | ENEMY | ALL
        GPS2_SIDE    = "ENEMY",
        GPS1_ORDER   = "FRONT",
        GPS2_ORDER   = "FRONT",
        GPS1_ACTIVE_ONLY = true, -- restrict table 1 to sectors crossed by the front line
        DEFAULT_CORRIDOR = 1,   -- SA page default corridor (1..7, 0 = NONE)
        DEFAULT_FAOR = 4,       -- default FAOR line (1..3, 4 = NONE)
        DEFAULT_FLOT = 4,       -- default FLOT line (1..3, 4 = NONE)
        DEFAULT_MEZ_LVL = 4,    -- default MEZ threat level (1..3, 4 = NONE)
    },
    -- config.lua values outside these are clamped (MEZ THRTS 40, corridor 14 pts, GPS 100+100)
    limits = {
        THREATS = { 0, 40, int = true }, MIN_RANGE = { 0 }, DEDUP_M = { 0 },
        THREAT_LEVEL = { 1, 3, int = true }, CORRIDOR_PTS = { 2, 14, int = true },
        GPS1_MAX = { 0, 100, int = true }, GPS2_MAX = { 0, 100, int = true },
        GPS1_NM = { 0 }, GPS2_NM = { 0 },
        DEFAULT_CORRIDOR = { 0, 7, int = true }, DEFAULT_FAOR = { 1, 4, int = true },
        DEFAULT_FLOT = { 1, 4, int = true }, DEFAULT_MEZ_LVL = { 1, 4, int = true },
    },

    build = function(s, lib, opt)
        -- Independently assignable SA lines/corridors. FAOR/FLOT have 7 points per line,
        -- corridors 14. Sector boundaries are closed so their last segment is visible.
        local sectors = lib.activeSectors(s)
        local corridors, nCorridors = assignedLines(s, lib, opt, "CORRIDOR", "CORR", 7, opt.CORRIDOR_PTS, sectors)
        local faor, nFaor = assignedLines(s, lib, opt, "FAOR", "FAOR", 3, 7, sectors)
        local flot, nFlot = assignedLines(s, lib, opt, "FLOT", "FLOT", 3, 7, sectors)

        -- GPS WYPT: only what is in play (the map's objective lists) inside the sectors the
        -- front runs through; without sector data everything in play counts.
        local function inPlay(p)
            return sectors == nil or lib.inAnySector(p.x, p.z, sectors)
        end
        local function gpsPt(num, p)
            return { id = "GPS_WYPT" .. num, wypt_num = num, x = lib.round(p.x), y = lib.round(p.z),
                alt = lib.elevation(s.env, p.x, p.z), text = gpsLabel(lib, p.name),
                note = lib.asciiUpper(p.name) }
        end

        -- GPS tables 1/2: independently configurable sources, side, range and ordering.
        local src1 = mapPoints(s, lib, opt.GPS1_SOURCES, opt.GPS1_SIDE, opt.GPS1_NM,
            opt.GPS1_ORDER, opt.GPS1_ACTIVE_ONLY and inPlay or nil)
        local gps, n1 = {}, 0
        for i = 1, math.min(#src1, opt.GPS1_MAX) do
            n1 = n1 + 1
            gps[#gps + 1] = gpsPt(n1, src1[i])
        end

        local src2 = mapPoints(s, lib, opt.GPS2_SOURCES, opt.GPS2_SIDE, opt.GPS2_NM, opt.GPS2_ORDER)
        local n2 = 0
        for i = 1, math.min(#src2, opt.GPS2_MAX) do
            n2 = n2 + 1
            gps[#gps + 1] = gpsPt(100 + n2, src2[i])
        end

        local mez = {}
        for i, t in ipairs(lib.enemyThreats(s, opt.THREATS, opt)) do
            mez[i] = { id = "MEZ_THRTS_" .. i, num = i, x = lib.round(t.x), y = lib.round(t.z), text = t.text,
                threat_type = t.name, threat_ring_radius = lib.round(t.range / 1852, 0.01),   -- [NM]
                threat_level = opt.THREAT_LEVEL }
        end

        local data = lib.cartridge(TYPE, s.env)
        if #gps > 0 then data.GPS_WYPT = gps end
        data.SA = { CORRIDORS = corridors, FAOR_FLOT = { FAOR = faor, FLOT = flot },
            mirror_MEZ_THRTS = true,
            Default_FAOR_Line = opt.DEFAULT_FAOR, Default_FLOT_Line = opt.DEFAULT_FLOT,
            Default_MEZ_THRTS_Level = opt.DEFAULT_MEZ_LVL }
        if opt.DEFAULT_CORRIDOR >= 1 and corridors[opt.DEFAULT_CORRIDOR] then
            data.SA.Default_CORRIDORS_Point = opt.DEFAULT_CORRIDOR
        end
        if opt.THREATS > 0 then
            data.SA.mirror_MEZ_THRTS = false
            data.SA.MEZ_THRTS = mez
        end
        local cmds = cmdsNode(opt.CMDS)
        if cmds then data.ALR67 = { CMDS = { CMDSProgramSettings = cmds } } end
        return data, { corridors = nCorridors, faor = nFaor, flot = nFlot,
            gps1 = n1, gps2 = n2, threats = #mez }
    end,

    outputs = {
        {
            id      = "dcs-dtc-waypoints",
            format  = "json",
            dir     = "%USERPROFILE%\\Documents\\DCS-DTC\\Presets\\FA18C",
            file    = "SARMAT.json",
            enabled = false,
            build   = function(s, lib, opt, built)
                -- The app accepts 0..59; keep 0 free and renumber GPS tables 1/2 as 1..59.
                local gps = built["dcs-dtc"].GPS_WYPT
                if not gps or #gps == 0 then return nil, { waypoints = 0 } end
                local points = {}
                for i = 1, math.min(#gps, 59) do
                    local p = gps[i]
                    points[i] = lib.dcsDtcWaypoint(s.env, i, p.note or p.text, p.x, p.y)
                end
                return {
                    Aircraft = "FA18C",
                    Upload = { Waypoints = true },
                    Waypoints = { Waypoints = points },
                    Version = 2,
                }, { waypoints = #points }
            end,
        },
    },
}
