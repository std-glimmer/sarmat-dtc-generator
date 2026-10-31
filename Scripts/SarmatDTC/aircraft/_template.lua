-- Template for a new aircraft module and the reference of the module API (the only full
-- description; SarmatDTC_core.lua and AGENTS.md refer here). Copy to aircraft/<DTC type>.lua
-- (files starting with "_" are not loaded) and add the type to AIRCRAFT in config.lua.
--
-- Before writing: read the module's DTC editor in the DCS install
-- (CoreMods/aircraft/<module>/DTC/<type>_DTC.lua): the `data.type` value, which keys setData
-- imports, whether it checks `terrain`, and the limits (MAX_*) of the section you fill.
--
-- Module fields:
--   type      DCS unit type = DTC `type` (required)
--   options   defaults; config.lua OPTIONS[type] overrides them (`enabled = false` skips the module)
--   limits    { NAME = { min, max, int = true } } for numeric options (min/max may be nil):
--             config.lua values are rounded/clamped, a non-number gets the default; dcs.log warns
--   base      { terrainPaths = { "NAV", "MPD.GEO_LINES", ... }, byIndex = { "NAV" } } for
--             config.lua BASE_DTC: map-bound sections dropped from a base made on another map;
--             lists replaced element by element instead of as a whole
--   build     function(s, lib, opt) -> data, stats: the native DCS cartridge DTC/SARMAT_<type>.dtc
--             (output id "dcs-dtc"). `data` is the cartridge "data" table, `stats` a flat
--             { name = number } table for dcs.log. Fill only what you own: an empty table keeps
--             the base DTC value, so write no empty placeholder sections.
--   outputs   extra files for other DTC systems, see below
--   variant, variants   alternative fill algorithms, see below
-- A module needs `build` and/or `outputs`. The loader names the problem when a module is rejected.
--
-- situation (s), the same for every module:
--   s.side                      "red" | "blue" - own coalition
--   s.front                     { {x, z}, ... } front line
--   s.groups                    { {x, z, friendly, type, count, class, ad, adLead}, ... } live ground groups
--                               class: "armor" | "mech" | "arty" | "inf" | "generic"
--                               ad: AD key (lib.AD_TYPES) when the group has air defence, else nil
--                               adLead: the lead unit itself is that AD type
--   s.sites                     { {x, z, friendly, ad, name}, ... } SAM sites without a live group
--   s.farps                     { {x, z, friendly, name, kind}, ... } FARPs / FOBs ("FARP" | "FOB")
--   s.spawn                     { x, z, name } own start base, nil if unknown
--   s.env                       terrain id and terrain callbacks (for lib.elevation/latLon/cartridge)
-- DCS DTC stores DCS x as `x` and DCS z as `y`.
--
-- lib (SarmatDTC_core):
--   geometry   round(v, step = 0.1), dist(a, b), distToPolyline(x, z, line),
--              simplify(line, maxPts), chain(line, maxLines, ptsPerLine) (lines share end points)
--   priority   byScore(list, score(p), limit) (lowest first, stable), byFront(list, front, limit)
--   threats    enemyThreats(s, limit, { MIN_RANGE, DEDUP_M }) -> { {x, z, key, name, text, range, alt} },
--              THREAT_DEFS[key] = { name (ED threat name), text, range [m], alt [m] }, AD_TYPES
--   terrain    elevation(env, x, z) [m], latLon(env, x, z)
--   output     cartridge(type, env) -> { type, name, terrain }, CARTRIDGE_NAME, asciiUpper(s, maxLen),
--              toLua(value), NATIVE_OUTPUT ("dcs-dtc")
--
-- Outputs: { id, format, dir, file, enabled, build(s, lib, opt, built) -> content, stats }.
-- Each runs after `build` and gets built["dcs-dtc"] (the native cartridge data, built even when its
-- own output is disabled) and the earlier outputs. Formats: "json", "lua", "text" (content is a
-- string), "dcs-dtc". dir: relative to Saved Games\DCS.openbeta (default "DTC"), absolute, or with
-- %ENV% variables; dir/file placeholders: {type} {side} {terrain}. Users override `enabled`/`dir`/
-- `file` in config.lua OPTIONS[type].outputs[id]; a new external system starts with enabled = false.
-- content nil = nothing to write (logged as "not written"; see aircraft/F-15ESE.lua).
--
-- Variants (optional): alternative fill algorithms or option presets, one is chosen in
-- config.lua OPTIONS[type].variant (unknown name: error in the log, `variant` default is used).
-- A variant's `options` go over the module options, config.lua OPTIONS over both; its `build`
-- replaces the module `build` for the native cartridge (in all variants or in none). `opt.variant`
-- = chosen name. Outputs are shared by all variants. Without `variants` there is no `variant` field.

local TYPE = "MyAircraft_DTC_type"

return {
    type = TYPE,
    options = {
        POINTS = 10,            -- overridable from config.lua OPTIONS["MyAircraft_DTC_type"]
    },
    limits = { POINTS = { 2, 20, int = true } },   -- the editor's MAX_* for this list

    variant  = "default",
    variants = {
        default = {},                                   -- module options and build
        dense   = { options = { POINTS = 20 } },        -- preset of the same build
        -- other = { options = { ... }, build = function(s, lib, opt) ... end },  -- own algorithm
    },

    build = function(s, lib, opt)
        local points = {}
        for i, p in ipairs(lib.simplify(s.front, opt.POINTS)) do
            points[i] = { x = lib.round(p.x), y = lib.round(p.z), alt = lib.elevation(s.env, p.x, p.z) }
        end
        local data = lib.cartridge(TYPE, s.env)
        data.SOME_SECTION = { LINE = points }
        return data, { points = #points }
    end,

    outputs = {
        {
            id      = "my-tool",
            format  = "json",
            dir     = "%USERPROFILE%\\Documents\\MyDTCTool\\{type}",
            file    = "SARMAT.json",
            enabled = false,    -- opt-in: config.lua OPTIONS[type].outputs["my-tool"] = { enabled = true }
            build   = function(s, lib, opt, built)
                local front = {}
                for i, p in ipairs(built["dcs-dtc"].SOME_SECTION.LINE) do
                    local lat, lon = lib.latLon(s.env, p.x, p.y)
                    front[i] = { lat = lat, lon = lon }
                end
                return { name = "SARMAT front", side = s.side, front = front }, { points = #front }
            end,
        },
    },
}
