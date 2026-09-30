-- player/runtime.lua
--
-- THE TERMINATE-PROTECTION SEAM.
--
-- WHY THIS EXISTS
-- ---------------
-- In CC:Tweaked, `os.pullEvent` AUTO-TERMINATES the running program when the
-- user presses Ctrl+T: it raises a "Terminated" error at the pull site and
-- every subsequent cleanup step is skipped.  For a music player that is a real
-- bug, not a nicety: the speakers keep whatever audio was queued and the
-- transport is left in an undefined state.  `os.pullEventRaw` is the escape
-- hatch -- it RETURNS the `terminate` event to the caller instead of aborting,
-- so the program gets to stop its speakers before it unwinds.  This module owns
-- that discipline in ONE place, so the player core never has to remember it.
--
-- FROZEN PUBLIC INTERFACE (ccnbslib.lua builds on these EXACT
-- names):
--
--   local runtime = require("player.runtime")
--
--   runtime.run(body, opts) -> { terminated = <boolean>,
--                                result     = <body's return value>,
--                                error      = <string|nil> }
--
--   runtime.cleanup(speakers, session) -> <integer>  -- speakers stopped
--   runtime.stop_speakers(speakers)    -> <integer>  -- speakers stopped
--
-- THE BODY CONTRACT
-- -----------------
-- `runtime.run` calls `body(pull)`, where `pull` is the resolved event source.
-- A body that needs to wait for an event calls the pull it was handed; a body
-- that never waits can simply ignore the argument.  Resolution is LAZY and
-- happens at call time, never at module load:
--
--   * `opts.pull`, when supplied, is used verbatim (the unit-test seam); the
--     global is then NEVER consulted -- see the injection test.
--   * otherwise the global `os.pullEventRaw` is read inside `run`.
--
-- If a call through that seam yields `"terminate"` as its first value, the seam
-- wrapper records the terminate and raises a terminate-shaped error so the body
-- unwinds; `run` then runs the SAME cleanup as an in-body terminate.
--
-- THE TERMINATE-SHAPE DETECTION RULE
-- ----------------------------------
-- A real Ctrl+T during body execution is reported by `os.pullEvent` as a raised
-- error.  CC:T raises the string `"Terminated"` (and may prefix/suffix it), so
-- we classify ANY raised error whose message CONTAINS `"terminate"`
-- (case-insensitive) as a terminate.  Every other raised error is a genuine
-- crash:
--
--   * terminate -> terminated = true,  error = nil,      cleanup runs;
--   * other     -> terminated = false, error = <message>, cleanup STILL runs
--                 (never leak speakers on a crash) but is NOT reported as a
--                 terminate.
--
-- A normal return means terminated = false, result = body's return value, and
-- NO cleanup (there is nothing to interrupt).
--
-- THE NEVER-RE-RAISE GUARANTEE
-- ----------------------------
-- `runtime.run` NEVER re-raises.  A caller cannot have the program die
-- mid-cleanup: every failure -- the body, a speaker's stop(), the session's
-- cancel(), even `on_terminate` -- is contained and reported through the return
-- value.  Cleanup therefore also cannot be interrupted by a second terminate.
--
-- `opts.speakers`: array of speaker records (player/speaker.lua), may be nil or
-- empty.  `opts.session`: optional object with a `:cancel()` method.
-- `opts.on_terminate`: optional function() run AFTER cleanup, only on terminate.
-- `opts.stop_all`: optional function(speakers) overriding the per-speaker stop.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No integer division, no bitwise
-- operators, no utf8, no string.dump, no os.exit.  `os.pullEvent` is NEVER used
-- here -- `os.pullEventRaw` (or the injected seam) is the only event source.

local runtime = {}

-- Unpacking helper: `table.unpack` is the Lua 5.2 name; fall back to the global
-- for older Cobalt builds.  Read at load, which is safe (it is not a host API).
local unpack_values = table.unpack or unpack

-- ---------------------------------------------------------------------------
-- Terminate-shape detection
-- ---------------------------------------------------------------------------

-- True when a raised error's message names a terminate.  CC:Tweaked raises the
-- string "Terminated" and may add a prefix or suffix ("Terminated: press
-- Ctrl+T"), so a case-insensitive substring test is the right granularity.
local function is_terminate(value)
  if type(value) ~= "string" then
    return false
  end
  return value:lower():find("terminate", 1, true) ~= nil
end

-- ---------------------------------------------------------------------------
-- runtime.stop_speakers(speakers) -> integer
-- ---------------------------------------------------------------------------

-- Stop every speaker record, DEFENSIVELY: a speaker whose stop() raises must
-- not prevent the OTHERS from being stopped, and nothing may propagate.  Returns
-- the number of speakers that stopped successfully.  Missing/nil/non-callable
-- records are simply not counted (their pcall fails), never fatal.
function runtime.stop_speakers(speakers)
  if type(speakers) ~= "table" then
    return 0
  end

  local stopped = 0
  for _, record in ipairs(speakers) do
    local ok = pcall(function()
      record:stop()
    end)
    if ok then
      stopped = stopped + 1
    end
  end
  return stopped
end

-- ---------------------------------------------------------------------------
-- runtime.cleanup(speakers, session) -> integer
-- ---------------------------------------------------------------------------

-- Stop speakers then cancel the session, each step independently protected.
-- With `session == nil` this must not raise.  `stop_fn` is an optional override
-- for the stopping step (runtime.run threads `opts.stop_all` through here).
-- Idempotent: calling it again is harmless even if a speaker's stop() is
-- re-invoked.  Returns the number of speakers stopped successfully.
function runtime.cleanup(speakers, session, stop_fn)
  local stopper = runtime.stop_speakers
  if type(stop_fn) == "function" then
    stopper = stop_fn
  end

  local stopped = 0
  local ok, count = pcall(stopper, speakers)
  if ok and type(count) == "number" then
    stopped = count
  end

  if session ~= nil then
    local cancel = session.cancel
    if type(cancel) == "function" then
      pcall(cancel, session)
    end
  end

  return stopped
end

-- ---------------------------------------------------------------------------
-- runtime.run(body, opts) -> { terminated, result, error }
-- ---------------------------------------------------------------------------

function runtime.run(body, opts)
  if type(opts) ~= "table" then
    opts = {}
  end

  local speakers = opts.speakers
  local session = opts.session
  local on_terminate = opts.on_terminate

  -- Resolve the event source LAZILY, at call time only.  Reading the global at
  -- module load would make this file un-requireable in plain Lua 5.2.
  local source = opts.pull
  if source == nil then
    local os_lib = rawget(_G, "os")
    if os_lib ~= nil then
      source = os_lib.pullEventRaw
    end
  end

  -- Set when the seam observes a terminate; read after the body unwinds so a
  -- body that swallowed the internal error is still treated as terminated.
  local seam_terminated = false

  -- The pull handed to the body.  A thin, terminate-aware wrapper over the
  -- resolved source: normally it forwards every event value unchanged, but a
  -- first value of "terminate" becomes an unwind so cleanup cannot be skipped.
  local function pull(...)
    if type(source) ~= "function" then
      error("runtime.run: no event source available "
        .. "(os.pullEventRaw is missing; pass opts.pull)", 2)
    end

    local values = { source(...) }
    if values[1] == "terminate" then
      seam_terminated = true
      error("Terminated", 0)
    end
    return unpack_values(values, 1, #values)
  end

  local ok, result = pcall(body, pull)

  local terminated = seam_terminated
  local err = nil
  if not ok then
    if is_terminate(result) then
      terminated = true
    elseif not terminated then
      err = tostring(result)
    end
  end

  -- Cleanup runs on ANY abnormal exit: terminate OR crash.  A normal return
  -- needs no cleanup.
  if terminated or err ~= nil then
    runtime.cleanup(speakers, session, opts.stop_all)
  end

  -- on_terminate runs AFTER cleanup, only on terminate, and cannot re-raise.
  if terminated and type(on_terminate) == "function" then
    pcall(on_terminate)
  end

  local output = { terminated = terminated, result = nil, error = err }
  if not terminated and err == nil then
    output.result = result
  end
  return output
end

return runtime
