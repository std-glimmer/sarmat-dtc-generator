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

local function byType(list)
    local t = {}
    for _, c in ipairs(list) do t[c.type] = c.data end
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

        -- generic checks for every module, including future ones
        for _, cart in ipairs(list) do
            check(cart.data.type == cart.type, tag .. ": " .. cart.type .. " data.type mismatch")
            check(cart.data.terrain == "Syria", tag .. ": " .. cart.type .. " terrain")
            check(cart.data.name == core.CARTRIDGE_NAME, tag .. ": " .. cart.type .. " name")
            check(pcall(JSON.encode, JSON, cart.data), tag .. ": " .. cart.type .. " not JSON-encodable")
            for k, v in pairs(cart.stats) do
                check(type(v) == "number", tag .. ": " .. cart.type .. " stat " .. k .. " is not a number")
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
            for _, cart in ipairs(list) do
                local f = assert(io.open(outDir .. "\\SARMAT_" .. cart.type .. "_" .. side .. ".dtc", "wb"))
                f:write(JSON:encode_pretty({ data = cart.data, name = "", type = cart.type }))
                f:close()
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
    print(string.format("%-14s CTRLM own=%d enemy=%d farps=%d  TGT=%d", tag, r.own, r.enemy, r.farps, r.tgt))
end
if failures > 0 then
    print(failures .. " check(s) failed")
    os.exit(1)
end
print("core: all checks passed (" .. #modules .. " aircraft modules)")
