-- nbs/layers.lua
--
-- NBS layers-section parser.
--
-- The layers section is the only part of an .nbs file whose layout changes
-- with the song version, so this module is a thin, version-gated walk over the
-- shared byte cursor (nbs/reader.lua).  It performs NO decoding of its own:
-- every field is read through the cursor, and every overrun surfaces as the
-- cursor's typed E_TRUNCATED table.
--
-- FROZEN PUBLIC INTERFACE
--   local layers = require("nbs.layers")
--   layers.parse(r, version, layer_count) -> <array of layer records>
--
--   r           a cursor from nbs.reader.new(bytes)
--   version     the song version, already read by the header parser
--   layer_count the number of layer records that follow, UNTRUSTED
--
-- Each returned record has EXACTLY these keys:
--   name     string, BYTE-EXACT (CP1252 bytes, never transcoded here)
--   lock     0 = unlocked, 1 = locked, 2 = SOLO ; nil when version < 4
--   volume   integer 0..100
--   panning  integer 0..200 (100 = centre) ; nil when version < 2
--
-- RECORD LAYOUT (read layer_count times, in order)
--   str name                          -- i32 length + raw bytes
--   u8  lock     -- ONLY when version >= 4
--   u8  volume   -- 0..100
--   u8  panning  -- ONLY when version >= 2  (0..200, 100 = centre)
--
-- Version matrix:
--   v0, v1        name + volume
--   v2, v3        name + volume + panning
--   v4 and above  name + lock + volume + panning
--
-- The lock byte and the panning byte are ABSENT on older versions.  Reading
-- them unconditionally would consume the next field (or the next record) and
-- silently desynchronise the entire section, so both gates are explicit below.
--
-- LOCK SEMANTICS -- three values, not two
--   The public documentation mentions only 0 (unlocked) and 1 (locked), but
--   the real format also uses 2 = SOLO.  This parser exposes the raw integer
--   verbatim; it neither rejects 2 nor folds it into 0 or 1.  Acting on solo
--   is a playback concern and lives in a later layer.
--
-- SAFETY
--   layer_count comes from the file and is untrusted (the format docs warn
--   that more than 200 layers can crash some NBS versions).  Every record
--   consumes at least 5 bytes -- a 4-byte string length plus at least one
--   volume byte -- so a count larger than the remaining byte budget cannot be
--   honest.  The guard below rejects such a count BEFORE any table is sized or
--   any record is read; it raises a typed table:
--     { code = "E_BAD_LAYER_COUNT", msg = <string>,
--       layer_count = <n>, remaining = <n> }
--   via error(table, 0), mirroring the reader's typed-error contract so the
--   boundary layer can branch on `.code`.  A hostile count can therefore never
--   drive a large allocation or a long loop.
--
-- Cobalt / Lua 5.2 constraints: no `//`, no bitwise operators, no goto, no
-- utf8.*, no math.maxinteger, no collectgarbage.  Only arithmetic, string and
-- table operations are used.

local layers = {}

-- Smallest possible on-disk size of one layer record: a 4-byte string length
-- (the name may be empty, but the length prefix is always present) plus a
-- 1-byte volume.  Documented here for readers; the guard uses the simpler and
-- strictly-weaker bound `layer_count <= remaining`, which is sufficient to make
-- the loop and its allocations bounded by the input size.
local MIN_RECORD_BYTES = 5

-- layers.parse(r, version, layer_count) -> array of layer records.
--
-- Raises a typed error table on:
--   * an implausible layer_count  -> { code = "E_BAD_LAYER_COUNT", ... }
--   * a truncated name/scalar     -> { code = "E_TRUNCATED", ... } (from reader)
function layers.parse(r, version, layer_count)
  -- Untrusted-count guard.  Must run BEFORE the loop and before any array is
  -- sized by `layer_count`: if the caller promises more records than there are
  -- bytes left to describe them (each record needs at least MIN_RECORD_BYTES,
  -- in particular at least one byte), the count is impossible.
  local remaining = r:remaining()
  if layer_count > remaining then
    error({
      code = "E_BAD_LAYER_COUNT",
      msg = string.format(
        "layer_count %d exceeds the %d byte(s) remaining for the section",
        layer_count, remaining),
      layer_count = layer_count,
      remaining = remaining,
    }, 0)
  end

  local result = {}
  local index = 1
  while index <= layer_count do
    local name = r:read_string()

    local lock = nil
    if version >= 4 then
      lock = r:u8()
    end

    local volume = r:u8()

    local panning = nil
    if version >= 2 then
      panning = r:u8()
    end

    result[index] = {
      name = name,
      lock = lock,
      volume = volume,
      panning = panning,
    }
    index = index + 1
  end

  return result
end

-- ---------------------------------------------------------------------------
-- WHAT THE LOCK BYTE MEANS (it is a mute/solo switch, not an editor permission)
-- ---------------------------------------------------------------------------
-- The NBS specification calls this byte "Layer lock" and documents only "1 =
-- locked", which reads like an editor convenience. The OpenNBS project's own issue
-- tracker corrects that (OpenNBS/NoteBlockStudio#307):
--
--   "The 'Layer lock' field, originally intended to be a boolean, may actually
--    assume values 0-2 (0= unlocked, 1=locked, 2=solo). This is currently
--    undocumented in the NBS specification..."
--
-- and a developer in the same thread says the field is what people use to "mute
-- incomplete sections of the song or single out certain layers".
--
-- The decisive argument is SOLO: a value of 2 is a PLAYBACK concept, and solo
-- cannot exist without a corresponding mute. So 1 mutes, and a player that ignores
-- it plays audio the author deliberately silenced. Measured on a real song
-- (THE KING.nbs, 65 layers): 3 layers carried lock=1 with 903 notes, all of which
-- were being played.
--
-- The rule lives HERE, next to the code that reads the byte, because TWO modules
-- need it and they must agree: player/plan.lua decides which notes become events,
-- and nbs/analyze.lua predicts how many speakers those events need. If the two
-- disagreed, the analysis would size the fan-out for notes that will never play.

-- The three values the byte can take.
layers.UNLOCKED = 0
layers.MUTED = 1
layers.SOLO = 2

-- layers.any_solo(layer_array) -> boolean
--
-- True when ANY layer in the song is solo.  A solo on one layer silences every
-- non-solo layer, so this is a property of the SONG, not of a layer, and it has to
-- be known before any single note can be judged.
function layers.any_solo(layer_array)
  if type(layer_array) ~= "table" then
    return false
  end
  for index = 1, #layer_array do
    local record = layer_array[index]
    if type(record) == "table" and record.lock == layers.SOLO then
      return true
    end
  end
  return false
end

-- layers.audible(lock, any_solo) -> boolean
--
-- Whether a layer carrying this lock byte contributes notes.
--
--   lock is nil   a v0-v3 file has no lock byte at all, so nil MUST read as
--                 unmuted; treating it as truthy would silence every old song
--   lock = 0      unlocked: plays unless some other layer is solo
--   lock = 1      MUTED: never plays
--   lock = 2      SOLO: plays, and silences every layer that is not solo
--
-- Written as a function rather than an inline expression because the rule has four
-- cases and an inline version is exactly where the next reader would go wrong.
function layers.audible(lock, any_solo)
  if any_solo then
    -- Solo silences everything that is not itself solo -- including ordinary
    -- unlocked layers and, for the same reason, muted ones.
    return lock == layers.SOLO
  end
  return lock ~= layers.MUTED
end

-- layers.audible_at(layer_array, any_solo, layer_index) -> boolean
--
-- The same decision for a 0-based layer_index from a note record.  layer_array is
-- 1-based, so layer L is layer_array[L + 1].  A reference to a layer that the
-- decoded song does not contain has no lock byte, so it is judged as UNLOCKED --
-- which keeps the pre-existing "a missing layer still emits" contract, and, under
-- solo, correctly leaves it silent because it is not itself solo.
function layers.audible_at(layer_array, any_solo, layer_index)
  if type(layer_index) ~= "number" then
    return true
  end
  local record = nil
  if type(layer_array) == "table" then
    record = layer_array[layer_index + 1]
  end
  local lock = nil
  if type(record) == "table" then
    lock = record.lock
  end
  return layers.audible(lock, any_solo)
end

return layers
