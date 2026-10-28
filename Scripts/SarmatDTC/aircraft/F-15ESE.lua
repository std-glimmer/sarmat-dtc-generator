-- F-15E Strike Eagle (DCS type "F-15ESE"). EXAMPLE / PREPARATION ONLY.
--
-- DCS has no native DTC editor for this module (no CoreMods/aircraft/F-15E/DTC), and the target
-- cartridge format (another DTC system) is not decided yet. `prepare` collects everything the
-- script knows in a ready-to-use form; the output builds it and writes nothing.
-- To finish: pick the target system, convert `prepare(...)` into its format inside the output's
-- build and return that content (set format/dir/file, see aircraft/_template.lua).
--
-- What the prepared data gives for the F-15E:
--   spawn     own start base           -> WP 1 / home steerpoint of route A, landing alternate
--   front     front line, n points     -> a dedicated route (e.g. route B) drawn as the FLOT on the TSD/MPD
--   threats   enemy SAM rings          -> steerpoints/markpoints to avoid, with ED threat name, radius,
--                                         altitude; ring radius can drive route planning (stand-off)
--   targets   enemy ground groups      -> target points ("1." style) / aim points for A/G attack, with
--                                         class (armor/mech/arty/inf), lead type and count
--   own       own ground groups        -> friendly positions (no-strike / CAS reference points)
--   farps     own/enemy FARPs and FOBs -> alternates (own), targets (enemy)
-- Every point has DCS x/z, decimal lat/lon (WGS84, from the terrain) and elevation in metres
-- and feet. Lists are ordered by priority: near the front and near own spawn base first.
-- Missing so far (add to SarmatDTC.lua env if a format needs it): MGRS (Terrain.GetMGRScoordinates),
-- radio presets, TACAN, airfield runways.

local FT = 3.28084

-- Point with all coordinate forms.
local function geo(s, lib, p)
    local lat, lon = lib.latLon(s.env, p.x, p.z)
    local elev = lib.elevation(s.env, p.x, p.z)
    return { x = lib.round(p.x), z = lib.round(p.z), lat = lat, lon = lon,
        elev = elev, elevFt = math.floor(elev * FT + 0.5) }
end

local function withGeo(s, lib, p, fields)
    local g = geo(s, lib, p)
    for k, v in pairs(fields) do g[k] = v end
    return g
end

local M = {
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
}

-- Returns {
--   side, terrain,
--   spawn   = geo + { name } | nil,
--   front   = { geo, ... },
--   threats = { geo + { key, name, text, range, rangeNm, alt, altFt }, ... },
--   targets = { geo + { class, type, count }, ... },
--   own     = { geo + { class, type, count, ad }, ... },
--   farps   = { geo + { name, kind, friendly }, ... },
-- }
function M.prepare(s, lib, opt)
    local function score(p)
        local v = lib.distToPolyline(p.x, p.z, s.front)
        if s.spawn then v = v + opt.SPAWN_WEIGHT * lib.dist(p, s.spawn) end
        return v
    end

    local d = { side = s.side, terrain = s.env.terrain, front = {}, threats = {}, targets = {}, own = {}, farps = {} }
    if s.spawn then d.spawn = withGeo(s, lib, s.spawn, { name = s.spawn.name }) end

    if #s.front >= 2 then
        for i, p in ipairs(lib.simplify(s.front, opt.FRONT_PTS)) do d.front[i] = geo(s, lib, p) end
    end
    for i, t in ipairs(lib.enemyThreats(s, opt.THREATS, opt)) do
        d.threats[i] = withGeo(s, lib, t, { key = t.key, name = t.name, text = t.text, range = t.range,
            rangeNm = lib.round(t.range / 1852, 0.1), alt = t.alt, altFt = math.floor(t.alt * FT + 0.5) })
    end

    local enemy, own = {}, {}
    for _, g in ipairs(s.groups) do
        if not g.friendly and not g.ad then enemy[#enemy + 1] = g end   -- enemy AD is in threats
        if g.friendly then own[#own + 1] = g end
    end
    for i, g in ipairs(lib.byScore(enemy, score, opt.TARGETS)) do
        d.targets[i] = withGeo(s, lib, g, { class = g.class, type = g.type, count = g.count })
    end
    for i, g in ipairs(lib.byScore(own, score, opt.OWN)) do
        d.own[i] = withGeo(s, lib, g, { class = g.class, type = g.type, count = g.count, ad = g.ad })
    end
    for i, f in ipairs(lib.byScore(s.farps, score)) do
        d.farps[i] = withGeo(s, lib, f, { name = f.name, kind = f.kind, friendly = f.friendly })
    end
    return d
end

M.outputs = {
    {
        id     = "prepared",
        format = "json",                 -- placeholder: final format unknown
        file   = "SARMAT_{type}.json",   -- placeholder
        build  = function(s, lib, opt)
            local d = M.prepare(s, lib, opt)
            -- No final generation yet: convert `d` to the target DTC format here and return it.
            return nil, { front = #d.front, threats = #d.threats, targets = #d.targets,
                own = #d.own, farps = #d.farps, spawn = d.spawn and 1 or 0 }
        end,
    },
}

return M
