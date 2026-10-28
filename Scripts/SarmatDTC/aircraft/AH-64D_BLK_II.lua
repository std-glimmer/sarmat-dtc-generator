-- AH-64D: Control Measures (own/enemy ground groups, own AD, FARPs), Targets and Threats
-- (enemy AD by type) and the front line as FLOT in Mission 1.
-- Format: CoreMods/aircraft/AH-64D/DTC/NAV/{Points,Lines}.lua; NAV is imported only on matching terrain.
--
-- Priority (lowest score wins a slot):
--   score = distance to front + SPAWN_WEIGHT * distance to own spawn base (if known)
--   enemy objects: score * ENEMY_FACTOR

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

-- TGT/THRT symbol ids by AD key (Points.lua PointsID.TGT)
local TGT_IDS = {
    ["SA-10"] = 12, ["SA-11"] = 13, PATRIOT = 43, ["SA-5"] = 7, ["SA-2"] = 4, HAWK = 24,
    ["SA-6"] = 8, ["SA-3"] = 5, NASAMS = 2, ["SA-15"] = 17, PANTSIR = 35, ["SA-19"] = 20,
    ROLAND = 25, ["SA-8"] = 10, RAPIER = 29, ["HQ-7"] = 28, ["SA-13"] = 15, CHAPARRAL = 46,
    ["SA-9"] = 11, STINGER = 44, MANPADS = 18, ["ZSU-23-4"] = 21, GEPARD = 56, VULCAN = 57,
    ["ZSU-57"] = 31, ["ZU-23"] = 30, AAA = 26, RADAR = 32,
}
local TGT_GENERIC = 2       -- GU (Generic Air Defense Unit)

local function adNote(g)
    return g.ad .. (g.adLead and "" or (" + " .. g.type)) .. " X" .. g.count
end

return {
    type = "AH-64D_BLK_II",
    base = { terrainPaths = { "NAV" } },   -- config.lua BASE_DTC: map-bound sections of the base file
    options = {
        CTRLM       = 49,   -- C51..C99
        CTRLM_FARPS = nil,  -- nil: FARPs compete with units by distance to front; N: reserve up to N slots
        TGT         = 50,   -- T01..T50
        LINES       = 15,
        LINE_PTS    = 4,    -- 2..4 vertices per line
        SPAWN_WEIGHT = 0.5, -- weight of distance to own spawn base vs distance to front (0 = ignore spawn)
        ENEMY_FACTOR = 0.7, -- enemy score multiplier (< 1 prefers enemy objects, 1 = no preference)
    },

    build = function(s, lib, opt)
        local env, up = s.env, lib.asciiUpper

        -- candidates
        local ctrlm, tgt = {}, {}
        for _, g in ipairs(s.groups) do
            if g.ad and not g.friendly then
                tgt[#tgt + 1] = { x = g.x, z = g.z, id = TGT_IDS[g.ad] or TGT_GENERIC, note = up(adNote(g), 40) }
            elseif g.ad then
                ctrlm[#ctrlm + 1] = { x = g.x, z = g.z, id = CTRLM_OWN_AD, friendly = true,
                    note = up("OWN AD " .. adNote(g), 40) }
            else
                local ids = CTRLM_IDS[g.class] or CTRLM_IDS.generic
                ctrlm[#ctrlm + 1] = { x = g.x, z = g.z, id = g.friendly and ids[1] or ids[2], friendly = g.friendly,
                    note = up((g.friendly and "OWN " or "ENEMY ") .. CLASS_NAMES[g.class] .. " "
                        .. g.type .. " X" .. g.count, 40) }
            end
        end
        for _, site in ipairs(s.sites) do
            if not site.friendly then
                tgt[#tgt + 1] = { x = site.x, z = site.z, id = TGT_IDS[site.ad] or TGT_GENERIC,
                    note = up(site.ad .. " SITE " .. site.name, 40) }
            end
        end
        for _, f in ipairs(s.farps) do
            ctrlm[#ctrlm + 1] = { x = f.x, z = f.z, id = CTRLM_FARP, farp = true, friendly = f.friendly,
                note = up(f.name .. (f.friendly and " OWN" or " ENEMY"), 40) }
        end

        -- priority: near the front, near own spawn base, enemy first
        local function score(p)
            local v = lib.distToPolyline(p.x, p.z, s.front)
            if s.spawn then v = v + opt.SPAWN_WEIGHT * lib.dist(p, s.spawn) end
            if not p.friendly then v = v * opt.ENEMY_FACTOR end
            return v
        end
        local selected
        if opt.CTRLM_FARPS then
            local farps, others = {}, {}
            for _, p in ipairs(ctrlm) do
                if p.farp then farps[#farps + 1] = p else others[#others + 1] = p end
            end
            selected = lib.byScore(farps, score, math.min(opt.CTRLM_FARPS, opt.CTRLM))
            for _, p in ipairs(lib.byScore(others, score, opt.CTRLM - #selected)) do selected[#selected + 1] = p end
            selected = lib.byScore(selected, score, opt.CTRLM)
        else
            selected = lib.byScore(ctrlm, score, opt.CTRLM)
        end

        local ctrlmPts, tgtPts = {}, {}
        local farpOwn, farpEnemy = 0, 0
        for i, p in ipairs(selected) do
            local num = 50 + i
            local text = "C" .. num
            if p.farp then
                if p.friendly then farpOwn = farpOwn + 1; text = string.format("F%02d", farpOwn)
                else farpEnemy = farpEnemy + 1; text = string.format("E%02d", farpEnemy) end
            end
            ctrlmPts[i] = { alt = lib.elevation(env, p.x, p.z), id = p.id, note = p.note, num = num, text = text,
                x = lib.round(p.x), y = lib.round(p.z) }
        end
        for i, p in ipairs(lib.byScore(tgt, score, opt.TGT)) do
            tgtPts[i] = { alt = lib.elevation(env, p.x, p.z), id = p.id, note = p.note, num = i,
                text = string.format("T%02d", i), x = lib.round(p.x), y = lib.round(p.z) }
        end

        local lines = {}
        if #s.front >= 2 then
            for _, seg in ipairs(lib.chain(s.front, opt.LINES, opt.LINE_PTS)) do
                local vertices = {}
                for j, p in ipairs(seg) do vertices[j] = { x = lib.round(p.x), y = lib.round(p.z) } end
                lines[#lines + 1] = { note = "FRONT", text = "", type_num = 4, vertices = vertices } -- 4 = FLOT
            end
        end

        local data = lib.cartridge("AH-64D_BLK_II", env)
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
        local enemy = 0
        for _, p in ipairs(selected) do if not p.friendly then enemy = enemy + 1 end end
        return data, { ctrlm = #ctrlmPts, enemy = enemy, tgt = #tgtPts, lines = #lines }
    end,
}
