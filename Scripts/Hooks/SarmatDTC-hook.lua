-- Loads SarmatDTC (Saved Games/DCS.openbeta/Scripts/SarmatDTC) into the DCS GUI environment.
-- io.open + loadstring instead of dofile: DCS's Lua opens UTF-8 paths (lfs.writedir() of a Cyrillic
-- user name) with io.open, but not with dofile.
local ok, err = pcall(function()
    local lfs = require('lfs')
    local path = lfs.writedir() .. 'Scripts\\SarmatDTC\\SarmatDTC.lua'
    local f = assert(io.open(path, 'rb'))
    local text = f:read('*a')
    f:close()
    assert(loadstring(text, '@' .. path))()
end)
if not ok then
    log.write('SARMAT.DTC', log.ERROR, 'failed to load: ' .. tostring(err))
end
