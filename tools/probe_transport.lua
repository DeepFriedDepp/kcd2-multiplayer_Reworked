-- WO-1 transport probes.
--
-- Answers which replacement channel is achievable, in the order the work order
-- prefers them:
--   (a) a Lua-side socket        -> needs `socket`, or LuaJIT `ffi` for Win32
--   (b) a file mailbox on disk   -> needs a working `io.open`
--   (c) structured kcd.log tail  -> needs LogAlways to be cheap and lossless
--   (d) batched ExecuteString    -> always available
--
-- Results as run against KCD2 v1.5.2 on 2026-07-27 are recorded in
-- docs/WO-1-transport.md. Re-run after a game patch to confirm they still hold.
--
-- Output convention, one finding per line so it can be grepped out of kcd.log:
--   [KCD2-MP-PROBE] <context>.<key>=<value>
-- `exec` is the console ExecuteString context, `tick` is inside a
-- Script.SetTimer callback. They are reported separately because the two
-- environments demonstrably differ -- Terrain is a table in the tick and nil in
-- the console -- so availability must never be assumed to carry across.
--
-- KEEP EACH BLOCK SMALL. Long or deeply nested chunks are silently dropped by
-- the console endpoint: no output, no Lua error, nothing in the log. Payload
-- length is not the cause (an 8000-character single-line chunk executes fine,
-- as does a 60-line one), so the trigger is something about chunk complexity
-- and was not worth pinning down. Several short blocks are reliable; one long
-- one is not.
--
-- Driven by tools/Probe-Transport.ps1, which sends each block and reads the
-- answers back out of kcd.log.

--@@BLOCK globals
-- Which standard libraries survived the sandbox. `ffi` is the headline: LuaJIT
-- FFI would make option (a) reachable via ws2_32 without LuaSocket.
local function P(k,v) System.LogAlways("[KCD2-MP-PROBE] exec."..k.."="..tostring(v)) end
P("lua_version", _VERSION)
for _,n in ipairs({"io","os","package","ffi","jit","bit","socket","debug","coroutine"}) do
    P("lib."..n, type(rawget(_G,n)))
end
for _,n in ipairs({"require","load","loadstring","dofile","loadfile","setfenv"}) do
    P("fn."..n, type(rawget(_G,n)))
end

--@@BLOCK oslib
-- os.clock is already used by the mod, so `os` exists in some form. This is
-- about how much of it survived -- getenv in particular would be needed to
-- resolve a writable directory for an option (b) mailbox.
local function P(k,v) System.LogAlways("[KCD2-MP-PROBE] exec."..k.."="..tostring(v)) end
for _,n in ipairs({"clock","time","date","getenv","remove","rename","tmpname","execute"}) do
    P("os."..n, type(os[n]))
end

--@@BLOCK iolib
-- Option (b). Presence of the io table at all.
local function P(k,v) System.LogAlways("[KCD2-MP-PROBE] exec."..k.."="..tostring(v)) end
P("io", type(rawget(_G,"io")))
if type(io) == "table" then
    for _,n in ipairs({"open","lines","read","write","close","popen"}) do
        P("io."..n, type(io[n]))
    end
end

--@@BLOCK socket
-- Option (a). Both routes: a LuaSocket module, or ffi reaching Win32 directly.
local function P(k,v) System.LogAlways("[KCD2-MP-PROBE] exec."..k.."="..tostring(v)) end
P("socket.global", type(rawget(_G,"socket")))
local ok, mod = pcall(require, "socket")
P("socket.require", ok and type(mod) or "FAILED")
P("ffi", type(rawget(_G,"ffi")))

--@@BLOCK tick
-- Re-checks availability from inside a Script.SetTimer callback, the context
-- options (b) and (c) would actually run in.
--
-- Terrain is included as a control for the documented exec-vs-tick difference,
-- but it came back nil in BOTH contexts on the 2026-07-27 run -- the mod itself
-- was not loaded then (KCD2MP was nil), so this did not reproduce the known
-- Terrain.GetElevation asymmetry and proves nothing either way. The re-check is
-- kept regardless: the asymmetry is documented, and confirming a capability in
-- the context that will actually use it costs one extra block.
Script.SetTimer(50, function()
    local function P(k,v) System.LogAlways("[KCD2-MP-PROBE] tick."..k.."="..tostring(v)) end
    P("reached", "YES")
    for _,n in ipairs({"io","os","ffi","package","socket"}) do
        P("lib."..n, type(rawget(_G,n)))
    end
    P("Terrain", type(rawget(_G,"Terrain")))
end)

--@@BLOCK lograte
-- Option (c) feasibility: burst 50 tagged lines and let the driver check for
-- drops and reordering. If LogAlways is cheap and lossless it can carry a real
-- outbound event stream, which removes the need to poll the game at all.
local t0 = os.clock()
for i = 1, 50 do
    System.LogAlways(string.format("[KCD2-MP-PROBE] lograte.seq=%d t=%.6f", i, os.clock()))
end
System.LogAlways(string.format("[KCD2-MP-PROBE] exec.lograte_elapsed=%.6f", os.clock() - t0))
