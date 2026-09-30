-- player/plan.lua
--
-- The PURE event planner: turns a decoded NBS song into a FULLY-ORDERED list of
-- timed speaker events.  This module is the DETERMINISM ANCHOR of the player.
--
-- FROZEN PUBLIC INTERFACE
--   local plan = require("player.plan")
--   plan.plan(song, analysis) -> <array of events>
--
--   song      the value produced by nbs.decode (fields used here: header,
--             layers, notes).  NEVER mutated.
--   analysis  the value produced by nbs.analyze (field used here: tick_ms).
--
--   Each event table uses EXACTLY these keys:
--     t_ms          number   = tick_index * analysis.tick_ms
--     tick_index    integer  the note's tick
--     layer_index   integer  the note's layer (0-based)
--     note_index    integer  1-based index WITHIN its (tick, layer) group
--     instrument    integer  the raw NBS instrument id
--     key           integer
--     kind          "play_note" | "play_sound" | "custom"  (instrument_table)
--     name          string, or nil exactly when kind == "custom"
--     custom_index  integer, or nil unless kind == "custom"
--     volume        number, 0..3   (mapping.speaker_volume of combined volume)
--     pitch         integer, semitones, UNCLAMPED (mapping.pitch_semitones)
--     pitch_cents   number, the cents residual (mapping.cents_to_semitones)
--     layer_volume  integer, the source layer's volume (default 100 if missing)
--
-- ===========================================================================
-- THE FROZEN TOTAL ORDER -- THE MOST IMPORTANT REQUIREMENT
-- ===========================================================================
-- Events are sorted ASCENDING by the tuple
--
--     (tick_index, layer_index, note_index)
--
-- note_index is the THIRD and final key.  It is NOT a globally unique id: it is
-- a 1-based position WITHIN each (tick_index, layer_index) group (see below), so
-- it is exactly the field through which the caller's input array order reaches
-- the output.  Two notes in the SAME (tick, layer) group are ordered by the
-- order they appear in `song.notes`; the planner does NOT re-order within a
-- group.  For two notes in DIFFERENT groups the input order is irrelevant.
-- The sort is performed with an EXPLICIT comparison function (see less_event):
-- do NOT "optimise" it away on the assumption that the input is pre-sorted, and
-- do NOT sort by t_ms alone (t_ms is a function of tick_index, so it adds no
-- information and would drop the layer/note tiebreak).
--
-- *** WARNING TO FUTURE EDITORS ***
-- The Tier-2 integration tests assert on the ORDERED sequence of speaker calls
-- the plan produces.  That comparison is only meaningful because this module
-- fixes the order deterministically.  Introducing any dependence on a hash-table
-- iteration order (`pairs`) or on the clock would make those integration
-- assertions flaky.  The input array's order is DELIBERATELY significant for
-- note_index WITHIN a (tick, layer) group, but it must be read from the array
-- POSITIONS -- never from an unordered table walk.  This module must stay a
-- pure, total, deterministic function: no clock, no peripherals, no I/O, no
-- globals, no mutation of its inputs.  Calling plan(song, analysis) twice on the
-- SAME input array must give byte-identical output.
--
-- HOW note_index IS COMPUTED
--   A note_index belongs to a (tick, layer) GROUP and restarts at 1 for each new
--   group.  This module builds an orderable list of the input notes keyed by
--   (tick, layer, position-in-input), sorts THAT list once, and then walks it in
--   order, incrementing a counter while consecutive entries share the same
--   (tick, layer) and resetting it to 1 otherwise.  The input position is the
--   tiebreak for notes already in the same (tick, layer) group, and because that
--   position becomes note_index -- the third sort key -- it DOES determine the
--   emitted order of same-group notes.  The planner never re-orders inside a
--   group; a caller that wants a specific within-group order must supply it in
--   `song.notes`.
--
-- t_ms IS DERIVED, NEVER ACCUMULATED
--   t_ms = tick_index * analysis.tick_ms is computed per event from the note's
--   own tick.  It is deliberately NOT advanced with `previous_t_ms + tick_ms`:
--   progressive addition would accumulate floating-point rounding error and
--   break the drift guarantee a later module relies on.  With a repeating
--   tick_ms (e.g. 1000/3) tick N still reports exactly N * tick_ms.
--
-- MUTED AND NON-SOLO LAYERS ARE NOT PLANNED
--   The NBS per-layer byte the specification calls "Layer lock" is really a
--   mute/solo switch (0 unlocked, 1 muted, 2 solo -- see nbs/layers.lua for the
--   evidence).  A muted layer, and every non-solo layer while any layer is solo,
--   contributes NO events at all.
--
--   Silence means ABSENCE, not zero volume.  A muted note must not spend a speaker
--   call: CC:Tweaked caps a speaker at 8 notes per game tick
--   (SpeakerPeripheral.playNote returns false past `Config.maxNotesPerTick`), so an
--   event emitted at volume 0 would crowd out notes that should sound.
--
--   This is the ONE thing this module decides about a note's audibility, and it
--   decides it with the same rule nbs/analyze.lua uses, so the plan and the
--   capacity analysis can never disagree about which notes will play.
--
-- CUSTOM NOTES ARE STILL EMITTED
--   Apart from the audibility rule above, this module does not decide whether a
--   note is PLAYED; it PLANS.  A custom instrument becomes an event with
--   kind == "custom", name == nil and a custom_index.  The dispatch layer refuses
--   it later.  Emitting it keeps the plan a faithful projection of the AUDIBLE
--   song, which is exactly what makes a plan-vs-recording comparison meaningful.
--
-- MISSING LAYER
--   The decoded layer array is 1-based, so layer_index L reads layers[L + 1].
--   A note referencing a layer beyond the decoded list (or a song with no
--   layers at all) is NOT dropped and does NOT raise: the layer volume defaults
--   to 100, the substitution is recorded in the event's own layer_volume field,
--   and the event is still emitted in its correct place in the order.
--
-- VOLUME
--   mapping.combined_volume(layer_volume, note.velocity) first (the NBS
--   combination formula), then mapping.speaker_volume(combined) (the 0..3
--   speaker scaling), in that order.
--
-- Lua 5.2 / Cobalt constraints honoured: no `//`, no bitwise operators, no
-- utf8.*, no math.maxinteger, no collectgarbage, no string.dump, no os.exit.
-- `pairs` is never used over a hash table anywhere in this module.

local mapping = require("player.mapping")
local instrument_table = require("nbs.instrument_table")
-- The mute/solo rule.  It lives in nbs/layers.lua, next to the code that reads the
-- byte, because nbs/analyze.lua needs the SAME rule -- see the note there.
local layer_format = require("nbs.layers")

local plan = {}

-- The layer volume substituted when a note references a layer that the decoded
-- song does not contain.  100 is NBS's neutral full volume; the event records
-- the substituted value so the defaulting is visible in the plan.
local DEFAULT_LAYER_VOLUME = 100

-- less_event(a, b): the frozen total order, (tick, layer, note), ascending.
-- The ONLY comparator used on the emitted events; there is no tiebreaker after
-- note_index because note_index is unique within any (tick, layer) group.
local function less_event(a, b)
  if a.tick_index ~= b.tick_index then
    return a.tick_index < b.tick_index
  end
  if a.layer_index ~= b.layer_index then
    return a.layer_index < b.layer_index
  end
  return a.note_index < b.note_index
end

-- less_grouped(a, b): the construction-time order, (tick, layer, input
-- position).  Used only to assign note_index deterministically; the emitted
-- order is fixed afterwards by less_event.
local function less_grouped(a, b)
  if a.record.tick ~= b.record.tick then
    return a.record.tick < b.record.tick
  end
  if a.record.layer ~= b.record.layer then
    return a.record.layer < b.record.layer
  end
  return a.position < b.position
end

-- plan.plan(song, analysis) -> array of events.  Pure and total over a decoded
-- song; see the module header for the full contract.
function plan.plan(song, analysis)
  local notes = song.notes or {}
  local layers = song.layers or {}
  local header = song.header or {}
  local vanilla_instrument_count = header.vanilla_instrument_count
  local tick_ms = analysis.tick_ms

  -- Whether the song is in SOLO mode.  Computed ONCE, over the whole layer array,
  -- because a solo on ANY layer silences every non-solo one -- so this cannot be
  -- decided note by note.
  local any_solo = layer_format.any_solo(layers)

  -- Orderable copies of the notes that are actually AUDIBLE.  The input array
  -- itself is only read; `position` is the 1-based input index, used purely to
  -- break ties WITHIN an already-equal (tick, layer) group.
  --
  -- Filtering here rather than inside the emit loop keeps `total` honest and means
  -- the grouping below can only ever see notes that will be emitted.
  local grouped = {}
  local total = 0
  for index = 1, #notes do
    local record = notes[index]
    if layer_format.audible_at(layers, any_solo, record.layer) then
      total = total + 1
      grouped[total] = { record = record, position = index }
    end
  end
  table.sort(grouped, less_grouped)

  local events = {}

  -- note_index bookkeeping: the previous (tick, layer) and its running count.
  local group_tick = nil
  local group_layer = nil
  local group_count = 0

  for index = 1, total do
    local record = grouped[index].record
    local tick = record.tick
    local layer = record.layer

    if tick == group_tick and layer == group_layer then
      group_count = group_count + 1
    else
      group_tick = tick
      group_layer = layer
      group_count = 1
    end
    local note_index = group_count

    -- Layer volume: layers is 1-based, layer_index is 0-based.  A missing layer
    -- (or a layer without a numeric volume) defaults to 100 and still emits.
    local source_layer = layers[layer + 1]
    local layer_volume = DEFAULT_LAYER_VOLUME
    if type(source_layer) == "table"
      and type(source_layer.volume) == "number" then
      layer_volume = source_layer.volume
    end

    -- NBS combination first, then the speaker 0..3 scaling.
    local combined = mapping.combined_volume(layer_volume, record.velocity)

    -- Which call the speaker must make.  resolve() owns the v5-vs-v6 boundary.
    local resolved = instrument_table.resolve(record.instrument,
      vanilla_instrument_count)

    local event = {
      t_ms = tick * tick_ms, -- derived per event; never accumulated
      tick_index = tick,
      layer_index = layer,
      note_index = note_index,
      instrument = record.instrument,
      key = record.key,
      kind = resolved.kind,
      name = resolved.name,
      custom_index = resolved.custom_index,
      volume = mapping.speaker_volume(combined),
      pitch = mapping.pitch_semitones(record.key),
      pitch_cents = mapping.cents_to_semitones(record.pitch),
      layer_volume = layer_volume,
    }

    events[#events + 1] = event
  end

  -- Enforce the frozen total order explicitly.  Do not rely on `grouped` already
  -- being in this order.
  table.sort(events, less_event)

  return events
end

return plan
