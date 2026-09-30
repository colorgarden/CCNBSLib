-- player/dispatch.lua
--
-- THE ROUTING LAYER: given ONE already-planned event and one speaker record,
-- decide exactly which call to make -- and when to REFUSE.
--
-- FROZEN PUBLIC INTERFACE
--   local dispatch = require("player.dispatch")
--
--   dispatch.new(opts)              -> d             (opts reserved; ignored)
--   d:event(event, speaker_record)  -> result        (NEVER raises)
--   d:warnings()                    -> array of codes, in emission order
--   d:reset()                       -> clears the warning ledger
--
--   dispatch.WARN_CUSTOM_INSTRUMENT = "custom-instrument"
--   dispatch.WARN_PLAY_SOUND_PITCH  = "play-sound-pitch"
--
--   result = {
--     called        boolean,        -- true when a speaker method was invoked
--     method        "play_note" | "play_sound" | nil,
--     speaker_side  string | nil,
--     refused       boolean | nil,  -- speaker returned false (a NORMAL refusal)
--     warning_code  string | nil,   -- BARE code; player/warnings.lua owns WARN[...]
--     error_message string | nil,   -- ONLY for a raised/unusable call
--   }
--
-- ---------------------------------------------------------------------------
-- DISPATCH DOES NOT RE-RESOLVE ANYTHING
-- ---------------------------------------------------------------------------
-- player/plan.lua has ALREADY resolved the instrument routing (`kind`, `name`,
-- `custom_index`) and ALREADY mapped the volume (0..3) and the playNote pitch
-- (integer semitones, UNCLAMPED).  Dispatch therefore:
--   * NEVER calls nbs.instrument_table.resolve (no instrument re-routing);
--   * NEVER calls mapping.speaker_volume (no volume re-mapping);
--   * forwards event.volume and event.pitch VERBATIM.
-- The ONE numeric job left for dispatch is the playSound RATIO (branch 2), which
-- plan.lua deliberately did not bake into `pitch` (that field holds semitones).
--
-- ---------------------------------------------------------------------------
-- THE THREE ROUTING BRANCHES
-- ---------------------------------------------------------------------------
-- 1. kind == "play_note"
--      speaker:play_note(event.name, event.volume, event.pitch)
--      The pitch is passed VERBATIM.  It MAY BE NEGATIVE (extended range):
--      passing it through unclamped is the whole point of the mapping decision.
--      We do NOT clamp, do NOT guard, and do NOT warn about it.
--
-- 2. kind == "play_sound"   (a v6 trumpet)
--      speaker:play_sound(event.name, event.volume, ratio)
--      `ratio` is the playSound PITCH RATIO, not semitones, computed from
--      event.key via mapping.play_sound_pitch (allowed: dispatch may call it).
--      playSound only accepts 0.5..2.0, so a trumpet far from the key-45
--      reference cannot be represented faithfully.  mapping.play_sound_pitch
--      clamps for us; when the IDEAL ratio (2 ^ ((key - 45) / 12)) lies OUTSIDE
--      0.5..2.0 we emit WARN_PLAY_SOUND_PITCH so the user knows that note's
--      pitch is approximate.  Detection is by comparison: the clamped value
--      differs from the ideal exactly when clamping happened.
--
-- 3. kind == "custom"
--      REFUSE.  NO speaker call at all (called = false, method = nil) and emit
--      WARN_CUSTOM_INSTRUMENT.  We NEVER raise and NEVER pass a custom name to
--      play_sound.
--
-- An unrecognised/missing `kind` is also a refusal with NO warning.
--
-- ---------------------------------------------------------------------------
-- ONCE-ONLY WARNING POLICY
-- ---------------------------------------------------------------------------
-- A dispatcher carries a small ledger for one playback.  d:warnings() returns
-- the codes emitted so far IN EMISSION ORDER; a given code appears AT MOST ONCE
-- no matter how many events trigger it.  d:reset() clears the ledger so a fresh
-- playback can warn again.  This lets the UI print each warning exactly once per
-- song without the dispatcher knowing anything about printing.
--
-- TWO LEDGER LAYERS -- BOTH DELIBERATE, NOT DUPLICATES.  The public player
-- (ccnbslib.lua) does NOT call d:warnings() or d:reset(); it keeps its OWN
-- once-per-code aggregate and forwards each bare code ONCE to its
-- opts.on_warning callback.  This dispatcher's ledger is a separate, lower
-- layer: it guarantees per-instance once-only semantics for any DIRECT user of
-- dispatch, independent of however a caller aggregates on top.  So
-- d:warnings()/d:reset() have no production caller but stay part of the FROZEN
-- public interface and are asserted by the test suite.
--
-- ---------------------------------------------------------------------------
-- REFUSAL vs ERROR  (the distinction is deliberate and observable)
-- ---------------------------------------------------------------------------
--   refused = true,  called = true,  error_message = nil
--       The speaker was called and RETURNED FALSE.  On a REAL CC:Tweaked
--       speaker this is NORMAL -- the 8-notes-per-tick budget refuses often --
--       so dispatch forwards it and never treats it as a failure.
--
--   refused = false, called = false, error_message = <string>
--       The call could not be completed: the speaker RAISED, was absent, or had
--       no such method.  The raise is pcall-contained so the dispatcher is never
--       poisoned and d:event NEVER raises, for ANY input.
--
-- A malformed event (not a table, no name for play_note/play_sound, ...) is a
-- plain refusal: called = false with no warning and no error_message.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No integer division, no bitwise
-- operators, no utf8, no string.dump, no os.exit, no globals.

local mapping = require("player.mapping")

local dispatch = {}

-- The bare warning CODES.  Formatting (the WARN[...] wrapper) belongs to
-- player/warnings.lua (a later task); dispatch only names the codes.
dispatch.WARN_CUSTOM_INSTRUMENT = "custom-instrument"
dispatch.WARN_PLAY_SOUND_PITCH = "play-sound-pitch"

-- The playSound ratio reference: key 45 (F#4) maps to ratio 1.0.  Mirrors
-- player/mapping.lua rule (4); used ONLY to detect whether the returned ratio
-- was clamped (see branch 2 above).
local RATIO_REFERENCE_KEY = 45

-- ---------------------------------------------------------------------------
-- Result constructors -- one shape everywhere, so callers can rely on it.
-- ---------------------------------------------------------------------------

-- A refusal that made NO call: custom, an unknown kind, or a malformed event.
-- `refused` stays nil (there was nothing to refuse) and there is no error.
local function no_call(speaker_side, warning_code)
  return {
    called = false,
    method = nil,
    speaker_side = speaker_side,
    refused = nil,
    warning_code = warning_code,
  }
end

-- A completed call.  `refused` is the speaker's own boolean signal: true when
-- it returned false.  A successful call carries refused = false, not nil, so
-- "declined" and "accepted" stay distinguishable.
local function completed(method, speaker_side, refused)
  return {
    called = true,
    method = method,
    speaker_side = speaker_side,
    refused = refused,
    warning_code = nil,
  }
end

-- An unusable call: the speaker raised, was missing, or lacked the method.  It
-- is deliberately NOT a refusal (refused = false) and carries the reason.
local function unusable(message, speaker_side)
  return {
    called = false,
    method = nil,
    speaker_side = speaker_side,
    refused = false,
    warning_code = nil,
    error_message = message,
  }
end

-- The speaker's side, when it is a usable record with a string side.
local function side_of(record)
  if type(record) == "table" and type(record.side) == "string" then
    return record.side
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Once-only warning ledger
-- ---------------------------------------------------------------------------

-- Record `code` if it has not been recorded yet and return it; otherwise return
-- nil (already emitted).  The order of first emission is preserved.
local function warn_once(self, code)
  if self._warn_seen[code] then
    return nil
  end
  self._warn_seen[code] = true
  self._warn_order[#self._warn_order + 1] = code
  return code
end

-- ---------------------------------------------------------------------------
-- The pcall boundary: invoke a speaker method and classify the outcome
-- ---------------------------------------------------------------------------

-- method_name is the seam name ("play_note" / "play_sound"); args holds up to
-- three positional arguments.  Always returns a result table; never raises.
local function invoke(record, speaker_side, method_name, args)
  if type(record) ~= "table" then
    return unusable(
      "dispatch: no speaker record supplied for " .. method_name, speaker_side)
  end

  local fn = record[method_name]
  if type(fn) ~= "function" then
    return unusable(
      "dispatch: speaker on side " .. tostring(speaker_side)
        .. " has no " .. method_name .. " method", speaker_side)
  end

  -- Explicit `self`: the speaker record methods take a self parameter.
  local ok, value = pcall(fn, record, args[1], args[2], args[3])
  if not ok then
    return unusable(
      "dispatch: " .. method_name .. " raised: " .. tostring(value), speaker_side)
  end

  -- A speaker returning false is a NORMAL refusal, forwarded unchanged.
  return completed(method_name, speaker_side, value == false)
end

-- ---------------------------------------------------------------------------
-- Branch 1: play_note
-- ---------------------------------------------------------------------------

local function route_play_note(event, record, speaker_side)
  if type(event.name) ~= "string" then
    return no_call(speaker_side, nil)
  end
  -- volume and pitch are forwarded VERBATIM; pitch may be negative (no clamp).
  return invoke(record, speaker_side, "play_note",
    { event.name, event.volume, event.pitch })
end

-- ---------------------------------------------------------------------------
-- Branch 2: play_sound (v6 trumpet -- ratio in 0.5..2.0)
-- ---------------------------------------------------------------------------

local function route_play_sound(self, event, record, speaker_side)
  if type(event.name) ~= "string" or type(event.key) ~= "number" then
    return no_call(speaker_side, nil)
  end

  local ideal = 2 ^ ((event.key - RATIO_REFERENCE_KEY) / 12)
  local ratio = mapping.play_sound_pitch(event.key)
  local result = invoke(record, speaker_side, "play_sound",
    { event.name, event.volume, ratio })

  -- Only warn once we actually made a call, and only when the ratio was clamped
  -- (the clamped value differs from the ideal exactly in that case).
  if result.called and ratio ~= ideal then
    result.warning_code = warn_once(self, dispatch.WARN_PLAY_SOUND_PITCH)
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Public constructor and methods
-- ---------------------------------------------------------------------------

-- dispatch.new(opts) -> d.  `opts` is reserved for forward compatibility and is
-- currently ignored.  Each dispatcher owns its OWN warning ledger, so two
-- concurrent playbacks never share once-only state.
function dispatch.new(opts)
  local d = {
    _warn_order = {},
    _warn_seen = {},
  }

  -- d:event(event, speaker_record) -> result.  Total and non-raising: it handles
  -- a nil/non-table event, an unknown kind, a missing speaker and a raising
  -- speaker method without ever propagating an error.
  function d:event(event, record)
    local speaker_side = side_of(record)

    if type(event) ~= "table" then
      return no_call(speaker_side, nil)
    end

    local kind = event.kind
    if kind == "play_note" then
      return route_play_note(event, record, speaker_side)
    elseif kind == "play_sound" then
      return route_play_sound(self, event, record, speaker_side)
    elseif kind == "custom" then
      return no_call(speaker_side,
        warn_once(self, dispatch.WARN_CUSTOM_INSTRUMENT))
    end

    -- Unknown or missing kind: a refusal with no warning.
    return no_call(speaker_side, nil)
  end

  -- d:warnings() -> a copy of the emitted codes, in emission order.
  function d:warnings()
    local copy = {}
    for index = 1, #self._warn_order do
      copy[index] = self._warn_order[index]
    end
    return copy
  end

  -- d:reset() -> clears the once-only ledger so a fresh playback can warn again.
  function d:reset()
    self._warn_order = {}
    self._warn_seen = {}
  end

  return d
end

return dispatch
