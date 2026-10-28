-- SarmatDTC core: builds DTC data tables from SARMAT map data (status.json + units.json).
-- Pure Lua 5.1, no DCS dependencies: terrain access is injected through `env`.
--
-- env = {
--     terrain   = "Syria",                       -- DCS terrain id written into the cartridges
--     getHeight = function(x, z) return m end,   -- optional, terrain elevation [m]
--     toLatLon  = function(x, z) return lat, lon end, -- optional, needed by F-14 lines
-- }
-- Coordinates: SARMAT x/z are DCS map coordinates; DTC files store them as x (north) / y (east).

local M = {}

M.CARTRIDGE_NAME = "SARMAT"

M.LIMITS = {
    CTRLM      = 49,   -- AH-64D Control Measures (C51..C99)
    CTRLM_FARPS = nil, -- nil: FARPs compete with units by distance to front; N: reserve up to N slots for FARPs
    TGT        = 50,   -- AH-64D Targets and Threats (T01..T50)
    AH64_LINES = 15, AH64_LINE_PTS = 4,
    F16_PTS    = 25,   -- GEO LINES steerpoints 31..55
    F18_LINES  = 3,  F18_LINE_PTS  = 7,
    F14_LINES  = 2,  F14_LINE_PTS  = 9, -- F-14 plan holds max 20 points in total
}

local FARP_TWIN_M  = 600    -- the map merges FARPs closer than this into one site
local AD_DEDUP_M   = 2000   -- SAM site from status.json vs. live AD group from units.json

------------------------------------------------------------------------------
-- geometry
------------------------------------------------------------------------------

local function round(v, step)
    step = step or 0.1
    return math.floor(v / step + 0.5) * step
end

local function distSegment(px, pz, ax, az, bx, bz)
    local dx, dz = bx - ax, bz - az
    local len2 = dx * dx + dz * dz
    local t = 0
    if len2 > 0 then
        t = ((px - ax) * dx + (pz - az) * dz) / len2
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local cx, cz = ax + t * dx, az + t * dz
    return math.sqrt((px - cx) ^ 2 + (pz - cz) ^ 2)
end

local function distToPolyline(x, z, line)
    if #line == 0 then return 0 end
    if #line == 1 then return math.sqrt((x - line[1].x) ^ 2 + (z - line[1].z) ^ 2) end
    local best = math.huge
    for i = 1, #line - 1 do
        local d = distSegment(x, z, line[i].x, line[i].z, line[i + 1].x, line[i + 1].z)
        if d < best then best = d end
    end
    return best
end

local function dist(a, b)
    return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
end

-- Reduce a polyline to at most maxPts points, keeping the most significant vertices
-- (top-down Douglas-Peucker driven by point count instead of tolerance).
function M.simplify(line, maxPts)
    local n = #line
    if n <= maxPts then return line end
    local keep = { [1] = true, [n] = true }
    local kept = 2
    while kept < maxPts do
        local bestI, bestD = nil, -1
        local a = 1
        for b = 2, n do
            if keep[b] then
                for i = a + 1, b - 1 do
                    local d = distSegment(line[i].x, line[i].z, line[a].x, line[a].z, line[b].x, line[b].z)
                    if d > bestD then bestD, bestI = d, i end
                end
                a = b
            end
        end
        if not bestI then break end
        keep[bestI] = true
        kept = kept + 1
    end
    local out = {}
    for i = 1, n do
        if keep[i] then out[#out + 1] = line[i] end
    end
    return out
end

-- Split a polyline into chained lines (each next line starts where the previous ended).
function M.chain(line, maxLines, maxPerLine)
    local maxPts = 1 + maxLines * (maxPerLine - 1)
    local pts = M.simplify(line, maxPts)
    local lines = {}
    local i = 1
    while i < #pts and #lines < maxLines do
        local seg = {}
        for j = i, math.min(i + maxPerLine - 1, #pts) do
            seg[#seg + 1] = pts[j]
        end
        lines[#lines + 1] = seg
        i = i + #seg - 1
    end
    return lines
end

------------------------------------------------------------------------------
-- unit classification
------------------------------------------------------------------------------

-- Air defence types, ordered by threat (first match wins for a group).
-- tgt = AH-64D TGT/THRT symbol id (CoreMods/aircraft/AH-64D/DTC/NAV/Points.lua).
local AD_TYPES = {
    { tgt = 12, name = "SA-10",    pat = { "s%-300", "5p85", "64h6", "40b6", "54k6", "sa%-10[^%d]" } },
    { tgt = 13, name = "SA-11",    pat = { "sa%-11[^%d]", "buk", "9a310", "9s18", "9a39" } },
    { tgt = 43, name = "PATRIOT",  pat = { "patriot" } },
    { tgt = 7,  name = "SA-5",     pat = { "s%-200", "sa%-5[^%d]" } },
    { tgt = 4,  name = "SA-2",     pat = { "snr_75", "s_75", "s%-75", "volhov", "sa%-2[^%d]" } },
    { tgt = 24, name = "HAWK",     pat = { "hawk" } },
    { tgt = 8,  name = "SA-6",     pat = { "kub", "sa%-6[^%d]" } },
    { tgt = 5,  name = "SA-3",     pat = { "s%-125", "5p73", "sa%-3[^%d]" } },
    { tgt = 2,  name = "NASAMS",   pat = { "nasams" } },
    { tgt = 17, name = "SA-15",    pat = { " tor ", "9a331", "sa%-15[^%d]" } },
    { tgt = 35, name = "PANTSIR",  pat = { "pantsir", "panzir", "96k6" } },
    { tgt = 20, name = "SA-19",    pat = { "tunguska", "2s6", "sa%-19[^%d]" } },
    { tgt = 25, name = "ROLAND",   pat = { "roland" } },
    { tgt = 10, name = "SA-8",     pat = { "osa ", "9a33 ", "sa%-8[^%d]" } },
    { tgt = 29, name = "RAPIER",   pat = { "rapier" } },
    { tgt = 28, name = "HQ-7",     pat = { "hq%-7" } },
    { tgt = 15, name = "SA-13",    pat = { "strela%-10", "sa%-13[^%d]" } },
    { tgt = 46, name = "CHAPARRAL",pat = { "chaparral", "m48 " } },
    { tgt = 11, name = "SA-9",     pat = { "strela%-1 ", "9p31", "sa%-9[^%d]" } },
    { tgt = 44, name = "STINGER",  pat = { "avenger", "m1097", "linebacker", "m6 ", "stinger" } },
    { tgt = 18, name = "MANPADS",  pat = { "igla", "sa%-18", "sa%-24", "manpad" } },
    { tgt = 21, name = "ZSU-23-4", pat = { "shilka", "zsu%-23%-4" } },
    { tgt = 56, name = "GEPARD",   pat = { "gepard" } },
    { tgt = 57, name = "VULCAN",   pat = { "vulcan" } },
    { tgt = 31, name = "ZSU-57",   pat = { "zsu%-?57", "zsu_57" } },
    { tgt = 30, name = "ZU-23",    pat = { "zu%-23" } },
    { tgt = 26, name = "AAA",      pat = { "c%-ram", "phalanx", "flak", "bofors", "s%-60", "ks%-19", "aaa" } },
    { tgt = 32, name = "RADAR",    pat = { "ewr", "1l13", "55g6", "dog ear", "p%-19", "fps%-117", "radar" } },
}
local GENERIC_AD = { tgt = 2, name = "SAM" }   -- GU (Generic Air Defense Unit)

-- Ground unit classes for Control Measures; ids = {friendly, enemy}.
local GROUND_CLASSES = {
    { key = "armor", ids = { 14, 34 }, pat = { "t%-%d%d", "t90", "abrams", "m%-1 ", "leopard", "challenger",
        "leclerc", "merkava", "pt_76", "m%-60", "chieftain", "zbd", "ztz", "tank" } },
    { key = "mech",  ids = { 29, 43 }, pat = { "bmp", "bmd", "btr", "bradley", "m%-2 ", "marder", "lav",
        "stryker", "m%-113", "mtlb", "brdm", "cobra", "aav", "warrior", "mcv", "zbl", "bdrm", "ifv", "apc" } },
    { key = "arty",  ids = { 23, 39 }, pat = { "msta", "sau ", "2s1", "2s3", "2s9", "2s19", "m%-109", "paladin",
        "grad", "uragan", "smerch", "mlrs", "himars", "bm%-", "mortar", "m777", "2a18", "b8m1", "howitzer" } },
    { key = "inf",   ids = { 22, 41 }, pat = { "infantry", "soldier", "paratrooper", "insurgent" } },
}
local GENERIC_IDS = { 24, 46 }         -- FU / EU
local FRIENDLY_AD_ID = 12              -- CTRLM "AD (Friendly Air Defense)"
local FARP_ID = 68                     -- CTRLM "FC (FARP, Fuel and Ammo)"
local CLASS_NAMES = { armor = "ARMOR", mech = "MECH", arty = "ARTY", inf = "INF", generic = "UNIT" }

local function norm(s)
    return " " .. string.lower(tostring(s or "")) .. " "
end

local function matchAny(s, pats)
    for _, p in ipairs(pats) do
        if string.find(s, p) then return true end
    end
    return false
end

-- Returns AD_TYPES entry for the most dangerous air defence member, or nil.
function M.adTypeOf(types)
    local normed = {}
    for i, t in ipairs(types) do normed[i] = norm(t) end
    for _, ad in ipairs(AD_TYPES) do
        for _, s in ipairs(normed) do
            if matchAny(s, ad.pat) then return ad end
        end
    end
    return nil
end

-- Returns class key ("armor", "mech", "arty", "inf" or "generic") by member majority.
function M.groundClassOf(types)
    local counts, bestKey, bestN = {}, "generic", 0
    for _, t in ipairs(types) do
        local s = norm(t)
        for _, c in ipairs(GROUND_CLASSES) do
            if matchAny(s, c.pat) then
                counts[c.key] = (counts[c.key] or 0) + 1
                break
            end
        end
    end
    for _, c in ipairs(GROUND_CLASSES) do   -- ties resolved by table order
        local n = counts[c.key] or 0
        if n > bestN then bestKey, bestN = c.key, n end
    end
    return bestKey
end

local function groundIdOf(key, friendly)
    local idx = friendly and 1 or 2
    for _, c in ipairs(GROUND_CLASSES) do
        if c.key == key then return c.ids[idx] end
    end
    return GENERIC_IDS[idx]
end

local function asciiUpper(s, maxLen)
    s = string.upper(string.gsub(tostring(s or ""), "[^%w%s%-%._/()+]", ""))
    s = string.gsub(s, "%s+", " ")
    if maxLen and #s > maxLen then s = string.sub(s, 1, maxLen) end
    return s
end

------------------------------------------------------------------------------
-- candidate collection
------------------------------------------------------------------------------

local function sideKey(s)
    s = string.lower(tostring(s or ""))
    if s == "red" or s == "blue" then return s end
    return nil
end

local function collect(status, units, mySide)
    local front = {}
    for _, p in ipairs(status.front or {}) do
        if p.x and p.z then front[#front + 1] = { x = p.x, z = p.z } end
    end

    local ctrlm, tgt = {}, {}
    local enemyAD = {}

    -- live ground groups
    for _, g in ipairs(units and units.groups or {}) do
        local side = sideKey(g.side)
        if g.cat == "ground" and side and g.x and g.z then
            local types = g.types or { g.type }
            if #types == 0 then types = { g.type } end
            local friendly = side == mySide
            local ad = M.adTypeOf(types)
            local count = g.count or #types
            local adNote = ad and (ad.name .. ((M.adTypeOf({ g.type }) == ad) and "" or (" + " .. (g.type or "")))
                .. " X" .. count)
            if ad and not friendly then
                enemyAD[#enemyAD + 1] = { x = g.x, z = g.z, ad = ad, note = asciiUpper(adNote, 40) }
            elseif ad then
                ctrlm[#ctrlm + 1] = { x = g.x, z = g.z, id = FRIENDLY_AD_ID, note = asciiUpper("OWN AD " .. adNote, 40) }
            else
                local cls = M.groundClassOf(types)
                ctrlm[#ctrlm + 1] = { x = g.x, z = g.z, id = groundIdOf(cls, friendly),
                    note = asciiUpper((friendly and "OWN " or "ENEMY ") .. CLASS_NAMES[cls] .. " "
                        .. (g.type or "") .. " X" .. count, 40) }
            end
        end
    end

    -- SAM sites from status.json (may be despawned while nobody is near, still a threat)
    for _, o in ipairs(status.strong or {}) do
        local side = sideKey(o.side)
        if (o.kind == "SAM" or o.kind == "Sam") and side and side ~= mySide and not o.dead and o.x and o.z then
            local covered = false
            for _, a in ipairs(enemyAD) do
                if dist(a, o) < AD_DEDUP_M then covered = true break end
            end
            if not covered then
                local ad = M.adTypeOf({ o.name or "" }) or GENERIC_AD
                enemyAD[#enemyAD + 1] = { x = o.x, z = o.z, ad = ad,
                    note = asciiUpper(ad.name .. " SITE " .. string.gsub(o.name or "", "^SAM%s*", ""), 40) }
            end
        end
    end
    for _, a in ipairs(enemyAD) do
        tgt[#tgt + 1] = { x = a.x, z = a.z, id = a.ad.tgt, note = a.note }
    end

    -- FARPs (and FOBs), merging twin pads like the map does
    local farps = {}
    for _, o in ipairs(status.objectives or {}) do
        local owner = sideKey(o.owner)
        if (o.kind == "FARP" or o.kind == "FOB") and owner and o.x and o.z then
            local twin = false
            for _, f in ipairs(farps) do
                if f.owner == owner and dist(f, o) <= FARP_TWIN_M then twin = true break end
            end
            if not twin then
                local name = tostring(o.name or "")
                if o.kind == "FARP" then name = "FARP " .. name end
                farps[#farps + 1] = { x = o.x, z = o.z, owner = owner, name = name }
            end
        end
    end
    for _, f in ipairs(farps) do
        local friendly = f.owner == mySide
        ctrlm[#ctrlm + 1] = { x = f.x, z = f.z, id = FARP_ID, farp = true, friendly = friendly,
            note = asciiUpper(f.name .. (friendly and " OWN" or " ENEMY"), 40) }
    end

    return front, ctrlm, tgt
end

local function byFront(list, front, limit)
    for _, p in ipairs(list) do
        p.d = distToPolyline(p.x, p.z, front)
    end
    table.sort(list, function(a, b) return a.d < b.d end)
    local out = {}
    for i = 1, math.min(limit, #list) do out[i] = list[i] end
    return out
end

------------------------------------------------------------------------------
-- cartridges
------------------------------------------------------------------------------

local function elevation(env, x, z)
    if env.getHeight then
        local ok, h = pcall(env.getHeight, x, z)
        if ok and type(h) == "number" then return math.floor(h + 0.5) end
    end
    return 0
end

local function buildAH64(env, front, ctrlm, tgt)
    local L = M.LIMITS
    local ctrlmPts, tgtPts = {}, {}
    local farpOwn, farpEnemy = 0, 0
    local selected
    if L.CTRLM_FARPS then
        local farps, others = {}, {}
        for _, p in ipairs(ctrlm) do
            if p.farp then farps[#farps + 1] = p else others[#others + 1] = p end
        end
        selected = byFront(farps, front, math.min(L.CTRLM_FARPS, L.CTRLM))
        for _, p in ipairs(byFront(others, front, L.CTRLM - #selected)) do selected[#selected + 1] = p end
        selected = byFront(selected, front, L.CTRLM)
    else
        selected = byFront(ctrlm, front, L.CTRLM)
    end
    for i, p in ipairs(selected) do
        local num = 50 + i
        local text = "C" .. num
        if p.farp then
            if p.friendly then farpOwn = farpOwn + 1; text = string.format("F%02d", farpOwn)
            else farpEnemy = farpEnemy + 1; text = string.format("E%02d", farpEnemy) end
        end
        ctrlmPts[i] = { alt = elevation(env, p.x, p.z), id = p.id, note = p.note, num = num, text = text,
            x = round(p.x), y = round(p.z) }
    end
    for i, p in ipairs(byFront(tgt, front, L.TGT)) do
        tgtPts[i] = { alt = elevation(env, p.x, p.z), id = p.id, note = p.note, num = i,
            text = string.format("T%02d", i), x = round(p.x), y = round(p.z) }
    end

    local lines = {}
    if #front >= 2 then
        for _, seg in ipairs(M.chain(front, L.AH64_LINES, L.AH64_LINE_PTS)) do
            local vertices = {}
            for j, p in ipairs(seg) do vertices[j] = { x = round(p.x), y = round(p.z) } end
            lines[#lines + 1] = { note = "FRONT", text = "", type_num = 4, vertices = vertices } -- 4 = FLOT
        end
    end

    return {
        type = "AH-64D_BLK_II",
        name = M.CARTRIDGE_NAME,
        terrain = env.terrain,
        NAV = {
            MissionFile = 1,
            Mission_1 = {
                Points = {
                    WPTHZ = { isEnabled = false, POINTS = {} },
                    CTRLM = { isEnabled = true, POINTS = ctrlmPts },
                    TGT   = { isEnabled = true, POINTS = tgtPts },
                },
                Lines = lines,
            },
        },
    }, { ctrlm = #ctrlmPts, tgt = #tgtPts, lines = #lines }
end

local function buildF16(env, front)
    local pts = {}
    if #front >= 2 then
        for i, p in ipairs(M.simplify(front, M.LIMITS.F16_PTS)) do
            pts[i] = { alt = elevation(env, p.x, p.z), id = "GEO_LINES" .. (30 + i), number = i,
                L1 = true, L2 = false, L3 = false, L4 = false, note = "FRONT", x = round(p.x), y = round(p.z) }
        end
    end
    return {
        type = "F-16C_50",
        name = M.CARTRIDGE_NAME,
        terrain = env.terrain,
        MPD = { terrain = env.terrain, mirror_GEO_LINES = false, GEO_LINES = pts },
    }, { points = #pts }
end

local function buildF18(env, front)
    local L = M.LIMITS
    local flot = {}
    if #front >= 2 then
        for n, seg in ipairs(M.chain(front, L.F18_LINES, L.F18_LINE_PTS)) do
            local points = {}
            for j, p in ipairs(seg) do
                points[j] = { id = "FLOT_" .. n .. "_PT_" .. j, x = round(p.x), y = round(p.z) }
            end
            flot[n] = { id = "FLOT_" .. n, note = "FRONT", num = n, points = points }
        end
    end
    return {
        type = "FA-18C_hornet",
        name = M.CARTRIDGE_NAME,
        terrain = env.terrain,
        SA = { FAOR_FLOT = { FAOR = {}, FLOT = flot }, mirror_MEZ_THRTS = true },
    }, { lines = #flot }
end

local function buildF14(env, front)
    local L = M.LIMITS
    local lines = {}
    if #front >= 2 then
        for _, seg in ipairs(M.chain(front, L.F14_LINES, L.F14_LINE_PTS)) do
            local points = {}
            for j, p in ipairs(seg) do
                local lat, lon = 0, 0
                if env.toLatLon then
                    local ok, a, b = pcall(env.toLatLon, p.x, p.z)
                    if ok and a then lat, lon = a, b end
                end
                points[j] = { elev = elevation(env, p.x, p.z), lat = lat, lon = lon, x = round(p.x), y = round(p.z) }
            end
            lines[#lines + 1] = { closed = false, points = points }
        end
    end
    return {
        type = "F-14BU",
        name = M.CARTRIDGE_NAME,
        cartridge_name = M.CARTRIDGE_NAME,
        terrain = env.terrain,
        NAV = { { name = "FRONT", waypoints = {}, lines = lines, additional_points = {}, route_as_line = false } },
    }, { lines = #lines }
end

-- Returns list of { type = <unit type>, data = <cartridge data table>, stats = {...} }.
function M.build(status, units, mySide, env)
    mySide = sideKey(mySide) or "blue"
    local front, ctrlm, tgt = collect(status or {}, units or {}, mySide)
    local out = {}
    local function add(fn, ...)
        local data, stats = fn(env, ...)
        out[#out + 1] = { type = data.type, data = data, stats = stats }
    end
    add(buildAH64, front, ctrlm, tgt)
    add(buildF16, front)
    add(buildF18, front)
    add(buildF14, front)
    return out
end

return M
