-- AH-64D: Control Measures (enemy units, own units near the front, FARPs), Targets and Threats
-- (enemy AD by type) and the front line as FLOT in Mission 1.
-- Format: CoreMods/aircraft/AH-64D/DTC/NAV/{Points,Lines}.lua; NAV is imported only on matching terrain.
--
-- Planned like a TSD picture for one sortie, not a copy of the whole map:
--   * only the area of operations (if the spawn base is known): objects within (distance from the
--     base to the front + AO_DEPTH_M) of the base; own FARPs only between the base and the front
--   * one symbol per position: groups of one side closer than CLUSTER_M to a more important group
--     merge into it (its position, majority class, summed vehicle count); units at a FARP/FOB of
--     their side merge into the FARP point; one threat point per AD type within CLUSTER_M
--   * own units only near the front (fratricide), own air defence off (it is no threat to us)
--   * CTRLM free text is shown on the TSD instead of the point index: vehicle count for units,
--     F01../E01.. for own/enemy FARPs (the full description is in the point note)
--   * TGT holds only threats and stops at T25, the DTC "safe set": T26..T50 stay free for
--     targets stored by the crew (TADS/HMD/fly-over STO go to the next empty TGT point)
--
-- Priority (lowest score wins a slot):
--   CTRLM: distance to front + SPAWN_WEIGHT * distance to own spawn base (if known),
--          enemy objects: score * ENEMY_FACTOR
--   TGT:   (distance to front - threat ring, capped at RING_CAP_M) + SPAWN_WEIGHT * distance to spawn,
--          so a SAM whose ring reaches over the front goes before AAA further behind it
-- CTRLM list order: own FARPs, then enemy objects, then own units (each by priority).

-- CTRLM symbol ids by ground class: { friendly, enemy } (Points.lua PointsID.CTRLM)
local CTRLM_IDS = {
    armor   = { 14, 34 },   -- AM / AE
    mech    = { 29, 43 },   -- MI / EM
    arty    = { 23, 39 },   -- FL / EF
    inf     = { 22, 41 },   -- FI / EI
    generic = { 24, 46 },   -- FU / EU
}
local CTRLM_OWN_AD = 12     -- AD (Friendly Air Defense)
local CTRLM_FARP   = 68     -- FC (FARP, Fuel and Ammo)
local CLASS_NAMES  = { armor = "ARMOR", mech = "MECH", arty = "ARTY", inf = "INF", generic = "UNIT" }
local CLASS_ORDER  = { "armor", "mech", "arty", "inf" }   -- majority ties; generic only if nothing else

-- TGT/THRT symbol ids by AD key (Points.lua PointsID.TGT)
local TGT_IDS = {
    ["SA-10"] = 12, ["SA-11"] = 13, PATRIOT = 43, ["SA-5"] = 7, ["SA-2"] = 4, HAWK = 24,
    ["SA-6"] = 8, ["SA-3"] = 5, NASAMS = 2, ["SA-15"] = 17, PANTSIR = 35, ["SA-19"] = 20,
    ROLAND = 25, ["SA-8"] = 10, RAPIER = 29, ["HQ-7"] = 28, ["SA-13"] = 15, CHAPARRAL = 46,
    ["SA-9"] = 11, STINGER = 44, MANPADS = 18, ["ZSU-23-4"] = 21, GEPARD = 56, VULCAN = 57,
    ["ZSU-57"] = 31, ["ZU-23"] = 30, AAA = 26, RADAR = 32,
}
local TGT_GENERIC = 2       -- GU (Generic Air Defense Unit)
local HOME_M = 5000         -- own FARP up to this much further from the front than the base is still "home"

local TYPE        = "AH-64D_BLK_II"
local CTRLM_FIRST = 51      -- number of the first Control Measure point (C51)
local NOTE_LEN    = 40      -- point note, shown on the POINT page
local TEXT_MAX_N  = 999     -- vehicle count in the 3-character free text
local LINE_FLOT   = 4       -- Lines.lua type_num of a FLOT line
local RANK_STEP   = 1e9     -- above any score: the CTRLM list is ordered by rank, then by score

local function adNote(g)
    return g.ad .. (g.adLead and "" or (" + " .. g.type)) .. " X" .. g.count
end

-- Greedy merge of `list` (already sorted by priority): an item closer than `radius` to the seed of
-- a cluster with the same `key(item)` joins it, otherwise it seeds a new cluster at its own position.
-- Seeds of one key are therefore at least `radius` apart. Returns clusters { seed, members }.
local function mergeNear(list, radius, key, dist)
    local clusters = {}
    for _, p in ipairs(list) do
        local into
        for _, c in ipairs(clusters) do
            if c.key == key(p) and dist(c.seed, p) < radius then into = c break end
        end
        if into then
            into.members[#into.members + 1] = p
        else
            clusters[#clusters + 1] = { key = key(p), seed = p, members = { p } }
        end
    end
    return clusters
end

-- Majority class of merged groups by vehicle count; returns class, vehicles, type of its biggest group.
local function clusterClass(members)
    local count, biggest, total = {}, {}, 0
    for _, g in ipairs(members) do
        total = total + g.count
        count[g.class] = (count[g.class] or 0) + g.count
        if not biggest[g.class] or g.count > biggest[g.class].count then biggest[g.class] = g end
    end
    local best, bestN = "generic", 0
    for _, c in ipairs(CLASS_ORDER) do
        if (count[c] or 0) > bestN then best, bestN = c, count[c] end
    end
    return best, total, (biggest[best] or members[1]).type
end

-- Distances and scores of one build (see Priority in the header).
local function planner(s, lib, opt)
    local dist = lib.dist
    local P = {}
    function P.frontDist(p) return lib.distToPolyline(p.x, p.z, s.front) end
    function P.spawnDist(p) return s.spawn and opt.SPAWN_WEIGHT * dist(p, s.spawn) or 0 end
    function P.ring(t)
        local def = lib.THREAT_DEFS[t.ad]
        return def and math.min(def.range, opt.RING_CAP_M) or 0
    end
    -- area of operations; own FARPs behind the base are not on the way to the fight
    local baseFront = s.spawn and P.frontDist(s.spawn)
    function P.inAO(p, reach)
        if not s.spawn or opt.AO_DEPTH_M <= 0 then return true end
        if p.farp and p.friendly and P.frontDist(p) > baseFront + HOME_M then return false end
        return dist(p, s.spawn) - (reach or 0) <= baseFront + opt.AO_DEPTH_M
    end
    -- priority: near the front, near own spawn base, enemy first
    function P.score(p)
        local v = P.frontDist(p) + P.spawnDist(p)
        if not p.friendly then v = v * opt.ENEMY_FACTOR end
        return v
    end
    function P.threatScore(t) return P.frontDist(t) - P.ring(t) + P.spawnDist(t) end
    return P
end

-- Enemy AD groups and SAM sites in the area of operations become threats, the other groups
-- CTRLM units (own ones only near the front, own AD only with OWN_AD).
local function candidates(s, P, opt)
    local units, threats = {}, {}
    for _, g in ipairs(s.groups) do
        if g.ad and not g.friendly then
            local t = { x = g.x, z = g.z, ad = g.ad, count = g.count, note = adNote(g) }
            if P.inAO(t, P.ring(t)) then threats[#threats + 1] = t end
        elseif (opt.OWN_AD or not g.ad) and P.inAO(g) and
                not (g.friendly and opt.OWN_FRONT_M > 0 and P.frontDist(g) > opt.OWN_FRONT_M) then
            units[#units + 1] = g
        end
    end
    for _, site in ipairs(s.sites) do
        local t = { x = site.x, z = site.z, ad = site.ad, count = 0, note = site.ad .. " SITE " .. site.name }
        if not site.friendly and P.inAO(t, P.ring(t)) then threats[#threats + 1] = t end
    end
    return units, threats
end

-- CTRLM symbols: FARPs/FOBs (units of their side at them belong to them) and merged unit positions.
-- Returns symbols { x, z, id, note, text?, farp?, friendly }, number of groups merged away.
local function ctrlmSymbols(s, lib, P, opt, units)
    local up, dist = lib.asciiUpper, lib.dist
    local symbols, merged = {}, 0
    local farps = {}
    for _, f in ipairs(s.farps) do
        local p = { x = f.x, z = f.z, friendly = f.friendly, farp = true, name = f.name, count = 0 }
        if P.inAO(p) then farps[#farps + 1] = p end
    end
    local free = {}
    for _, g in ipairs(lib.byScore(units, P.score)) do
        local farp
        for _, f in ipairs(farps) do
            if f.friendly == g.friendly and dist(f, g) < opt.CLUSTER_M then farp = f break end
        end
        if farp then
            farp.count = farp.count + g.count
            merged = merged + 1
        else
            free[#free + 1] = g
        end
    end
    for _, f in ipairs(farps) do
        local defenders = (not f.friendly and f.count > 0) and (" X" .. f.count) or ""
        symbols[#symbols + 1] = { x = f.x, z = f.z, id = CTRLM_FARP, farp = true, friendly = f.friendly,
            note = up(f.name .. (f.friendly and " OWN" or " ENEMY") .. defenders, NOTE_LEN) }
    end
    local function unitKey(g) return (g.friendly and "own" or "enemy") .. (g.ad and "AD" or "") end
    for _, c in ipairs(mergeNear(free, opt.CLUSTER_M, unitKey, dist)) do
        local g, n = c.seed, #c.members
        merged = merged + n - 1
        local class, total, typeName = clusterClass(c.members)
        local grp = n > 1 and (" " .. n .. " GRP") or ""
        local p = { x = g.x, z = g.z, friendly = g.friendly, text = tostring(math.min(total, TEXT_MAX_N)) }
        if g.ad then
            p.id, p.note = CTRLM_OWN_AD, "OWN AD " .. adNote(g) .. grp
        else
            local ids = CTRLM_IDS[class]
            p.id = g.friendly and ids[1] or ids[2]
            p.note = (g.friendly and "OWN " or "ENEMY ") .. CLASS_NAMES[class] .. " X" .. total .. grp .. " " .. typeName
        end
        p.note = up(p.note, NOTE_LEN)
        symbols[#symbols + 1] = p
    end
    return symbols, merged
end

-- Up to opt.CTRLM symbols by priority (opt.CTRLM_FARPS reserves slots for FARPs), in the order
-- of the TSD CTRLM list: own FARPs, enemy, own units.
local function selectCtrlm(lib, P, opt, symbols)
    local selected
    if opt.CTRLM_FARPS then
        local farpPts, others = {}, {}
        for _, p in ipairs(symbols) do
            if p.farp then farpPts[#farpPts + 1] = p else others[#others + 1] = p end
        end
        selected = lib.byScore(farpPts, P.score, math.min(opt.CTRLM_FARPS, opt.CTRLM))
        for _, p in ipairs(lib.byScore(others, P.score, opt.CTRLM - #selected)) do selected[#selected + 1] = p end
    else
        selected = lib.byScore(symbols, P.score, opt.CTRLM)
    end
    return lib.byScore(selected, function(p)
        local rank = (p.farp and p.friendly) and 0 or (p.friendly and 2 or 1)
        return rank * RANK_STEP + P.score(p)
    end)
end

-- CTRLM points C51.. Free text: vehicle count for units, F01../E01.. for own/enemy FARPs.
-- Returns points, counts { farpOwn, farpEnemy, enemy }.
local function ctrlmPoints(s, lib, selected)
    local pts, n = {}, { farpOwn = 0, farpEnemy = 0, enemy = 0 }
    for i, p in ipairs(selected) do
        local text = p.text
        if p.farp then
            if p.friendly then n.farpOwn = n.farpOwn + 1; text = string.format("F%02d", n.farpOwn)
            else n.farpEnemy = n.farpEnemy + 1; text = string.format("E%02d", n.farpEnemy) end
        end
        if not p.friendly then n.enemy = n.enemy + 1 end
        pts[i] = { alt = lib.elevation(s.env, p.x, p.z), id = p.id, note = p.note, num = CTRLM_FIRST - 1 + i,
            text = text, x = lib.round(p.x), y = lib.round(p.z) }
    end
    return pts, n
end

-- TGT points T01.. (up to opt.TGT): one per AD type within CLUSTER_M, by threat priority.
-- Returns points, number of threats merged away.
local function tgtPoints(s, lib, P, opt, threats)
    local merged, kept = 0, {}
    for _, c in ipairs(mergeNear(lib.byScore(threats, P.threatScore), opt.CLUSTER_M,
            function(t) return t.ad end, lib.dist)) do
        local t, n = c.seed, #c.members
        merged = merged + n - 1
        if n > 1 then
            local total = 0
            for _, m in ipairs(c.members) do total = total + m.count end
            t.note = t.ad .. (total > 0 and (" X" .. total) or "") .. " " .. n .. " GRP"
        end
        kept[#kept + 1] = t
    end
    local pts = {}
    for i = 1, math.min(opt.TGT, #kept) do
        local p = kept[i]
        pts[i] = { alt = lib.elevation(s.env, p.x, p.z), id = TGT_IDS[p.ad] or TGT_GENERIC,
            note = lib.asciiUpper(p.note, NOTE_LEN), num = i, text = string.format("T%02d", i),
            x = lib.round(p.x), y = lib.round(p.z) }
    end
    return pts, merged
end

-- The front line as chained FLOT lines.
local function flotLines(s, lib, opt)
    local lines = {}
    if #s.front >= 2 then
        for _, seg in ipairs(lib.chain(s.front, opt.LINES, opt.LINE_PTS)) do
            local vertices = {}
            for j, p in ipairs(seg) do vertices[j] = { x = lib.round(p.x), y = lib.round(p.z) } end
            lines[#lines + 1] = { note = "FRONT", text = "", type_num = LINE_FLOT, vertices = vertices }
        end
    end
    return lines
end

return {
    type = TYPE,
    base = { terrainPaths = { "NAV" } },   -- config.lua BASE_DTC: map-bound sections of the base file
    options = {
        CTRLM       = 49,   -- C51..C99
        CTRLM_FARPS = nil,  -- nil: FARPs compete with units by distance to front; N: reserve up to N slots
        TGT         = 25,   -- T01..T25 (safe set); up to 50, but then the crew has no free points to store
        LINES       = 15,
        LINE_PTS    = 4,    -- 2..4 vertices per line
        SPAWN_WEIGHT = 0.5, -- weight of distance to own spawn base vs distance to front (0 = ignore spawn)
        ENEMY_FACTOR = 0.7, -- enemy score multiplier (< 1 prefers enemy objects, 1 = no preference)
        AO_DEPTH_M   = 80000, -- [m] how far past the front the area of operations reaches (0 = whole map)
        CLUSTER_M    = 2000,  -- [m] one symbol per position / one threat per AD type (0 = no merging)
        OWN_FRONT_M  = 10000, -- [m] own units further from the front are not shown (0 = all)
        OWN_AD       = false, -- show own air defence groups (AD symbol)
        RING_CAP_M   = 15000, -- [m] threat ring counted for TGT priority (radar horizon of a low helicopter)
    },
    -- config.lua values outside these are clamped (Points.lua / Lines.lua limits)
    limits = {
        CTRLM = { 0, 49, int = true }, CTRLM_FARPS = { 0, 49, int = true }, TGT = { 0, 50, int = true },
        LINES = { 0, 15, int = true }, LINE_PTS = { 2, 4, int = true },
        SPAWN_WEIGHT = { 0 }, ENEMY_FACTOR = { 0 }, AO_DEPTH_M = { 0 }, CLUSTER_M = { 0 },
        OWN_FRONT_M = { 0 }, RING_CAP_M = { 0 },
    },

    -- config.lua OPTIONS["AH-64D_BLK_II"] = { variant = "..." }; a variant without its own build
    -- uses the build below with its options, e.g. theater = { options = { TGT = 50, AO_DEPTH_M = 0 } }
    variant  = "sortie",
    variants = {
        sortie = {},        -- TSD picture for one sortie (header comment)
    },

    build = function(s, lib, opt)
        local P = planner(s, lib, opt)
        local units, threats = candidates(s, P, opt)
        local symbols, mergedUnits = ctrlmSymbols(s, lib, P, opt, units)
        local ctrlmPts, n = ctrlmPoints(s, lib, selectCtrlm(lib, P, opt, symbols))
        local tgtPts, mergedThreats = tgtPoints(s, lib, P, opt, threats)
        local lines = flotLines(s, lib, opt)

        local data = lib.cartridge(TYPE, s.env)
        data.NAV = {
            MissionFile = 1,
            Mission_1 = {
                Points = {
                    CTRLM = { isEnabled = true, POINTS = ctrlmPts },
                    TGT   = { isEnabled = true, POINTS = tgtPts },
                },
                Lines = lines,
            },
        }
        return data, { ctrlm = #ctrlmPts, enemy = n.enemy, farps = n.farpOwn + n.farpEnemy, tgt = #tgtPts,
            lines = #lines, merged = mergedUnits + mergedThreats }
    end,
}
