-- SarmatDTC core: turns SARMAT map data (status.json + units.json) into an aircraft-neutral
-- "situation" and runs the aircraft modules (Scripts/SarmatDTC/aircraft/*.lua) over it.
-- Pure Lua 5.1, no DCS dependencies: terrain access is injected through `env`.
--
-- env = {
--     terrain   = "Syria",                            -- DCS terrain id written into the cartridges
--     getHeight = function(x, z) return m end,        -- optional, terrain elevation [m]
--     toLatLon  = function(x, z) return lat, lon end, -- optional
--     spawn     = { x, z, name },                     -- optional, own slot's start base
-- }
-- Coordinates: SARMAT x/z are DCS map coordinates; DTC files store them as x (north) / y (east).
--
-- Aircraft modules (aircraft/<type>.lua): the module API (fields, situation, lib, outputs,
-- variants, limits) is described in aircraft/_template.lua. This file loads the modules
-- (M.loadAircraft), merges their options (module -> variant -> config.lua, then `limits`),
-- builds the native cartridge (output "dcs-dtc", always first) and the extra outputs (M.build)
-- and lays the native one over the base DTC (M.applyBase).

local M = {}

M.CARTRIDGE_NAME = "SARMAT"
M.FILE_PREFIX = "SARMAT_"
M.NATIVE_OUTPUT = "dcs-dtc"

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

-- Copy of `list` sorted by score(p) ascending (lower = more important), cut to `limit` items.
-- Equal scores keep the input order.
function M.byScore(list, score, limit)
    local sorted = {}
    for i, p in ipairs(list) do
        sorted[i] = { s = score(p), i = i, p = p }
    end
    table.sort(sorted, function(a, b)
        if a.s ~= b.s then return a.s < b.s end
        return a.i < b.i
    end)
    local out = {}
    for i = 1, math.min(limit or #sorted, #sorted) do out[i] = sorted[i].p end
    return out
end

-- Copy of `list` sorted by distance to the front line, cut to `limit` items.
function M.byFront(list, front, limit)
    return M.byScore(list, function(p) return M.distToPolyline(p.x, p.z, front) end, limit)
end

M.dist = dist

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

-- Serializes a value as Lua source ("return { ... }" with format "lua"); keys sorted for stable output.
function M.toLua(value, indent)
    indent = indent or ""
    local t = type(value)
    if t == "string" then return string.format("%q", value) end
    if t == "number" then
        if value ~= value then return "0/0" end                  -- NaN and infinities as Lua expressions
        if value == math.huge then return "1/0" elseif value == -math.huge then return "-1/0" end
        return tostring(value)
    end
    if t == "boolean" or t == "nil" then return tostring(value) end
    if t ~= "table" then error("cannot serialize " .. t) end
    local inner = indent .. "    "
    local parts = {}
    local n = #value
    for i = 1, n do parts[#parts + 1] = inner .. M.toLua(value[i], inner) end
    local keys = {}
    for k in pairs(value) do
        if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        local key = (type(k) == "string" and string.match(k, "^[%a_][%w_]*$")) and k
            or ("[" .. M.toLua(k) .. "]")
        parts[#parts + 1] = inner .. key .. " = " .. M.toLua(value[k], inner)
    end
    if #parts == 0 then return "{}" end
    return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. indent .. "}"
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
-- threat catalogue (ED names shared by the F-16 THREAT_PTS and F/A-18 MEZ_THRTS editors,
-- CoreMods/aircraft/{F-16C/DTC/MPD/THREAT_PTS_defs,FA-18C/DTC/SA/MEZ_THRTS_defs}.lua)
------------------------------------------------------------------------------

-- AD key -> { name = ED threat name ("Custom" if ED has none), text (<= 3 chars), range [m], alt [m] }
M.THREAT_DEFS = {
    ["SA-10"]    = { name = "SAM SA-10 'Grumble'",  text = "10", range = 120000, alt = 27000 },
    ["SA-11"]    = { name = "SAM SA-11 'Gadfly'",   text = "11", range = 50000,  alt = 22000 },
    PATRIOT      = { name = "SAM Patriot",          text = "P",  range = 100000, alt = 160000 },
    ["SA-5"]     = { name = "SAM SA-5 'Gammon'",    text = "5",  range = 255000, alt = 40000 },
    ["SA-2"]     = { name = "SAM SA-2 'Guideline'", text = "2",  range = 43000,  alt = 25000 },
    HAWK         = { name = "SAM Hawk",             text = "HK", range = 45000,  alt = 20000 },
    ["SA-6"]     = { name = "SAM SA-6 'Gainful'",   text = "6",  range = 25000,  alt = 14000 },
    ["SA-3"]     = { name = "SAM SA-3 'Goa'",       text = "3",  range = 18000,  alt = 20000 },
    NASAMS       = { name = "SAM NASAMS",           text = "NS", range = 15000,  alt = 17000 },
    ["SA-15"]    = { name = "SAM SA-15 'Gauntlet'", text = "15", range = 12000,  alt = 8000 },
    PANTSIR      = { name = "SAM SA-22 'Greyhound'", text = "22", range = 20000, alt = 15000 },
    ["SA-19"]    = { name = "SAM SA-19 'Grison'",   text = "19", range = 8000,   alt = 3500 },
    ROLAND       = { name = "SAM Roland",           text = "RO", range = 8000,   alt = 6000 },
    ["SA-8"]     = { name = "SAM SA-8 'Gecko'",     text = "8",  range = 10300,  alt = 5000 },
    RAPIER       = { name = "SAM Rapier",           text = "RP", range = 6800,   alt = 4000 },
    ["HQ-7"]     = { name = "SAM HQ-7",             text = "7",  range = 15000,  alt = 5500 },
    ["SA-13"]    = { name = "SAM SA-13 'Gopher'",   text = "13", range = 5000,   alt = 3500 },
    CHAPARRAL    = { name = "SAM Chaparrel",        text = "CH", range = 8500,   alt = 10000 },
    ["SA-9"]     = { name = "SAM SA-9 'Gaskin'",    text = "9",  range = 4200,   alt = 5000 },
    STINGER      = { name = "SAM Avenger",          text = "AV", range = 4500,   alt = 5200 },
    MANPADS      = { name = "Custom",               text = "MP", range = 5000,   alt = 3500 },
    ["ZSU-23-4"] = { name = "SPAAA ZSU-23-4",       text = "A",  range = 2500,   alt = 2500 },
    GEPARD       = { name = "SPAAA Gepard",         text = "A",  range = 4000,   alt = 3000 },
    VULCAN       = { name = "SPAAA Vulcan",         text = "A",  range = 2000,   alt = 5000 },
    ["ZSU-57"]   = { name = "SPAAA ZSU-57-2",       text = "A",  range = 7000,   alt = 7000 },
    ["ZU-23"]    = { name = "Custom",               text = "ZU", range = 2500,   alt = 2500 },
    AAA          = { name = "Custom",               text = "A",  range = 2500,   alt = 2500 },
    SAM          = { name = "Custom",               text = "SAM", range = 15000, alt = 9144 },  -- unrecognised site
    -- RADAR has no entry: radars are not threat rings
}

-- Enemy air defence as threat rings: live AD groups + SAM sites, without radars and threats
-- shorter than opt.MIN_RANGE, one ring per type within opt.DEDUP_M. Ordered by how far the ring
-- edge is from the front (rings reaching over the front first), cut to `limit`.
-- Returns { {x, z, key, name, text, range, alt}, ... }.
function M.enemyThreats(s, limit, opt)
    opt = opt or {}
    local minRange, dedup = opt.MIN_RANGE or 0, opt.DEDUP_M or 5000
    local candidates = {}
    local function add(p, key)
        local def = M.THREAT_DEFS[key]
        if def and def.range >= minRange then
            candidates[#candidates + 1] = { x = p.x, z = p.z, key = key, name = def.name, text = def.text,
                range = def.range, alt = def.alt }
        end
    end
    for _, g in ipairs(s.groups) do
        if g.ad and not g.friendly then add(g, g.ad) end
    end
    for _, site in ipairs(s.sites) do
        if not site.friendly then add(site, site.ad) end
    end
    local sorted = M.byScore(candidates, function(t)
        return M.distToPolyline(t.x, t.z, s.front) - t.range
    end)
    local out = {}
    for _, t in ipairs(sorted) do
        if #out >= limit then break end
        local dup = false
        for _, o in ipairs(out) do
            if o.key == t.key and dist(o, t) < dedup then dup = true break end
        end
        if not dup then out[#out + 1] = t end
    end
    return out
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
--     spawn  = { x, z, name } | nil                 -- own start base (env.spawn), set by M.build
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

-- Checks `opt` against module limits { NAME = { min, max, int = true } } (min/max may be nil):
-- numbers are rounded (int) and clamped, a non-number is replaced by defaults[NAME]; nil is left.
-- Fixes `opt` in place and returns the list of warnings.
local function applyLimits(opt, limits, defaults)
    local warnings = {}
    for k, lim in pairs(limits or {}) do
        local v = opt[k]
        if v ~= nil then
            local fixed = v
            if type(v) ~= "number" or v ~= v then
                fixed = defaults[k]
            else
                if lim.int then fixed = math.floor(fixed + 0.5) end
                if lim[1] and fixed < lim[1] then fixed = lim[1] end
                if lim[2] and fixed > lim[2] then fixed = lim[2] end
            end
            if fixed ~= v then
                opt[k] = fixed
                warnings[#warnings + 1] = k .. " = " .. tostring(v) .. " is out of range, using " .. tostring(fixed)
            end
        end
    end
    table.sort(warnings)
    return warnings
end

-- Variants are valid when the default exists, each one is a table with optional options/build,
-- and either no variant resolves a native build or every one does (module build or its own).
local function validVariants(mod)
    if mod.variants == nil then return mod.variant == nil end
    if type(mod.variants) ~= "table" or type(mod.variant) ~= "string"
        or type(mod.variants[mod.variant]) ~= "table" then
        return false
    end
    local withBuild, without = 0, 0
    for name, v in pairs(mod.variants) do
        if type(name) ~= "string" or type(v) ~= "table" or (v.options ~= nil and type(v.options) ~= "table")
            or (v.build ~= nil and type(v.build) ~= "function") then
            return false
        end
        if v.build or mod.build then withBuild = withBuild + 1 else without = without + 1 end
    end
    return withBuild == 0 or without == 0
end

local function hasNative(mod)
    if type(mod.build) == "function" then return true end
    for _, v in pairs(type(mod.variants) == "table" and mod.variants or {}) do
        if type(v) == "table" and type(v.build) == "function" then return true end
    end
    return false
end

-- What is wrong with a loaded module (see the header for its shape), nil if nothing.
local function moduleProblem(mod)
    if type(mod) ~= "table" then return "must return a table" end
    if type(mod.type) ~= "string" then return "`type` must be the DCS unit type string" end
    if not (hasNative(mod) or type(mod.outputs) == "table") then
        return "needs `build` (function) and/or `outputs` (list)"
    end
    if not validVariants(mod) then
        return "`variants` need `variant` = name of the default one, each variant { options = table?, build = function? },"
            .. " and a native build in all variants or in none"
    end
    if mod.limits ~= nil and type(mod.limits) ~= "table" then return "`limits` must be a table" end
    local ids = { [M.NATIVE_OUTPUT] = hasNative(mod) }
    for i, o in ipairs(mod.outputs or {}) do
        if type(o.id) ~= "string" or type(o.file) ~= "string" or type(o.build) ~= "function" then
            return "outputs[" .. i .. "] needs `id`, `file` (strings) and `build` (function)"
        end
        if ids[o.id] then
            return "outputs[" .. i .. "]: id '" .. o.id .. "' is used twice ('" .. M.NATIVE_OUTPUT .. "' = the native cartridge)"
        end
        ids[o.id] = true
    end
    return nil
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
        local problem = ok and moduleProblem(mod) or (not ok and tostring(mod))
        if problem then
            errors[#errors + 1] = f .. ": " .. problem
        else
            modules[#modules + 1] = mod
        end
    end
    return modules, errors
end

------------------------------------------------------------------------------
-- base cartridge (config.lua BASE_DTC): our data over a copy of the user's DCS DTC
------------------------------------------------------------------------------

local function deepCopy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = deepCopy(x) end
    return t
end

local function splitPath(path)
    local parts = {}
    for p in string.gmatch(path, "[^%.]+") do parts[#parts + 1] = p end
    return parts
end

local function overlay(dst, src, byIndex, path)
    for k, v in pairs(src) do
        local d = dst[k]
        local p = path and (path .. "." .. tostring(k)) or tostring(k)
        if type(v) ~= "table" then
            dst[k] = v
        elseif next(v) == nil then
            if d == nil then dst[k] = {} end             -- empty: keep what the base has
        elseif byIndex[p] and type(d) == "table" then
            for i, x in ipairs(v) do d[i] = deepCopy(x) end   -- replace only our elements
        elseif #v > 0 or type(d) ~= "table" or (#d > 0) then
            dst[k] = deepCopy(v)                         -- lists we filled replace the base list
        else
            overlay(d, v, byIndex, p)                    -- dictionaries merge
        end
    end
end

-- Returns a copy of `base` (cartridge "data") with `ours` laid over it, and the list of dropped paths.
-- spec = { terrainPaths = {"NAV", "MPD.NAV_PTS", ...}, byIndex = {"NAV"} } (module field `base`).
-- terrainPaths are removed from the base when its terrain is known and differs from `terrain`.
-- Rules: scalars and non-empty lists from `ours` replace, dictionaries merge, an empty table in
-- `ours` keeps the base value, byIndex lists replace element by element.
function M.applyBase(base, ours, spec, terrain)
    spec = spec or {}
    local merged = deepCopy(base)
    local dropped = {}
    if base.terrain and terrain and base.terrain ~= terrain then
        for _, path in ipairs(spec.terrainPaths or {}) do
            local parts = splitPath(path)
            local t = merged
            for i = 1, #parts - 1 do t = type(t) == "table" and t[parts[i]] or nil end
            if type(t) == "table" and t[parts[#parts]] ~= nil then
                t[parts[#parts]] = nil
                dropped[#dropped + 1] = path
            end
        end
    end
    local byIndex = {}
    for _, p in ipairs(spec.byIndex or {}) do byIndex[p] = true end
    overlay(merged, ours, byIndex, nil)
    return merged, dropped
end

-- Keeps the modules whose type is in `list` (config.lua AIRCRAFT), in list order; nil list keeps all.
-- Returns selected modules, list entries without a module.
function M.selectModules(modules, list)
    if type(list) ~= "table" then return modules, {} end
    local byType = {}
    for _, m in ipairs(modules) do byType[m.type] = m end
    local selected, missing, seen = {}, {}, {}
    for _, t in ipairs(list) do
        if byType[t] and not seen[t] then
            selected[#selected + 1] = byType[t]
            seen[t] = true
        elseif not byType[t] then
            missing[#missing + 1] = tostring(t)
        end
    end
    return selected, missing
end

-- Variant of a module by name (config.lua OPTIONS[type].variant), nil name = default.
-- Returns name, variant table (nil for a module without variants), error string for an unknown name.
function M.variantOf(mod, name)
    if mod.variants == nil then
        return nil, nil, name ~= nil and ("has no variants, '" .. tostring(name) .. "' ignored") or nil
    end
    if name == nil or name == mod.variant then return mod.variant, mod.variants[mod.variant] end
    if type(mod.variants[name]) == "table" then return name, mod.variants[name] end
    return mod.variant, mod.variants[mod.variant],
        "unknown variant '" .. tostring(name) .. "', using '" .. mod.variant .. "'"
end

-- Output list of a module with the native DCS DTC output (variant build or module `build`) first;
-- its file is <prefix>{type}.dtc (default M.FILE_PREFIX).
function M.outputsOf(mod, variant, prefix)
    local list = {}
    local build = variant and variant.build or mod.build
    if build then
        list[1] = { id = M.NATIVE_OUTPUT, format = "dcs-dtc", dir = "DTC",
            file = (prefix or M.FILE_PREFIX) .. "{type}.dtc",
            build = function(s, lib, opt) return build(s, lib, opt) end }
    end
    for _, o in ipairs(mod.outputs or {}) do list[#list + 1] = o end
    return list
end

local function expand(s, vars)
    return (string.gsub(s, "{(%w+)}", function(k) return vars[k] or ("{" .. k .. "}") end))
end

-- Builds output `o` of `mod`; the native cartridge is laid over run.base. The content goes to
-- run.built[o.id] for the next outputs. Returns the result entry (nil for a disabled output)
-- or nil, error string. run = { situation, opt, built, base, terrain, vars, variant }.
local function runOutput(mod, o, run)
    local ok, content, stats = pcall(o.build, run.situation, M, run.opt, run.built)
    local dropped
    if ok and content ~= nil and o.id == M.NATIVE_OUTPUT and type(run.base) == "table" then
        ok, content, dropped = pcall(M.applyBase, run.base, content, mod.base, run.terrain)
    end
    if not ok or (content == nil and o.id == M.NATIVE_OUTPUT) then
        return nil, mod.type .. "/" .. o.id .. ": " .. tostring(ok and "no content" or content)
    end
    local entry = { type = mod.type, id = o.id, stats = stats or {},
        variant = run.variant, defaultVariant = run.variant == mod.variant }
    if content == nil then
        entry.skip = true   -- the output prepared its data but has nothing to write (e.g. format not known yet)
    else
        if o.format == "dcs-dtc" and type(content) == "table" then content.type = mod.type end
        run.built[o.id] = content
        entry.format, entry.content = o.format or "json", content
        entry.dir, entry.file = expand(o.dir or "DTC", run.vars), expand(o.file, run.vars)
        entry.base, entry.dropped = dropped ~= nil, dropped
    end
    if o.enabled == false then return nil end   -- built for the other outputs only
    return entry
end

-- Runs every module over the situation. `overrides[type]` merges into module options
-- (`enabled = false` skips the module, `variant` picks a variant whose options go in between);
-- `overrides[type].outputs[id]` merges into an output (`enabled`, `dir`, `file`).
-- `bases[type]` = base cartridge data (config.lua BASE_DTC) that the
-- native cartridge is laid over (M.applyBase). `prefix` = native file name prefix (default M.FILE_PREFIX).
-- A failing module or output does not stop the others.
-- Returns list of { type, id, format, dir, file, content, stats, base, dropped, variant,
-- defaultVariant }, list of error strings, list of warnings (options fixed by the module `limits`).
-- An extra output whose build returns nil is listed as { type, id, skip = true, stats } (nothing to write).
function M.build(status, units, mySide, env, modules, overrides, bases, prefix)
    local situation = M.situation(status, units, mySide)
    situation.env = env
    if env.spawn and env.spawn.x and env.spawn.z then situation.spawn = env.spawn end
    local out, errors, warnings = {}, {}, {}
    for _, mod in ipairs(modules) do
        local ov = overrides and overrides[mod.type] or {}
        local vname, variant, verr = M.variantOf(mod, ov.variant)
        local defaults = merge(mod.options, variant and variant.options)
        local opt = merge(defaults, ov)
        opt.outputs, opt.variant = nil, vname
        if opt.enabled ~= false then
            if verr then errors[#errors + 1] = mod.type .. ": " .. verr end
            for _, w in ipairs(applyLimits(opt, mod.limits, defaults)) do
                warnings[#warnings + 1] = mod.type .. ": " .. w
            end
            local run = { situation = situation, opt = opt, built = {}, base = bases and bases[mod.type],
                terrain = env.terrain, variant = vname,
                vars = { type = mod.type, side = situation.side, terrain = tostring(env.terrain or "") } }
            for _, o in ipairs(M.outputsOf(mod, variant, prefix)) do
                local o2 = merge(o, ov.outputs and ov.outputs[o.id])
                -- the native cartridge is always built (other outputs may reuse it), written only if enabled
                if o2.enabled ~= false or o2.id == M.NATIVE_OUTPUT then
                    local entry, err = runOutput(mod, o2, run)
                    if entry then out[#out + 1] = entry elseif err then errors[#errors + 1] = err end
                end
            end
        end
    end
    return out, errors, warnings
end

return M
