-- F-14B(U): front line in navigation plan 1.
-- Format: CoreMods/aircraft/F14/DTC/F-14BU_DTC.lua (NAV_MAX_LINES 4, NAV_MAX_LINE_PTS 9,
-- at most 20 points per plan in total - hence 2 x 9 by default).

local TYPE    = "F-14BU"
local MAX_PTS = 20   -- points per navigation plan

return {
    type = TYPE,
    -- plan 1 is ours, plans 2..12 come from the base file; the F-14 editor writes no terrain id,
    -- so a base without it keeps its navigation data
    base = { terrainPaths = { "NAV", "JDAM" }, byIndex = { "NAV" } },
    options = {
        LINES    = 2,
        LINE_PTS = 9,
    },
    -- config.lua values outside these are clamped; LINES is also cut to MAX_PTS points in total
    limits = { LINES = { 1, 4, int = true }, LINE_PTS = { 2, 9, int = true } },

    build = function(s, lib, opt)
        local maxLines = math.min(opt.LINES, math.floor(MAX_PTS / opt.LINE_PTS))
        local lines = {}
        if #s.front >= 2 then
            for _, seg in ipairs(lib.chain(s.front, maxLines, opt.LINE_PTS)) do
                local points = {}
                for j, p in ipairs(seg) do
                    local lat, lon = lib.latLon(s.env, p.x, p.z)
                    points[j] = { elev = lib.elevation(s.env, p.x, p.z), lat = lat, lon = lon,
                        x = lib.round(p.x), y = lib.round(p.z) }
                end
                lines[#lines + 1] = { closed = false, points = points }
            end
        end
        local data = lib.cartridge(TYPE, s.env)
        data.cartridge_name = lib.CARTRIDGE_NAME
        data.NAV = { { name = "FRONT", waypoints = {}, lines = lines, additional_points = {}, route_as_line = false } }
        return data, { lines = #lines }
    end,

    outputs = {
        {
            id      = "dcs-dtc-waypoints",
            format  = "json",
            dir     = "%USERPROFILE%\\Documents\\DCS-DTC\\Presets\\F14BU",
            file    = "SARMAT.json",
            enabled = false,
            build   = function(s, lib)
                -- The app uploads flight-plan waypoints 51..99; use own landing places only.
                local objects = {}
                for _, source in ipairs({ s.airfields, s.farps }) do
                    for _, p in ipairs(source) do
                        if p.friendly then objects[#objects + 1] = p end
                    end
                end
                local ordered = lib.byFront(objects, s.front)
                local points = {}
                for i = 1, math.min(#ordered, 49) do
                    local p = ordered[i]
                    points[i] = lib.dcsDtcWaypoint(s.env, 50 + i, p.name, p.x, p.z)
                end
                if #points == 0 then return nil, { waypoints = 0 } end
                return {
                    Aircraft = "F14BU",
                    Upload = { Waypoints = true },
                    Waypoints = { Waypoints = points },
                    Version = 2,
                }, { waypoints = #points }
            end,
        },
    },
}
