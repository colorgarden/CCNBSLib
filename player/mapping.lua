-- player/mapping.lua
--
-- The ONE frozen place where NBS numbers become CC:Tweaked speaker arguments.
--
-- Every later layer (plan/speaker/dispatch/fanout) asserts on the EXACT numbers
-- this module hands to `speaker.playNote` / `speaker.playSound`, so this module
-- is deliberately a set of PURE, TOTAL, documented functions with NO state and
-- NO "helpful" corrections.  Two product decisions below are counter-intuitive
-- and MUST be honoured exactly.
--
-- ---------------------------------------------------------------------------
-- 1. Volume formula
-- ---------------------------------------------------------------------------
-- NBS stores a per-layer volume (0..100) and a per-note velocity (0..100); the
-- audible combination is their product scaled back to 0..100:
--
--     combined_volume = (layer_volume * note_velocity) / 100
--
-- A legacy note has no stored velocity, so the decoder supplies 100 for it (the
-- neutral element), and combined_volume(layer, 100) == layer.
--
-- The speaker's own volume argument is a 0.0..3.0 scalar:
--
--     speaker_volume(v) = clamp(round_half_up(v / 100 * 3), 0, 3)
--
-- Rounding is HALF UP: `floor(x + 0.5)`, so 1.5 -> 2. This is documented and
-- pinned by the test suite.  Inputs outside 0..100 clamp.
--
-- ---------------------------------------------------------------------------
-- 2. Pitch (playNote semitones) is NOT CLAMPED -- product decision
-- ---------------------------------------------------------------------------
--     pitch_semitones(key) = key - 33
--
-- NBS key 33 (F#3) is semitone 0, key 45 (F#4) is 12, key 57 (F#5) is 24 -- a
-- two-octave native range -- but Minecraft's note-block pitch accepts
-- out-of-range values and community "extended range" resource packs supply the
-- extra samples.  Clamping to 0..24 here would SILENTLY BREAK the extended-range
-- feature this project promises, so we do NOT clamp: key 20 -> -13 and key 90
-- -> 57 are passed through verbatim.  Out-of-native-range notes are reported to
-- the user by a separate warning layer (not here) -- the mapping never decides
-- what is playable, it only translates.
--
-- ---------------------------------------------------------------------------
-- 3. Panning is DROPPED -- CC:Tweaked has no per-note panning
-- ---------------------------------------------------------------------------
-- NBS layers carry a panning value (0..200), but `speaker.playNote` and
-- `speaker.playSound` have no panning argument.  We therefore drop panning
-- entirely: this module deliberately exposes NO panning function and no caller
-- may invent an extra argument.  Stereo placement is simply not representable.
--
-- ---------------------------------------------------------------------------
-- 4. playSound pitch limitation (ratio, clamped to 0.5..2.0)
-- ---------------------------------------------------------------------------
--     play_sound_pitch(key) = clamp(2 ^ ((key - 45) / 12), 0.5, 2.0)
--
-- `speaker.playSound` takes a RATIO in 0.5..2.0 (about +/- one octave) around
-- the reference key 45 (F#4), which is ratio 1.0.  A note whose key lies far
-- outside that window cannot be represented faithfully: we clamp so it stays
-- audible but its pitch WILL be wrong.  This is preferable to throwing, and the
-- mismatch is surfaced by the warning layer, not hidden here.
--
-- cents_to_semitones(c) = c / 100 exposes the NBS per-note cents offset as an
-- explicit, testable residual.  `playNote`'s pitch argument is an INTEGER number
-- of semitones, so the caller DROPS this residual -- the drop is intentional and
-- kept separate from pitch_semitones() so it is visible rather than smuggled in.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No integer division, no bitwise
-- operators, no utf8, no state.

local mapping = {}

-- The boundaries of the native NBS key range (a two-octave window).  This is the
-- AUTHORITATIVE definition: nbs/analyze.lua references these two values for its
-- extended-range boundary, and the test suite pins them, so there
-- is exactly ONE copy of 33 / 57 in the codebase.  These are NOT clamp bounds
-- for pitch_semitones -- see the module header.
mapping.NATIVE_MIN_KEY = 33
mapping.NATIVE_MAX_KEY = 57

-- The reference key for the playSound ratio: key 45 (F#4) maps to ratio 1.0.
local RATIO_REFERENCE_KEY = 45
-- The speaker's playSound pitch ratio window (about one octave either way).
local RATIO_MIN = 0.5
local RATIO_MAX = 2.0

-- clamp(value, lo, hi): returns value clamped into [lo, hi].  Used by the
-- bounded outputs only; pitch_semitones is intentionally left unbounded.
local function clamp(value, lo, hi)
  if value < lo then
    return lo
  end
  if value > hi then
    return hi
  end
  return value
end

-- round_half_up(x): floor(x + 0.5).  17/100*3 = 0.51 is the first volume that
-- rounds up to 1 (16/100*3 = 0.48 rounds down to 0), and 1.5 -> 2 at volume 50,
-- matching the boundary table in the spec.
local function round_half_up(x)
  return math.floor(x + 0.5)
end

-- mapping.speaker_volume(volume_0_to_100) -> number in 0..3
--
-- Scales an NBS 0..100 volume onto the speaker's 0.0..3.0 volume argument,
-- rounding half up and clamping out-of-range inputs.  See rule (1) above.
function mapping.speaker_volume(volume_0_to_100)
  return clamp(round_half_up(volume_0_to_100 / 100 * 3), 0, 3)
end

-- mapping.pitch_semitones(key) -> integer, key - 33, UNCLAMPED
--
-- Translates an NBS key to playNote's semitone offset.  DELIBERATELY NOT
-- CLAMPED: extended-range resource packs make out-of-range pitches meaningful,
-- and the warning layer -- not this function -- decides what to complain about.
-- See rule (2) above.
function mapping.pitch_semitones(key)
  return key - 33
end

-- mapping.combined_volume(layer_volume, note_velocity) -> number in 0..100
--
-- Combines the two 0..100 NBS volumes with the product formula, then clamps to
-- 0..100.  A legacy note's missing velocity is supplied as 100 by the decoder.
function mapping.combined_volume(layer_volume, note_velocity)
  return clamp((layer_volume * note_velocity) / 100, 0, 100)
end

-- mapping.play_sound_pitch(key) -> number ratio, clamped into 0.5..2.0
--
-- The ideal ratio is 2 ^ ((key - 45) / 12) around the key-45 reference; it is
-- clamped into playSound's 0.5..2.0 window.  Keys far from 45 are audible but
-- pitched wrong -- a documented limitation, see rule (4) above.
function mapping.play_sound_pitch(key)
  local ideal = 2 ^ ((key - RATIO_REFERENCE_KEY) / 12)
  return clamp(ideal, RATIO_MIN, RATIO_MAX)
end

-- mapping.cents_to_semitones(pitch_cents) -> number, pitch_cents / 100
--
-- Exposes the NBS cents offset as an explicit residual.  The caller DROPS it
-- when building the integer playNote pitch; keeping it here (and out of
-- pitch_semitones) makes that intentional drop visible and testable.
function mapping.cents_to_semitones(pitch_cents)
  return pitch_cents / 100
end

-- ---------------------------------------------------------------------------
-- 5. Extended range: a different RECORDING, not a different pitch
-- ---------------------------------------------------------------------------
-- THE LIMIT THIS WORKS AROUND.  `playNote` takes semitones and the server passes
-- them through -- `SpeakerPeripheral.playNote` only calls `checkFinite` -- but the
-- CLIENT flattens the result: `SoundEngine.calculatePitch` calls `Mth.clamp` with
-- PITCH_MIN/PITCH_MAX, i.e. 0.5..2.0.  So one recording reaches exactly one octave
-- either side of its own pitch, and anything beyond that is heard as the edge note.
--
-- THE WAY OUT.  The octave comes from WHICH FILE plays, not from the pitch.  The
-- extranotes resource pack ships by OpenNBS registers the same instruments recorded
-- two octaves up and down:
--
--     block.note_block.<instrument>_1     two octaves above the original
--     block.note_block.<instrument>_-1    two octaves below
--
-- Playing `_1` at a ratio in 0.5..2.0 therefore covers the two octaves ABOVE the
-- native range, and `_-1` the two below -- six octaves in total, key 9..81, against
-- NBS's own 0..87.
--
-- `speaker.playSound` can name any of them.  CC does NOT check that a sound is
-- registered -- `tryGetRegistryObject` is consulted only to refuse music discs, and
-- a null result passes -- so the name reaches the client, which resolves it against
-- its own resource packs.  That also means the honest trade-off: a shifted note is
-- SILENT on a client without the pack, where passing the raw pitch through would
-- have been audible at the wrong pitch.  That is why the caller chooses a policy.

-- The register of recordings: the native two octaves, plus one either side.
mapping.SHIFTED_LOW_KEY = 9    -- key 9  -> pitch -24 -> the _-1 recording
mapping.SHIFTED_HIGH_KEY = 81  -- key 81 -> pitch  48 -> the _1 recording

-- The distance between recordings, in semitones: two octaves.
local RECORDING_SPAN = 24

-- mapping.shifted_sound_name(name, suffix) -> string
--
-- `name` is the instrument's own name as `instrument_table` already produces it
-- (harp, bass, pling, ...).  Those 16 names are EXACTLY the ones the pack registers,
-- compared against the pack's own sounds.json, so no translation table is needed.
function mapping.shifted_sound_name(name, suffix)
  return "block.note_block." .. tostring(name) .. tostring(suffix)
end

-- mapping.shift_for_key(key) -> { suffix = "_-1" | "_1", ratio = <number> } | nil
--
-- nil when the key is inside the native range, which means "keep using playNote" --
-- the cheap path, eight notes per speaker per tick.  A non-nil result means the note
-- has to go through playSound with a different recording, which costs a whole
-- speaker-tick per note.
--
-- The ratio is `play_sound_pitch` called with the key moved by one recording span,
-- so the arithmetic stays in the one place that already owns it:
--
--   _1  recording is 24 semitones higher, so ask for a key 24 lower
--   _-1 recording is 24 semitones lower,  so ask for a key 24 higher
--
-- Over each shifted range that ratio spans exactly 0.5000 .. 2.0000 -- verified --
-- which is why one extra recording per two octaves is precisely enough and nothing
-- inside the range needs clamping.
function mapping.shift_for_key(key)
  if type(key) ~= "number" then
    return nil
  end
  if key >= mapping.NATIVE_MIN_KEY and key <= mapping.NATIVE_MAX_KEY then
    return nil
  end
  if key > mapping.NATIVE_MAX_KEY then
    return { suffix = "_1", ratio = mapping.play_sound_pitch(key - RECORDING_SPAN) }
  end
  return { suffix = "_-1", ratio = mapping.play_sound_pitch(key + RECORDING_SPAN) }
end

-- THE FOUR POLICIES for a note outside its recording's own octave. They exist
-- because the situation has no single right answer: it depends on whether the client
-- has the extra recordings and on what the listener would rather hear.
--
--   SHIFT        play an octave-shifted RECORDING -- correct pitch, needs the pack
--   PASSTHROUGH  send the raw semitones and let the client flatten them to 0.5..2.0
--   CLAMP        flatten them OURSELVES, to the native 0..24 range
--   DROP         do not play the note at all
--
-- SHIFT and PASSTHROUGH differ in whether a resource pack is required; CLAMP and DROP
-- are for a listener who has decided the note is wrong either way and prefers a
-- predictable result. DROP removes the note from the plan entirely, so it costs no
-- speaker slot -- the same treatment a muted layer gets.
mapping.OUT_OF_RANGE_SHIFT = "shift"
mapping.OUT_OF_RANGE_PASSTHROUGH = "passthrough"
mapping.OUT_OF_RANGE_CLAMP = "clamp"
mapping.OUT_OF_RANGE_DROP = "drop"

-- Every accepted policy, in the order a menu should offer them: the one that fixes
-- the pitch first, then the two that trade pitch for audibility, then silence.
mapping.OUT_OF_RANGE_POLICIES = {
  mapping.OUT_OF_RANGE_SHIFT,
  mapping.OUT_OF_RANGE_PASSTHROUGH,
  mapping.OUT_OF_RANGE_CLAMP,
  mapping.OUT_OF_RANGE_DROP,
}

-- mapping.DEFAULT_OUT_OF_RANGE -- and the default is SHIFT, deliberately.
--
-- Defaulting to passthrough would mean the resource pack never changes anything: an
-- out-of-range note would still arrive as a plain pitch and still be clamped, so the
-- extended range would exist in the code and not in the ear. The feature has to be on
-- for the pack to matter.
--
-- The trade-off is real and is the reason the warning exists: on a client without the
-- pack a shifted name resolves to nothing, so the note is SILENT rather than merely
-- mistuned. `extended-range` says so at the start of playback. Anyone who prefers
-- always-audible-but-wrong can pass "passthrough".
mapping.DEFAULT_OUT_OF_RANGE = mapping.OUT_OF_RANGE_SHIFT

-- mapping.clamped_pitch(key) -> integer in 0..24
--
-- `pitch_semitones` moved to the native edges. This is the CLAMP policy: the note
-- still plays, on the nearest native pitch, so the result is predictable rather than
-- dependent on whatever the client does with an out-of-range pitch.
function mapping.clamped_pitch(key)
  local pitch = mapping.pitch_semitones(key)
  if type(pitch) ~= "number" then
    return 0
  end
  if pitch < 0 then
    return 0
  end
  if pitch > 24 then
    return 24
  end
  return pitch
end

-- mapping.route(bucket, key, out_of_range) -> "play_note" | "play_sound" | "custom"
--
-- THE single owner of "which call does this note become?".  Two modules need this
-- answer and they MUST agree:
--
--   player/plan.lua    decides the event's kind, i.e. which call is made
--   nbs/analyze.lua    counts how many notes consume a speaker-tick, i.e. how many
--                      speakers are needed
--
-- If they disagreed, the analysis would size the fan-out for a different cost than
-- the plan actually incurs -- telling the user "two speakers is enough" while notes
-- are dropped.  So the rule lives here, once, and both call it.
--
-- `bucket` is instrument_table's classification ("vanilla" | "play_sound" |
-- "custom").  `out_of_range` is the caller's policy.
function mapping.route(bucket, key, out_of_range)
  if bucket == "custom" then
    -- A custom instrument is refused at playback and costs nothing.
    return "custom"
  end
  if bucket == "play_sound" then
    -- Already a name-based sound; the policy does not change that.
    return "play_sound"
  end

  -- A vanilla note inside its recording's own octave is untouched by any policy.
  if mapping.shift_for_key(key) == nil then
    return "play_note"
  end

  if out_of_range == mapping.OUT_OF_RANGE_SHIFT then
    -- A different RECORDING carries the octave, so this becomes a playSound, which
    -- costs a whole speaker-tick rather than a share of eight.
    return "play_sound"
  end
  if out_of_range == mapping.OUT_OF_RANGE_DROP then
    -- "dropped" is a fourth outcome, not a kind of call: player/plan.lua emits no
    -- event for it and nbs/analyze.lua counts it as nothing, so a dropped note costs
    -- no speaker slot at all.
    return "dropped"
  end

  -- PASSTHROUGH and CLAMP both stay a playNote; they differ only in the pitch
  -- argument, which player/plan.lua chooses.
  return "play_note"
end

return mapping
