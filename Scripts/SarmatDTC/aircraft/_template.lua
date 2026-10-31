-- Template for a new aircraft module. Copy to aircraft/<DTC type>.lua (files starting with "_"
-- are not loaded) and add the type to AIRCRAFT in config.lua.
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
--      distToPolyline, elevation(env, x, z), latLon(env, x, z), cartridge(type, env), asciiUpper(s, len),
--      toLua(value)
-- DCS DTC stores DCS x as `x` and DCS z as `y`.
--
-- Outputs: `build` = native DCS cartridge DTC/SARMAT_<type>.dtc (output id "dcs-dtc").
-- `outputs` = extra files for other DTC systems; each runs after `build` and gets
-- built["dcs-dtc"] (the native cartridge data) to reuse. Formats: "json", "lua", "text", "dcs-dtc".
-- dir: relative to Saved Games\DCS.openbeta, absolute, or with %ENV% variables;
-- dir/file placeholders: {type} {side} {terrain}. Users override `enabled`/`dir`/`file`
-- in config.lua OPTIONS[type].outputs[id]. A module may have only `outputs` and no `build`.
--
-- Variants (optional): alternative fill algorithms or option presets, one is chosen in
-- config.lua OPTIONS[type].variant (unknown name: error in the log, `variant` default is used).
-- A variant's `options` go over the module options, config.lua OPTIONS over both; its `build`
-- replaces the module `build` for the native cartridge. `opt.variant` = chosen name.
-- Outputs are shared by all variants. Without `variants` there is no `variant` field.

return {
    type = "MyAircraft_DTC_type",
    options = {
        POINTS = 10,            -- overridable from config.lua OPTIONS["MyAircraft_DTC_type"]
    },

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
        local data = lib.cartridge("MyAircraft_DTC_type", s.env)
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
