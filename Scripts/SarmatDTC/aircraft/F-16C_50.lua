-- F-16C: front line as GEO LINES (steerpoints 31..55, line L1) and enemy SAM threats as
-- THREAT PTS (steerpoints 56..70, with rings).
-- Format: CoreMods/aircraft/F-16C/DTC/MPD/{GEO_LINES,THREAT_PTS}.lua; MPD is imported only on
-- matching terrain. mirror_* = false: use our data instead of the mission's.

-- ED threat name -> index in THREAT_PTS_defs (MPD/THREAT_PTS_defs.lua, 1 = Custom)
local DEF_NUM = {
    ["Custom"] = 1, ["LPWS C-RAM"] = 3, ["SAM Avenger"] = 4, ["SAM Chaparrel"] = 5, ["SAM Hawk"] = 6,
    ["SAM HQ-7"] = 7, ["SAM NASAMS"] = 9, ["SAM Patriot"] = 10, ["SAM Rapier"] = 11, ["SAM Roland"] = 12,
    ["SAM SA-2 'Guideline'"] = 13, ["SAM SA-3 'Goa'"] = 14, ["SAM SA-5 'Gammon'"] = 15,
    ["SAM SA-6 'Gainful'"] = 16, ["SAM SA-8 'Gecko'"] = 17, ["SAM SA-9 'Gaskin'"] = 18,
    ["SAM SA-10 'Grumble'"] = 19, ["SAM SA-11 'Gadfly'"] = 20, ["SAM SA-13 'Gopher'"] = 21,
    ["SAM SA-15 'Gauntlet'"] = 22, ["SAM SA-19 'Grison'"] = 24, ["SAM SA-22 'Greyhound'"] = 25,
    ["SPAAA Gepard"] = 26, ["SPAAA Vulcan"] = 27, ["SPAAA ZSU-23-4"] = 28, ["SPAAA ZSU-57-2"] = 29,
}

return {
    type = "F-16C_50",
    base = { terrainPaths = { "MPD.NAV_PTS", "MPD.DEST", "MPD.GEO_LINES", "MPD.THREAT_PTS", "MPD.VIPVRP" } },
    options = {
        POINTS    = 25,     -- GEO LINES
        THREATS   = 15,     -- THREAT PTS (0 = keep the mission's threats)
        MIN_RANGE = 6000,   -- [m] skip short-range AD (AAA, MANPADS, SA-9/13, Avenger)
        DEDUP_M   = 5000,   -- one ring per threat type within this distance
    },

    build = function(s, lib, opt)
        local pts = {}
        if #s.front >= 2 then
            for i, p in ipairs(lib.simplify(s.front, opt.POINTS)) do
                pts[i] = { alt = lib.elevation(s.env, p.x, p.z), id = "GEO_LINES" .. (30 + i), number = i,
                    L1 = true, L2 = false, L3 = false, L4 = false, note = "FRONT",
                    x = lib.round(p.x), y = lib.round(p.z) }
            end
        end

        local threats = {}
        for i, t in ipairs(lib.enemyThreats(s, opt.THREATS, opt)) do
            threats[i] = { number = i, id = "THREAT_PTS" .. (55 + i), x = lib.round(t.x), y = lib.round(t.z),
                threatName = t.name, def_num = DEF_NUM[t.name] or 1, radius = t.range, alt = t.alt,
                elev = lib.elevation(s.env, t.x, t.z), text = t.text, ring = true }
        end

        local data = lib.cartridge("F-16C_50", s.env)
        data.MPD = { terrain = s.env.terrain, mirror_GEO_LINES = false, GEO_LINES = pts }
        if opt.THREATS > 0 then
            data.MPD.mirror_THREAT_PTS = false
            data.MPD.THREAT_PTS = threats
        end
        return data, { points = #pts, threats = #threats }
    end,
}
