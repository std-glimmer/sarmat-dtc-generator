-- AH-64D: WPTHZ (airfields and FARPs), Control Measures (units, OP, depots), Areas, Targets, FLOT.
-- Format: CoreMods/aircraft/AH-64D/DTC/NAV/{Points,Areas,Lines}.lua; NAV requires matching terrain.
--
-- Mission 1 covers the western half of the front, Mission 2 the eastern half. Each has its own
-- front lines and up to 50 WPTHZ / 49 CTRLM / 25 TGT points selected only from that geographic half.
-- Planned like a TSD picture for one sortie, not a copy of the whole map:
--   * every point is within AO_DEPTH_M of the front (default 10 km; 0 = no limit); if the spawn
--     base is known, the previous base-to-front sortie area also applies; own FARPs stay en route
--   * airfields and FARPs/FOBs use WPTHZ only; OP and live depots use FC Control Measures
--   * a connected large cluster (AREA_MIN_GROUPS groups within AREA_DIST_M) becomes one
--     four-vertex AREA and one CTRLM at its center, labelled by class and source-group count
--   * one unit symbol per position: groups of one side closer than CLUSTER_M to a more important
--     group merge (majority symbol class, summed vehicle count); one threat per AD type in that radius
--   * own units only near the front (fratricide), own air defence off (it is no threat to us)
--   * FREE text is at most 3 chars: airfield abbreviation, FARP/OP/depot number, or class + count:
--     T = tanks, A = artillery, C = mixed/mechanized/infantry/other, S = air defence
--   * TGT holds only threats and stops at T25, the DTC "safe set": T26..T50 stay free for
--     targets stored by the crew (TADS/HMD/fly-over STO go to the next empty TGT point)
--
-- Priority (lowest score wins a slot):
--   WPTHZ/CTRLM: distance to front + SPAWN_WEIGHT * distance to own spawn/last landing base,
--                enemy objects: score * ENEMY_FACTOR; own landing places precede enemy ones
--   TGT: (distance to front - threat ring, capped at RING_CAP_M) + SPAWN_WEIGHT * distance to base,
--        so a SAM whose ring reaches over the front goes before AAA further behind it

-- CTRLM symbol ids by ground class: { friendly, enemy } (Points.lua PointsID.CTRLM)
local CTRLM_IDS = {
    armor   = { 14, 34 },   -- AM / AE
    mech    = { 29, 43 },   -- MI / EM
    arty    = { 23, 39 },   -- FL / EF
    inf     = { 22, 41 },   -- FI / EI
    generic = { 24, 46 },   -- FU / EU
}
local CTRLM_OWN_AD = 12     -- AD (Friendly Air Defense)
local CTRLM_SUPPLY = 68     -- FC (FARP, Fuel and Ammo), also used for OP/depot supply points
local WPTHZ_WP     = 6      -- WP (Waypoint); WPTHZ has no airfield/FARP-specific symbol
local CLASS_NAMES  = { armor = "ARMOR", mech = "MECH", arty = "ARTY", inf = "INF", generic = "UNIT" }
local CLASS_ORDER  = { "armor", "mech", "arty", "inf" }   -- majority ties; generic only if nothing else
local CLASS_TEXT   = { armor = "T", arty = "A" }         -- all other/mixed classes use C

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
local TEXT_MAX_N  = 99      -- class prefix + at most two decimal digits = 3-character free text
local LINE_FLOT   = 4       -- Lines.lua type_num of a FLOT line
local RANK_STEP   = 1e9     -- above any score: own points, then enemy points, each by priority

local function countText(prefix, count)
    count = math.max(0, math.min(TEXT_MAX_N, math.floor(tonumber(count) or 0)))
    return prefix .. tostring(count)
end

-- Last number in OP2 BLUE-17 is 17; Depot RED-10 similarly uses 10.
local function numberedText(name, prefix, fallback)
    local number
    for digits in string.gmatch(tostring(name or ""), "%d+") do number = tonumber(digits) end
    return countText(prefix, number or fallback or 0)
end

-- FARP 22-1 is pad 1 of FARP 22: the free text identifies the FARP, not an individual pad.
local function farpText(name, fallback)
    local number = tonumber(string.match(tostring(name or ""), "%d+"))
    return countText("F", number or fallback or 0)
end

local function groupText(class, count, mixed, ad)
    if ad then return countText("S", count) end
    return countText((not mixed and CLASS_TEXT[class]) or "C", count)
end

local function airfieldText(name)
    local text = string.upper(string.gsub(tostring(name or ""), "[^%w%s%-]", ""))
    text = string.gsub(text, "^A[LN][%s%-]+", "")   -- leading Arabic article AL-/AN-, also with a space
    text = string.gsub(text, "[^A-Z]", "")
    return string.sub(text, 1, 3)
end

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
    local best, bestN, classes = "generic", 0, 0
    for _, c in ipairs(CLASS_ORDER) do
        if (count[c] or 0) > bestN then best, bestN = c, count[c] end
    end
    for _, n in pairs(count) do if n > 0 then classes = classes + 1 end end
    return best, total, (biggest[best] or members[1]).type, classes > 1
end

local AREA_MAX   = 12     -- NAV/Areas.lua: NAV_AREAS_MAXIMUM_COUNT
local AREA_PAD_M = 500    -- keep the bounding rectangle clear of the outermost group positions

-- Large single-linked clusters become one four-vertex engagement area and one mandatory CTRLM.
-- Only groups of the same side connect. A new group can join through any already connected member.
local function findAreas(s, lib, P, opt)
    local areas, symbols, inArea = {}, {}, {}
    local merged = 0
    if opt.AREA_MIN_GROUPS <= 0 or opt.AREA_DIST_M <= 0 or opt.CTRLM <= 0 then
        return areas, symbols, inArea, merged
    end
    local eligible = {}
    for _, g in ipairs(lib.byScore(s.groups, P.score)) do
        if (not g.ad or not g.friendly or opt.OWN_AD) and P.inAO(g, g.ad and P.ring(g) or 0) and
                not (g.friendly and opt.OWN_FRONT_M > 0 and P.frontDist(g) > opt.OWN_FRONT_M) then
            eligible[#eligible + 1] = g
        end
    end
    local clusters, used = {}, {}
    for i, g in ipairs(eligible) do
        if not used[i] then
            local c = { friendly = g.friendly, members = {} }
            local queue, head = { i }, 1
            used[i] = true
            while head <= #queue do
                local current = eligible[queue[head]]
                c.members[#c.members + 1] = current
                for j, other in ipairs(eligible) do
                    if not used[j] and other.friendly == g.friendly
                            and lib.dist(current, other) <= opt.AREA_DIST_M then
                        used[j] = true
                        queue[#queue + 1] = j
                    end
                end
                head = head + 1
            end
            if #c.members >= opt.AREA_MIN_GROUPS then clusters[#clusters + 1] = c end
        end
    end
    clusters = lib.byScore(clusters, function(c) return P.score(c.members[1]) end)
    for i = 1, math.min(AREA_MAX, opt.CTRLM, #clusters) do
        local c = clusters[i]
        local first = c.members[1]
        local minX, maxX, minZ, maxZ = first.x, first.x, first.z, first.z
        for _, g in ipairs(c.members) do
            inArea[g] = true
            minX, maxX = math.min(minX, g.x), math.max(maxX, g.x)
            minZ, maxZ = math.min(minZ, g.z), math.max(maxZ, g.z)
        end
        minX, maxX = minX - AREA_PAD_M, maxX + AREA_PAD_M
        minZ, maxZ = minZ - AREA_PAD_M, maxZ + AREA_PAD_M
        local cx, cz = (minX + maxX) / 2, (minZ + maxZ) / 2
        local n = #c.members
        local class, total, _, mixed = clusterClass(c.members)
        local allAd = true
        for _, g in ipairs(c.members) do if not g.ad then allAd = false break end end
        local ids = CTRLM_IDS[class]
        local side = c.friendly and "OWN" or "ENEMY"
        areas[#areas + 1] = {
            note = side .. " AREA " .. n .. " GRP",
            vertices = {
                { x = lib.round(minX), y = lib.round(minZ) },
                { x = lib.round(maxX), y = lib.round(minZ) },
                { x = lib.round(maxX), y = lib.round(maxZ) },
                { x = lib.round(minX), y = lib.round(maxZ) },
            },
            caption_pos = {}, center_pos = { x = 0, y = 0 },
        }
        symbols[#symbols + 1] = {
            x = cx, z = cz, friendly = c.friendly, area = true,
            id = c.friendly and ids[1] or ids[2], text = groupText(class, n, mixed, allAd),
            note = lib.asciiUpper(side .. " AREA " .. n .. " GRP X" .. total .. " " .. CLASS_NAMES[class], NOTE_LEN),
        }
        merged = merged + n - 1
    end
    return areas, symbols, inArea, merged
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
    -- Hard front-distance limit for every native DTC point, plus the spawn-based sortie area.
    -- A threat ring may extend the spawn area, but never admits a point beyond AO_DEPTH_M.
    local baseFront = s.spawn and P.frontDist(s.spawn)
    function P.inAO(p, reach)
        if opt.AO_DEPTH_M > 0 and P.frontDist(p) > opt.AO_DEPTH_M then return false end
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

-- Groups selected for an AREA are represented only by its central CTRLM. Other enemy AD groups
-- and SAM sites become threats; the remaining groups become ordinary CTRLM units.
local function candidates(s, lib, P, opt)
    local units, threats = {}, {}
    local areas, areaSymbols, inArea, areaMerged = findAreas(s, lib, P, opt)
    for _, g in ipairs(s.groups) do
        if not inArea[g] then
            if g.ad and not g.friendly then
                local t = { x = g.x, z = g.z, ad = g.ad, count = g.count, note = adNote(g) }
                if P.inAO(t, P.ring(t)) then threats[#threats + 1] = t end
            elseif (opt.OWN_AD or not g.ad) and P.inAO(g) and
                    not (g.friendly and opt.OWN_FRONT_M > 0 and P.frontDist(g) > opt.OWN_FRONT_M) then
                units[#units + 1] = g
            end
        end
    end
    for _, site in ipairs(s.sites) do
        local t = { x = site.x, z = site.z, ad = site.ad, count = 0, note = site.ad .. " SITE " .. site.name }
        if not site.friendly and P.inAO(t, P.ring(t)) then threats[#threats + 1] = t end
    end
    return units, threats, areas, areaSymbols, areaMerged
end

-- CTRLM symbols: mandatory AREA centers, OP/depot supply points and merged unit positions.
-- Landing places never use CTRLM. Returns symbols and the number of groups merged away.
local function ctrlmSymbols(s, lib, P, opt, units, areaSymbols)
    local up, dist = lib.asciiUpper, lib.dist
    local symbols, merged = {}, 0
    for _, p in ipairs(areaSymbols) do symbols[#symbols + 1] = p end
    for _, source in ipairs({
        { list = s.strongpoints, prefix = "O", label = "OP", object = "ops" },
        { list = s.depots, prefix = "D", label = "DEPOT", object = "depots" },
    }) do
        for _, object in ipairs(source.list) do
            local p = { x = object.x, z = object.z, friendly = object.friendly,
                id = CTRLM_SUPPLY, object = source.object, text = numberedText(object.name, source.prefix),
                note = up(source.label .. " " .. (object.friendly and "OWN " or "ENEMY ") .. object.name, NOTE_LEN) }
            if P.inAO(p) then symbols[#symbols + 1] = p end
        end
    end
    local function unitKey(g) return (g.friendly and "own" or "enemy") .. (g.ad and "AD" or "") end
    for _, c in ipairs(mergeNear(lib.byScore(units, P.score), opt.CLUSTER_M, unitKey, dist)) do
        local g, n = c.seed, #c.members
        merged = merged + n - 1
        local class, total, typeName, mixed = clusterClass(c.members)
        local grp = n > 1 and (" " .. n .. " GRP") or ""
        local p = { x = g.x, z = g.z, friendly = g.friendly, text = groupText(class, total, mixed, g.ad) }
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

-- AREA centers are mandatory so no area is left without its symbol. All remaining slots are
-- shared by OP/depots and units; legacy CTRLM_FARPS values are deliberately ignored.
local function selectCtrlm(lib, P, opt, symbols)
    local areaPts, others = {}, {}
    for _, p in ipairs(symbols) do
        if p.area then areaPts[#areaPts + 1] = p else others[#others + 1] = p end
    end
    local selected = lib.byScore(areaPts, P.score, opt.CTRLM)
    for _, p in ipairs(lib.byScore(others, P.score, opt.CTRLM - #selected)) do selected[#selected + 1] = p end
    return lib.byScore(selected, function(p)
        return (p.friendly and 2 or 1) * RANK_STEP + P.score(p)
    end)
end

-- CTRLM points C51.. Free text: class + group count for AREA, class + vehicles for units.
local function ctrlmPoints(s, lib, selected)
    local pts, enemy, objects = {}, 0, { ops = 0, depots = 0 }
    for i, p in ipairs(selected) do
        if not p.friendly then enemy = enemy + 1 end
        if p.object then objects[p.object] = objects[p.object] + 1 end
        pts[i] = { alt = lib.elevation(s.env, p.x, p.z), id = p.id, note = p.note, num = CTRLM_FIRST - 1 + i,
            text = p.text, x = lib.round(p.x), y = lib.round(p.z) }
    end
    return pts, enemy, objects
end

-- Native WPTHZ WP 1..50: airfields and FARPs/FOBs only. Own landing places precede enemy ones.
local function wptPoints(s, lib, P, opt)
    local objects = {}
    for _, source in ipairs({ { list = s.airfields, farp = false }, { list = s.farps, farp = true } }) do
        for _, object in ipairs(source.list) do
            local p = { x = object.x, z = object.z, friendly = object.friendly,
                name = object.name, farp = source.farp }
            if P.inAO(p) then objects[#objects + 1] = p end
        end
    end
    local ordered = lib.byScore(objects, function(p)
        return (p.friendly and 0 or 1) * RANK_STEP + P.score(p)
    end, opt.WPTHZ_PTS)
    local pts, n = {}, { airfields = 0, farps = 0 }
    for i, p in ipairs(ordered) do
        local text = p.farp and farpText(p.name, i) or airfieldText(p.name)
        if text == "" then text = string.sub("AF" .. i, 1, 3) end
        if p.farp then n.farps = n.farps + 1 else n.airfields = n.airfields + 1 end
        local note = (p.farp and "FARP " or "AIRFIELD ") .. (p.friendly and "OWN " or "ENEMY ") .. p.name
        pts[i] = { alt = lib.elevation(s.env, p.x, p.z), id = WPTHZ_WP,
            note = lib.asciiUpper(note, NOTE_LEN), num = i, text = text, x = lib.round(p.x), y = lib.round(p.z) }
    end
    return pts, n
end

-- TGT points T01.. (up to opt.TGT): one per AD type within CLUSTER_M, by threat priority.
-- Returns points, number of threats merged away. FREE text is S + live vehicles, or SAM for a site.
local function tgtPoints(s, lib, P, opt, threats)
    local merged, kept = 0, {}
    for _, c in ipairs(mergeNear(lib.byScore(threats, P.threatScore), opt.CLUSTER_M,
            function(t) return t.ad end, lib.dist)) do
        local t, n = c.seed, #c.members
        merged = merged + n - 1
        local total = 0
        for _, m in ipairs(c.members) do total = total + m.count end
        if n > 1 then t.note = t.ad .. (total > 0 and (" X" .. total) or "") .. " " .. n .. " GRP" end
        t.text = total > 0 and countText("S", total) or "SAM"
        kept[#kept + 1] = t
    end
    local pts = {}
    for i = 1, math.min(opt.TGT, #kept) do
        local p = kept[i]
        pts[i] = { alt = lib.elevation(s.env, p.x, p.z), id = TGT_IDS[p.ad] or TGT_GENERIC,
            note = lib.asciiUpper(p.note, NOTE_LEN), num = i, text = p.text,
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

-- Clip the front to a west-east longitude band. Adjacent missions share the interpolated
-- cut point. For a winding front, use the longest continuous fragment in the band.
local function clipFront(front, lo, hi)
    local runs, current = {}, {}
    local function add(p)
        local last = current[#current]
        if not last or last.x ~= p.x or last.z ~= p.z then current[#current + 1] = p end
    end
    local function finish()
        if #current >= 2 then runs[#runs + 1] = current end
        current = {}
    end
    for i = 1, #front - 1 do
        local a, b = front[i], front[i + 1]
        local dz = b.z - a.z
        if dz == 0 then
            if a.z >= lo and a.z <= hi then add(a) add(b) else finish() end
        else
            local ta, tb = (lo - a.z) / dz, (hi - a.z) / dz
            local t0, t1 = math.max(0, math.min(ta, tb)), math.min(1, math.max(ta, tb))
            if t0 <= t1 then
                add({ x = a.x + (b.x - a.x) * t0, z = a.z + (b.z - a.z) * t0 })
                add({ x = a.x + (b.x - a.x) * t1, z = a.z + (b.z - a.z) * t1 })
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

local function frontHalf(front, west)
    if #front < 2 then return nil end
    local minZ, maxZ = front[1].z, front[1].z
    for i = 2, #front do
        minZ = math.min(minZ, front[i].z)
        maxZ = math.max(maxZ, front[i].z)
    end
    if maxZ <= minZ then return nil end
    local cut = (minZ + maxZ) / 2
    local part = clipFront(front, west and minZ or cut, west and cut or maxZ)
    return part, cut
end

-- Each DTC mission receives objects only from its own geographic half. Independent WPTHZ and
-- CTRLM pools stay dense instead of spreading one selection over the entire front.
local function missionSituation(s, front, cut, west)
    local part = {}
    for k, v in pairs(s) do part[k] = v end
    part.front = front
    for _, key in ipairs({ "groups", "sites", "farps", "airfields", "strongpoints", "depots" }) do
        local filtered = {}
        for _, p in ipairs(s[key]) do
            if (west and p.z <= cut) or (not west and p.z > cut) then filtered[#filtered + 1] = p end
        end
        part[key] = filtered
    end
    return part
end

local function buildMission(s, lib, opt)
    local P = planner(s, lib, opt)
    local units, threats, areas, areaSymbols, areaMerged = candidates(s, lib, P, opt)
    local symbols, mergedUnits = ctrlmSymbols(s, lib, P, opt, units, areaSymbols)
    local ctrlmPts, enemy, objects = ctrlmPoints(s, lib, selectCtrlm(lib, P, opt, symbols))
    local wptPts, landing = wptPoints(s, lib, P, opt)
    local tgtPts, mergedThreats = tgtPoints(s, lib, P, opt, threats)
    local lines = flotLines(s, lib, opt)
    return {
        Points = {
            WPTHZ = { isEnabled = true, POINTS = wptPts },
            CTRLM = { isEnabled = true, POINTS = ctrlmPts },
            TGT   = { isEnabled = true, POINTS = tgtPts },
        },
        Lines = lines,
        Areas = areas,
    }, { wpt = #wptPts, airfields = landing.airfields, farps = landing.farps,
        ctrlm = #ctrlmPts, enemy = enemy, ops = objects.ops, depots = objects.depots,
        tgt = #tgtPts, lines = #lines, areas = #areas,
        merged = areaMerged + mergedUnits + mergedThreats }
end

return {
    type = TYPE,
    base = { terrainPaths = { "NAV" } },   -- config.lua BASE_DTC: map-bound sections of the base file
    options = {
        WPTHZ_PTS   = 50,   -- native WP 1..50: airfields and FARPs/FOBs (0 = no landing waypoints)
        CTRLM       = 49,   -- C51..C99: units, AREA centers, OP and live depots
        TGT         = 25,   -- T01..T25 (safe set); up to 50, but then the crew has no free points to store
        LINES       = 15,
        LINE_PTS    = 4,    -- 2..4 vertices per line
        SPAWN_WEIGHT = 0.5, -- weight of distance to own spawn base vs distance to front (0 = ignore spawn)
        ENEMY_FACTOR = 0.7, -- enemy score multiplier (< 1 prefers enemy objects, 1 = no preference)
        AO_DEPTH_M   = 10000, -- [m] maximum point distance from the front (0 = whole map)
        CLUSTER_M    = 1000,  -- [m] one symbol per position / one threat per AD type (0 = no merging)
        AREA_MIN_GROUPS = 5,  -- minimum connected groups for one AREA (0 = disabled)
        AREA_DIST_M   = 3000, -- [m] maximum distance between connected groups (0 = disabled)
        OWN_FRONT_M  = 10000, -- [m] own units further from the front are not shown (0 = all)
        OWN_AD       = false, -- show own air defence groups (AD symbol)
        RING_CAP_M   = 15000, -- [m] threat ring counted for TGT priority (radar horizon of a low helicopter)
        WP_PTS      = 50,     -- DTC for DCS waypoint-only preset: WP 1..50
        WP_NM       = 0,      -- maximum distance from the front [NM], 0 = unlimited
        WP_SOURCES  = "AIRFIELDS,FARPS,STRONGPOINTS,STRONGHOLDS,GROUPS",
        WP_SIDE     = "ALL",  -- OWN | ENEMY | ALL
        WP_ORDER    = "FRONT", -- FRONT | FRONT_FAR | EAST_WEST | WEST_EAST | NORTH_SOUTH |
                              -- SOUTH_NORTH | NAME | MAP
    },
    -- config.lua values outside these are clamped (Points.lua / Lines.lua limits)
    limits = {
        WPTHZ_PTS = { 0, 50, int = true }, CTRLM = { 0, 49, int = true }, TGT = { 0, 50, int = true },
        LINES = { 0, 15, int = true }, LINE_PTS = { 2, 4, int = true },
        SPAWN_WEIGHT = { 0 }, ENEMY_FACTOR = { 0 }, AO_DEPTH_M = { 0 }, CLUSTER_M = { 0 },
        AREA_MIN_GROUPS = { 0, 49, int = true }, AREA_DIST_M = { 0 },
        OWN_FRONT_M = { 0 }, RING_CAP_M = { 0 },
        WP_PTS = { 0, 50, int = true }, WP_NM = { 0 },
    },

    -- config.lua OPTIONS["AH-64D_BLK_II"] = { variant = "..." }; a variant without its own build
    -- uses the build below with its options, e.g. theater = { options = { TGT = 50, AO_DEPTH_M = 0 } }
    variant  = "sortie",
    variants = {
        sortie = {},        -- TSD picture for one sortie (header comment)
    },

    build = function(s, lib, opt)
        local data = lib.cartridge(TYPE, s.env)
        data.NAV = { MissionFile = 1 }
        local total = { wpt = 0, airfields = 0, ctrlm = 0, enemy = 0, farps = 0, ops = 0, depots = 0,
            tgt = 0, lines = 0, areas = 0, merged = 0 }
        local function addMission(index, missionSituation)
            local mission, n = buildMission(missionSituation, lib, opt)
            data.NAV["Mission_" .. index] = mission
            for key, value in pairs(n) do total[key] = total[key] + value end
        end
        for index, west in ipairs({ true, false }) do
            local front, cut = frontHalf(s.front, west)
            if front then addMission(index, missionSituation(s, front, cut, west)) end
        end
        -- A missing or zero-width front cannot be split; retain one best-effort mission.
        if not data.NAV.Mission_1 and not data.NAV.Mission_2 then addMission(1, s) end
        return data, total
    end,

    outputs = {
        {
            id      = "dcs-dtc-waypoints",
            format  = "json",
            dir     = "%USERPROFILE%\\Documents\\DCS-DTC\\Presets\\AH64D",
            file    = "SARMAT.json",
            enabled = false,
            build   = function(s, lib, opt)
                -- Ordinary WP 1..50: selected landing places, strongpoints and live ground groups.
                -- This is a separate waypoint-only preset; native WPTHZ/CTRLM/TGT behavior is unchanged.
                local groupObjects = {}
                for _, g in ipairs(s.groups) do
                    groupObjects[#groupObjects + 1] = {
                        x = g.x, z = g.z, friendly = g.friendly, group = true,
                        name = (g.friendly and "BLU " or "RED ") .. tostring(g.type or "GROUP")
                            .. " X" .. tostring(g.count or 0),
                    }
                end
                local sourceLists = {
                    { "AIRFIELDS", s.airfields }, { "FARPS", s.farps },
                    { "STRONGPOINTS", s.strongpoints }, { "STRONGHOLDS", s.strongholds },
                    { "GROUPS", groupObjects },
                }
                local sources = "," .. string.upper(tostring(opt.WP_SOURCES or "")):gsub("%s", "") .. ","
                local side = string.upper(tostring(opt.WP_SIDE or "ALL"))
                local selected = {}
                for _, entry in ipairs(sourceLists) do
                    if string.find(sources, "," .. entry[1] .. ",", 1, true) then
                        for _, p in ipairs(entry[2]) do
                            local sideOk = side == "ALL" or (side == "OWN" and p.friendly)
                                or (side == "ENEMY" and not p.friendly)
                            local near = opt.WP_NM <= 0
                                or lib.distToPolyline(p.x, p.z, s.front) <= opt.WP_NM * 1852
                            if sideOk and near then selected[#selected + 1] = p end
                        end
                    end
                end
                local order = string.upper(tostring(opt.WP_ORDER or "FRONT"))
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
                    ordered = lib.byFront(selected, s.front)
                end
                local points = {}
                local groups, own, enemy = 0, 0, 0
                for i = 1, math.min(#ordered, opt.WP_PTS) do
                    local p = ordered[i]
                    points[i] = lib.dcsDtcWaypoint(s.env, i, p.name, p.x, p.z)
                    points[i].PointType = "WP"
                    points[i].Identifier = "WP"
                    if p.group then groups = groups + 1 end
                    if p.friendly then own = own + 1 else enemy = enemy + 1 end
                end
                if #points == 0 then return nil, { waypoints = 0, groups = 0, own = 0, enemy = 0 } end
                return {
                    Aircraft = "AH64D",
                    Upload = { Waypoints = true },
                    Waypoints = { Waypoints = points },
                    Version = 2,
                }, { waypoints = #points, groups = groups, own = own, enemy = enemy }
            end,
        },
    },
}
