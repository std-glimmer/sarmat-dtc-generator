-- F-16C: front line as GEO LINES (steerpoints 31..55, line L1).
-- Format: CoreMods/aircraft/F-16C/DTC/MPD/GEO_LINES.lua; MPD is imported only on matching terrain.

return {
    type = "F-16C_50",
    options = {
        POINTS = 25,
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
        local data = lib.cartridge("F-16C_50", s.env)
        data.MPD = { terrain = s.env.terrain, mirror_GEO_LINES = false, GEO_LINES = pts }
        return data, { points = #pts }
    end,
}
