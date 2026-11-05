-- The real LuaSec of the mod (lib\ssl.dll, ssl.lua, cacert.pem) in luae.exe: loaded from a Cyrillic
-- folder (UTF-8 path, like a Cyrillic user name: the DLL and CA file go through %ProgramData%) and a
-- TLS context made. With "online": one real download of status.json from the SARMAT map.
-- usage (from the DCS install folder): luae.exe test_tls.lua <Scripts\SarmatDTC folder> <temp folder> [online]
local scriptDir, temp, online = arg[1] .. '\\', arg[2] .. '\\', arg[3] == 'online'

local function loadFile(path)
    local f = assert(io.open(path, 'rb'))
    local text = f:read('*a')
    f:close()
    return assert(loadstring(text, '@' .. path))()
end
local function mkdir(dir) os.execute('mkdir "' .. dir .. '" 2>nul') end

local failures = 0
local function check(cond, msg)
    if not cond then
        failures = failures + 1
        print('FAIL: ' .. msg)
    end
end

local http = dofile(scriptDir .. 'SarmatDTC_http.lua')

local libDir = temp .. 'Пилот\\lib\\'
mkdir(libDir)
for _, name in ipairs({ 'ssl.dll', 'ssl.lua', 'cacert.pem' }) do
    local src = io.open(scriptDir .. 'lib\\' .. name, 'rb')
    check(src, 'lib\\' .. name .. ' missing')
    if src then
        local dst = assert(io.open(libDir .. name, 'wb'))
        dst:write(src:read('*a'))
        dst:close()
        src:close()
    end
end

print('-- LuaSocket + LuaSec from a Cyrillic folder')
local ok, tls, note = pcall(http.loadTls, libDir, 'test', loadFile, mkdir)
check(ok, 'loadTls: ' .. tostring(tls))
print('  ' .. tostring(note))
if ok then
    check(string.find(tostring(note), 'SarmatDTC\\ssl%-test%.dll'), 'DLL not loaded through %ProgramData%: ' .. tostring(note))
    check(tls.context ~= nil, 'no TLS context')
end

if ok and online then
    print('-- one real download')
    local socket = tls.socket
    local req = http.get('https://baikalprimestudio.com/data/status.json',
        { socket = socket, ssl = tls.ssl, context = tls.context })
    local started, steps, maxStep = socket.gettime(), 0, 0
    local done, value
    repeat
        local t = socket.gettime()
        done, value = req:step(t)
        maxStep = math.max(maxStep, socket.gettime() - t)
        steps = steps + 1
        if done == nil then socket.sleep(0.016) end   -- one frame
    until done ~= nil
    print(string.format('  %s, %d steps in %.1f s, longest step %d ms', done and (#value .. ' bytes') or value,
        steps, socket.gettime() - started, maxStep * 1000))
    check(done and string.match(value, '^%s*{'), 'download failed: ' .. tostring(value))
end

if failures > 0 then
    print(failures .. ' check(s) failed')
    os.exit(1)
end
print('tls: all checks passed')
