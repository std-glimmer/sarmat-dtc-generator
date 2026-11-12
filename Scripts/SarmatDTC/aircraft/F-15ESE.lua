-- F-15E Strike Eagle (DCS type "F-15ESE"): a "DTC for DCS" JSON preset for Haack's F-15E DTC
-- mod, in the format the strike-eagle-dtc tool exports (src/eagle_dtc/dtcfile.py there is the
-- reference): Aircraft "F15E", Version 2, coordinates "N 36°16.819’" (prime = U+2019), feet.
-- The mod looks for F-15E presets in Documents\DCS-DTC\Presets\F15E (the tool's export folder),
-- so the file appears there as the preset "SARMAT".
--
-- What the cartridge holds (DCS has no native DTC editor for the F-15E, there is no "dcs-dtc"
-- output here):
--   Route A  enemy airfields and FARPs/FOBs within ROUTE_A_NM of the front line,
--            closest to the front first (target points)
--   Route B  enemy strongpoints (OP*) and strongholds within ROUTE_B_NM of the front line,
--            ordered east to west (target points)
--   Route C  own airfields and FARPs/FOBs, closest to the front line first (steerpoints)
--   drawings the front line (red solid) and the engagement rings of enemy SAMs (yellow dashed);
--            the mod merges them into the SIT page, it draws at most 32 shapes in total
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

-- Sort by distance to the front line ascending (stable).
local function byFront(lib, s, list)
    return lib.byScore(list, function(p) return lib.distToPolyline(p.x, p.z, s.front) end)
end

-- Sort east to west (DCS z is the east axis), north to south on ties.
local function eastToWest(list)
    local out = {}
    for i, p in ipairs(list) do out[i] = p end
    table.sort(out, function(a, b)
        if a.z ~= b.z then return a.z > b.z end
        return a.x > b.x
    end)
    return out
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
        ROUTE_A_NM  = 50,      -- route A: enemy airfields/FARPs this close to the front [NM]
        ROUTE_B_NM  = 20,      -- route B: enemy strongpoints/strongholds this close to the front [NM]
        TARGETS     = 99,      -- route B: at most this many target points
        MAX_WP      = 99,      -- waypoints per route (the jet's route holds 99)
        THREATS     = 0,       -- SAM engagement rings drawn on the SIT page. 0 = none: the Modern
                               -- F-15E mod draws its own SAM/EWR rings natively (amber/gray/magenta,
                               -- on SIT and TSD), our GeoJSON rings would overlap them. Set e.g. 24
                               -- only if the native rings are not visible on the server.
        MIN_RANGE   = 6000,    -- [m] see lib.enemyThreats: skip short-range AD
        DEDUP_M     = 5000,    -- one ring per threat type within this distance
        FRONT_PTS   = 30,      -- front line points in the drawing (0 = no line)
        FRONT_COLOR = "#FF0000",
        FRONT_STYLE = "solid", -- solid | dash | dot | dotdash
        RING_PTS    = 24,      -- polygon segments per threat ring
        RING_COLOR  = "#FFFF00",
        RING_STYLE  = "dash",
        -- non-numeric settings from config.user.lua only (see displaysNode/miscNode above):
        -- DISPLAYS = { Pilot = { LeftMPD = { { page = "TSD", mode = "NAV" }, ... } }, WSO = {...} }
        -- MISC = { Bingo = 4000, CARAALOW = 500, TACANChannel = 44, TACANBand = "X",
        --          TACANMode = "TR", TACANOn = true, ILSFrequency = 108.5, TGPCode = 1688 }
    },
    limits = {
        ROUTE_A_NM = { 0 }, ROUTE_B_NM = { 0 }, TARGETS = { 0, 99, int = true },
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

                -- Route A: enemy airfields and FARPs/FOBs near the front, closest first
                local rteASrc = {}
                for _, a in ipairs(s.airfields) do
                    if not a.friendly and nearFront(a, opt.ROUTE_A_NM) then rteASrc[#rteASrc + 1] = a end
                end
                for _, f in ipairs(s.farps) do
                    if not f.friendly and nearFront(f, opt.ROUTE_A_NM) then rteASrc[#rteASrc + 1] = f end
                end
                local routeA = {}
                for _, p in ipairs(byFront(lib, s, rteASrc)) do
                    if #routeA >= opt.MAX_WP then break end
                    routeA[#routeA + 1] = wp(#routeA + 1, p, true)
                end

                -- Route B: enemy strongpoints and strongholds near the front, east to west
                local rteBSrc = {}
                for _, p in ipairs(s.strongpoints) do
                    if not p.friendly and nearFront(p, opt.ROUTE_B_NM) then rteBSrc[#rteBSrc + 1] = p end
                end
                for _, p in ipairs(s.strongholds) do
                    if not p.friendly and nearFront(p, opt.ROUTE_B_NM) then rteBSrc[#rteBSrc + 1] = p end
                end
                local routeB = {}
                local maxTargets = math.min(opt.MAX_WP, opt.TARGETS)
                for _, p in ipairs(eastToWest(rteBSrc)) do
                    if #routeB >= maxTargets then break end
                    routeB[#routeB + 1] = wp(#routeB + 1, p, true)
                end

                -- Route C: own airfields and FARPs/FOBs, closest to the front first
                local rteCSrc = {}
                for _, a in ipairs(s.airfields) do
                    if a.friendly then rteCSrc[#rteCSrc + 1] = a end
                end
                for _, f in ipairs(s.farps) do
                    if f.friendly then rteCSrc[#rteCSrc + 1] = f end
                end
                local routeC = {}
                for _, p in ipairs(byFront(lib, s, rteCSrc)) do
                    if #routeC >= opt.MAX_WP then break end
                    routeC[#routeC + 1] = wp(#routeC + 1, p, false)
                end

                -- Drawings: front line + threat rings (color/style from options)
                local frontColor = cssColor(opt.FRONT_COLOR, "#FF0000")
                local frontStyle = lineStyle(opt.FRONT_STYLE, "solid")
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
                local rings = {}
                for _, t in ipairs(lib.enemyThreats(s, opt.THREATS, opt)) do
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
                    return nil, { routeA = 0, routeB = 0, routeC = 0, threats = 0, front = 0 }
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
                    threats = #rings, front = opt.FRONT_PTS >= 2 and #s.front >= 2 and 1 or 0 }
            end,
        },
    },
}
