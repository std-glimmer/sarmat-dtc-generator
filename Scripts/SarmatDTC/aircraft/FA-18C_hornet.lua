-- F/A-18C: front line as SA FLOT lines and enemy SAM threats as SA MEZ THRTS (threat rings).
-- Format: CoreMods/aircraft/FA-18C/DTC/SA/{FAOR_FLOT,MEZ_THRTS}.lua. setData copies
-- mirror_MEZ_THRTS as is, so it is always written: false = our threats, true = the mission's.

local TYPE = "FA-18C_hornet"

return {
    type = TYPE,
    base = { terrainPaths = { "WYPT", "GPS_WYPT", "TCN", "SA.CAP_PTS", "SA.CORRIDORS", "SA.FAOR_FLOT", "SA.MEZ_THRTS" } },
    options = {
        LINES        = 3,
        LINE_PTS     = 7,
        THREATS      = 40,      -- MEZ THRTS (0 = keep the mission's threats)
        MIN_RANGE    = 6000,    -- [m] skip short-range AD (AAA, MANPADS, SA-9/13, Avenger)
        DEDUP_M      = 5000,    -- one ring per threat type within this distance
        THREAT_LEVEL = 1,       -- 1..3
    },
    -- config.lua values outside these are clamped (FLOT 3 x 7, MEZ THRTS 40)
    limits = {
        LINES = { 1, 3, int = true }, LINE_PTS = { 2, 7, int = true }, THREATS = { 0, 40, int = true },
        MIN_RANGE = { 0 }, DEDUP_M = { 0 }, THREAT_LEVEL = { 1, 3, int = true },
    },

    build = function(s, lib, opt)
        local flot = {}
        if #s.front >= 2 then
            for n, seg in ipairs(lib.chain(s.front, opt.LINES, opt.LINE_PTS)) do
                local points = {}
                for j, p in ipairs(seg) do
                    points[j] = { id = "FLOT_" .. n .. "_PT_" .. j, x = lib.round(p.x), y = lib.round(p.z) }
                end
                flot[n] = { id = "FLOT_" .. n, note = "FRONT", num = n, points = points }
            end
        end

        local mez = {}
        for i, t in ipairs(lib.enemyThreats(s, opt.THREATS, opt)) do
            mez[i] = { id = "MEZ_THRTS_" .. i, num = i, x = lib.round(t.x), y = lib.round(t.z), text = t.text,
                threat_type = t.name, threat_ring_radius = lib.round(t.range / 1852, 0.01),   -- [NM]
                threat_level = opt.THREAT_LEVEL }
        end

        local data = lib.cartridge(TYPE, s.env)
        data.SA = { FAOR_FLOT = { FAOR = {}, FLOT = flot }, mirror_MEZ_THRTS = true }
        if opt.THREATS > 0 then
            data.SA.mirror_MEZ_THRTS = false
            data.SA.MEZ_THRTS = mez
        end
        return data, { lines = #flot, threats = #mez }
    end,
}
