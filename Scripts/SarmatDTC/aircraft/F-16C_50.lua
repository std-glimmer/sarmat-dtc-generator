-- F-16C: front line as GEO LINES line 1 (points 31..41 of the 31..55 shared with lines 1-4),
-- airfields and FARPs of BOTH sides as DEST PTS (steerpoints 81..99), and enemy SAM threats as
-- THREAT PTS (steerpoints 56..70, with rings).
-- Format: CoreMods/aircraft/F-16C/DTC/MPD/{GEO_LINES,DEST,THREAT_PTS,CMDS}.lua, COLR/COLR_defs.lua;
-- MPD is imported only on matching terrain. mirror_* = false: use our data instead of the mission's.
-- opt.CMDS -> MPD.CMDS (countermeasure programs), opt.COLR -> top-level COLR (symbology colors);
-- both come from config.user.lua only, absent = the base DTC's / aircraft's own values are kept.

-- ED threat name -> index in THREAT_PTS_defs (MPD/THREAT_PTS_defs.lua, 1 = Custom)
local DEF_NUM = {
    ["Custom"] = 1, ["LPWS C-RAM"] = 3, ["SAM Avenger"] = 4, ["SAM Chaparrel"] = 5, ["SAM Hawk"] = 6,
    ["SAM HQ-7"] = 7, ["SAM NASAMS"] = 9, ["SAM Patriot"] = 10, ["SAM Rapier"] = 11, ["SAM Roland"] = 12,
    ["SAM SA-2 'Guideline'"] = 13, ["SAM SA-3 'Goa'"] = 14, ["SAM SA-5 'Gammon'"] = 15,
    ["SAM SA-6 'Gainful'"] = 16, ["SAM SA-8 'Gecko'"] = 17, ["SAM SA-9 'Gaskin'"] = 18,
    ["SAM SA-10 'Grumble'"] = 19, ["SAM SA-11 'Gadfly'"] = 20, ["SAM SA-13 'Gopher'"] = 21,
    ["SAM SA-15 'Gauntlet'"] = 22, ["SAM SA-19 'Grison'"] = 24, ["SAM SA-22 'Greyhound'"] = 25,
    ["SPAAA Gepard"] = 26, ["SPAAA Vulcan"] = 27, ["SPAAA ZSU-23-4"] = 28, ["SPAAA ZSU-57-2"] = 29,
}

local TYPE = "F-16C_50"

local CMDS_PROGRAMS = { "MAN1", "MAN2", "MAN3", "MAN4", "MAN5", "MAN6", "AUTO1", "AUTO2", "AUTO3", "BYP" }
local CMDS_TYPES = { "Chaff", "Flare", "Other1", "Other2" }

-- opt.CMDS = { bingo = { ChaffNum, FlaresNum, Other1Num, Other2Num, FDBK, REQCTR, BINGO },
--   delay = 0..10, MAN1..BYP = { chaffBQ, chaffBI, chaffSQ, chaffSI, flare.., other1.., other2.. } }
-- -> MPD.CMDS (CMDSBingoSettings / CMDSProgramSettings / CMDSPrograms.delayBetweenPrograms);
-- only the fields present are written (the base DTC keeps the rest). nil when CMDS is not configured.
local function cmdsNode(c)
    if type(c) ~= "table" then return nil end
    local function qty(v) return type(v) == "number" and math.max(0, math.min(99, math.floor(v + 0.5))) or nil end
    local function intv(v) return type(v) == "number" and math.max(0, math.min(10, v)) or nil end
    local out = {}
    local b = c.bingo
    if type(b) == "table" then
        local bingo = { ChaffNum = qty(b.ChaffNum), FlaresNum = qty(b.FlaresNum),
            Other1Num = qty(b.Other1Num), Other2Num = qty(b.Other2Num) }
        for _, k in ipairs({ "FDBK", "REQCTR", "BINGO" }) do
            if type(b[k]) == "boolean" then bingo[k] = b[k] end
        end
        if next(bingo) then out.CMDSBingoSettings = bingo end
    end
    local progs = {}
    for _, name in ipairs(CMDS_PROGRAMS) do
        local p = c[name]
        if type(p) == "table" then
            local prog = {}
            for _, t in ipairs(CMDS_TYPES) do
                local pre = string.lower(t)
                local s = { BurstQuantity = qty(p[pre .. "BQ"]), BurstInterval = intv(p[pre .. "BI"]),
                    SalvoQuantity = qty(p[pre .. "SQ"]), SalvoInterval = intv(p[pre .. "SI"]) }
                if next(s) then prog[t] = s end
            end
            if next(prog) then progs[name] = prog end
        end
    end
    if next(progs) then out.CMDSProgramSettings = progs end
    if type(c.delay) == "number" then
        out.CMDSPrograms = { delayBetweenPrograms = math.max(0, math.min(10, math.floor(c.delay + 0.5))) }
    end
    return next(out) and out or nil
end

-- Symbology color keys (CoreMods/aircraft/F-16C/DTC/COLR/COLR_defs.lua); values 1..8
-- (1 = White, 2 = Red, 3 = Green, 4 = Cyan, 5 = Yellow, 6 = Magenta, 7 = Blue, 8 = Gray).
local COLR_KEYS = {}
for _, k in ipairs({
    "MFDFCR_NonSymbolOrientedText", "MFDFCR_SOIBox", "MFDFCR_OFFLetters", "MFDFCR_OSBSelectionFlash",
    "MFDFCR_AntennaAzimuthElevationIndicators", "MFDFCR_AntennaAzimuthElevationScaleMarks",
    "MFDFCR_AzimuthScanLimitLines", "MFDFCR_RangeMarks", "MFDFCR_HorizonLine", "MFDFCR_AcquisitionCursor",
    "MFDFCR_AcquisitionCursorMaximumSearchAltitude", "MFDFCR_AcquisitionCursorMinimumSearchAltitudePositive",
    "MFDFCR_AcquisitionCursorMinimumSearchAltitudeNegative", "MFDFCR_ExpandBox",
    "MFDFCR_AllowableSteeringErrorCircle", "MFDFCR_AttackSteeringCue", "MFDFCR_AttackSteeringCueLimitCross",
    "MFDFCR_DynamicLaunchZone", "MFDFCR_TrackedTargetSymbol", "MFDFCR_SystemTrackTargetSymbol",
    "MFDFCR_TOICircle", "MFDFCR_AIM120KillX", "MFDFCR_FriendIFFReply", "MFDFCR_UnknownIFFReply",
    "HSDHAD_Ownship", "HSDHAD_RangeRingsCentered", "HSDHAD_RangeRingsDepressed", "HSDHAD_FCRSensorVolume",
    "HSDHAD_FCRAAGhostCursor", "HSDHAD_FCRAGGhostCursor", "HSDHAD_AcquisitionCursor",
    "HSDHAD_AircraftReferenceSymbol", "HSDHAD_AircraftReferenceSteeringBars", "HSDHAD_BullseyeLineOfSight",
    "HSDHAD_BullseyeSteeringSymbol", "HSDHAD_SelectedSteerpoint", "HSDHAD_ActiveNavigationRouteSteerpoints",
    "HSDHAD_ActiveNavigationRouteLine", "HSDHAD_InactiveNavigationRouteSteerpoints",
    "HSDHAD_InactiveNavigationRouteLine", "HSDHAD_GeographicLine1", "HSDHAD_GeographicLine2",
    "HSDHAD_GeographicLine3", "HSDHAD_GeographicLine4", "HSDHAD_OwnshipMarkpoint",
    "HSDHAD_PreplannedThreatOutside", "HSDHAD_PreplannedThreatInside", "HSDHAD_SEADTargetOfInterestBox",
    "MISC_TNDLWingmanSymbol", "MISC_TNDLMarkpoint", "MISC_TNDLSEADTargetFriendly",
    "MISC_TNDLSEADTargetNonfriendly", "MISC_SMDLWingman14", "MISC_SMDLWingman58", "MISC_SMDLWingman18outside",
    "MISC_SMDLWingmanAATargetOfInterest", "MISC_SMDLWingmanAATargetOfInterestoutside",
    "MISC_SMDLWingmanSEADTargetOfInterestoutside", "MISC_SMDLMarkpoint", "MISC_SMDLSEADTargetFriendly",
    "MISC_SMDLSEADTargetNonfriendly", "MISC_TGPAttitudeAdvisoryBox", "MISC_WPNAGM65MissileSymbology",
    "MISC_WPNAGM88DetectedThreatsStatusBoxHAS", "MISC_WPNAGM88LaunchStatusDividerLinePOS",
}) do COLR_KEYS[k] = true end

-- opt.COLR = { MFDFCR_NonSymbolOrientedText = 1..8, ... } -> top-level COLR; unknown keys are
-- ignored, only the keys present are written. nil when COLR is not configured.
local function colrNode(c)
    if type(c) ~= "table" then return nil end
    local out = {}
    for k, v in pairs(c) do
        if COLR_KEYS[k] and type(v) == "number" then
            out[k] = math.max(1, math.min(8, math.floor(v + 0.5)))
        end
    end
    return next(out) and out or nil
end

return {
    type = TYPE,
    base = { terrainPaths = { "MPD.NAV_PTS", "MPD.DEST", "MPD.GEO_LINES", "MPD.THREAT_PTS", "MPD.VIPVRP" } },
    options = {
        POINTS    = 11,     -- GEO line 1 (front): points 31..41, the rest of 31..55 stays free
        DEST_PTS  = 19,     -- DEST PTS 81..99: airfields/FARPs of both sides (0 = keep the base)
        THREATS   = 15,     -- THREAT PTS (0 = keep the mission's threats)
        MIN_RANGE = 6000,   -- [m] skip short-range AD (AAA, MANPADS, SA-9/13, Avenger)
        DEDUP_M   = 5000,   -- one ring per threat type within this distance
    },
    -- config.lua values outside these are clamped (GEO 31..55, THREAT PTS 56..70, DEST 81..99)
    limits = { POINTS = { 2, 11, int = true }, DEST_PTS = { 0, 19, int = true },
        THREATS = { 0, 15, int = true }, MIN_RANGE = { 0 }, DEDUP_M = { 0 } },

    build = function(s, lib, opt)
        -- GEO line 1 = the whole front line, fitted into steerpoints 31..41
        local pts = {}
        if #s.front >= 2 then
            for i, p in ipairs(lib.simplify(s.front, opt.POINTS)) do
                pts[i] = { alt = lib.elevation(s.env, p.x, p.z), id = "GEO_LINES" .. (30 + i), number = i,
                    L1 = true, L2 = false, L3 = false, L4 = false, note = "FRONT",
                    x = lib.round(p.x), y = lib.round(p.z) }
            end
        end

        -- DEST PTS 81..99: airfields and FARPs of both sides, split evenly red/blue,
        -- nearest to the front first; a short side yields its slots to the other
        local dest = {}
        if opt.DEST_PTS > 0 then
            local enemy, friendly = {}, {}
            local function pool(o)
                table.insert(o.friendly and friendly or enemy, o)
            end
            for _, o in ipairs(s.airfields) do pool(o) end
            for _, o in ipairs(s.farps) do pool(o) end
            enemy = lib.byFront(enemy, s.front)
            friendly = lib.byFront(friendly, s.front)
            local nE = math.min(math.ceil(opt.DEST_PTS / 2), #enemy)
            local nF = math.min(opt.DEST_PTS - nE, #friendly)
            nE = math.min(nE + (opt.DEST_PTS - nE - nF), #enemy)
            local merged = {}
            for i = 1, nE do merged[#merged + 1] = enemy[i] end
            for i = 1, nF do merged[#merged + 1] = friendly[i] end
            merged = lib.byFront(merged, s.front)
            for i, o in ipairs(merged) do
                dest[i] = { number = i, id = "DEST" .. (80 + i), x = lib.round(o.x), y = lib.round(o.z),
                    alt = lib.elevation(s.env, o.x, o.z), text = "D" .. (80 + i),
                    note = (o.friendly and "BLU: " or "RED: ") .. o.name }
            end
        end

        local threats = {}
        for i, t in ipairs(lib.enemyThreats(s, opt.THREATS, opt)) do
            threats[i] = { number = i, id = "THREAT_PTS" .. (55 + i), x = lib.round(t.x), y = lib.round(t.z),
                threatName = t.name, def_num = DEF_NUM[t.name] or 1, radius = t.range, alt = t.alt,
                elev = lib.elevation(s.env, t.x, t.z), text = t.text, ring = true }
        end

        local data = lib.cartridge(TYPE, s.env)
        data.MPD = { terrain = s.env.terrain, mirror_GEO_LINES = false, GEO_LINES = pts }
        if opt.DEST_PTS > 0 then
            data.MPD.mirror_DEST = false
            data.MPD.DEST = dest
        end
        if opt.THREATS > 0 then
            data.MPD.mirror_THREAT_PTS = false
            data.MPD.THREAT_PTS = threats
        end
        local cmds = cmdsNode(opt.CMDS)
        if cmds then data.MPD.CMDS = cmds end
        local colr = colrNode(opt.COLR)
        if colr then data.COLR = colr end
        return data, { points = #pts, dest = #dest, threats = #threats }
    end,
}
