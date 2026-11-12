-- F/A-18C: the SARMAT front line as an SA CORRIDORS corridor, enemy SAM threats as SA MEZ
-- THRTS rings, and the airfields/strongpoints around the front as GPS WYPT tables.
-- Format: CoreMods/aircraft/FA-18C/DTC/SA/*.lua, GPS WYPT/*.lua, ALR67/CMDS_defs.lua.
--
-- What the cartridge holds:
--   SA.CORRIDORS  the front line as corridor 1 (the whole line, up to CORRIDOR_PTS points)
--   GPS_WYPT      table 1 (numbers 1-100): airfields and FARPs/FOBs of both sides inside the
--                 sectors the front line runs through (only the ones in play in the mission —
--                 the map's objective list, not every airfield of the theater), closest to
--                 the front first; table 2 (numbers 101-200): enemy strongpoints (OP*) and
--                 strongholds, closest to the front first. text = 5-char label, note = name.
--   SA.MEZ_THRTS  enemy SAM rings (THREATS = 0 keeps the mission's own threats instead)
--   SA defaults   Default_CORRIDORS_Point / Default_FAOR_Line / Default_FLOT_Line /
--                 Default_MEZ_THRTS_Level (the "Default" combos of the DTC SA pages)
--   ALR67.CMDS    CMDS program presets (opt.CMDS, from config.user.lua only; absent = the
--                 base DTC's / aircraft's own programs are kept)
-- FLOT lines are no longer written (the front is a corridor now): an empty FLOT table keeps
-- whatever the base DTC has. setData copies mirror_MEZ_THRTS as is, so it is always written:
-- false = our threats, true = the mission's.

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

return {
    type = TYPE,
    base = { terrainPaths = { "WYPT", "GPS_WYPT", "TCN", "SA.CAP_PTS", "SA.CORRIDORS", "SA.FAOR_FLOT", "SA.MEZ_THRTS" } },
    options = {
        THREATS      = 40,      -- MEZ THRTS (0 = keep the mission's threats)
        MIN_RANGE    = 6000,    -- [m] skip short-range AD (AAA, MANPADS, SA-9/13, Avenger)
        DEDUP_M      = 5000,    -- one ring per threat type within this distance
        THREAT_LEVEL = 1,       -- 1..3
        CORRIDOR_PTS = 14,      -- front line points in corridor 1 (the DTC takes at most 14)
        GPS1_MAX     = 100,     -- GPS WYPT table 1: airfields/FARPs (0 = none)
        GPS2_MAX     = 100,     -- GPS WYPT table 2: enemy strongpoints/strongholds (0 = none)
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
        DEFAULT_CORRIDOR = { 0, 7, int = true }, DEFAULT_FAOR = { 1, 4, int = true },
        DEFAULT_FLOT = { 1, 4, int = true }, DEFAULT_MEZ_LVL = { 1, 4, int = true },
    },

    build = function(s, lib, opt)
        -- The whole front line as corridor 1 (the DTC draws a 10 NM wide band around it)
        local corridors = {}
        if #s.front >= 2 then
            local pts = lib.simplify(s.front, opt.CORRIDOR_PTS)
            local points = {}
            for j, p in ipairs(pts) do
                points[j] = { id = "CORR_1_PT_" .. j, x = lib.round(p.x), y = lib.round(p.z) }
            end
            corridors[1] = { id = "CORR_1", num = 1, note = "FLOT", points = points }
        end

        -- GPS WYPT: only what is in play (the map's objective lists) inside the sectors the
        -- front runs through; without sector data everything in play counts.
        local sectors = lib.activeSectors(s)
        local function inPlay(p)
            return sectors == nil or lib.inAnySector(p.x, p.z, sectors)
        end
        local function gpsPt(num, p)
            return { id = "GPS_WYPT" .. num, wypt_num = num, x = lib.round(p.x), y = lib.round(p.z),
                alt = lib.elevation(s.env, p.x, p.z), text = gpsLabel(lib, p.name),
                note = lib.asciiUpper(p.name) }
        end

        -- Table 1 (1-100): airfields and FARPs/FOBs of both sides, closest to the front first
        local src1 = {}
        for _, a in ipairs(s.airfields) do if inPlay(a) then src1[#src1 + 1] = a end end
        for _, f in ipairs(s.farps) do if inPlay(f) then src1[#src1 + 1] = f end end
        local gps, n1 = {}, 0
        for _, p in ipairs(lib.byFront(src1, s.front, opt.GPS1_MAX)) do
            n1 = n1 + 1
            gps[#gps + 1] = gpsPt(n1, p)
        end

        -- Table 2 (101-200): enemy strongpoints and strongholds, closest to the front first
        local src2 = {}
        for _, p in ipairs(s.strongpoints) do if not p.friendly then src2[#src2 + 1] = p end end
        for _, p in ipairs(s.strongholds) do if not p.friendly then src2[#src2 + 1] = p end end
        local n2 = 0
        for _, p in ipairs(lib.byFront(src2, s.front, opt.GPS2_MAX)) do
            n2 = n2 + 1
            gps[#gps + 1] = gpsPt(100 + n2, p)
        end

        local mez = {}
        for i, t in ipairs(lib.enemyThreats(s, opt.THREATS, opt)) do
            mez[i] = { id = "MEZ_THRTS_" .. i, num = i, x = lib.round(t.x), y = lib.round(t.z), text = t.text,
                threat_type = t.name, threat_ring_radius = lib.round(t.range / 1852, 0.01),   -- [NM]
                threat_level = opt.THREAT_LEVEL }
        end

        local data = lib.cartridge(TYPE, s.env)
        if #gps > 0 then data.GPS_WYPT = gps end
        data.SA = { CORRIDORS = corridors, FAOR_FLOT = { FAOR = {}, FLOT = {} },
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
        return data, { corridors = #corridors, gps1 = n1, gps2 = n2, threats = #mez }
    end,
}
