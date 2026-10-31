-- Offline test of SarmatDTC_core.lua and aircraft modules on recorded map data (tests/fixtures).
-- usage: luae.exe test_core.lua <DCS install dir> <SarmatDTC dir> [out dir]
-- Run from run_tests.ps1. Writes the generated cartridges into [out dir] when given.
local dcsDir, scriptDir, outDir = arg[1], arg[2], arg[3]
local JSON = dofile(dcsDir .. "\\Scripts\\JSON.lua")
local core = dofile(scriptDir .. "\\SarmatDTC_core.lua")

local function read(p)
    local f = assert(io.open(p, "rb"), "cannot open " .. p)
    local s = f:read("*a")
    f:close()
    return s
end

local function listDir(dir)
    local files = {}
    local p = assert(io.popen('dir /b "' .. dir .. '"'))
    for line in p:lines() do files[#files + 1] = line end
    p:close()
    return files
end

local status = JSON:decode(read(scriptDir .. "\\tests\\fixtures\\status.json"))
local units = JSON:decode(read(scriptDir .. "\\tests\\fixtures\\units.json"))
local env = {
    terrain = "Syria",
    getHeight = function(x, z) return 123.4 end,
    toLatLon = function(x, z) return 35 + x / 111000, 39 + z / 91000 end,
}

local failures = 0
local function check(cond, msg)
    if not cond then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end

-- module discovery
local aircraftDir = scriptDir .. "\\aircraft\\"
local modules, loadErrors = core.loadAircraft(aircraftDir, listDir(aircraftDir))
check(#loadErrors == 0, "module load errors: " .. table.concat(loadErrors, "; "))
local mods = {}
for _, m in ipairs(modules) do
    check(mods[m.type] == nil, "duplicate module type " .. m.type)
    mods[m.type] = m
end
check(mods["_template"] == nil and mods["MyAircraft_DTC_type"] == nil, "template must not be loaded")
for _, t in ipairs({ "AH-64D_BLK_II", "F-16C_50", "FA-18C_hornet", "F-14BU", "F-15ESE" }) do
    check(mods[t] ~= nil, "module not found: " .. t)
end

-- the template is the API reference: it must stay a working module
do
    local tpl = dofile(aircraftDir .. "_template.lua")
    local out, errors, warns = core.build(status, units, "blue", env, { tpl },
        { [tpl.type] = { variant = "dense", outputs = { ["my-tool"] = { enabled = true } } } })
    check(#errors == 0 and #warns == 0 and #out == 2 and out[2].content.front[1].lat ~= nil,
        "template module: " .. table.concat(errors, "; ") .. table.concat(warns, "; "))
end

-- F-15E example: collects all data, writes nothing; the commented final build must stay valid Lua
do
    local f15 = mods["F-15ESE"]
    local e = {}
    for k, v in pairs(env) do e[k] = v end
    e.spawn = { x = 96000, z = 180000, name = "north" }
    local out, errors = core.build(status, units, "blue", e, { f15 }, {})
    check(#errors == 0 and #out == 1 and out[1].skip == true and out[1].content == nil, "F-15E: output must be skipped")
    local st = out[1].stats
    check(st.front >= 2 and st.front <= f15.options.FRONT_PTS, "F-15E: front " .. tostring(st.front))
    check(st.threats > 0 and st.threats <= f15.options.THREATS, "F-15E: threats " .. tostring(st.threats))
    check(st.targets > 0 and st.targets <= f15.options.TARGETS, "F-15E: targets " .. tostring(st.targets))
    check(st.own > 0 and st.farps > 0 and st.spawn == 1, "F-15E: own/farps/spawn")

    local src = read(aircraftDir .. "F-15ESE.lua")
    local example = string.match(src, "%-%-%[%[ Example.-\n(%s*local function wp.-)\n%s*%]%]")
    check(example ~= nil, "F-15E: commented build example not found")
    if example then
        local fn, err = loadstring("local d, lib, stats = ...\n" .. example)
        check(fn ~= nil, "F-15E: commented build example does not compile: " .. tostring(err))
    end
end

-- broken / disabled modules must not stop the others
do
    local broken = { type = "BROKEN", build = function() error("boom") end }
    local list = { broken, mods["F-16C_50"] }
    local out, errors = core.build(status, units, "blue", env, list, { ["F-16C_50"] = {} })
    check(#out == 1 and out[1].type == "F-16C_50", "broken module stopped the others")
    check(#errors == 1 and string.find(errors[1], "boom"), "broken module error not reported")
    out = core.build(status, units, "blue", env, list, { ["F-16C_50"] = { enabled = false } })
    check(#out == 0, "enabled = false ignored")
end

-- config.lua AIRCRAFT selection
do
    local sel, missing = core.selectModules(modules, { "F-16C_50", "NOPE", "AH-64D_BLK_II", "F-16C_50" })
    check(#sel == 2 and sel[1].type == "F-16C_50" and sel[2].type == "AH-64D_BLK_II", "selectModules order/filter")
    check(#missing == 1 and missing[1] == "NOPE", "selectModules missing")
    sel = core.selectModules(modules, nil)
    check(#sel == #modules, "selectModules without list must keep all")
    local cfg = dofile(scriptDir .. "\\config.lua")
    sel, missing = core.selectModules(modules, cfg.AIRCRAFT)
    check(#sel == #modules and #missing == 0, "shipped config.lua must list every module")
end

-- extra outputs (other DTC systems)
do
    local calls = {}
    local multi = {
        type = "MULTI",
        options = { N = 3 },
        build = function(s, lib, opt)
            local d = lib.cartridge("MULTI", s.env)
            d.FRONT = lib.simplify(s.front, opt.N)
            return d, { points = #d.FRONT }
        end,
        outputs = {
            { id = "txt", format = "text", dir = "Exports\\{side}", file = "{type}_{terrain}.txt",
              build = function(s, lib, opt, built)
                  calls[#calls + 1] = "txt"
                  return "points=" .. #built["dcs-dtc"].FRONT, { lines = 1 }
              end },
            { id = "luafile", format = "lua", file = "{type}.lua", enabled = false,
              build = function(s, lib, opt, built)
                  calls[#calls + 1] = "lua"
                  return { n = opt.N, txt = built.txt }
              end },
            { id = "bad", format = "json", file = "x.json", build = function() error("bad output") end },
        },
    }
    local out, errors = core.build(status, units, "red", env, { multi },
        { MULTI = { N = 4, outputs = { luafile = { enabled = true, dir = "C:\\Abs\\{side}" } } } })
    local byId = {}
    for _, o in ipairs(out) do byId[o.id] = o end
    check(#out == 3, "MULTI: expected 3 outputs, got " .. #out)
    check(out[1].id == core.NATIVE_OUTPUT and out[1].format == "dcs-dtc", "native output must be first")
    check(out[1].file == core.FILE_PREFIX .. "MULTI.dtc" and out[1].dir == "DTC", "native output path")
    check(out[1].content.type == "MULTI" and #out[1].content.FRONT == 4, "native content / option override")
    check(byId.txt and byId.txt.content == "points=4", "text output reuses native cartridge")
    check(byId.txt and byId.txt.dir == "Exports\\red" and byId.txt.file == "MULTI_Syria.txt", "placeholders")
    check(byId.luafile and byId.luafile.content.txt == "points=4" and byId.luafile.dir == "C:\\Abs\\red",
        "output override: enabled/dir")
    check(table.concat(calls, ",") == "txt,lua", "outputs must run in declared order")
    check(#errors == 1 and string.find(errors[1], "MULTI/bad"), "failing output must be reported only")
    out = core.build(status, units, "red", env, { multi }, { MULTI = { outputs = { ["dcs-dtc"] = { enabled = false } } } })
    check(#out == 1 and out[1].id == "txt" and out[1].content == "points=3",
        "disabled native output must still feed the other outputs")
end

-- variants: preset options, own build, config precedence, unknown name
do
    local var = {
        type = "VAR",
        options = { N = 3, K = 1 },
        build = function(s, lib, opt)
            local d = lib.cartridge("VAR", s.env)
            d.FRONT, d.ALGO, d.K, d.V = lib.simplify(s.front, opt.N), "main", opt.K, opt.variant
            return d, { points = #d.FRONT }
        end,
        variant = "base",
        variants = {
            base  = {},
            dense = { options = { N = 5, K = 2 } },
            other = { options = { N = 2 }, build = function(s, lib, opt)
                local d = lib.cartridge("VAR", s.env)
                d.ALGO, d.N = "other", opt.N
                return d, { n = opt.N }
            end },
        },
        outputs = {
            { id = "txt", format = "text", file = "VAR.txt",
              build = function(s, lib, opt, built) return built["dcs-dtc"].ALGO end },
        },
    }
    local function run(ov)
        local out, errors = core.build(status, units, "blue", env, { var }, { VAR = ov })
        return out[1] and out[1].content, out, errors
    end
    local c, out, errors = run({})
    check(#errors == 0 and c.ALGO == "main" and #c.FRONT == 3 and c.V == "base", "variant: default")
    check(out[1].variant == "base" and out[1].defaultVariant == true and out[2].content == "main", "variant: default flags")
    c, out = run({ variant = "dense", K = 7 })
    check(#c.FRONT == 5 and c.K == 7 and c.V == "dense", "variant: preset options / config precedence")
    check(out[1].variant == "dense" and out[1].defaultVariant == false, "variant: non-default flag")
    c, out = run({ variant = "other" })
    check(c.ALGO == "other" and c.N == 2 and out[2].content == "other", "variant: own build feeds outputs")
    c, out, errors = run({ variant = "nope" })
    check(c.ALGO == "main" and out[1].variant == "base", "variant: unknown name must fall back to default")
    check(#errors == 1 and string.find(errors[1], "unknown variant 'nope'", 1, true), "variant: unknown name not reported")
    local _, errs = core.build(status, units, "blue", env, { mods["F-16C_50"] }, { ["F-16C_50"] = { variant = "x" } })
    check(#errs == 1 and string.find(errs[1], "has no variants", 1, true), "variant on a module without variants")
end

-- every variant of every module builds a valid native cartridge
for _, mod in ipairs(modules) do
    for name in pairs(mod.variants or {}) do
        local label = mod.type .. "[" .. name .. "]"
        local out, errors = core.build(status, units, "blue", env, { mod }, { [mod.type] = { variant = name } })
        check(#errors == 0, label .. ": " .. table.concat(errors, "; "))
        for _, o in ipairs(out) do
            check(o.variant == name, label .. ": variant not reported")
            for k, v in pairs(o.stats) do check(type(v) == "number", label .. " stat " .. k .. " is not a number") end
            if o.format == "dcs-dtc" then
                check(o.content.type == mod.type and o.content.terrain == "Syria"
                    and o.content.name == core.CARTRIDGE_NAME, label .. ": header")
                check(pcall(JSON.encode, JSON, o.content), label .. " not serializable")
            end
        end
    end
end

-- option limits: config.lua values are clamped with a warning, module defaults need none
do
    for _, mod in ipairs(modules) do
        local names = { false }   -- false: module without variants
        if mod.variants then
            names = {}
            for k in pairs(mod.variants) do names[#names + 1] = k end
        end
        for _, name in ipairs(names) do
            local _, _, warns = core.build(status, units, "blue", env, { mod }, { [mod.type] = { variant = name or nil } })
            check(#warns == 0, mod.type .. ": defaults outside limits: " .. table.concat(warns, "; "))
        end
        for k, v in pairs(mod.options or {}) do
            if type(v) == "number" then check(mod.limits and mod.limits[k], mod.type .. ": option " .. k .. " has no limits") end
        end
    end
    local f16 = mods["F-16C_50"]
    local out, errors, warns = core.build(status, units, "blue", env, { f16 },
        { ["F-16C_50"] = { POINTS = 30, THREATS = "15", MIN_RANGE = -1 } })
    local mpd = out[1].content.MPD
    check(#errors == 0 and #warns == 3, "F-16 limits: " .. #warns .. " warning(s)")
    check(#mpd.GEO_LINES <= 25 and mpd.GEO_LINES[#mpd.GEO_LINES].id == "GEO_LINES" .. (30 + #mpd.GEO_LINES)
        and #mpd.THREAT_PTS == 15, "F-16 limits: values not clamped")
    check(string.find(table.concat(warns, "\n"), "F-16C_50: POINTS = 30 is out of range, using 25", 1, true),
        "F-16 limits: warning text " .. tostring(warns[1]))
    out, errors, warns = core.build(status, units, "blue", env, { mods["AH-64D_BLK_II"] },
        { ["AH-64D_BLK_II"] = { CTRLM = 60, TGT = 10.6 } })
    local pts = out[1].content.NAV.Mission_1.Points
    check(#warns == 2 and #pts.TGT.POINTS == 11 and pts.CTRLM.POINTS[#pts.CTRLM.POINTS].num <= 99,
        "AH-64 limits: CTRLM/TGT not clamped")
    out = core.build(status, units, "blue", env, { mods["F-14BU"] }, { ["F-14BU"] = { LINES = 4, LINE_PTS = 9 } })
    local total = 0
    for _, ln in ipairs(out[1].content.NAV[1].lines) do total = total + #ln.points end
    check(total <= 20, "F-14: 4 x 9 must be cut to 20 points, got " .. total)
end

-- module validation: variants
do
    local tmp = os.getenv("TEMP") .. "\\"
    local bad = {
        ['variant = "x", variants = { y = {} }'] = "missing default variant",
        ['variants = { y = {} }'] = "variants without default",
        ['variant = "y", variants = { y = { options = 1 } }'] = "variant options not a table",
    }
    for body, what in pairs(bad) do
        local name = "sdtc_badvar_" .. os.time() .. ".lua"
        local f = assert(io.open(tmp .. name, "wb"))
        f:write('return { type = "X", build = function() return {} end, ' .. body .. ' }')
        f:close()
        local ok, errs = core.loadAircraft(tmp, { name })
        os.remove(tmp .. name)
        check(#ok == 0 and #errs == 1, "must be rejected: " .. what)
    end
    -- outputs-only module: one variant with a native build and one without is inconsistent
    local name = "sdtc_badvar_" .. os.time() .. ".lua"
    local f = assert(io.open(tmp .. name, "wb"))
    f:write('return { type = "X", outputs = { { id = "o", file = "o", build = function() end } }, '
        .. 'variant = "a", variants = { a = {}, b = { build = function() return {} end } } }')
    f:close()
    local ok, errs = core.loadAircraft(tmp, { name })
    os.remove(tmp .. name)
    check(#ok == 0 and #errs == 1, "must be rejected: variant native build in only some variants")
end

-- module validation: unique output ids, required fields
do
    local tmp = os.getenv("TEMP") .. "\\"
    local name = "sdtc_badmod_" .. os.time() .. ".lua"
    local f = assert(io.open(tmp .. name, "wb"))
    f:write('return { type = "X", build = function() return {} end, outputs = { { id = "dcs-dtc", file = "a", build = function() end } } }')
    f:close()
    local ok, errs = core.loadAircraft(tmp, { name })
    os.remove(tmp .. name)
    check(#ok == 0 and #errs == 1, "duplicate native output id must be rejected")
end

-- Lua serializer round trip
do
    local value = { 1, "two", { x = 1.5, ["bad key"] = true }, name = "q\"uote\n", nested = { list = { 3, 4 } } }
    local back = assert(loadstring("return " .. core.toLua(value)))()
    check(back[1] == 1 and back[2] == "two" and back[3].x == 1.5 and back[3]["bad key"] == true
        and back.name == value.name and back.nested.list[2] == 4, "toLua round trip")
    local odd = assert(loadstring("return " .. core.toLua({ nan = 0 / 0, inf = 1 / 0, ninf = -1 / 0 })))()
    check(odd.nan ~= odd.nan and odd.inf == math.huge and odd.ninf == -math.huge, "toLua NaN/inf")
end

-- base cartridge (config.lua BASE_DTC)
do
    local function nativeOf(mod, base)
        local out, errors = core.build(status, units, "blue", env, { mods[mod] }, {}, { [mod] = base })
        check(#errors == 0, mod .. " with base: " .. table.concat(errors, "; "))
        return out[1].content, out[1]
    end

    -- merge rules
    local m = core.applyBase({ a = { 1, 2 }, b = { x = 1, y = 2 }, c = "base", d = { 1, 2, 3 } },
        { a = {}, b = { y = 3, z = 4 }, c = "ours", d = { 9 } })
    check(m.a[2] == 2, "empty table in ours must keep the base value")
    check(m.b.x == 1 and m.b.y == 3 and m.b.z == 4, "dictionaries must merge")
    check(m.c == "ours" and #m.d == 1 and m.d[1] == 9, "scalars and lists from ours must replace")
    local baseT = { keep = { 1 } }
    core.applyBase(baseT, { keep = { 2 } })
    check(baseT.keep[1] == 1, "applyBase must not modify the base")

    -- AH-64: everything we do not fill comes from the base
    local oldPts = {}
    for i = 1, 60 do oldPts[i] = { num = 50 + i, text = "OLD", x = 0, y = 0 } end
    local apacheBase = {
        type = "AH-64D_BLK_II", name = "MY", terrain = "Syria",
        Radios = { VHF = 121.5 }, Laser = { A = 1688 },
        NAV = { MissionFile = 2,
            Mission_1 = {
                Points = { WPTHZ = { isEnabled = true, POINTS = { { num = 1, text = "W01" } } },
                           CTRLM = { isEnabled = false, POINTS = oldPts } },
                Lines = { { note = "OLD LINE", type_num = 1, vertices = {} } },
                Routes = { { Name = "ALPHA", isEnabled = true } },
            },
            Mission_2 = { Lines = { { note = "M2" } } } },
    }
    local ah, entry = nativeOf("AH-64D_BLK_II", apacheBase)
    local m1 = ah.NAV.Mission_1
    check(entry.base and #entry.dropped == 0, "AH-64: base not reported as used")
    check(ah.Radios.VHF == 121.5 and ah.Laser.A == 1688, "AH-64: radios/laser not taken from base")
    check(ah.name == core.CARTRIDGE_NAME and ah.type == "AH-64D_BLK_II" and ah.NAV.MissionFile == 1, "AH-64: header")
    check(m1.Points.WPTHZ.isEnabled and m1.Points.WPTHZ.POINTS[1].text == "W01", "AH-64: base waypoints lost")
    check(m1.Routes[1].Name == "ALPHA" and ah.NAV.Mission_2.Lines[1].note == "M2", "AH-64: base routes/mission 2 lost")
    check(m1.Points.CTRLM.isEnabled and #m1.Points.CTRLM.POINTS <= 49, "AH-64: CTRLM must replace base points")
    for _, p in ipairs(m1.Points.CTRLM.POINTS) do check(p.text ~= "OLD", "AH-64: stale base CTRLM point") end
    check(m1.Lines[1].note == "FRONT", "AH-64: our lines must replace base lines")

    -- base from another map: map-bound sections are not used, the rest is
    apacheBase.terrain = "Caucasus"
    ah, entry = nativeOf("AH-64D_BLK_II", apacheBase)
    check(#entry.dropped == 1 and entry.dropped[1] == "NAV", "AH-64: NAV of another map must be dropped")
    check(ah.Radios.VHF == 121.5 and ah.terrain == "Syria", "AH-64: radios from another-map base")
    check(ah.NAV.Mission_2 == nil and ah.NAV.Mission_1.Points.WPTHZ == nil, "AH-64: another-map waypoints leaked")

    -- F-14: plan 1 ours, other plans from base (base without terrain id keeps navigation)
    local f14 = nativeOf("F-14BU", { type = "F-14BU", cartridge_name = "MY", CMDS = { X = 1 },
        NAV = { { name = "P1", waypoints = { { name = "WP" } } }, { name = "P2" } }, JDAM = { stations = {} } })
    check(f14.NAV[1].name == "FRONT" and #f14.NAV[1].waypoints == 0, "F-14: plan 1 must be ours")
    check(f14.NAV[2] and f14.NAV[2].name == "P2" and f14.JDAM and f14.CMDS.X == 1, "F-14: base plans/JDAM/CMDS lost")

    -- F/A-18: base FAOR kept, FLOT and threats ours
    local f18 = nativeOf("FA-18C_hornet", { type = "FA-18C_hornet", terrain = "Syria", COMM = { C = 1 },
        WYPT = { NAV_PTS = { { wypt_num = 1 } } },
        SA = { FAOR_FLOT = { FAOR = { { id = "FAOR_1" } }, FLOT = { { id = "OLD" } } }, MEZ_THRTS = { { id = "OLD" } } } })
    check(f18.COMM.C == 1 and f18.WYPT.NAV_PTS[1].wypt_num == 1, "F/A-18: base COMM/WYPT lost")
    check(f18.SA.FAOR_FLOT.FAOR[1].id == "FAOR_1" and f18.SA.FAOR_FLOT.FLOT[1].id == "FLOT_1", "F/A-18: FAOR/FLOT merge")
    check(f18.SA.MEZ_THRTS[1].id == "MEZ_THRTS_1", "F/A-18: base MEZ threats must be replaced")

    -- F-16: base nav points stay, our lines/threats replace
    local f16 = nativeOf("F-16C_50", { type = "F-16C_50", terrain = "Syria", COMM = { C = 1 },
        MPD = { NAV_PTS = { { id = "STPT1" } }, mirror_NAV_PTS = false, GEO_LINES = { { id = "OLD" } } } })
    check(f16.MPD.NAV_PTS[1].id == "STPT1" and f16.MPD.mirror_NAV_PTS == false and f16.COMM.C == 1, "F-16: base nav lost")
    check(f16.MPD.GEO_LINES[1].id == "GEO_LINES31", "F-16: base geo lines must be replaced")
end

-- threat catalogue must match the DCS editors' lists
do
    dofile(dcsDir .. "\\CoreMods\\aircraft\\F-16C\\DTC\\MPD\\THREAT_PTS_defs.lua")
    dofile(dcsDir .. "\\CoreMods\\aircraft\\FA-18C\\DTC\\SA\\MEZ_THRTS_defs.lua")
    local f16, f18 = {}, {}
    for _, d in ipairs(THREAT_PTS_defs) do f16[d.name] = true end
    for _, d in ipairs(MEZ_THRTS_defs) do f18[d.name] = true end
    for key, def in pairs(core.THREAT_DEFS) do
        if def.name ~= "Custom" then
            check(f16[def.name], "THREAT_DEFS[" .. key .. "] '" .. def.name .. "' not in F-16 THREAT_PTS_defs")
            check(f18[def.name], "THREAT_DEFS[" .. key .. "] '" .. def.name .. "' not in F/A-18 MEZ_THRTS_defs")
        end
        check(#def.text <= 3, "THREAT_DEFS[" .. key .. "] text longer than 3")
    end
    for _, ad in ipairs(core.AD_TYPES) do
        check(ad.key == "RADAR" or core.THREAT_DEFS[ad.key], "AD key " .. ad.key .. " has no THREAT_DEFS entry")
    end
end

-- AH-64 priority: around the spawn base, enemy first, still near the front
-- (short lists over the whole map, so that the order decides what gets in)
do
    local ah = mods["AH-64D_BLK_II"]
    local function ctrlmOf(spawn, over)
        local e = {}
        for k, v in pairs(env) do e[k] = v end
        e.spawn = spawn
        local o = { CTRLM = 20, TGT = 10, AO_DEPTH_M = 0 }
        for k, v in pairs(over or {}) do o[k] = v end
        local out = core.build(status, units, "red", e, { ah }, { ["AH-64D_BLK_II"] = o })
        return out[1].content.NAV.Mission_1.Points.CTRLM.POINTS, out[1].content.NAV.Mission_1.Points.TGT.POINTS, out[1].stats
    end
    local function meanDist(points, p0)
        local sum = 0
        for _, p in ipairs(points) do sum = sum + math.sqrt((p.x - p0.x) ^ 2 + (p.y - p0.z) ^ 2) end
        return sum / #points
    end
    local spawnN = { x = 96000, z = 180000, name = "north" }    -- near the front, east
    local spawnS = { x = 20000, z = -120000, name = "south" }   -- near the front, west
    local cN, tN = ctrlmOf(spawnN)
    local cS, tS = ctrlmOf(spawnS)
    local c0, t0 = ctrlmOf(nil)
    check(meanDist(cN, spawnN) < meanDist(c0, spawnN), "spawn north: CTRLM not closer to spawn")
    check(meanDist(cS, spawnS) < meanDist(c0, spawnS), "spawn south: CTRLM not closer to spawn")
    check(meanDist(tN, spawnN) < meanDist(t0, spawnN), "spawn north: TGT not closer to spawn")
    check(meanDist(cN, spawnN) < meanDist(cS, spawnN), "different spawns must give different selections")
    local _, _, sEnemy = ctrlmOf(spawnN)
    local _, _, sEven = ctrlmOf(spawnN, { ENEMY_FACTOR = 1 })
    check(sEnemy.enemy > sEven.enemy, "ENEMY_FACTOR must prefer enemy objects (" .. sEnemy.enemy .. " vs " .. sEven.enemy .. ")")
    local cW = ctrlmOf(spawnN, { SPAWN_WEIGHT = 0 })
    local same = #cW == #c0
    for i = 1, math.min(#cW, #c0) do same = same and cW[i].x == c0[i].x and cW[i].y == c0[i].y end
    check(same, "SPAWN_WEIGHT = 0 must ignore the spawn")
    print(string.format("spawn priority: mean dist to north spawn %.0f km (no spawn %.0f km), enemy %d vs %d without preference",
        meanDist(cN, spawnN) / 1000, meanDist(c0, spawnN) / 1000, sEnemy.enemy, sEven.enemy))
end

-- AH-64 TSD picture: area of operations, one symbol per position, own units only near the front,
-- readable free text, TGT safe set
do
    local ah = mods["AH-64D_BLK_II"]
    local o = ah.options
    local function d(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
    local function first(note) return string.match(note, "^(%S+)") end
    local ownAD = 0
    for _, case in ipairs({ { "blue", 103379, 83165, "Taftanaz" }, { "red", 8419, 75521, "Hama" } }) do
        local side, tag = case[1], "AH-64 " .. case[1] .. " " .. case[4]
        local e = {}
        for k, v in pairs(env) do e[k] = v end
        e.spawn = { x = case[2], z = case[3], name = case[4] }
        local function run(over)
            local out, errors = core.build(status, units, side, e, { ah }, { ["AH-64D_BLK_II"] = over or {} })
            check(#errors == 0, tag .. ": build errors " .. table.concat(errors, "; "))
            local pts = out[1].content.NAV.Mission_1.Points
            return pts.CTRLM.POINTS, pts.TGT.POINTS, out[1].stats
        end
        local ctrlm, tgt, st = run()
        local front = core.situation(status, units, side).front
        local function frontDist(p) return core.distToPolyline(p.x, p.y, front) end
        local spawn = { x = e.spawn.x, y = e.spawn.z }
        local reach = frontDist(spawn) + o.AO_DEPTH_M

        check(#ctrlm > 0 and #tgt > 0 and #tgt <= 25, tag .. ": point counts " .. #ctrlm .. "/" .. #tgt)
        check(st.merged > 0, tag .. ": nothing merged")
        local lastRank = 0
        for i, p in ipairs(ctrlm) do
            local farp, own = p.id == 68, string.sub(p.note, 1, 4) == "OWN "
            check(p.id ~= 12, tag .. ": own AD shown by default")
            check(d(p, spawn) <= reach + 1, tag .. ": CTRLM outside the area of operations " .. p.note)
            if farp then
                own = string.sub(p.text, 1, 1) == "F"
                check(string.match(p.text, "^[FE]%d%d$") ~= nil, tag .. ": FARP text " .. p.text)
                if own then
                    check(frontDist(p) <= frontDist(spawn) + 5000 + 1, tag .. ": own FARP behind the base " .. p.note)
                end
            else
                check(string.match(p.text, "^%d+$") ~= nil, tag .. ": unit text is not a vehicle count " .. p.text)
                if own then check(frontDist(p) <= o.OWN_FRONT_M + 1, tag .. ": own unit far from the front " .. p.note) end
                for j = 1, i - 1 do
                    local q = ctrlm[j]
                    if q.id ~= 68 and string.sub(q.note, 1, 4) == string.sub(p.note, 1, 4) then
                        check(d(p, q) >= o.CLUSTER_M - 1, tag .. ": unit symbols overlap " .. q.note .. " / " .. p.note)
                    end
                end
            end
            local rank = (farp and own) and 0 or (own and 2 or 1)
            check(rank >= lastRank, tag .. ": CTRLM order (own FARPs, enemy, own units) at " .. p.text)
            lastRank = rank
        end
        for i, p in ipairs(tgt) do
            check(d(p, spawn) - o.RING_CAP_M <= reach + 1, tag .. ": TGT outside the area of operations " .. p.note)
            for j = 1, i - 1 do
                local q = tgt[j]
                check(first(q.note) ~= first(p.note) or d(p, q) >= o.CLUSTER_M - 1, tag .. ": duplicate threat " .. p.note)
            end
        end

        local c0, t0, s0 = run({ CLUSTER_M = 0 })
        check(s0.merged == 0 and #c0 >= #ctrlm and #t0 >= #tgt, tag .. ": CLUSTER_M = 0 must not merge")
        local cAll = run({ AO_DEPTH_M = 0 })
        check(#cAll >= #ctrlm, tag .. ": AO_DEPTH_M = 0 must not filter")
        for _, p in ipairs(run({ OWN_AD = true })) do if p.id == 12 then ownAD = ownAD + 1 end end
        print(string.format("%s: CTRLM %d (no merging %d), TGT %d, merged %d", tag, #ctrlm, #c0, #tgt, st.merged))
    end
    check(ownAD > 0, "AH-64: OWN_AD = true shows no own air defence")
end

local function byType(list)
    local t = {}
    for _, c in ipairs(list) do
        if c.id == core.NATIVE_OUTPUT then t[c.type] = c.content end
    end
    return t
end

local function chained(lines, pointsKey)
    for i = 2, #lines do
        local prev, cur = lines[i - 1][pointsKey], lines[i][pointsKey]
        local a, b = prev[#prev], cur[1]
        if a.x ~= b.x or a.y ~= b.y then return false end
    end
    return true
end

local function countPrefix(points, prefix)
    local n = 0
    for _, p in ipairs(points) do
        if string.sub(p.note, 1, #prefix) == prefix then n = n + 1 end
    end
    return n
end

local results = {}
for _, side in ipairs({ "blue", "red" }) do
    for _, quota in ipairs({ false, 15 }) do
        local overrides = quota and { ["AH-64D_BLK_II"] = { CTRLM_FARPS = quota } } or {}
        local list, errors = core.build(status, units, side, env, modules, overrides)
        local tag = side .. (quota and " quota=" .. quota or "")
        check(#errors == 0, tag .. ": build errors: " .. table.concat(errors, "; "))
        check(#list == #modules, tag .. ": not every module produced a cartridge")

        -- generic checks for every module and output, including future ones
        local files = {}
        for _, o in ipairs(list) do
            local label = tag .. ": " .. o.type .. "/" .. o.id
            for k, v in pairs(o.stats) do
                check(type(v) == "number", label .. " stat " .. k .. " is not a number")
            end
            if not o.skip then
                local path = string.lower(o.dir .. "\\" .. o.file)
                check(not files[path], label .. " writes the same file as another output")
                files[path] = true
                check(string.find(o.file, "{") == nil and string.find(o.dir, "{") == nil, label .. " unexpanded placeholder")
                if o.format == "dcs-dtc" then
                    check(o.content.type == o.type, label .. " data.type mismatch")
                    check(o.content.terrain == "Syria", label .. " terrain")
                    check(o.content.name == core.CARTRIDGE_NAME, label .. " name")
                end
                if o.format == "text" then
                    check(type(o.content) == "string", label .. " text content must be a string")
                else
                    check(pcall(JSON.encode, JSON, o.content), label .. " not serializable")
                end
            end
        end

        local c = byType(list)
        local o = mods["AH-64D_BLK_II"].options
        local m1 = c["AH-64D_BLK_II"].NAV.Mission_1
        local ctrlm, tgt = m1.Points.CTRLM.POINTS, m1.Points.TGT.POINTS
        check(#ctrlm > 0 and #ctrlm <= o.CTRLM, tag .. ": CTRLM count " .. #ctrlm)
        check(#tgt > 0 and #tgt <= o.TGT, tag .. ": TGT count " .. #tgt)
        check(ctrlm[1].num == 51 and ctrlm[#ctrlm].num == 50 + #ctrlm, tag .. ": CTRLM numbering 51..")
        for _, p in ipairs(ctrlm) do check(#p.text <= 3, tag .. ": CTRLM text too long " .. p.text) end
        for _, p in ipairs(tgt) do check(#p.note <= 40, tag .. ": TGT note too long") end
        check(countPrefix(tgt, "OWN") == 0, tag .. ": friendly unit in TGT")
        check(#m1.Lines > 0 and #m1.Lines <= o.LINES, tag .. ": AH-64 line count")
        for _, ln in ipairs(m1.Lines) do
            check(#ln.vertices >= 2 and #ln.vertices <= o.LINE_PTS, tag .. ": AH-64 line vertices")
        end
        check(chained(m1.Lines, "vertices"), tag .. ": AH-64 lines not chained")
        local farps = 0
        for _, p in ipairs(ctrlm) do if p.id == 68 then farps = farps + 1 end end
        if quota then check(farps > 0 and farps <= quota, tag .. ": FARPs with quota " .. farps) end

        local geo = c["F-16C_50"].MPD.GEO_LINES
        check(#geo >= 2 and #geo <= mods["F-16C_50"].options.POINTS, tag .. ": F-16 points " .. #geo)
        check(geo[1].id == "GEO_LINES31", tag .. ": F-16 first id")

        -- SAM threats: F-16 THREAT PTS, F/A-18 MEZ THRTS
        local enemyAD = {}
        local sit = core.situation(status, units, side)
        for _, g in ipairs(sit.groups) do if g.ad and not g.friendly then enemyAD[#enemyAD + 1] = g end end
        for _, st in ipairs(sit.sites) do if not st.friendly then enemyAD[#enemyAD + 1] = st end end
        local function isEnemyAD(p)
            for _, a in ipairs(enemyAD) do
                if math.abs(a.x - p.x) < 1 and math.abs(a.z - p.y) < 1 then return true end
            end
            return false
        end
        local fopt = mods["F-16C_50"].options
        local mpd = c["F-16C_50"].MPD
        check(mpd.mirror_THREAT_PTS == false, tag .. ": F-16 mirror_THREAT_PTS")
        check(#mpd.THREAT_PTS > 0 and #mpd.THREAT_PTS <= fopt.THREATS, tag .. ": F-16 threats " .. #mpd.THREAT_PTS)
        for i, t in ipairs(mpd.THREAT_PTS) do
            check(t.id == "THREAT_PTS" .. (55 + i) and t.number == i, tag .. ": F-16 threat id/number")
            check(THREAT_PTS_defs[t.def_num].name == t.threatName, tag .. ": F-16 def_num " .. t.def_num .. " vs " .. t.threatName)
            check(t.radius >= fopt.MIN_RANGE and #t.text <= 3 and t.ring == true, tag .. ": F-16 threat fields")
            check(isEnemyAD(t), tag .. ": F-16 threat is not an enemy AD position")
            for j = 1, i - 1 do
                local o = mpd.THREAT_PTS[j]
                local d = math.sqrt((o.x - t.x) ^ 2 + (o.y - t.y) ^ 2)
                check(o.threatName ~= t.threatName or d >= fopt.DEDUP_M, tag .. ": F-16 duplicate ring " .. t.threatName)
            end
        end
        local hopt = mods["FA-18C_hornet"].options
        local sa = c["FA-18C_hornet"].SA
        check(sa.mirror_MEZ_THRTS == false, tag .. ": F/A-18 mirror_MEZ_THRTS")
        check(#sa.MEZ_THRTS > 0 and #sa.MEZ_THRTS <= hopt.THREATS, tag .. ": F/A-18 threats " .. #sa.MEZ_THRTS)
        check(#sa.MEZ_THRTS >= #mpd.THREAT_PTS, tag .. ": F/A-18 has fewer threats than F-16")
        for i, t in ipairs(sa.MEZ_THRTS) do
            check(t.id == "MEZ_THRTS_" .. i and t.num == i, tag .. ": F/A-18 MEZ id/num")
            check(t.threat_ring_radius >= hopt.MIN_RANGE / 1852 - 0.01 and t.threat_level == 1, tag .. ": F/A-18 MEZ fields")
            check(isEnemyAD(t), tag .. ": F/A-18 threat is not an enemy AD position")
        end
        results[tag .. "#threats"] = { f16 = #mpd.THREAT_PTS, f18 = #sa.MEZ_THRTS, first = mpd.THREAT_PTS[1].threatName }

        local fo = mods["FA-18C_hornet"].options
        local flot = c["FA-18C_hornet"].SA.FAOR_FLOT.FLOT
        check(#flot >= 1 and #flot <= fo.LINES, tag .. ": F/A-18 lines")
        for _, ln in ipairs(flot) do check(#ln.points >= 2 and #ln.points <= fo.LINE_PTS, tag .. ": F/A-18 points") end
        check(chained(flot, "points"), tag .. ": F/A-18 lines not chained")

        local plan = c["F-14BU"].NAV[1]
        local total = 0
        for _, ln in ipairs(plan.lines) do
            total = total + #ln.points
            check(#ln.points <= mods["F-14BU"].options.LINE_PTS, tag .. ": F-14 points per line")
        end
        check(total > 0 and total <= 20, tag .. ": F-14 total points " .. total)
        check(plan.lines[1].points[1].lat ~= 0, tag .. ": F-14 lat/lon filled")

        results[tag] = { own = countPrefix(ctrlm, "OWN"), enemy = countPrefix(ctrlm, "ENEMY"), tgt = #tgt, farps = farps }
        if outDir and not quota then
            for _, o in ipairs(list) do
                if o.id == core.NATIVE_OUTPUT then
                    local f = assert(io.open(outDir .. "\\SARMAT_" .. o.type .. "_" .. side .. ".dtc", "wb"))
                    f:write(JSON:encode_pretty({ data = o.content, name = "", type = o.type }))
                    f:close()
                end
            end
        end
    end
end

check(results.blue.tgt ~= results.red.tgt or results.blue.own ~= results.red.own, "sides produce identical output")

-- expected output: every module with default options must produce exactly the recorded files
-- (tests/fixtures/expected/<case>.lua). Refactoring must keep them; an intended change of the
-- output is recorded with run_tests.ps1 -UpdateExpected (env SDTC_UPDATE_EXPECTED=1).
do
    local update = os.getenv("SDTC_UPDATE_EXPECTED") == "1"
    local expectedDir = scriptDir .. "\\tests\\fixtures\\expected\\"
    if update then os.execute('mkdir "' .. expectedDir .. '" 2>nul') end
    local cases = {
        { "blue_nospawn", "blue" }, { "red_nospawn", "red" },
        { "blue_taftanaz", "blue", { x = 103379, z = 83165, name = "Taftanaz" } },
        { "red_hama", "red", { x = 8419, z = 75521, name = "Hama" } },
    }
    for _, case in ipairs(cases) do
        local e = {}
        for k, v in pairs(env) do e[k] = v end
        e.spawn = case[3]
        local list, errors = core.build(status, units, case[2], e, modules, {})
        check(#errors == 0, "expected " .. case[1] .. ": build errors " .. table.concat(errors, "; "))
        local snapshot = {}
        for i, o in ipairs(list) do
            snapshot[i] = { type = o.type, id = o.id, dir = o.dir, file = o.file, skip = o.skip,
                stats = o.stats, content = o.content }
        end
        local text = "return " .. core.toLua(snapshot) .. "\n"
        local path = expectedDir .. case[1] .. ".lua"
        if update then
            local f = assert(io.open(path, "wb"))
            f:write(text)
            f:close()
            print("expected output recorded: " .. path)
        else
            local f = io.open(path, "rb")
            local recorded = f and string.gsub(f:read("*a"), "\r", "")
            if f then f:close() end
            check(recorded ~= nil, "expected output missing: " .. path .. " (run_tests.ps1 -UpdateExpected)")
            if recorded and recorded ~= text then
                local ln = 1
                for i = 1, math.min(#recorded, #text) do
                    if string.byte(recorded, i) ~= string.byte(text, i) then break end
                    if string.byte(text, i) == 10 then ln = ln + 1 end
                end
                check(false, "output differs from " .. path .. " at line " .. ln)
            end
        end
    end
end

local tags = {}
for tag in pairs(results) do tags[#tags + 1] = tag end
table.sort(tags)
for _, tag in ipairs(tags) do
    local r = results[tag]
    if r.f16 then
        print(string.format("%-22s F-16 THREAT PTS=%d  F/A-18 MEZ=%d  first: %s", tag, r.f16, r.f18, r.first))
    else
        print(string.format("%-22s CTRLM own=%d enemy=%d farps=%d  TGT=%d", tag, r.own, r.enemy, r.farps, r.tgt))
    end
end
if failures > 0 then
    print(failures .. " check(s) failed")
    os.exit(1)
end
print("core: all checks passed (" .. #modules .. " aircraft modules)")
