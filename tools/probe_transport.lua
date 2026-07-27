-- WO-1 transport probes.
--
-- These decide which replacement channel is achievable, in the order the work
-- order prefers them:
--   (a) a Lua-side socket        -> needs `socket`, or LuaJIT `ffi` to reach Win32
--   (b) a file mailbox on disk   -> needs a working `io.open` and a writable path
--   (c) structured kcd.log tail  -> needs to know how fast LogAlways reaches disk
--   (d) batched ExecuteString    -> always available, measured as the fallback
--
-- Every block is a self-contained chunk: nothing is defined, nothing persists,
-- so blocks can be sent in any order and re-run freely. Each is small enough to
-- survive URL encoding through /api/System/Console/ExecuteString.
--
-- Output convention, one finding per line so it can be grepped out of kcd.log:
--   [KCD2-MP-PROBE] <context>.<key>=<value>
-- context is `exec` when run directly through the console, `tick` when run from
-- inside a Script.SetTimer callback. They are reported separately on purpose:
-- Terrain.GetElevation is already known to exist in one and not the other, so
-- availability must never be assumed to carry across.
--
-- Driven by tools/Probe-Transport.ps1, which sends each block and then reads
-- the answers back out of kcd.log.

--@@BLOCK globals
-- Which standard libraries survived the sandbox. `ffi` is the headline: if
-- LuaJIT's FFI is exposed, option (a) becomes reachable via Win32 sockets
-- directly and the whole work order gets much easier.
local function P(k, v) System.LogAlways("[KCD2-MP-PROBE] exec." .. k .. "=" .. tostring(v)) end
pcall(function()
    P("lua_version", _VERSION)
    local libs = { "io", "os", "package", "ffi", "jit", "bit", "socket",
                   "debug", "coroutine", "string", "table", "math" }
    for _, n in ipairs(libs) do
        P("lib." .. n, type(rawget(_G, n)))
    end
    local fns = { "require", "load", "loadstring", "dofile", "loadfile", "rawget", "setfenv" }
    for _, n in ipairs(fns) do
        P("fn." .. n, type(rawget(_G, n)))
    end
    if type(jit) == "table" then
        P("jit.version", jit.version)
        P("jit.os", jit.os)
        P("jit.arch", jit.arch)
    end
end)

--@@BLOCK oslib
-- os.clock is already used by the mod, so `os` exists in some form. This is
-- about how much of it: os.time/os.date give timestamps for latency work, and
-- os.getenv resolves a writable directory for the option (b) mailbox.
local function P(k, v) System.LogAlways("[KCD2-MP-PROBE] exec." .. k .. "=" .. tostring(v)) end
pcall(function()
    if type(os) ~= "table" then P("os", "MISSING") return end
    for _, n in ipairs({ "clock", "time", "date", "getenv", "remove", "rename",
                         "tmpname", "execute", "difftime" }) do
        P("os." .. n, type(os[n]))
    end
    if type(os.clock) == "function" then P("os.clock_value", os.clock()) end
    if type(os.time)  == "function" then P("os.time_value",  os.time())  end
    if type(os.getenv) == "function" then
        for _, e in ipairs({ "TEMP", "TMP", "USERPROFILE", "LOCALAPPDATA", "CD" }) do
            P("env." .. e, os.getenv(e))
        end
    end
end)

--@@BLOCK iolib
-- Presence of the io table and its functions. Presence alone proves nothing --
-- the write test in the next block is what actually decides option (b).
local function P(k, v) System.LogAlways("[KCD2-MP-PROBE] exec." .. k .. "=" .. tostring(v)) end
pcall(function()
    if type(io) ~= "table" then P("io", "MISSING") return end
    for _, n in ipairs({ "open", "lines", "read", "write", "close", "popen",
                         "input", "output", "tmpfile" }) do
        P("io." .. n, type(io[n]))
    end
end)

--@@BLOCK iowrite
-- The real option (b) test: write a file, flush it, read it back, delete it.
-- Several candidate directories are tried because the game's working directory
-- is unknown and a relative path may land somewhere unhelpful. The resolved
-- path of whichever succeeds is what the agent would tail, so it is logged.
local function P(k, v) System.LogAlways("[KCD2-MP-PROBE] exec." .. k .. "=" .. tostring(v)) end
pcall(function()
    if type(io) ~= "table" or type(io.open) ~= "function" then
        P("iowrite.result", "SKIPPED_NO_IO")
        return
    end

    local marker = "KCD2MP_PROBE_" .. tostring(math.random(100000, 999999))
    local candidates = { "kcd2mp_probe.tmp" }
    if type(os) == "table" and type(os.getenv) == "function" then
        for _, e in ipairs({ "TEMP", "USERPROFILE", "LOCALAPPDATA" }) do
            local d = os.getenv(e)
            if d then table.insert(candidates, d .. "\\kcd2mp_probe.tmp") end
        end
    end

    for i, path in ipairs(candidates) do
        local ok = pcall(function()
            local fh, err = io.open(path, "wb")
            if not fh then
                P("iowrite." .. i .. ".path", path)
                P("iowrite." .. i .. ".open", "FAILED: " .. tostring(err))
                return
            end
            fh:write(marker)
            fh:close()

            local rh = io.open(path, "rb")
            local got = rh and rh:read("*a") or nil
            if rh then rh:close() end

            P("iowrite." .. i .. ".path", path)
            P("iowrite." .. i .. ".roundtrip", (got == marker) and "OK" or ("MISMATCH:" .. tostring(got)))

            if type(os.remove) == "function" then
                P("iowrite." .. i .. ".delete", tostring(pcall(os.remove, path)))
            end
        end)
        if not ok then
            P("iowrite." .. i .. ".path", path)
            P("iowrite." .. i .. ".open", "THREW")
        end
    end
end)

--@@BLOCK socket
-- Option (a). LuaSocket is unlikely to be present, but if `ffi` showed up in
-- the globals block then Win32 sockets are reachable without it, so the ffi
-- probe below matters more than the `socket` one.
local function P(k, v) System.LogAlways("[KCD2-MP-PROBE] exec." .. k .. "=" .. tostring(v)) end
pcall(function()
    P("socket.global", type(rawget(_G, "socket")))
    if type(require) == "function" then
        local ok, mod = pcall(require, "socket")
        P("socket.require", ok and type(mod) or ("FAILED: " .. tostring(mod)))
    else
        P("socket.require", "NO_REQUIRE")
    end

    if type(rawget(_G, "ffi")) == "table" then
        -- If this loads, option (a) is open: ws2_32 can be called directly.
        local ok, err = pcall(function()
            local C = ffi.load("ws2_32")
            P("ffi.ws2_32", C and "LOADED" or "NIL")
        end)
        if not ok then P("ffi.ws2_32", "FAILED: " .. tostring(err)) end
    else
        P("ffi.ws2_32", "SKIPPED_NO_FFI")
    end
end)

--@@BLOCK tick
-- Re-runs the availability checks from inside a Script.SetTimer callback.
-- Terrain.GetElevation is documented as existing here but not in the console
-- context, so the two environments demonstrably differ and every capability
-- option (b) or (c) would depend on has to be confirmed in the context that
-- would actually use it -- the tick, not the console.
--
-- Follows the established self-rescheduling-first discipline by not
-- rescheduling at all: this fires once and stops.
pcall(function()
    Script.SetTimer(50, function()
        local function P(k, v) System.LogAlways("[KCD2-MP-PROBE] tick." .. k .. "=" .. tostring(v)) end
        pcall(function()
            P("reached", "YES")
            for _, n in ipairs({ "io", "os", "ffi", "package", "socket" }) do
                P("lib." .. n, type(rawget(_G, n)))
            end
            P("fn.require", type(rawget(_G, "require")))
            P("terrain.GetElevation", type(Terrain) == "table" and type(Terrain.GetElevation) or "NO_TERRAIN")

            if type(io) == "table" and type(io.open) == "function" then
                local path = "kcd2mp_probe_tick.tmp"
                if type(os) == "table" and type(os.getenv) == "function" then
                    local d = os.getenv("TEMP")
                    if d then path = d .. "\\kcd2mp_probe_tick.tmp" end
                end
                local ok = pcall(function()
                    local fh = io.open(path, "wb")
                    if not fh then P("iowrite.open", "FAILED") return end
                    fh:write("TICK_OK")
                    fh:close()
                    local rh = io.open(path, "rb")
                    local got = rh and rh:read("*a") or nil
                    if rh then rh:close() end
                    P("iowrite.path", path)
                    P("iowrite.roundtrip", (got == "TICK_OK") and "OK" or "MISMATCH")
                    if type(os.remove) == "function" then pcall(os.remove, path) end
                end)
                if not ok then P("iowrite.roundtrip", "THREW") end
            else
                P("iowrite.roundtrip", "SKIPPED_NO_IO")
            end
        end)
    end)
end)

--@@BLOCK lograte
-- Option (c) feasibility. Writes a burst of tagged lines with an os.clock
-- stamp on each. How fast these appear in kcd.log, and whether any are
-- dropped or reordered, decides whether a log tail can carry a real event
-- stream or only occasional messages.
pcall(function()
    local t0 = os.clock()
    for i = 1, 50 do
        System.LogAlways(string.format("[KCD2-MP-PROBE] lograte.seq=%d t=%.6f", i, os.clock()))
    end
    System.LogAlways(string.format("[KCD2-MP-PROBE] exec.lograte_elapsed=%.6f", os.clock() - t0))
end)
