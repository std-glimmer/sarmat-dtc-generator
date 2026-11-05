-- SarmatDTC_http: non-blocking HTTPS GET for the DCS GUI thread (LuaSocket + LuaSec), no curl.
-- No DCS dependencies: the socket and ssl modules are passed in (tests use fakes).
--
--   local req = http.get('https://host/path', { socket = socket, ssl = ssl, context = ctx })
--   each frame: local done, value = req:step(now)   -- nil: running; true, body; false, reason
--   req:close() cancels it.
--
-- Every socket call has a zero timeout, so a step never waits for the network. The one blocking
-- call is the DNS lookup at the start of an attempt (socket.dns.toip, usually a few ms).
-- Same protection as the old curl flags: HTTPS only (also for redirects), peer certificate and host
-- name are verified, at most maxSize bytes (the JSON is parsed on the GUI thread).

local M = {}

M.DEFAULTS = {
    connectTimeout = 15,                -- s, TCP connect
    timeout        = 40,                -- s, a whole attempt
    retries        = 2,                 -- repeated attempts after a transient error
    retryDelay     = 2,                 -- s, doubled for each further retry
    retryMaxTime   = 60,                -- s since the first attempt: no retry starts later
    maxSize        = 5 * 1024 * 1024,   -- bytes of the body
    maxRedirects   = 3,
    userAgent      = 'SarmatDTC',
    blockSize      = 16384,
    readsPerStep   = 64,                -- receive calls per step: at most ~1 MB per frame
}

-- TLS settings of ssl.newcontext; cafile: PEM bundle (LuaSec does not use the Windows store).
function M.tlsParams(cafile)
    return { mode = 'client', protocol = 'any', verify = 'peer', options = 'all', cafile = cafile }
end

-- "https://host[:port]/path" -> host, port, path; nil, reason for anything else.
function M.parseUrl(url)
    local scheme, rest = string.match(tostring(url), '^(%a[%w+.-]*)://(.*)$')
    if not scheme then return nil, 'bad url ' .. tostring(url) end
    if string.lower(scheme) ~= 'https' then return nil, 'not https: ' .. tostring(url) end
    local authority, path = string.match(rest, '^([^/?#]*)(.*)$')
    local host, port = string.match(authority, '^([%w%.%-]+):(%d+)$')
    if not host then host = string.match(authority, '^([%w%.%-]+)$') end
    if not host or host == '' then return nil, 'bad host in ' .. tostring(url) end
    path = string.gsub(path, '#.*$', '')
    if path == '' then path = '/' elseif string.sub(path, 1, 1) == '?' then path = '/' .. path end
    return string.lower(host), tonumber(port) or 443, path
end

-- RFC 6125 matching: exact, or a wildcard as the whole leftmost label ("*.example.com").
local function nameMatches(pattern, host)
    pattern = string.lower(tostring(pattern))
    if pattern == host then return true end
    local suffix = string.match(pattern, '^%*(%.[^%*]+%.[^%*]+)$')
    if not suffix then return false end
    local first, tail = string.match(host, '^([^%.]+)(%..+)$')
    return first ~= nil and tail == suffix
end

-- Does the LuaSec x509 certificate name `host`? Subject alternative names, else the subject CN.
function M.certMatches(cert, host)
    if not cert then return false end
    local okE, ext = pcall(function() return cert:extensions() end)
    local san = okE and type(ext) == 'table' and ext['2.5.29.17']
    local names = type(san) == 'table' and san.dNSName
    if type(names) == 'table' and #names > 0 then
        for _, n in ipairs(names) do
            if nameMatches(n, host) then return true end
        end
        return false
    end
    local okS, subject = pcall(function() return cert:subject() end)
    for _, e in ipairs(okS and type(subject) == 'table' and subject or {}) do
        if (e.name == 'commonName' or e.oid == '2.5.4.3') and nameMatches(e.value, host) then return true end
    end
    return false
end

-- Body of a "Transfer-Encoding: chunked" response, nil if malformed or incomplete.
function M.dechunk(s)
    local out, pos = {}, 1
    while true do
        local eol = string.find(s, '\r\n', pos, true)
        if not eol then return nil end
        local size = tonumber(string.match(string.sub(s, pos, eol - 1), '^%s*(%x+)') or '', 16)
        if not size then return nil end
        if size == 0 then return table.concat(out) end
        local from = eol + 2
        local to = from + size - 1
        if to > #s then return nil end
        out[#out + 1] = string.sub(s, from, to)
        pos = to + 3   -- data, CRLF
    end
end

local WAIT = { wantread = true, wantwrite = true, timeout = true }

local Req = {}
Req.__index = Req

function M.get(url, opts)
    local o = {}
    for k, v in pairs(M.DEFAULTS) do o[k] = v end
    for k, v in pairs(opts or {}) do o[k] = v end
    return setmetatable({ url = url, opt = o, attempt = 0, redirects = 0, phase = 'wait', wakeAt = 0 }, Req)
end

function Req:close()
    local c = self.conn or self.tcp
    if c then pcall(c.close, c) end
    self.conn, self.tcp = nil, nil
end

function Req:finish(ok, value)
    self:close()
    self.phase = 'done'
    self.ok, self.value = ok, value
end

-- Transient errors are retried while attempts and retryMaxTime allow, the rest end the request.
function Req:fail(now, reason, final)
    self:close()
    local o = self.opt
    local delay = o.retryDelay * 2 ^ (self.attempt - 1)
    if final or self.attempt > o.retries or now + delay - self.first > o.retryMaxTime then
        return self:finish(false, reason)
    end
    self.lastError = reason
    self.phase, self.wakeAt = 'wait', now + delay
end

function Req:start(now)
    local o = self.opt
    local host, port, path = M.parseUrl(self.url)
    if not host then return self:finish(false, port) end
    self.host, self.port, self.path = host, port, path
    self.attempt = self.attempt + 1
    self.started = now
    self.head, self.status, self.headers = '', nil, nil
    self.body, self.size = {}, 0
    self.out = 'GET ' .. path .. ' HTTP/1.1\r\nHost: ' .. host .. (port ~= 443 and (':' .. port) or '')
        .. '\r\nUser-Agent: ' .. o.userAgent .. '\r\nAccept: application/json\r\nConnection: close\r\n\r\n'
    self.sent = 0
    local ip = o.socket.dns.toip(host)
    if not ip then return self:fail(now, 'host not found') end
    self.ip = ip
    local tcp, errT = o.socket.tcp()
    if not tcp then return self:fail(now, 'no socket (' .. tostring(errT) .. ')') end
    self.tcp = tcp
    tcp:settimeout(0)
    local ok, err = tcp:connect(ip, port)
    if ok then
        self.phase = 'tls'
    elseif WAIT[err] or string.find(tostring(err), 'in progress', 1, true) then
        self.phase = 'connect'
    else
        self:fail(now, 'cannot connect (' .. tostring(err) .. ')')
    end
end

function Req:connect(now)
    if now - self.started > self.opt.connectTimeout then return self:fail(now, 'connect timeout') end
    local _, writable = self.opt.socket.select(nil, { self.tcp }, 0)
    if not (writable and (writable[self.tcp] or writable[1])) then return end
    if self.tcp:getpeername() then
        self.phase = 'tls'
    else
        local _, err = self.tcp:connect(self.ip, self.port)   -- names the error of the failed connect
        self:fail(now, 'cannot connect (' .. tostring(err) .. ')')
    end
end

function Req:tls(now)
    local o = self.opt
    if not o.context then
        local ctx, err = o.ssl.newcontext(M.tlsParams(o.cafile))
        if not ctx then return self:finish(false, 'TLS setup failed (' .. tostring(err) .. ')') end
        o.context = ctx   -- reused by the retries
    end
    local conn, err = o.ssl.wrap(self.tcp, o.context)
    if not conn then return self:finish(false, 'TLS setup failed (' .. tostring(err) .. ')') end
    self.tcp, self.conn = nil, conn   -- the connection owns the socket now
    conn:settimeout(0)
    conn:sni(self.host)
    self.phase = 'handshake'
end

function Req:handshake(now)
    local ok, err = self.conn:dohandshake()
    if not ok then
        if WAIT[err] then return end
        -- a certificate problem stays the same on the next attempt
        return self:fail(now, 'TLS handshake failed (' .. tostring(err) .. ')', string.find(tostring(err), 'certificate', 1, true))
    end
    if not self.conn:getpeerverification() then
        return self:finish(false, 'certificate not verified')
    end
    if not M.certMatches(self.conn:getpeercertificate(), self.host) then
        return self:finish(false, 'certificate is not for ' .. self.host)
    end
    self.phase = 'send'
end

function Req:send(now)
    local last, err, partial = self.conn:send(self.out, self.sent + 1)
    self.sent = last or partial or self.sent
    if self.sent >= #self.out then
        self.phase = 'receive'
    elseif err and not WAIT[err] then
        self:fail(now, 'send failed (' .. tostring(err) .. ')')
    end
end

function Req:addBody(now, s)
    if s == '' then return end
    self.size = self.size + #s
    if self.size > self.opt.maxSize then return self:finish(false, 'file too big') end
    self.body[#self.body + 1] = s
    if self.length and self.size >= self.length and not self.chunked then self:complete(now) end
end

-- Status line and headers; then 200 goes on with the body, redirects and errors end this attempt.
function Req:parseHead(now)
    local eoh, last = string.find(self.head, '\r?\n\r?\n')
    if not eoh then
        if #self.head > 65536 then self:fail(now, 'bad response', true) end
        return
    end
    local head, rest = string.sub(self.head, 1, eoh - 1), string.sub(self.head, last + 1)
    self.head = nil
    local status = tonumber(string.match(head, '^HTTP/%d%.%d (%d%d%d)') or '')
    if not status then return self:fail(now, 'bad response', true) end
    local headers = {}
    for k, v in string.gmatch(head, '\n([^:\r\n]+):[ \t]*([^\r\n]*)') do headers[string.lower(k)] = v end
    self.status, self.headers = status, headers
    if status >= 300 and status < 400 and headers.location then
        return self:redirect(now, headers.location)
    end
    if status ~= 200 then
        local transient = status == 408 or status == 429 or status >= 500
        return self:fail(now, 'HTTP ' .. status, not transient)
    end
    self.chunked = string.find(string.lower(headers['transfer-encoding'] or ''), 'chunked', 1, true) ~= nil
    self.length = tonumber(headers['content-length'] or '')
    if self.length and self.length > self.opt.maxSize then return self:finish(false, 'file too big') end
    self:addBody(now, rest)
end

function Req:redirect(now, location)
    self:close()
    if self.redirects >= self.opt.maxRedirects then return self:finish(false, 'too many redirects') end
    if string.sub(location, 1, 1) == '/' then
        location = 'https://' .. self.host .. (self.port ~= 443 and (':' .. self.port) or '') .. location
    end
    local host = M.parseUrl(location)
    if not host then return self:finish(false, 'redirect refused (' .. location .. ')') end
    self.redirects = self.redirects + 1
    self.url, self.attempt, self.first = location, 0, now
    self.phase, self.wakeAt = 'wait', now
end

function Req:complete(now)
    local body = table.concat(self.body)
    if self.chunked then
        body = M.dechunk(body)
        if not body then return self:fail(now, 'bad chunked body') end
    elseif self.length and #body ~= self.length then
        return self:fail(now, 'connection closed early')
    end
    self:finish(true, body)
end

function Req:receive(now)
    for _ = 1, self.opt.readsPerStep do
        local data, err, partial = self.conn:receive(self.opt.blockSize)
        local chunk = data or partial
        if chunk and chunk ~= '' then
            if self.head then
                self.head = self.head .. chunk
                self:parseHead(now)
            else
                self:addBody(now, chunk)
            end
            if self.phase ~= 'receive' then return end
        end
        -- many servers close without a TLS close_notify ("unexpected eof"): complete() checks the length
        if err == 'closed' or string.find(tostring(err), 'unexpected eof', 1, true) then
            if self.head then return self:fail(now, 'connection closed early') end
            return self:complete(now)
        elseif err and not WAIT[err] then
            return self:fail(now, 'receive failed (' .. tostring(err) .. ')')
        elseif err then
            return
        end
    end
end

local PHASES = { connect = Req.connect, tls = Req.tls, handshake = Req.handshake, send = Req.send, receive = Req.receive }

function Req:advance(now)
    -- several phases may complete in one step (a fast or already answered connection)
    for _ = 1, 8 do
        local before = self.phase
        if before == 'done' then return end
        if before == 'wait' then
            if now < self.wakeAt then return end
            self:start(now)
        else
            if now - self.started > self.opt.timeout then return self:fail(now, 'timeout') end
            PHASES[before](self, now)
        end
        if self.phase == before then return end
    end
end

-- nil while running; true, body; false, reason. Errors inside end the request, never the caller.
function Req:step(now)
    if self.phase ~= 'done' then
        self.first = self.first or now
        local ok, err = pcall(self.advance, self, now)
        if not ok then self:finish(false, 'internal error: ' .. tostring(err)) end
    end
    if self.phase == 'done' then return self.ok, self.value end
    return nil
end

------------------------------------------------------------------------------
-- loading LuaSocket and LuaSec
------------------------------------------------------------------------------

local function readAll(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('*a')
    f:close()
    return s
end

local function isAscii(s)
    return not string.find(s, '[\128-\255]')
end

-- LoadLibrary and OpenSSL take ANSI paths, a UTF-8 one (Cyrillic user name) fails. Such a file is
-- copied (io.open understands UTF-8) to %ProgramData%\SarmatDTC\<name> and used from there.
function M.ansiPath(path, name, mkdir)
    if isAscii(path) then return path end
    local root = os.getenv('ProgramData') or os.getenv('PUBLIC')
    if not root or not isAscii(root) then return path end
    local data = readAll(path)
    if not data then return path end
    local dir = root .. '\\SarmatDTC'
    if mkdir then pcall(mkdir, dir) end
    local target = dir .. '\\' .. name
    if readAll(target) ~= data then
        local f = io.open(target, 'wb')
        if not f then return path end
        f:write(data)
        f:close()
        if readAll(target) ~= data then return path end
    end
    return target
end

-- LuaSocket of DCS: on the default path, else in <DCS>\LuaSocket like other GUI hooks load it.
function M.loadSocket()
    local ok, s = pcall(require, 'socket')
    if ok and type(s) == 'table' and s.tcp then return s end
    package.path = package.path .. ';.\\LuaSocket\\?.lua'
    package.cpath = package.cpath .. ';.\\LuaSocket\\?.dll'
    ok, s = pcall(require, 'socket')
    if ok and type(s) == 'table' and s.tcp then return s end
    error('LuaSocket not found (' .. tostring(s) .. ')')
end

-- LuaSec from libDir (ssl.dll + ssl.lua), or the one another hook already loaded.
-- loadChunk(path): loads a Lua file from a UTF-8 path. Returns ssl, note.
function M.loadSsl(libDir, version, loadChunk, mkdir)
    local loaded = package.loaded.ssl
    if type(loaded) == 'table' and loaded.wrap and loaded.newcontext then
        return loaded, 'LuaSec ' .. tostring(loaded._VERSION) .. ' loaded by another hook'
    end
    local dll = M.ansiPath(libDir .. 'ssl.dll', 'ssl-' .. version .. '.dll', mkdir)
    for _, m in ipairs({ 'core', 'context', 'x509', 'config' }) do
        local name = 'ssl.' .. m
        if not package.loaded[name] then
            local f, err = package.loadlib(dll, 'luaopen_ssl_' .. m)
            if not f then error('cannot load ' .. dll .. ' (' .. tostring(err) .. ')') end
            package.preload[name] = f
        end
    end
    local ssl = loadChunk(libDir .. 'ssl.lua')
    package.loaded.ssl = ssl
    return ssl, 'LuaSec ' .. tostring(ssl._VERSION) .. ' from ' .. dll
end

-- Everything a request needs: { socket, ssl, context }, note; errors if something is missing.
function M.loadTls(libDir, version, loadChunk, mkdir)
    local socket = M.loadSocket()
    local ssl, note = M.loadSsl(libDir, version, loadChunk, mkdir)
    local cafile = M.ansiPath(libDir .. 'cacert.pem', 'cacert-' .. version .. '.pem', mkdir)
    local ctx, err = ssl.newcontext(M.tlsParams(cafile))
    if not ctx then error('TLS setup failed (' .. tostring(err) .. ', CA file ' .. cafile .. ')') end
    return { socket = socket, ssl = ssl, context = ctx }, note
end

return M
