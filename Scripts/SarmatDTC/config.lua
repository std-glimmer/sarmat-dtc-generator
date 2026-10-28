-- SarmatDTC user settings. Re-read on every mission start (no DCS restart needed).
return {
    -- Cartridges are generated only for the aircraft listed here.
    -- Comment out (--) a line to skip that aircraft. Names = `type` of the files in aircraft/.
    AIRCRAFT = {
        "AH-64D_BLK_II",
        "F-16C_50",
        "FA-18C_hornet",
        "F-14BU",
    },

    -- Per-aircraft overrides of the module options (see `options` in aircraft/<type>.lua)
    -- and of its outputs (`outputs` = { [output id] = { enabled = ..., dir = ..., file = ... } };
    -- the native DCS cartridge has id "dcs-dtc").
    OPTIONS = {
        -- ["AH-64D_BLK_II"] = { CTRLM_FARPS = 15, SPAWN_WEIGHT = 0.5, ENEMY_FACTOR = 0.7 },
        -- ["F-16C_50"] = { outputs = { ["dcs-dtc"] = { enabled = false } } },
    },
}
