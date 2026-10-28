-- Loads SarmatDTC (Saved Games/DCS.openbeta/Scripts/SarmatDTC) into the DCS GUI environment.
local ok, err = pcall(function()
    local lfs = require('lfs')
    dofile(lfs.writedir() .. 'Scripts\\SarmatDTC\\SarmatDTC.lua')
end)
if not ok then
    log.write('SARMAT.DTC', log.ERROR, 'failed to load: ' .. tostring(err))
end
