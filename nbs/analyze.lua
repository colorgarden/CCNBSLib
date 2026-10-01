-- nbs/analyze.lua
--
-- PURE load-time analysis pass for a decoded Note Block Studio song.
--
-- FROZEN PUBLIC INTERFACE
--   local analyze = require("nbs.analyze")
--   analyze.analyze(song) -> result
--
--   `song` is the value produced by nbs.decode (fields used here: header,
--   notes); `result` has these EXACT field names:
--     total_notes              integer  #song.notes
--     ticks_per_second         number   header.tempo_ticks_per_second
--     tick_ms                  number   1000 / ticks_per_second
--     peak_concurrent          integer  number of notes in the reported window
--     peak_window_ms           integer  50 (constant)
--     vanilla_notes_at_peak    integer  reported-window notes classified "vanilla"
--     play_sound_notes_at_peak integer  reported-window notes classified "play_sound"
--     custom_notes_at_peak     integer  reported-window notes classified "custom"
--     has_extended_range       boolean  true when ANY key is outside 33..57
--     min_key, max_key         integer  over all notes (0 and 0 when there are none)
--     all_notes_custom         boolean  true when the song has notes but NONE of
--                                        them classify as vanilla/play_sound --
--                                        i.e. every note is refused at playback
--     loop = { loop, max_loop_count, loop_start_tick }  copied from the header
--
--   THE REPORTED WINDOW is the 50 ms window that maximises the number of
--   CAPACITY-CONSUMING notes (vanilla + play_sound); ties go to the EARLIEST
--   window.  Custom notes are refused at playback, so they do NOT steer the
--   selection -- a crowd of them must never hide a real vanilla/trumpet burst
--   elsewhere and understate the requirement.  `custom_notes_at_peak` exposes
--   the refused notes that happen to share the reported window, so
--     vanilla_notes_at_peak + play_sound_notes_at_peak + custom_notes_at_peak
--       == peak_concurrent
--   and vanilla_notes_at_peak + play_sound_notes_at_peak is the maximum
--   capacity-consuming count over every 50 ms window in the song.
--
--   A song with NO capacity-consuming note has no requirement to maximise, so
--   the reported window falls back to the all-notes maximum burst; both buckets
--   and the requirement stay 0 while peak_concurrent still describes the
--   song's density.
--
-- This module is a PURE function: it reads no clock, touches no peripheral, does
-- no file I/O and relies on no global mutable state, so calling it twice on the
-- same song yields byte-identical values.  It only READS `song`; it never mutates
-- its input.
--
-- ===========================================================================
-- THE INVARIANT MOST LIKELY TO BE DONE WRONG: NBS TICK != 50 ms GAME TICK
-- ===========================================================================
-- NBS stores tempo as `tempo_raw` in hundredths of a "tick per second", so
--
--     ticks_per_second = tempo_raw / 100
--     ONE NBS TICK     = 1000 / ticks_per_second  milliseconds
--
-- The Minecraft speaker ceiling (one note per instrument per game tick) is
-- enforced per GAME tick, and one game tick is 50 ms -- a DIFFERENT clock from
-- the NBS tick.  Conflating the two is the single most likely bug here.
--
-- Worked example: at 10 NBS ticks/second, `tick_ms` is 100, so every NBS tick
-- spans TWO 50 ms game windows.  Ten notes on one NBS tick share one instant
-- (one window, peak 10), while ten notes on ten CONSECUTIVE NBS ticks are 100 ms
-- apart (ten separate windows, peak 1).  The window test is on millisecond time,
-- never on tick distance.
--
-- PEAK ALGORITHM
--   1. Map each note to a start time in ms: t = note.tick * tick_ms, and
--      classify it ONCE with instrument_table.bucket_of.
--   2. Sort those times ascending.
--   3. Two-pointer sliding window: for each left index i, advance a right index
--      j while times[j] - times[i] < 50 (STRICT `<`, so a gap of exactly 50 ms
--      starts a new window).
--   4. The REPORTED window is the one maximising the count of capacity-
--      CONSUMING notes (vanilla + play_sound) inside it -- NOT the total count.
--      Custom notes consume nothing and are refused at playback, so letting
--      them win the selection is exactly the bug that reported required == 0
--      while a vanilla burst elsewhere would drop.  A prefix sum of the
--      capacity flags makes each window's capacity count O(1).  Anchoring the
--      left edge on a note is complete: the maximum over all 50 ms windows is
--      attained by a window whose left edge sits on some note, and sliding an
--      optimal window's left edge right to its first capacity-consuming note
--      keeps every such note inside.
--   5. peak_concurrent is the number of ALL notes in the reported window
--      (customs included) -- that is the field's frozen meaning.  When the song
--      has no capacity-consuming note at all, step 4 has no maximum to find,
--      so the fallback is the all-notes maximum burst; the buckets and the
--      requirement stay 0.
--
-- INSTRUMENT BUCKETS (only the reported window is classified)
--   The classification rule has ONE owner: nbs/instrument_table.bucket_of --
--   the same classifier player/plan.lua reaches through resolve().  A
--   re-implementation here (hardcoded 0..15 / 16..19 constants) previously
--   DISAGREED with resolve for vanilla counts 10 and 17..19, which
--   under-budgeted speakers for v6 trumpets and produced a bogus "speakers"
--   warning for legacy custom ids.  Delegating keeps the analyzer's budget
--   identical to the calls the player will actually make:
--     vanilla     below the file's vanilla boundary, id 0..15
--     play_sound  16..19 below that boundary (the v6 "trumpet" native sounds)
--     custom      anything else -- refused at playback, so it counts toward
--                 NEITHER bucket AND does not steer the peak selection; it is
--                 reported separately as custom_notes_at_peak when it shares
--                 the window the requirement was computed from.
--
-- TIE-BREAK (deterministic)
--   When several distinct windows attain the same maximum CAPACITY count, the
--   reported split is taken from the EARLIEST window in time (the smallest left
--   index).  The selection loop only replaces the recorded peak on a STRICT
--   increase, so the first window to reach the maximum wins.
--
-- Lua 5.2 / Cobalt constraints honoured: no `//`, no bitwise operators, no
-- utf8.*, no math.maxinteger, no collectgarbage, no string.dump, no os.exit.

local instrument_table = require("nbs.instrument_table")
local mapping = require("player.mapping")
-- The mute/solo rule, shared with player/plan.lua so analysis and the plan can
-- never disagree about which notes will play.  nbs/layers.lua requires nothing,
-- so this adds no cycle.
local layers_module = require("nbs.layers")

local analyze = {}

-- One Minecraft game tick, in milliseconds.  This is the speaker-ceiling window.
local PEAK_WINDOW_MS = 50
-- `playNote` calls one speaker accepts per game tick.  Read from nbs.speakers so the
-- number 8 exists in exactly ONE place -- this module's window selection and that
-- module's requirement formula must never disagree about the cost of a note.
local speakers_module = require("nbs.speakers")
local PEAK_NOTES_PER_TICK = speakers_module.MAX_NOTES_PER_TICK

-- Native two-octave key range (33 = F#3, 45 = F#4, 57 = F#5), inclusive.
-- The NUMBERS are owned in ONE place: player/mapping.lua's public
-- NATIVE_MIN_KEY / NATIVE_MAX_KEY.  Referencing them here keeps the analyzer's
-- extended-range boundary identical to the mapping the player uses;
-- mapping.lua requires nothing, so this creates no require cycle.

-- analyze.analyze(song) -> result
-- analyze.analyze(song, opts) -> result
--
-- opts.out_of_range  the playback policy, mirroring player/plan.lua's, because the
--                    two MUST agree: `mapping.route` decides whether a note costs a
--                    playNote slot (8 per speaker-tick) or a playSound slot (ONE).
--                    Counting it as the cheaper one here would under-report the
--                    speaker requirement and notes would be dropped at playback.
function analyze.analyze(song, opts)
  local header = song.header or {}
  local notes = song.notes or {}
  local layers = song.layers or {}
  local total_notes = #notes

  local ticks_per_second = header.tempo_ticks_per_second
  local tick_ms = 1000 / ticks_per_second

  -- MUTED AND NON-SOLO LAYERS ARE EXCLUDED, using the SAME rule player/plan.lua
  -- uses to decide which notes become events (nbs/layers.lua owns it).  If the two
  -- disagreed, every capacity figure below would describe notes that will never
  -- play: the fan-out sizes itself from `peak_concurrent` and
  -- nbs.speakers.required_count(analysis), so an inflated peak means a spurious
  -- "not enough speakers" warning and dropped events.
  --
  -- `total_notes` deliberately still counts the FILE's notes -- it is a fact about
  -- the song, not a playback prediction -- so on a song with muted layers it is
  -- legitimately larger than the number of events the planner emits.
  local any_solo = layers_module.any_solo(layers)
  local out_of_range = type(opts) == "table" and opts.out_of_range
    or mapping.DEFAULT_OUT_OF_RANGE

  -- Key range + extended-range scan (over every AUDIBLE note, independent of the
  -- 50 ms window) plus ONE classification pass: each note's bucket is decided here
  -- by the single owner of the rule (instrument_table.bucket_of), and the SAME
  -- decision is kept for the window pass below -- so the window selection and
  -- the reported split can never disagree.
  local min_key = 0
  local max_key = 0
  local has_extended_range = false
  -- How many notes the player can actually schedule (vanilla or play_sound).
  -- A note that is neither is a custom instrument, refused at playback; when
  -- this stays 0 on a non-empty song the whole song is silent.
  local playable_notes = 0
  -- How many notes CONSUME speaker capacity (vanilla + play_sound).  Customs do
  -- not, so they must not influence which window is reported.
  local capacity_notes = 0
  local items = {}
  for index = 1, total_notes do
    local note = notes[index]

    if layers_module.audible_at(layers, any_solo, note.layer) then
      local key = note.key
      if #items == 0 then
        -- The FIRST audible note seeds the range, not the file's first note: a
        -- muted note must not define the song's key span.
        min_key = key
        max_key = key
      else
        if key < min_key then
          min_key = key
        end
        if key > max_key then
          max_key = key
        end
      end
      if key < mapping.NATIVE_MIN_KEY or key > mapping.NATIVE_MAX_KEY then
        has_extended_range = true
      end
      -- THE EFFECTIVE bucket, not the instrument's own. `mapping.route` is the single
      -- owner of "which call does this note become?", and it folds in the shift
      -- policy: a vanilla note too far outside its recording's octave becomes a
      -- playSound, which costs a whole speaker-tick instead of a share of eight.
      local instrument_bucket = instrument_table.bucket_of(note.instrument,
        header.vanilla_instrument_count)
      local bucket = mapping.route(instrument_bucket, note.key, out_of_range)
      local consumes = bucket == "play_note" or bucket == "play_sound"
      if consumes then
        playable_notes = playable_notes + 1
        capacity_notes = capacity_notes + 1
      end
      items[#items + 1] = {
        t = note.tick * tick_ms,
        bucket = bucket,
        consumes = consumes,
      }
    end
  end

  table.sort(items, function(a, b)
    return a.t < b.t
  end)

  -- The window scans below run over the AUDIBLE notes, which is what `items`
  -- holds.  It is PACKED, so it has `audible_notes` entries and indexing it with
  -- the file's note count runs off the end.  `total_notes` stays the file's count
  -- for the reported field, and the two are equal on any song without muted
  -- layers -- which is every fixture, so the suite could not have caught the
  -- difference. A real 65-layer song with muted layers is what exposed it.
  local audible_notes = #items

  -- Two-pointer sliding window over the sorted times.  `j` is monotonic: as the
  -- left edge moves right the window can only extend, never retract, so a single
  -- forward pass is exact.
  --
  -- WHAT THE WINDOW MAXIMISES: when the song has any capacity-consuming note,
  -- the reported window is the one holding the most of them (customs count for
  -- nothing and must never win the selection); ties keep the EARLIEST window.
  -- peak_span is the number of ALL notes in that window -- what peak_concurrent
  -- has always meant.
  local peak_capacity = 0
  local peak_left = nil
  local peak_span = 0
  if capacity_notes > 0 then
    -- TWO prefix sums, because the two kinds of note cost DIFFERENT amounts of a
    -- speaker. A play_note shares a tick with seven others; a play_sound takes the
    -- whole tick. So the window that needs the most speakers is NOT the window with
    -- the most notes, and selecting by raw count -- which is what this used to do --
    -- picks the wrong one as soon as a song mixes the two.
    --
    -- Worked example of the disagreement: a window with 1 play_note and 2
    -- play_sounds needs ceil(1/8) + 2 = 3 speakers, while a window with 3 play_notes
    -- needs ceil(3/8) = 1. Counting notes ranks the second higher.
    --
    -- The cost function here is EXACTLY nbs.speakers.required_count's formula, so the
    -- window it selects is the one that formula is describing.
    local note_prefix = {}
    local sound_prefix = {}
    note_prefix[0] = 0
    sound_prefix[0] = 0
    for index = 1, audible_notes do
      local bucket = items[index].bucket
      note_prefix[index] = note_prefix[index - 1]
        + (bucket == "play_note" and 1 or 0)
      sound_prefix[index] = sound_prefix[index - 1]
        + (bucket == "play_sound" and 1 or 0)
    end

    local j = 1
    for i = 1, audible_notes do
      if j < i then
        j = i
      end
      while j <= audible_notes and items[j].t - items[i].t < PEAK_WINDOW_MS do
        j = j + 1
      end
      local notes_in_window = note_prefix[j - 1] - note_prefix[i - 1]
      local sounds_in_window = sound_prefix[j - 1] - sound_prefix[i - 1]
      -- The same arithmetic as speakers.required_count, applied to this window.
      local cost = math.floor(notes_in_window / PEAK_NOTES_PER_TICK)
        + (notes_in_window % PEAK_NOTES_PER_TICK > 0 and 1 or 0)
        + sounds_in_window
      if cost > peak_capacity then
        peak_capacity = cost
        peak_left = i
        peak_span = j - i
      end
    end
  else
    -- No capacity-consuming note anywhere: nothing can be scheduled, so there
    -- is no requirement to maximise.  Fall back to the all-notes maximum burst
    -- so peak_concurrent still reports the song's density; both buckets and the
    -- requirement stay 0.
    local j = 1
    for i = 1, audible_notes do
      if j < i then
        j = i
      end
      while j <= audible_notes and items[j].t - items[i].t < PEAK_WINDOW_MS do
        j = j + 1
      end
      local count = j - i
      if count > peak_span then
        peak_span = count
        peak_left = i
      end
    end
  end

  -- Classify the reported window.  A strict `>` in the selection loops means the
  -- earliest window that attains the maximum is the one recorded.
  local vanilla_at_peak = 0
  local play_sound_at_peak = 0
  local custom_at_peak = 0
  if peak_left ~= nil and peak_span > 0 then
    for index = peak_left, peak_left + peak_span - 1 do
      -- ONE classifier already ran above: the very same function player/plan.lua
      -- reaches through instrument_table.resolve, so the analyzer and the
      -- allocator can never disagree about which notes need a playNote and
      -- which need a playSound.
      local bucket = items[index].bucket
      if bucket == "play_note" then
        vanilla_at_peak = vanilla_at_peak + 1
      elseif bucket == "play_sound" then
        play_sound_at_peak = play_sound_at_peak + 1
      else
        custom_at_peak = custom_at_peak + 1
      end
    end
  end

  return {
    total_notes = total_notes,
    ticks_per_second = ticks_per_second,
    tick_ms = tick_ms,
    -- The number of notes in the REPORTED window, customs included.  The
    -- window itself is chosen by the capacity-consuming count, so
    -- vanilla + play_sound + custom == peak_concurrent and vanilla +
    -- play_sound is the maximum capacity-consuming count over every 50 ms
    -- window of the song.
    peak_concurrent = peak_span,
    peak_window_ms = PEAK_WINDOW_MS,
    vanilla_notes_at_peak = vanilla_at_peak,
    play_sound_notes_at_peak = play_sound_at_peak,
    -- How many of the reported window's notes are custom (refused at playback):
    -- they are excluded from the selection and from the speaker requirement.
    custom_notes_at_peak = custom_at_peak,
    has_extended_range = has_extended_range,
    min_key = min_key,
    max_key = max_key,
    -- True for a non-empty song in which EVERY note is refused at playback
    -- (custom instrument ids).  A plain boolean, derived from the whole song --
    -- NOT from the reported window, whose buckets can be 0/0 for a song that
    -- still has playable notes elsewhere.
    --
    -- Based on the AUDIBLE note count, not the file's: a song whose every layer is
    -- muted also plays nothing, and reporting that as "all notes are custom
    -- instruments" would name the wrong cause.
    all_notes_custom = audible_notes > 0 and playable_notes == 0,
    loop = {
      loop = header.loop,
      max_loop_count = header.max_loop_count,
      loop_start_tick = header.loop_start_tick,
    },
  }
end

return analyze
