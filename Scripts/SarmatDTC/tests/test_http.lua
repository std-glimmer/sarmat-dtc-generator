-- Tests of SarmatDTC_http.lua (non-blocking HTTPS GET) with a fake LuaSocket/LuaSec (fake_net.lua).
-- usage: luae.exe test_http.lua <Scripts\SarmatDTC folder>
local scriptDir = arg[1] .. '/'
local testDir = string.match(arg[0], '^(.*[\\/])') or ''
local http = dofile(scriptDir .. 'SarmatDTC_http.lua')
local fakeNet = dofile(testDir .. 'fake_net.lua')

local failures = 0
local function check(cond, msg)
    if not cond then
        failures = failures + 1
        print('FAIL: ' .. msg)
    end
end

local function response(status, body, headers)
    local h = headers or ('Content-Length: ' .. #body .. '\r\n')
    return 'HTTP/1.1 ' .. status .. ' X\r\nServer: fake\r\n' .. h .. '\r\n' .. body
end

local BODY = '{"theatre": "Syria", "front": [' .. string.rep('{"x": 1, "z": 2}, ', 3000) .. '{}]}'

-- Runs a request against `script` with 0.1 s per step. Returns done, value, net, steps, seconds.
local function run(url, script, opts)
    local socket, ssl, net = fakeNet(script)
    local o = { socket = socket, ssl = ssl, cafile = 'ca.pem' }
    for k, v in pairs(opts or {}) do o[k] = v end
    local req = http.get(url, o)
    local now, steps = 1000, 0
    while steps < 20000 do
        steps = steps + 1
        local done, value = req:step(now)
        if done ~= nil then
            local again, value2 = req:step(now + 1)
            check(again == done and value2 == value, url .. ': result changed after the end')
            check(net.opened == net.closed, url .. ': ' .. (net.opened - net.closed) .. ' connection(s) left open')
            return done, value, net, steps, now - 1000
        end
        now = now + 0.1
    end
    req:close()
    return nil, 'never finished', net, steps, now - 1000
end

local U = 'https://example.com/data/status.json'

print('-- parseUrl')
local h, p, path = http.parseUrl('https://Example.com/data/status.json')
check(h == 'example.com' and p == 443 and path == '/data/status.json', 'plain https url')
h, p, path = http.parseUrl('https://example.com:8443')
check(h == 'example.com' and p == 8443 and path == '/', 'port, empty path')
h, p, path = http.parseUrl('https://example.com?x=1#frag')
check(path == '/?x=1', 'query without path: ' .. tostring(path))
check(not http.parseUrl('http://example.com/'), 'http accepted')
check(not http.parseUrl('file:///C:/x'), 'file accepted')
check(not http.parseUrl('https://user@example.com/'), 'user info accepted')
check(not http.parseUrl('nonsense'), 'nonsense accepted')

print('-- dechunk')
check(http.dechunk('5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n') == 'hello world', 'chunked body')
check(http.dechunk('5\r\nhel') == nil, 'incomplete chunk accepted')
check(http.dechunk('zz\r\n') == nil, 'bad chunk size accepted')

print('-- certificate names')
local function cert(names) return { extensions = function() return { ['2.5.29.17'] = { dNSName = names } } end } end
check(http.certMatches(cert({ 'other.org', 'Example.com' }), 'example.com'), 'SAN match')
check(http.certMatches(cert({ '*.example.com' }), 'www.example.com'), 'wildcard match')
check(not http.certMatches(cert({ '*.example.com' }), 'example.com'), 'wildcard matched the bare domain')
check(not http.certMatches(cert({ '*.example.com' }), 'a.b.example.com'), 'wildcard matched two labels')
check(not http.certMatches(cert({ 'example.com.evil.org' }), 'example.com'), 'suffix match')
local cnCert = { extensions = function() return {} end,
    subject = function() return { { oid = '2.5.4.3', name = 'commonName', value = 'example.com' } } end }
check(http.certMatches(cnCert, 'example.com'), 'CN fallback without SAN')
check(not http.certMatches(nil, 'example.com'), 'no certificate matched')

print('-- ok: slow handshake, request and body in pieces')
local done, value, net = run(U, { respond = function() return response(200, BODY) end,
    handshakeWants = 3, piece = 700, stall = true, connect = 'progress' })
check(done == true and value == BODY, 'body: ' .. tostring(done) .. ' ' .. tostring(value and #value))
check(net.requests[1] == 'example.com/data/status.json', 'request: ' .. tostring(net.requests[1]))
check(net.selects >= 3, 'connect in progress not polled')
check(net.params and net.params.verify == 'peer' and net.params.cafile == 'ca.pem' and net.params.mode == 'client',
    'TLS parameters')

print('-- connect never completes')
done, value, net = run(U, { respond = function() return response(200, 'x') end, connect = 'slow' }, { connectTimeout = 1, retries = 0 })
check(done == false and value == 'connect timeout', 'slow connect: ' .. tostring(value))

print('-- connect refused, retried')
done, value, net = run(U, { connect = 'refused' }, { retryDelay = 0.5 })
check(done == false and value == 'cannot connect (connection refused)' and net.opened == 3,
    'refused: ' .. tostring(value) .. ', ' .. net.opened .. ' attempt(s)')

print('-- host not found')
done, value, net = run(U, { dns = false }, { retryDelay = 0.5 })
check(done == false and value == 'host not found' and net.opened == 0, 'dns: ' .. tostring(value))

print('-- body without Content-Length, ends with the connection')
done, value = run(U, { respond = function() return 'HTTP/1.1 200 OK\r\n\r\n' .. BODY end, piece = 5000 })
check(done == true and value == BODY, 'body until close')

print('-- chunked body')
done, value = run(U, { respond = function()
    return response(200, '4\r\n{"a"\r\n3\r\n: 1\r\n1\r\n}\r\n0\r\n\r\n', 'Transfer-Encoding: chunked\r\n')
end, piece = 3 })
check(done == true and value == '{"a": 1}', 'chunked: ' .. tostring(value))

print('-- HTTP errors: 404 at once, 503 retried')
done, value, net = run(U, { respond = function() return response(404, 'no') end })
check(done == false and value == 'HTTP 404' and net.opened == 1, '404: ' .. tostring(value) .. ', ' .. net.opened)
local n = 0
done, value, net = run(U, { respond = function()
    n = n + 1
    if n == 1 then return response(503, 'busy') end
    return response(200, BODY)
end })
check(done == true and value == BODY and net.opened == 2, '503 then 200: ' .. tostring(done) .. ' ' .. net.opened)
done, value, net = run(U, { respond = function() return response(500, 'err') end }, { retryDelay = 1 })
check(done == false and value == 'HTTP 500' and net.opened == 3, '500 three times: ' .. tostring(value) .. ' ' .. net.opened)

print('-- redirects: https followed, http refused, loops stopped')
done, value, net = run('https://example.com/old', { respond = function(path)
    if path == '/old' then return response(308, '', 'Location: https://cdn.example.net/data/status.json\r\nContent-Length: 0\r\n') end
    return response(200, BODY)
end })
check(done == true and value == BODY and net.requests[2] == 'cdn.example.net/data/status.json',
    'redirect to another https host: ' .. tostring(net.requests[2]))
done, value, net = run('https://example.com/old', { respond = function(path)
    if path == '/old' then return response(301, '', 'Location: /new\r\nContent-Length: 0\r\n') end
    return response(200, 'new')
end })
check(done == true and value == 'new' and net.requests[2] == 'example.com/new', 'relative redirect')
done, value = run(U, { respond = function() return response(302, '', 'Location: http://example.com/x\r\n') end })
check(done == false and value == 'redirect refused (http://example.com/x)', 'http redirect: ' .. tostring(value))
done, value, net = run(U, { respond = function() return response(302, '', 'Location: /loop\r\n') end })
check(done == false and value == 'too many redirects' and #net.requests == 4, 'redirect loop: ' .. tostring(value))

print('-- size limit: by Content-Length and while streaming')
done, value, net = run(U, { respond = function() return response(200, BODY) end }, { maxSize = 1000 })
check(done == false and value == 'file too big' and net.opened == 1, 'Content-Length over the limit: ' .. tostring(value))
done, value = run(U, { respond = function() return 'HTTP/1.1 200 OK\r\n\r\n' .. BODY end, piece = 300 }, { maxSize = 1000 })
check(done == false and value == 'file too big', 'streamed body over the limit: ' .. tostring(value))

print('-- truncated body, bad response')
done, value = run(U, { respond = function() return 'HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nshort' end }, { retryDelay = 0.5 })
check(done == false and value == 'connection closed early', 'truncated: ' .. tostring(value))
done, value, net = run(U, { respond = function() return 'garbage\r\n\r\n' end })
check(done == false and value == 'bad response' and net.opened == 1, 'not HTTP: ' .. tostring(value))

print('-- TLS: certificate problems are not retried')
done, value, net = run(U, { handshakeError = 'certificate verify failed' })
check(done == false and value == 'TLS handshake failed (certificate verify failed)' and net.opened == 1,
    'bad certificate: ' .. tostring(value) .. ', ' .. net.opened)
done, value, net = run(U, { certNames = { 'evil.org' } })
check(done == false and value == 'certificate is not for example.com' and net.opened == 1, 'wrong host: ' .. tostring(value))
done, value = run(U, { verified = false })
check(done == false and value == 'certificate not verified', 'unverified: ' .. tostring(value))
done, value, net = run(U, { handshakeError = 'closed' }, { retryDelay = 0.5 })
check(done == false and value == 'TLS handshake failed (closed)' and net.opened == 3, 'handshake reset retried')

print('-- timeout: retried until retryMaxTime')
local seconds
done, value, net, _, seconds = run(U, { respond = function() return nil end })
check(done == false and value == 'timeout' and net.opened == 2, 'timeout: ' .. tostring(value) .. ', ' .. net.opened .. ' attempt(s)')
check(seconds < 130, 'timeout took ' .. seconds .. ' s')

print('-- not https')
done, value, net = run('http://example.com/x', {})
check(done == false and value == 'not https: http://example.com/x' and net.opened == 0, 'http url: ' .. tostring(value))

print('-- close() cancels a running request')
local socket, ssl, net2 = fakeNet({ respond = function() return nil end })
local req = http.get(U, { socket = socket, ssl = ssl })
check(req:step(0) == nil and req:step(0.1) == nil, 'request finished without an answer')
req:close()
check(net2.opened == 1 and net2.closed == 1, 'cancelled request left a connection open')

print('-- an error inside a step ends the request, not the caller')
socket, ssl = fakeNet({})
ssl.wrap = function() error('boom') end
req = http.get(U, { socket = socket, ssl = ssl })
local okStep, d, v = pcall(req.step, req, 0)
check(okStep and d == false and string.find(tostring(v), '^internal error: .*boom'), 'internal error: ' .. tostring(v))

if failures > 0 then
    print(failures .. ' check(s) failed')
    os.exit(1)
end
print('http: all checks passed')
