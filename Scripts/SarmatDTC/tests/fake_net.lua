-- Fake LuaSocket + LuaSec for the tests: no network, the answers come from `script`.
-- usage: local socket, ssl, net = dofile('fake_net.lua')(script)
--   script.respond(path, conn) -> raw HTTP response, or nil: the server never answers
--   script.dns = false          -> host not found
--   script.connect = 'progress' -> connect completes after a few select calls; 'slow' -> never;
--                    'refused' -> it fails
--   script.handshakeWants = n   -> n x 'wantread' before the handshake completes
--   script.handshakeError = s   -> the handshake fails with s
--   script.verified = false     -> getpeerverification() is false
--   script.certNames = { ... }  -> dNSName entries of the peer certificate (default: the SNI host)
--   script.piece = n            -> at most n bytes per receive call
--   script.stall = true         -> every other receive call returns 'wantread'
-- net: opened/closed connection counts, requests ("host/path" of each request), params (newcontext)
return function(script)
    local net = { opened = 0, closed = 0, requests = {}, selects = 0 }

    local socket = { dns = {} }
    function socket.dns.toip(host)
        if script.dns == false then return nil, 'host not found' end
        return '10.0.0.1'
    end
    function socket.select(_, w)
        net.selects = net.selects + 1
        if script.connect == 'slow' or net.selects % 3 ~= 0 then return {}, {} end   -- writable on every third call
        return {}, { w[1], [w[1]] = true }
    end
    function socket.tcp()
        net.opened = net.opened + 1
        local t = { connects = 0 }
        function t:settimeout() end
        function t:connect()
            self.connects = self.connects + 1
            if script.connect == 'refused' then
                if self.connects == 1 then return nil, 'timeout' end
                return nil, 'connection refused'
            end
            if script.connect == 'slow' or script.connect == 'progress' then return nil, 'timeout' end
            return 1
        end
        function t:getpeername()
            if script.connect == 'refused' then return nil, 'not connected' end
            return '10.0.0.1', 443
        end
        function t:close() net.closed = net.closed + 1 end
        return t
    end

    local function cert(names)
        return {
            extensions = function() return { ['2.5.29.17'] = { name = 'subjectAltName', dNSName = names } } end,
            subject = function() return {} end,
        }
    end

    local ssl = { _VERSION = 'fake' }
    function ssl.newcontext(params)
        net.params = params
        return { context = true }
    end
    function ssl.wrap(tcp)
        local c = { wants = script.handshakeWants or 0, out = '', calls = 0 }
        function c:settimeout() end
        function c:sni(host) self.host = host end
        function c:dohandshake()
            if self.wants > 0 then
                self.wants = self.wants - 1
                return nil, 'wantread'
            end
            if script.handshakeError then return nil, script.handshakeError end
            return true
        end
        function c:getpeerverification() return script.verified ~= false end
        function c:getpeercertificate() return cert(script.certNames or { self.host }) end
        function c:send(data, i)
            local j = math.min(#data, i + 19)   -- 20 bytes per call
            self.out = self.out .. string.sub(data, i, j)
            if j < #data then return nil, 'wantwrite', j end
            return j
        end
        function c:receive(n)
            if self.resp == nil then
                local path = string.match(self.out, '^GET (%S+)')
                net.requests[#net.requests + 1] = tostring(self.host) .. tostring(path)
                self.resp = script.respond(path, self) or false
                self.pos = 1
            end
            if self.resp == false then return nil, 'wantread', '' end
            self.calls = self.calls + 1
            if script.stall and self.calls % 2 == 0 then return nil, 'wantread', '' end
            if self.pos > #self.resp then return nil, 'closed', '' end
            local piece = string.sub(self.resp, self.pos, self.pos + math.min(n, script.piece or n) - 1)
            self.pos = self.pos + #piece
            if #piece == n then return piece end
            return nil, 'wantread', piece
        end
        function c:close() net.closed = net.closed + 1 end
        return c
    end

    return socket, ssl, net
end
