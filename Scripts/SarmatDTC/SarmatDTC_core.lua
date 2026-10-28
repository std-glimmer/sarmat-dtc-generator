-- SarmatDTC core: turns SARMAT map data (status.json + units.json) into an aircraft-neutral
-- "situation" and runs the aircraft modules (Scripts/SarmatDTC/aircraft/*.lua) over it.
-- Pure Lua 5.1, no DCS dependencies: terrain access is injected through `env`.
--
-- env = {
--     terrain   = "Syria",                            -- DCS terrain id written into the cartridges
--     getHeight = function(x, z) return m end,        -- optional, terrain elevation [m]
--     toLatLon  = function(x, z) return lat, lon end, -- optional
-- }
-- Coordinates: SARMAT x/z are DCS map coordinates; DTC files store them as x (north) / y (east).
--
-- Aircraft module (aircraft/<type>.lua) returns:
-- {
--     type    = "F-16C_50",               -- DTC unit type, also the output file name SARMAT_<type>.dtc
--     options = { POINTS = 25, ... },     -- defaults, overridable per type from CONFIG.AIRCRAFT
--     build   = function(situation, lib, options) return data, stats end,
-- }
-- `data` is the cartridge "data" table, `stats` a flat {name = number} table for the log.

local M = {}

M.CARTRIDGE_NAME = "SARMAT"

local FARP_TWIN_M  = 600    -- the map merges FARPs closer than this into one site
local AD_DEDUP_M   = 2000   -- SAM site from status.json vs. live AD group from units.json

------------------------------------------------------------------------------
-- geometry
------------------------------------------------------------------------------

function M.round(v, step)
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

function M.distToPolyline(x, z, line)
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

-- Copy of `list` sorted by distance to the front line, cut to `limit` items.
function M.byFront(list, front, limit)
    local sorted = {}
    for i, p in ipairs(list) do
        sorted[i] = { d = M.distToPolyline(p.x, p.z, front), p = p }
    end
    table.sort(sorted, function(a, b) return a.d < b.d end)
    local out = {}
    for i = 1, math.min(limit or #sorted, #sorted) do out[i] = sorted[i].p end
    return out
end

------------------------------------------------------------------------------
-- terrain helpers for modules
------------------------------------------------------------------------------

function M.elevation(env, x, z)
    if env.getHeight then
        local ok, h = pcall(env.getHeight, x, z)
        if ok and type(h) == "number" then return math.floor(h + 0.5) end
    end
    return 0
end

function M.latLon(env, x, z)
    if env.toLatLon then
        local ok, lat, lon = pcall(env.toLatLon, x, z)
        if ok and lat then return lat, lon end
    end
    return 0, 0
end

-- Common cartridge header: { type, name, terrain }.
function M.cartridge(unitType, env)
    return { type = unitType, name = M.CARTRIDGE_NAME, terrain = env.terrain }
end

function M.asciiUpper(s, maxLen)
    s = string.upper(string.gsub(tostring(s or ""), "[^%w%s%-%._/()+]", ""))
    s = string.gsub(s, "%s+", " ")
    if maxLen and #s > maxLen then s = string.sub(s, 1, maxLen) end
    return s
end

------------------------------------------------------------------------------
-- unit classification
------------------------------------------------------------------------------

-- Air defence types, ordered by threat (first match wins for a group). `key` is what aircraft
-- modules map to their own threat symbols.
M.AD_TYPES = {
    { key = "SA-10",     pat = { "s%-300", "5p85", "64h6", "40b6", "54k6", "sa%-10[^%d]" } },
    { key = "SA-11",     pat = { "sa%-11[^%d]", "buk", "9a310", "9s18", "9a39" } },
    { key = "PATRIOT",   pat = { "patriot" } },
    { key = "SA-5",      pat = { "s%-200", "sa%-5[^%d]" } },
    { key = "SA-2",      pat = { "snr_75", "s_75", "s%-75", "volhov", "sa%-2[^%d]" } },
    { key = "HAWK",      pat = { "hawk" } },
    { key = "SA-6",      pat = { "kub", "sa%-6[^%d]" } },
    { key = "SA-3",      pat = { "s%-125", "5p73", "sa%-3[^%d]" } },
    { key = "NASAMS",    pat = { "nasams" } },
    { key = "SA-15",     pat = { " tor ", "9a331", "sa%-15[^%d]" } },
    { key = "PANTSIR",   pat = { "pantsir", "panzir", "96k6" } },
    { key = "SA-19",     pat = { "tunguska", "2s6", "sa%-19[^%d]" } },
    { key = "ROLAND",    pat = { "roland" } },
    { key = "SA-8",      pat = { "osa ", "9a33 ", "sa%-8[^%d]" } },
    { key = "RAPIER",    pat = { "rapier" } },
    { key = "HQ-7",      pat = { "hq%-7" } },
    { key = "SA-13",     pat = { "strela%-10", "sa%-13[^%d]" } },
    { key = "CHAPARRAL", pat = { "chaparral", "m48 " } },
    { key = "SA-9",      pat = { "strela%-1 ", "9p31", "sa%-9[^%d]" } },
    { key = "STINGER",   pat = { "avenger", "m1097", "linebacker", "m6 ", "stinger" } },
    { key = "MANPADS",   pat = { "igla", "sa%-18", "sa%-24", "manpad" } },
    { key = "ZSU-23-4",  pat = { "shilka", "zsu%-23%-4" } },
    { key = "GEPARD",    pat = { "gepard" } },
    { key = "VULCAN",    pat = { "vulcan" } },
    { key = "ZSU-57",    pat = { "zsu%-?57", "zsu_57" } },
    { key = "ZU-23",     pat = { "zu%-23" } },
    { key = "AAA",       pat = { "c%-ram", "phalanx", "flak", "bofors", "s%-60", "ks%-19", "aaa" } },
    { key = "RADAR",     pat = { "ewr", "1l13", "55g6", "dog ear", "p%-19", "fps%-117", "radar" } },
}
M.GENERIC_AD = "SAM"   -- SAM site whose type could not be recognised

-- Ground unit classes (ties resolved by table order).
M.GROUND_CLASSES = {
    { key = "armor", pat = { "t%-%d%d", "t90", "abrams", "m%-1 ", "leopard", "challenger",
        "leclerc", "merkava", "pt_76", "m%-60", "chieftain", "zbd", "ztz", "tank" } },
    { key = "mech",  pat = { "bmp", "bmd", "btr", "bradley", "m%-2 ", "marder", "lav",
        "stryker", "m%-113", "mtlb", "brdm", "cobra", "aav", "warrior", "mcv", "zbl", "bdrm", "ifv", "apc" } },
    { key = "arty",  pat = { "msta", "sau ", "2s1", "2s3", "2s9", "2s19", "m%-109", "paladin",
        "grad", "uragan", "smerch", "mlrs", "himars", "bm%-", "mortar", "m777", "2a18", "b8m1", "howitzer" } },
    { key = "inf",   pat = { "infantry", "soldier", "paratrooper", "insurgent" } },
}
M.GENERIC_CLASS = "generic"

local function norm(s)
    return " " .. string.lower(tostring(s or "")) .. " "
end

local function matchAny(s, pats)
    for _, p in ipairs(pats) do
        if string.find(s, p) then return true end
    end
    return false
end

-- Key of the most dangerous air defence type among `types`, or nil.
function M.adTypeOf(types)
    local normed = {}
    for i, t in ipairs(types) do normed[i] = norm(t) end
    for _, ad in ipairs(M.AD_TYPES) do
        for _, s in ipairs(normed) do
            if matchAny(s, ad.pat) then return ad.key end
        end
    end
    return nil
end

-- Class key ("armor", "mech", "arty", "inf" or "generic") by member majority.
function M.groundClassOf(types)
    local counts, bestKey, bestN = {}, M.GENERIC_CLASS, 0
    for _, t in ipairs(types) do
        local s = norm(t)
        for _, c in ipairs(M.GROUND_CLASSES) do
            if matchAny(s, c.pat) then
                counts[c.key] = (counts[c.key] or 0) + 1
                break
            end
        end
    end
    for _, c in ipairs(M.GROUND_CLASSES) do
        local n = counts[c.key] or 0
        if n > bestN then bestKey, bestN = c.key, n end
    end
    return bestKey
end

------------------------------------------------------------------------------
-- situation
------------------------------------------------------------------------------

local function sideKey(s)
    s = string.lower(tostring(s or ""))
    if s == "red" or s == "blue" then return s end
    return nil
end

-- situation = {
--     side   = "blue",
--     front  = { {x, z}, ... },                     -- front line polyline
--     groups = { {x, z, friendly, type, count, class, ad, adLead}, ... }
--              -- live ground groups; ad = AD key if any member is air defence,
--              -- adLead = the lead unit itself is that AD type
--     sites  = { {x, z, friendly, ad, name}, ... }  -- SAM sites not covered by a live AD group
--     farps  = { {x, z, friendly, name, kind}, ... } -- FARPs and FOBs, twin pads merged
--     env    = env                                  -- set by M.build, for lib.elevation/latLon/cartridge
-- }
function M.situation(status, units, mySide)
    status, units = status or {}, units or {}
    mySide = sideKey(mySide) or "blue"
    local s = { side = mySide, front = {}, groups = {}, sites = {}, farps = {} }

    for _, p in ipairs(status.front or {}) do
        if p.x and p.z then s.front[#s.front + 1] = { x = p.x, z = p.z } end
    end

    for _, g in ipairs(units.groups or {}) do
        local side = sideKey(g.side)
        if g.cat == "ground" and side and g.x and g.z then
            local types = g.types or {}
            if #types == 0 then types = { g.type } end
            local ad = M.adTypeOf(types)
            s.groups[#s.groups + 1] = {
                x = g.x, z = g.z, friendly = side == mySide,
                type = g.type or "", count = g.count or #types,
                class = M.groundClassOf(types), ad = ad,
                adLead = ad ~= nil and M.adTypeOf({ g.type }) == ad,
            }
        end
    end

    -- SAM sites (may be despawned while nobody is near, still a threat)
    for _, o in ipairs(status.strong or {}) do
        local side = sideKey(o.side)
        if (o.kind == "SAM" or o.kind == "Sam") and side and not o.dead and o.x and o.z then
            local friendly = side == mySide
            local covered = false
            for _, g in ipairs(s.groups) do
                if g.ad and g.friendly == friendly and dist(g, o) < AD_DEDUP_M then covered = true break end
            end
            if not covered then
                s.sites[#s.sites + 1] = { x = o.x, z = o.z, friendly = friendly,
                    ad = M.adTypeOf({ o.name or "" }) or M.GENERIC_AD,
                    name = (string.gsub(o.name or "", "^SAM%s*", "")) }
            end
        end
    end

    for _, o in ipairs(status.objectives or {}) do
        local owner = sideKey(o.owner)
        if (o.kind == "FARP" or o.kind == "FOB") and owner and o.x and o.z then
            local friendly = owner == mySide
            local twin = false
            for _, f in ipairs(s.farps) do
                if f.friendly == friendly and dist(f, o) <= FARP_TWIN_M then twin = true break end
            end
            if not twin then
                local name = tostring(o.name or "")
                if o.kind == "FARP" then name = "FARP " .. name end
                s.farps[#s.farps + 1] = { x = o.x, z = o.z, friendly = friendly, name = name, kind = o.kind }
            end
        end
    end

    return s
end

------------------------------------------------------------------------------
-- aircraft modules
------------------------------------------------------------------------------

local function merge(defaults, overrides)
    local out = {}
    for k, v in pairs(defaults or {}) do out[k] = v end
    for k, v in pairs(overrides or {}) do out[k] = v end
    return out
end

-- Loads aircraft modules from `dir` (with trailing separator); `files` = list of file names.
-- Files starting with "_" (templates) are skipped. Returns modules sorted by file name, errors.
function M.loadAircraft(dir, files)
    local names, modules, errors = {}, {}, {}
    for _, f in ipairs(files) do
        if string.match(f, "%.lua$") and not string.match(f, "^_") then names[#names + 1] = f end
    end
    table.sort(names)
    for _, f in ipairs(names) do
        local ok, mod = pcall(dofile, dir .. f)
        if ok and type(mod) == "table" and type(mod.type) == "string" and type(mod.build) == "function" then
            modules[#modules + 1] = mod
        else
            errors[#errors + 1] = f .. ": " .. (ok and "must return { type = ..., build = function }" or tostring(mod))
        end
    end
    return modules, errors
end

-- Runs every module over the situation. `overrides[type]` merges into module options;
-- `enabled = false` there skips the module. A failing module does not stop the others.
-- Returns list of { type, data, stats }, list of error strings.
function M.build(status, units, mySide, env, modules, overrides)
    local situation = M.situation(status, units, mySide)
    situation.env = env
    local out, errors = {}, {}
    for _, mod in ipairs(modules) do
        local opt = merge(mod.options, overrides and overrides[mod.type])
        if opt.enabled ~= false then
            local ok, data, stats = pcall(mod.build, situation, M, opt)
            if ok and type(data) == "table" then
                data.type = mod.type
                out[#out + 1] = { type = mod.type, data = data, stats = stats or {} }
            else
                errors[#errors + 1] = mod.type .. ": " .. tostring(data)
            end
        end
    end
    return out, errors
end

return M
