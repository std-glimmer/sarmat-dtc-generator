-- F-15E Strike Eagle (DCS type "F-15ESE"): a "DTC for DCS" JSON preset for Haack's F-15E DTC
-- mod, in the format the strike-eagle-dtc tool exports (src/eagle_dtc/dtcfile.py there is the
-- reference): Aircraft "F15E", Version 2, coordinates "N 36°16.819’" (prime = U+2019), feet.
-- One builder writes the same cartridge to two places: the DCS-DTC preset in
-- Documents\DCS-DTC\Presets\F15E and the directly loadable Modern F-15E cartridge in
-- <DCS profile>\ModernF15E\Cartridges. Both appear under the name "SARMAT".
--
-- What the cartridge holds (DCS has no native DTC editor for the F-15E, there is no "dcs-dtc"
-- output here):
--   Routes A/B/C are independently configurable with ROUTE_<id>_* options: source categories,
--   own/enemy/all, range from the front, point limit, ordering and target/steerpoint flag.
--   Defaults: A = enemy airfields/FARPs near the front; B = enemy strongpoints/strongholds
--   east to west; C = own airfields only, closest to the front first.
--   drawings include the front line (red solid), optional sector boundaries (white dotted),
--            and engagement rings of enemy SAMs (yellow dashed); the mod merges them into
--            the SIT page and draws at most 32 shapes in total, including mission drawings.
--            Our front line has priority, followed by sector boundaries and threat rings.
-- Radios/SmartWeapons are left out: the live map has no data for them (Upload flags false).
-- Display page presets and Misc (bingo, CARA, TACAN, ILS, TGP code) come from config.user.lua
-- (or the SarmatDTC configurator): OPTIONS["F-15ESE"].DISPLAYS / .MISC, see the bottom of this file.

local FT = 3.28084
local NM = 1852
local TYPE = "F-15ESE"

-- Degrees-minutes as the DTC for DCS files write them: "N 36°16.819’" (° = U+00B0, ’ = U+2019,
-- UTF-8 bytes; strike-eagle-dtc's parse_dm reads this back).
local function dm(value, pos, neg, degDigits)
    local a = math.abs(value)
    local deg = math.floor(a)
    local minutes = math.floor((a - deg) * 60000 + 0.5) / 1000
    if minutes >= 60 then deg, minutes = deg + 1, 0 end
    return string.format("%s %0" .. degDigits .. "d\194\176%06.3f\226\128\153",
        value >= 0 and pos or neg, deg, minutes)
end

local function latText(lat) return dm(lat, "N", "S", 2) end
local function lonText(lon) return dm(lon, "E", "W", 3) end

local function round6(v)
    return math.floor(v * 1e6 + 0.5) / 1e6
end

-- GeoJSON ring (closed polygon) of `radiusM` around lat/lon, `n` segments, [lon, lat] pairs.
local function ring(lat, lon, radiusM, n)
    local coords = {}
    local dLat = radiusM / 111320
    local cosLat = math.cos(math.rad(lat))
    local dLon = cosLat > 0.01 and radiusM / (111320 * cosLat) or 0
    for i = 0, n - 1 do
        local a = 2 * math.pi * i / n
        coords[#coords + 1] = { round6(lon + dLon * math.sin(a)), round6(lat + dLat * math.cos(a)) }
    end
    coords[#coords + 1] = coords[1]
    return coords
end

local function closedRing(points)
    local out = {}
    for i, p in ipairs(points) do out[i] = p end
    local first, last = out[1], out[#out]
    if first and last and (first.x ~= last.x or first.z ~= last.z) then out[#out + 1] = first end
    return out
end

-- Sort by distance to the front line ascending (stable).
local function byFront(lib, s, list)
    return lib.byScore(list, function(p) return lib.distToPolyline(p.x, p.z, s.front) end)
end

local LINE_STYLES = { solid = true, dash = true, dot = true, dotdash = true }

local function lineStyle(v, default)
    v = string.lower(tostring(v or ""))
    return LINE_STYLES[v] and v or default
end

local function cssColor(v, default)
    v = tostring(v or "")
    return string.match(v, "^#%x%x%x%x%x%x$") and string.upper(v) or default
end

-- Displays node: page/mode codes of the DTC for DCS file (strike-eagle-dtc dtcfile.py;
-- confirmed against Haack's schema of the Modern F-15E cartridge).
local PAGE_CODES = { ADI = 1, ARMT = 2, HSI = 3, TSD = 4, ENG = 5, HUD = 6, AARDR = 7, AGRDR = 8,
    TEWS = 9, TPOD = 10, AGDLVRY = 11, TF = 12, SMART = 13, SIT = 14 }
local MODE_CODES = { AA = 1, AG = 2, NAV = 3 }
local SLOT_KEYS = { "First", "Second", "Third" }
local DISPLAYS_BY_SEAT = { Pilot = { "LeftMPD", "RightMPD", "MPCD" },
    WSO = { "LeftMPCD", "LeftMPD", "RightMPD", "RightMPCD" } }

-- opt.DISPLAYS = { Pilot = { LeftMPD = { { page = "TSD", mode = "NAV" }, ... up to 3 }, ... }, WSO = {...} }
-- -> the Displays block of the file; nil when nothing valid is configured.
local function displaysNode(dsp)
    if type(dsp) ~= "table" then return nil end
    local out = {}
    for _, seat in ipairs({ "Pilot", "WSO" }) do
        for _, name in ipairs(DISPLAYS_BY_SEAT[seat]) do
            local slots = type(dsp[seat]) == "table" and dsp[seat][name] or nil
            if type(slots) == "table" then
                local block = {}
                for i = 1, 3 do
                    local slot = slots[i]
                    if type(slot) == "table" then
                        local page = PAGE_CODES[string.upper(tostring(slot.page or ""))]
                        local mode = MODE_CODES[string.upper(tostring(slot.mode or ""))]
                        if page and mode then
                            block[SLOT_KEYS[i] .. "Display"] = page
                            block[SLOT_KEYS[i] .. "DisplayMode"] = mode
                        end
                    end
                end
                if next(block) then
                    out[seat] = out[seat] or {}
                    out[seat][name] = block
                end
            end
        end
    end
    return next(out) and out or nil
end

-- opt.MISC = { Bingo, CARAALOW, TACANChannel, TACANBand = "X"|"Y", TACANMode = "TR"|"AA",
-- TACANOn = bool, ILSFrequency, TGPCode } -> the Misc block; nil when nothing is configured.
local function miscNode(m)
    if type(m) ~= "table" then return nil end
    local out = {}
    if type(m.Bingo) == "number" then
        out.Bingo = math.floor(m.Bingo + 0.5)
        out.BingoToBeUpdated = true
    end
    if type(m.CARAALOW) == "number" then
        out.CARAALOW = math.floor(m.CARAALOW + 0.5)
        out.CARAALOWToBeUpdated = true
    end
    if type(m.TACANChannel) == "number" then
        out.TACANChannel = math.floor(m.TACANChannel + 0.5)
        out.TACANBand = string.upper(tostring(m.TACANBand or "")) == "Y" and 1 or 0
        out.TACANToBeUpdated = true
        if m.TACANMode ~= nil then
            out.TACANMode = string.upper(tostring(m.TACANMode)) == "AA" and 1 or 0
        end
        if m.TACANOn ~= nil then
            out.TACANState = m.TACANOn and 1 or 0
        end
    end
    if type(m.ILSFrequency) == "number" then
        out.ILSFrequency = m.ILSFrequency
        out.ILSToBeUpdated = true
    end
    if type(m.TGPCode) == "number" then
        out.TGPCode = math.floor(m.TGPCode + 0.5)
        out.LaserSettingsToBeUpdated = true
    end
    return next(out) and out or nil
end

return {
    type = TYPE,
    options = {
        ROUTE_A_NM  = 50,      -- maximum distance from the front [NM], 0 = unlimited
        ROUTE_B_NM  = 20,
        ROUTE_C_NM  = 0,
        TARGETS     = 99,      -- route B point limit (legacy option name)
        ROUTE_A_LIMIT = 99,
        ROUTE_C_LIMIT = 99,
        ROUTE_A_SOURCES = "AIRFIELDS,FARPS",
        ROUTE_B_SOURCES = "STRONGPOINTS,STRONGHOLDS",
        ROUTE_C_SOURCES = "AIRFIELDS",
        ROUTE_A_SIDE = "ENEMY", -- OWN | ENEMY | ALL
        ROUTE_B_SIDE = "ENEMY",
        ROUTE_C_SIDE = "OWN",
        ROUTE_A_ORDER = "FRONT", -- FRONT | FRONT_FAR | EAST_WEST | WEST_EAST |
        ROUTE_B_ORDER = "EAST_WEST", -- NORTH_SOUTH | SOUTH_NORTH | NAME | MAP
        ROUTE_C_ORDER = "FRONT",
        ROUTE_A_TARGET = true,  -- target points instead of ordinary steerpoints
        ROUTE_B_TARGET = true,
        ROUTE_C_TARGET = false,
        MAX_WP      = 99,      -- safety cap per route (the jet's route holds 99)
        THREATS     = 0,       -- SAM engagement rings drawn on the SIT page. 0 = none: the Modern
                               -- F-15E mod draws its own SAM/EWR rings natively (amber/gray/magenta,
                               -- on SIT and TSD), our GeoJSON rings would overlap them. Set e.g. 24
                               -- only if the native rings are not visible on the server.
        MIN_RANGE   = 6000,    -- [m] see lib.enemyThreats: skip short-range AD
        DEDUP_M     = 5000,    -- one ring per threat type within this distance
        FRONT_PTS   = 30,      -- front line points in the drawing (0 = no line)
        FRONT_COLOR = "#FF0000",
        FRONT_STYLE = "solid", -- solid | dash | dot | dotdash
        SECTOR_SOURCE = "NONE", -- NONE | ACTIVE_SECTORS | OWN_SECTORS | ENEMY_SECTORS | ALL_SECTORS
        SECTOR_COLOR = "#FFFFFF",
        SECTOR_STYLE = "dot",  -- solid | dash | dot | dotdash
        RING_PTS    = 24,      -- polygon segments per threat ring
        RING_COLOR  = "#FFFF00",
        RING_STYLE  = "dash",
        -- non-numeric settings from config.user.lua only (see displaysNode/miscNode above):
        -- DISPLAYS = { Pilot = { LeftMPD = { { page = "TSD", mode = "NAV" }, ... } }, WSO = {...} }
        -- MISC = { Bingo = 4000, CARAALOW = 500, TACANChannel = 44, TACANBand = "X",
        --          TACANMode = "TR", TACANOn = true, ILSFrequency = 108.5, TGPCode = 1688 }
    },
    limits = {
        ROUTE_A_NM = { 0 }, ROUTE_B_NM = { 0 }, ROUTE_C_NM = { 0 },
        TARGETS = { 0, 99, int = true },
        ROUTE_A_LIMIT = { 0, 99, int = true }, ROUTE_C_LIMIT = { 0, 99, int = true },
        MAX_WP = { 1, 99, int = true },
        THREATS = { 0, 30, int = true },       -- the mod draws at most 32 shapes, the front line is one
        FRONT_PTS = { 0, 100, int = true }, RING_PTS = { 8, 48, int = true },
        MIN_RANGE = { 0 }, DEDUP_M = { 0 },
    },

    outputs = {
        {
            id     = "f15e-dtc",
            format = "json",
            dir    = "%USERPROFILE%\\Documents\\DCS-DTC\\Presets\\F15E",
            file   = "SARMAT.json",
            build  = function(s, lib, opt)
                local function wp(seq, p, target)
                    local lat, lon = lib.latLon(s.env, p.x, p.z)
                    return { Sequence = seq, Name = lib.asciiUpper(p.name, 12),
                        Latitude = latText(lat), Longitude = lonText(lon),
                        Elevation = math.floor(lib.elevation(s.env, p.x, p.z) * FT + 0.5),
                        Target = target }
                end
                local function nearFront(p, nm)
                    return lib.distToPolyline(p.x, p.z, s.front) <= nm * NM
                end

                local sourceLists = {
                    { "AIRFIELDS", s.airfields }, { "FARPS", s.farps },
                    { "STRONGPOINTS", s.strongpoints }, { "STRONGHOLDS", s.strongholds },
                }
                local function buildRoute(sourceText, side, rangeNm, limit, order, target)
                    local sources = "," .. string.upper(tostring(sourceText or "")):gsub("%s", "") .. ","
                    side = string.upper(tostring(side or "ALL"))
                    local selected = {}
                    for _, entry in ipairs(sourceLists) do
                        if string.find(sources, "," .. entry[1] .. ",", 1, true) then
                            for _, p in ipairs(entry[2]) do
                                local sideOk = side == "ALL" or (side == "OWN" and p.friendly)
                                    or (side == "ENEMY" and not p.friendly)
                                if sideOk and (rangeNm <= 0 or nearFront(p, rangeNm)) then
                                    selected[#selected + 1] = p
                                end
                            end
                        end
                    end
                    order = string.upper(tostring(order or "FRONT"))
                    local ordered
                    if order == "MAP" then
                        ordered = selected
                    elseif order == "FRONT_FAR" then
                        ordered = lib.byScore(selected, function(p)
                            return -lib.distToPolyline(p.x, p.z, s.front)
                        end)
                    elseif order == "NAME" then
                        ordered = {}
                        for i, p in ipairs(selected) do ordered[i] = p end
                        table.sort(ordered, function(a, b) return a.name < b.name end)
                    elseif order ~= "FRONT" then
                        local axis = (order == "NORTH_SOUTH" or order == "SOUTH_NORTH") and "x" or "z"
                        local descending = order == "EAST_WEST" or order == "NORTH_SOUTH"
                        ordered = {}
                        for i, p in ipairs(selected) do ordered[i] = p end
                        table.sort(ordered, function(a, b)
                            if a[axis] ~= b[axis] then
                                if descending then return a[axis] > b[axis] end
                            return a[axis] < b[axis]
                            end
                            return a.name < b.name
                        end)
                    else
                        ordered = byFront(lib, s, selected)
                    end
                    local route = {}
                    local maxPoints = math.min(opt.MAX_WP, limit)
                    for _, p in ipairs(ordered) do
                        if #route >= maxPoints then break end
                        route[#route + 1] = wp(#route + 1, p, target == true)
                    end
                    return route
                end

                local routeA = buildRoute(opt.ROUTE_A_SOURCES, opt.ROUTE_A_SIDE, opt.ROUTE_A_NM,
                    opt.ROUTE_A_LIMIT, opt.ROUTE_A_ORDER, opt.ROUTE_A_TARGET)
                local routeB = buildRoute(opt.ROUTE_B_SOURCES, opt.ROUTE_B_SIDE, opt.ROUTE_B_NM,
                    opt.TARGETS, opt.ROUTE_B_ORDER, opt.ROUTE_B_TARGET)
                local routeC = buildRoute(opt.ROUTE_C_SOURCES, opt.ROUTE_C_SIDE, opt.ROUTE_C_NM,
                    opt.ROUTE_C_LIMIT, opt.ROUTE_C_ORDER, opt.ROUTE_C_TARGET)

                -- Drawings: front line + sector boundaries + threat rings. The mod's 32-shape
                -- budget is shared with mission drawings; our own priority is front > sectors > rings.
                local frontColor = cssColor(opt.FRONT_COLOR, "#FF0000")
                local frontStyle = lineStyle(opt.FRONT_STYLE, "solid")
                local sectorColor = cssColor(opt.SECTOR_COLOR, "#FFFFFF")
                local sectorStyle = lineStyle(opt.SECTOR_STYLE, "dot")
                local ringColor = cssColor(opt.RING_COLOR, "#FFFF00")
                local ringStyle = lineStyle(opt.RING_STYLE, "dash")
                local drawings = {}
                if opt.FRONT_PTS >= 2 and #s.front >= 2 then
                    local coords = {}
                    for i, p in ipairs(lib.simplify(s.front, opt.FRONT_PTS)) do
                        local lat, lon = lib.latLon(s.env, p.x, p.z)
                        coords[i] = { round6(lon), round6(lat) }
                    end
                    drawings[#drawings + 1] = { name = "SARMAT front.geojson",
                        geojson = { type = "FeatureCollection", features = {
                            { type = "Feature",
                              properties = { name = "SARMAT FLOT", side = "all",
                                  color = frontColor, style = frontStyle },
                              geometry = { type = "LineString", coordinates = coords } } } } }
                end
                local frontCount = #drawings
                local sectors = {}
                local sectorSource = string.upper(tostring(opt.SECTOR_SOURCE or "NONE"))
                local active = sectorSource == "ACTIVE_SECTORS" and lib.activeSectors(s) or nil
                local activeSet = {}
                for _, sec in ipairs(active or {}) do activeSet[sec] = true end
                if sectorSource ~= "NONE" then
                    for i, sec in ipairs(s.sectors) do
                        if #sectors >= 32 - frontCount then break end
                        local selected = sectorSource == "ALL_SECTORS"
                            or (sectorSource == "ACTIVE_SECTORS" and activeSet[sec])
                            or (sectorSource == "OWN_SECTORS" and sec.owner == s.side)
                            or (sectorSource == "ENEMY_SECTORS" and sec.owner ~= s.side)
                        if selected then
                            local coords = {}
                            for j, p in ipairs(lib.simplify(closedRing(sec.ring), 64)) do
                                local lat, lon = lib.latLon(s.env, p.x, p.z)
                                coords[j] = { round6(lon), round6(lat) }
                            end
                            if #coords >= 4 then
                                local label = tostring(sec.name or "")
                                if label == "" then label = tostring(i) end
                                sectors[#sectors + 1] = { type = "Feature",
                                    properties = { name = "SARMAT SECTOR " .. label, side = "all",
                                        color = sectorColor, style = sectorStyle },
                                    geometry = { type = "Polygon", coordinates = { coords } } }
                            end
                        end
                    end
                end
                if #sectors > 0 then
                    drawings[#drawings + 1] = { name = "SARMAT sectors.geojson",
                        geojson = { type = "FeatureCollection", features = sectors } }
                end
                local rings = {}
                local ringLimit = math.max(0, math.min(opt.THREATS, 32 - frontCount - #sectors))
                for _, t in ipairs(lib.enemyThreats(s, ringLimit, opt)) do
                    local lat, lon = lib.latLon(s.env, t.x, t.z)
                    rings[#rings + 1] = { type = "Feature",
                        properties = { name = t.key .. " " .. lib.round(t.range / NM, 0.1) .. "NM",
                            side = "all", color = ringColor, style = ringStyle },
                        geometry = { type = "Polygon",
                            coordinates = { ring(lat, lon, t.range, opt.RING_PTS) } } }
                end
                if #rings > 0 then
                    drawings[#drawings + 1] = { name = "SARMAT threats.geojson",
                        geojson = { type = "FeatureCollection", features = rings } }
                end

                if #routeA == 0 and #routeB == 0 and #routeC == 0 and #drawings == 0
                    and opt.DISPLAYS == nil and opt.MISC == nil then
                    return nil, { routeA = 0, routeB = 0, routeC = 0, threats = 0, front = 0, sectors = 0 }
                end
                local displays = displaysNode(opt.DISPLAYS)
                local misc = miscNode(opt.MISC)
                local doc = {
                    Aircraft = "F15E",
                    Version  = 2,
                    Upload   = { DisplayUploadMode = 1,
                        RouteA = #routeA > 0, RouteB = #routeB > 0, RouteC = #routeC > 0,
                        Radios = false, Displays = displays ~= nil, SmartWeapons = false,
                        Misc = misc ~= nil, Kneeboard = false },
                }
                -- an empty Lua table would be written as {} instead of [], so empty routes are omitted
                if #routeA > 0 then doc.RouteA = { FirstAllowedWaypointNumber = 1, Waypoints = routeA } end
                if #routeB > 0 then doc.RouteB = { FirstAllowedWaypointNumber = 1, Waypoints = routeB } end
                if #routeC > 0 then doc.RouteC = { FirstAllowedWaypointNumber = 1, Waypoints = routeC } end
                if displays then doc.Displays = displays end
                if misc then doc.Misc = misc end
                if #drawings > 0 then doc.drawings = drawings end
                return doc, { routeA = #routeA, routeB = #routeB, routeC = #routeC,
                    threats = #rings, front = frontCount, sectors = #sectors }
            end,
        },
        {
            id     = "f15e-modern",
            format = "json",
            dir    = "ModernF15E\\Cartridges",
            file   = "SARMAT.json",
            -- The tray app reads its own imported copy, not the DCS-DTC preset directly.
            -- Reuse the previous output so both files always contain the same cartridge.
            build  = function(s, lib, opt, built)
                return built["f15e-dtc"]
            end,
        },
    },
}
