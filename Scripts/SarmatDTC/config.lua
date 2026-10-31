-- SarmatDTC user settings. Re-read on every mission start (no DCS restart needed).
return {
    -- Cartridges are generated only for the aircraft listed here.
    -- Comment out (--) a line to skip that aircraft. Names = `type` of the files in aircraft/.
    AIRCRAFT = {
        "AH-64D_BLK_II",
        "F-16C_50",
        "FA-18C_hornet",
        "F-14BU",
        "F-15ESE",          -- example: prepares data only, writes no file yet (format not decided)
    },

    -- Base DCS cartridge per aircraft (DCS native .dtc only): every field the script does not fill
    -- (radios, CMDS, laser codes, waypoints, ...) is taken from it. File name in
    -- Saved Games\DCS.openbeta\DTC or an absolute path. Navigation data of a base file made on
    -- another map is not used. Must not be the generated SARMAT_<type>.dtc itself.
    BASE_DTC = {
        -- ["AH-64D_BLK_II"] = "AH-64D_BLK_II_DTC_SAR_3.dtc",
        -- ["F-16C_50"]      = "F-16C_50_DTC_PD.dtc",
        -- ["FA-18C_hornet"] = "FA-18C_hornet_DTC_PD_1.dtc",
        -- ["F-14BU"]        = "F-14BU_DTC_SAR_1.dtc",
    },

    -- Per-aircraft overrides of the module options (see `options` in aircraft/<type>.lua)
    -- and of its outputs (`outputs` = { [output id] = { enabled = ..., dir = ..., file = ... } };
    -- the native DCS cartridge has id "dcs-dtc").
    OPTIONS = {
        -- ["AH-64D_BLK_II"] = { CTRLM_FARPS = 15, SPAWN_WEIGHT = 0.5, ENEMY_FACTOR = 0.7 },
        -- ["AH-64D_BLK_II"] = { TGT = 50, AO_DEPTH_M = 0, CLUSTER_M = 0, OWN_FRONT_M = 0, OWN_AD = true }, -- whole map, every group
        -- ["F-16C_50"] = { THREATS = 15, MIN_RANGE = 6000 },          -- MIN_RANGE in metres
        -- ["FA-18C_hornet"] = { THREATS = 0 },                         -- 0 = threats from the mission
        -- ["F-14BU"] = { outputs = { ["dcs-dtc"] = { enabled = false } } },
    },
}
