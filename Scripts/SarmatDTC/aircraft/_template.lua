-- Template for a new aircraft module. Copy to aircraft/<DTC type>.lua (files starting with "_"
-- are not loaded). The file name is free, but keep it equal to `type` for clarity.
--
-- Before writing: read the module's DTC editor in the DCS install
-- (CoreMods/aircraft/<module>/DTC/<type>_DTC.lua): the `data.type` value, which keys setData
-- imports, whether it checks `terrain`, and the limits (MAX_*) of the section you fill.
--
-- situation (s):
--   s.side                      "red" | "blue" - own coalition
--   s.front                     { {x, z}, ... } front line
--   s.groups                    { {x, z, friendly, type, count, class, ad, adLead}, ... } live ground groups
--                               class: "armor" | "mech" | "arty" | "inf" | "generic"
--                               ad: AD key (lib.AD_TYPES) when the group has air defence, else nil
--   s.sites                     { {x, z, friendly, ad, name}, ... } SAM sites without a live group
--   s.farps                     { {x, z, friendly, name, kind}, ... } FARPs / FOBs
--   s.env                       terrain id and terrain callbacks
-- lib: round, simplify(line, n), chain(line, lines, ptsPerLine), byFront(list, front, limit),
--      distToPolyline, elevation(env, x, z), latLon(env, x, z), cartridge(type, env), asciiUpper(s, len)
-- DTC stores DCS x as `x` and DCS z as `y`.

return {
    type = "MyAircraft_DTC_type",
    options = {
        POINTS = 10,            -- overridable from CONFIG.AIRCRAFT["MyAircraft_DTC_type"]
    },

    build = function(s, lib, opt)
        local points = {}
        for i, p in ipairs(lib.simplify(s.front, opt.POINTS)) do
            points[i] = { x = lib.round(p.x), y = lib.round(p.z), alt = lib.elevation(s.env, p.x, p.z) }
        end
        local data = lib.cartridge("MyAircraft_DTC_type", s.env)
        data.SOME_SECTION = { LINE = points }
        return data, { points = #points }
    end,
}
