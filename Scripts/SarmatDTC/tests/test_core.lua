-- Offline test of SarmatDTC_core.lua on recorded map data (tests/fixtures).
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

local L = core.LIMITS
local results = {}
for _, side in ipairs({ "blue", "red" }) do
    for _, quota in ipairs({ false, 15 }) do
        L.CTRLM_FARPS = quota or nil
        local list = core.build(status, units, side, env)
        local c = byType(list)
        local tag = side .. (quota and " quota=" .. quota or "")

        local ah = c["AH-64D_BLK_II"]
        local m1 = ah.NAV.Mission_1
        local ctrlm, tgt = m1.Points.CTRLM.POINTS, m1.Points.TGT.POINTS
        check(ah.terrain == "Syria", tag .. ": AH-64 terrain")
        check(#ctrlm > 0 and #ctrlm <= L.CTRLM, tag .. ": CTRLM count " .. #ctrlm)
        check(#tgt > 0 and #tgt <= L.TGT, tag .. ": TGT count " .. #tgt)
        check(ctrlm[1].num == 51 and ctrlm[#ctrlm].num == 50 + #ctrlm, tag .. ": CTRLM numbering 51..")
        for _, p in ipairs(ctrlm) do check(#p.text <= 3, tag .. ": CTRLM text too long " .. p.text) end
        for _, p in ipairs(tgt) do check(#p.note <= 40, tag .. ": TGT note too long") end
        check(countPrefix(tgt, "OWN") == 0, tag .. ": friendly unit in TGT")
        check(#m1.Lines > 0 and #m1.Lines <= L.AH64_LINES, tag .. ": AH-64 line count")
        for _, ln in ipairs(m1.Lines) do
            check(#ln.vertices >= 2 and #ln.vertices <= L.AH64_LINE_PTS, tag .. ": AH-64 line vertices")
        end
        check(chained(m1.Lines, "vertices"), tag .. ": AH-64 lines not chained")

        local farps = 0
        for _, p in ipairs(ctrlm) do if p.id == 68 then farps = farps + 1 end end
        if quota then check(farps > 0 and farps <= quota, tag .. ": FARPs with quota " .. farps) end

        local geo = c["F-16C_50"].MPD.GEO_LINES
        check(#geo >= 2 and #geo <= L.F16_PTS, tag .. ": F-16 points " .. #geo)
        check(geo[1].id == "GEO_LINES31", tag .. ": F-16 first id")

        local flot = c["FA-18C_hornet"].SA.FAOR_FLOT.FLOT
        check(#flot >= 1 and #flot <= L.F18_LINES, tag .. ": F/A-18 lines")
        for _, ln in ipairs(flot) do check(#ln.points >= 2 and #ln.points <= L.F18_LINE_PTS, tag .. ": F/A-18 points") end
        check(chained(flot, "points"), tag .. ": F/A-18 lines not chained")

        local plan = c["F-14BU"].NAV[1]
        local total = 0
        for _, ln in ipairs(plan.lines) do
            total = total + #ln.points
            check(#ln.points <= L.F14_LINE_PTS, tag .. ": F-14 points per line")
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
L.CTRLM_FARPS = nil

check(results.blue.tgt ~= results.red.tgt or results.blue.own ~= results.red.own, "sides produce identical output")

for tag, r in pairs(results) do
    print(string.format("%-14s CTRLM own=%d enemy=%d farps=%d  TGT=%d", tag, r.own, r.enemy, r.farps, r.tgt))
end
if failures > 0 then
    print(failures .. " check(s) failed")
    os.exit(1)
end
print("core: all checks passed")
