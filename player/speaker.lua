-- player/speaker.lua
--
-- THE INJECTABLE SPEAKER SEAM.
--
-- The rest of the player NEVER reaches for the global `peripheral` table
-- directly.  Every hardware access is funnelled through this module, so the
-- SAME player code can be driven by three different tiers:
--
--   1. pure Lua unit tests, where there is no `peripheral` global at all;
--   2. a CraftOS-PC headless harness that replaces the `peripheral` API with a
--      recorder -- see speaker.mock, which captures every call in order;
--   3. real Minecraft, where `peripheral` is the live CC:Tweaked API.
--
-- FROZEN PUBLIC INTERFACE (the dispatch, fan-out and Tier-2 layers depend on
-- these EXACT names):
--
--   local speaker = require("player.speaker")
--
--   speaker.discover()             -> array of speaker records, sorted by side
--   speaker.wrap(side, obj)        -> speaker record adapting a live peripheral
--   speaker.mock(side)             -> speaker record that RECORDS calls
--
-- A speaker record:
--   { side        = "left",
--     play_note   = function(self, name, volume, pitch) -> boolean,
--     play_sound  = function(self, name, volume, pitch) -> boolean,
--     stop        = function(self) }
--
-- A mock record adds:
--   record.calls  = array of { method = "play_note"|"play_sound"|"stop",
--                              args   = { ... } }
--   record.drain() -> returns the accumulated calls and CLEARS the buffer.
--
-- HARD RULES (enforced by the test suite):
--
--   * This module must NOT hard-code a call to the peripheral type-search
--     shortcut (the find helper).  Discovery uses ONLY getNames() and getType();
--     any other key on the peripheral global is off limits to the runtime core.
--   * This module must NOT capture the `peripheral` global at module scope.
--     The global is read lazily, inside function bodies only, and nil-checked,
--     so requiring this file in plain Lua 5.2 with no `peripheral` present is
--     safe.
--
-- REFUSALS ARE NOT ERRORS.  A CC:Tweaked speaker may accept only a handful of
-- playNote calls per game tick, so playNote/playSound returning false is a
-- normal refusal, not a failure.  The adapter therefore FORWARDS that boolean
-- unchanged -- it must never be swallowed or normalised away.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No integer division, no bitwise
-- operators, no utf8, no string.dump, no os.exit.

local speaker = {}

-- ---------------------------------------------------------------------------
-- Lazy access to the global peripheral table
-- ---------------------------------------------------------------------------

-- Read the global only when called, never at module scope.  Missing entirely in
-- plain Lua unit tests, where every entry point must degrade gracefully.
local function live_peripheral()
  return rawget(_G, "peripheral")
end

-- ---------------------------------------------------------------------------
-- speaker.mock(side) -> recording record
-- ---------------------------------------------------------------------------

-- Append one recorded call to the record's buffer.  `self` is the record the
-- caller invoked the method on; `buffer_owner` is the closed-over record, used
-- as a fallback so the buffer survives a drain() that swapped the table.
local function append_call(self, buffer_owner, method, ...)
  local calls = (self and self.calls) or buffer_owner.calls
  calls[#calls + 1] = { method = method, args = { ... } }
end

-- speaker.mock(side): a speaker record that performs no I/O.  Every method
-- records { method = ..., args = {...} } in call order and returns true: a mock
-- never refuses.  Used by unit tests and by the Tier-2 headless harness.
function speaker.mock(side)
  local record = {
    side = side,
    calls = {},
  }

  function record.play_note(self, name, volume, pitch)
    append_call(self, record, "play_note", name, volume, pitch)
    return true
  end

  function record.play_sound(self, name, volume, pitch)
    append_call(self, record, "play_sound", name, volume, pitch)
    return true
  end

  function record.stop(self)
    append_call(self, record, "stop")
    return true
  end

  -- drain(): hand back the accumulated calls and start a fresh buffer, so each
  -- Tier-2 step can assert on a clean slate.
  function record.drain()
    local drained = record.calls
    record.calls = {}
    return drained
  end

  return record
end

-- ---------------------------------------------------------------------------
-- speaker.wrap(side, peripheral_object) -> adapter record
-- ---------------------------------------------------------------------------

-- Look up one camelCase peripheral method.  A peripheral that lacks a method
-- must fail loudly and specifically, naming the side and the method, rather
-- than crash later with a nil-index.  Checked per call, so a peripheral that
-- exposes playNote but not playSound can still play notes.
local function require_method(peripheral_object, side, camel, snake)
  local fn = peripheral_object[camel]
  if type(fn) ~= "function" then
    error(string.format(
      "speaker.wrap: peripheral on side %q is missing method %q (needed by %s)",
      tostring(side), camel, snake), 2)
  end
  return fn
end

-- speaker.wrap(side, peripheral_object): adapt an already-obtained peripheral
-- object.  CC:Tweaked's speaker exposes camelCase playNote / playSound / stop;
-- this maps the seam's snake_case methods onto them and forwards the boolean
-- return of playNote/playSound unchanged (refusals must reach the caller).
--
-- THE PERIPHERAL'S METHODS TAKE NO `self` -- CALL THEM DOT-STYLE.
--
-- This is the same convention issue AGENTS.md section 3 records for the http
-- response handle, and getting it wrong here was a real, silent defect: every
-- note was passed as `playNote(peripheral_object, name, volume, pitch)`, so
-- `instrumentA` received a TABLE instead of the instrument name. The speaker
-- throws "Invalid instrument" for that, dispatch contains the raise in a pcall,
-- and playback therefore advanced normally through the whole song in total
-- silence -- the progress bar was right and nothing was audible.
--
-- The evidence, not a guess:
--   * the Java signature is
--       public final boolean playNote(ILuaContext context, String instrumentA,
--                                     Optional<Double> volumeA, Optional<Double> pitchA)
--     and ILuaContext is INJECTED, not a Lua argument, so from Lua the method
--     takes exactly (instrument, volume, pitch);
--   * CC:Tweaked's own usage is `speaker.playSound("entity.creeper.primed")`.
--
-- Contrast the RECORDS this returns: those ARE Lua tables whose methods take
-- `self` and are called with a colon (`record:play_note(...)`). Two conventions in
-- one module, and the seam boundary is exactly where they change.
function speaker.wrap(side, peripheral_object)
  if type(peripheral_object) ~= "table" then
    error(string.format(
      "speaker.wrap: expected a peripheral object for side %q, got %s",
      tostring(side), type(peripheral_object)), 2)
  end

  local record = { side = side }

  function record.play_note(self, name, volume, pitch)
    local fn = require_method(peripheral_object, side, "playNote", "play_note")
    -- DOT call: no self. See the note above.
    return fn(name, volume, pitch)
  end

  function record.play_sound(self, name, volume, pitch)
    local fn = require_method(peripheral_object, side, "playSound", "play_sound")
    -- DOT call: no self.
    return fn(name, volume, pitch)
  end

  function record.stop(self)
    local fn = require_method(peripheral_object, side, "stop", "stop")
    -- DOT call: no self.
    return fn()
  end

  return record
end

-- ---------------------------------------------------------------------------
-- speaker.discover() -> array of records for every attached speaker
-- ---------------------------------------------------------------------------

-- A discovered record resolves its live object lazily, on first method call,
-- through the global peripheral.wrap(side).  discover() itself therefore reads
-- ONLY getNames/getType -- never the find helper, never wrap -- which is what
-- the "no hard-coded find in the runtime core" guard in the spec checks.
local function discovered_record(side)
  local record = { side = side }
  local wrapped = nil

  local function live()
    if wrapped == nil then
      local peripheral = live_peripheral()
      if peripheral == nil or type(peripheral.wrap) ~= "function" then
        error(string.format(
          "speaker.discover: peripheral.wrap is unavailable for side %q",
          tostring(side)), 2)
      end
      local object = peripheral.wrap(side)
      if object == nil then
        error(string.format(
          "speaker.discover: no speaker is attached on side %q any more",
          tostring(side)), 2)
      end
      wrapped = speaker.wrap(side, object)
    end
    return wrapped
  end

  function record.play_note(self, name, volume, pitch)
    local target = live()
    return target.play_note(target, name, volume, pitch)
  end

  function record.play_sound(self, name, volume, pitch)
    local target = live()
    return target.play_sound(target, name, volume, pitch)
  end

  function record.stop(self)
    local target = live()
    return target.stop(target)
  end

  return record
end

-- speaker.discover(): enumerate attached peripherals, keep only speakers, and
-- return their records sorted by side name ASCENDING (stable, reproducible fan
-- out and Tier-2 recordings).  With no `peripheral` global at all -- plain Lua
-- unit tests -- it returns an EMPTY ARRAY instead of raising.  Each getType
-- call is pcall-guarded: a peripheral whose type lookup RAISES is skipped
-- rather than allowed to abort discovery of the healthy speakers.
function speaker.discover()
  local peripheral = live_peripheral()
  if peripheral == nil then
    return {}
  end

  local get_names = peripheral.getNames
  if type(get_names) ~= "function" then
    return {}
  end

  local get_type = peripheral.getType
  if type(get_type) ~= "function" then
    return {}
  end

  local names = get_names()
  local records = {}
  if type(names) == "table" then
    for _, side in ipairs(names) do
      -- One uncooperative peripheral must not abort discovery of the others:
      -- a getType that raises (absent/erroring peripheral) is treated as "not a
      -- speaker" and the scan continues.  The final ascending-side sort keeps
      -- discovery deterministic either way.
      local ok, kind = pcall(get_type, side)
      if ok and kind == "speaker" then
        records[#records + 1] = discovered_record(side)
      end
    end
  end

  table.sort(records, function(a, b)
    return a.side < b.side
  end)

  return records
end

return speaker
