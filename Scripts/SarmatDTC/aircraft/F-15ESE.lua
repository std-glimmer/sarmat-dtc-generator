-- F-15E Strike Eagle (DCS type "F-15ESE"). EXAMPLE: collects data, writes no file yet.
--
-- DCS has no native DTC editor for this module (no CoreMods/aircraft/F-15E/DTC), and the target
-- cartridge format (another DTC system) is not decided yet. The output's build gathers everything
-- the script knows into `d` and returns nil (logged as "not written"). An example of a final
-- build is commented out at the end of the file.
--
-- What the collected data gives for the F-15E:
--   d.spawn     own start base           -> WP 1 / home steerpoint of route A, landing alternate
--   d.front     front line, n points     -> a dedicated route (e.g. route B) drawn as the FLOT on the TSD/MPD
--   d.threats   enemy SAM rings          -> steerpoints/markpoints to avoid, with ED threat name, radius,
--                                           altitude; ring radius can drive route planning (stand-off)
--   d.targets   enemy ground groups      -> target points ("1." style) / aim points for A/G attack, with
--                                           class (armor/mech/arty/inf), lead type and count
--   d.own       own ground groups        -> friendly positions (no-strike / CAS reference points)
--   d.farps     own/enemy FARPs and FOBs -> alternates (own), targets (enemy)
-- Every point has DCS x/z, decimal lat/lon (WGS84, from the terrain) and elevation in metres
-- and feet. Lists are ordered by priority: near the front and near own spawn base first.
-- Missing so far (add to SarmatDTC.lua env if a format needs it): MGRS (Terrain.GetMGRScoordinates),
-- radio presets, TACAN, airfield runways.

local FT = 3.28084

-- Point with all coordinate forms plus extra fields.
local function geo(s, lib, p, fields)
    local lat, lon = lib.latLon(s.env, p.x, p.z)
    local elev = lib.elevation(s.env, p.x, p.z)
    local g = { x = lib.round(p.x), z = lib.round(p.z), lat = lat, lon = lon,
        elev = elev, elevFt = math.floor(elev * FT + 0.5) }
    for k, v in pairs(fields or {}) do g[k] = v end
    return g
end

return {
    type = "F-15ESE",
    options = {
        FRONT_PTS    = 20,      -- front line points
        THREATS      = 30,
        MIN_RANGE    = 6000,    -- [m] see lib.enemyThreats
        DEDUP_M      = 5000,
        TARGETS      = 30,
        OWN          = 20,
        SPAWN_WEIGHT = 0.5,     -- same priority idea as the AH-64 module
    },

    outputs = {
        {
            id     = "prepared",
            format = "json",                 -- placeholder: final format unknown
            file   = "SARMAT_{type}.json",   -- placeholder
            build  = function(s, lib, opt)
                local function score(p)
                    local v = lib.distToPolyline(p.x, p.z, s.front)
                    if s.spawn then v = v + opt.SPAWN_WEIGHT * lib.dist(p, s.spawn) end
                    return v
                end

                -- d = {
                --   side, terrain,
                --   spawn   = geo + { name } | nil,
                --   front   = { geo, ... },
                --   threats = { geo + { key, name, text, range, rangeNm, alt, altFt }, ... },
                --   targets = { geo + { class, type, count }, ... },
                --   own     = { geo + { class, type, count, ad }, ... },
                --   farps   = { geo + { name, kind, friendly }, ... },
                -- }   geo = { x, z, lat, lon, elev, elevFt }
                local d = { side = s.side, terrain = s.env.terrain,
                    front = {}, threats = {}, targets = {}, own = {}, farps = {} }
                if s.spawn then d.spawn = geo(s, lib, s.spawn, { name = s.spawn.name }) end

                if #s.front >= 2 then
                    for i, p in ipairs(lib.simplify(s.front, opt.FRONT_PTS)) do d.front[i] = geo(s, lib, p) end
                end
                for i, t in ipairs(lib.enemyThreats(s, opt.THREATS, opt)) do
                    d.threats[i] = geo(s, lib, t, { key = t.key, name = t.name, text = t.text, range = t.range,
                        rangeNm = lib.round(t.range / 1852, 0.1), alt = t.alt, altFt = math.floor(t.alt * FT + 0.5) })
                end

                local enemy, own = {}, {}
                for _, g in ipairs(s.groups) do
                    if not g.friendly and not g.ad then enemy[#enemy + 1] = g end   -- enemy AD is in threats
                    if g.friendly then own[#own + 1] = g end
                end
                for i, g in ipairs(lib.byScore(enemy, score, opt.TARGETS)) do
                    d.targets[i] = geo(s, lib, g, { class = g.class, type = g.type, count = g.count })
                end
                for i, g in ipairs(lib.byScore(own, score, opt.OWN)) do
                    d.own[i] = geo(s, lib, g, { class = g.class, type = g.type, count = g.count, ad = g.ad })
                end
                for i, f in ipairs(lib.byScore(s.farps, score)) do
                    d.farps[i] = geo(s, lib, f, { name = f.name, kind = f.kind, friendly = f.friendly })
                end

                local stats = { front = #d.front, threats = #d.threats, targets = #d.targets,
                    own = #d.own, farps = #d.farps, spawn = d.spawn and 1 or 0 }

                -- No final generation yet: nothing to write.
                return nil, stats

                --[[ Example of a final build for a hypothetical JSON cartridge of an external DTC tool
                     (route A from the spawn base along the front, route B with threats to avoid,
                     target points for A/G). Replace `return nil, stats` above with this and set the
                     output's format/dir/file to the tool's own location, e.g.
                     dir = "%USERPROFILE%\\Documents\\MyDTCTool\\F-15E", file = "SARMAT.json".

                local function wp(p, name)
                    return { name = name, lat = p.lat, lon = p.lon, elevation = p.elevFt }
                end
                local routeA, routeB, targets = {}, {}, {}
                if d.spawn then routeA[#routeA + 1] = wp(d.spawn, string.upper(d.spawn.name or "HOME")) end
                for i, p in ipairs(d.front) do routeA[#routeA + 1] = wp(p, "FLOT" .. i) end
                for i, t in ipairs(d.threats) do
                    local w = wp(t, t.text .. " " .. t.rangeNm .. "NM")
                    w.threatRadiusNm = t.rangeNm
                    routeB[i] = w
                end
                for i, t in ipairs(d.targets) do
                    local w = wp(t, lib.asciiUpper(t.class .. " " .. t.type, 12))
                    w.isTarget = true
                    targets[i] = w
                end
                return {
                    aircraft = "F-15E",
                    name     = lib.CARTRIDGE_NAME .. " " .. string.upper(d.side),
                    theater  = d.terrain,
                    routes   = { A = routeA, B = routeB },
                    targets  = targets,
                }, stats
                ]]
            end,
        },
    },
}
