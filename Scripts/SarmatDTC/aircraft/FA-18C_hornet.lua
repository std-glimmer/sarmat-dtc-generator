-- F/A-18C: front line as SA FLOT lines.
-- Format: CoreMods/aircraft/FA-18C/DTC/SA/FAOR_FLOT.lua. setData copies mirror_MEZ_THRTS as is,
-- so it must be written explicitly (default true = threats from the mission).

return {
    type = "FA-18C_hornet",
    options = {
        LINES    = 3,
        LINE_PTS = 7,
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
        local data = lib.cartridge("FA-18C_hornet", s.env)
        data.SA = { FAOR_FLOT = { FAOR = {}, FLOT = flot }, mirror_MEZ_THRTS = true }
        return data, { lines = #flot }
    end,
}
