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
for _, t in ipairs({ "AH-64D_BLK_II", "F-16C_50", "FA-18C_hornet", "F-14BU" }) do
    check(mods[t] ~= nil, "module not found: " .. t)
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
do
    local ah = mods["AH-64D_BLK_II"]
    local function ctrlmOf(spawn, over)
        local e = {}
        for k, v in pairs(env) do e[k] = v end
        e.spawn = spawn
        local out = core.build(status, units, "red", e, { ah }, { ["AH-64D_BLK_II"] = over or {} })
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
            for k, v in pairs(o.stats) do
                check(type(v) == "number", label .. " stat " .. k .. " is not a number")
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
