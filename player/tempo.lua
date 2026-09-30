-- player/tempo.lua
--
-- THE DRIFT-CORRECTED TEMPO SCHEDULER.
--
-- ---------------------------------------------------------------------------
-- WHY THIS MODULE EXISTS
-- ---------------------------------------------------------------------------
-- CC:Tweaked's timer primitive (os.startTimer -- used by the CC:T clock
-- adapter) rounds a requested delay UP to the next 0.05 s world tick.  A tempo
-- whose tick duration is NOT a multiple of 50 ms -- e.g. 15 ticks/second, i.e.
-- 66.667 ms per tick -- therefore CANNOT be represented exactly.  If a
-- scheduler repeatedly requested after(tick_ms) it would accumulate the
-- ~16.667 ms overshoot on every tick and the song would drift progressively
-- late: after 500 ticks the last event lands roughly 500 * 16.667 = 8.3 s past
-- where it belongs.
--
-- THE CUMULATIVE-IDEAL-TIMELINE RULE
-- ---------------------------------------------------------------------------
-- The scheduler never adds tick_ms to the previous delay.  Instead:
--
--   * An ANCHOR (start_ms = the clock reading when play() began) and a
--     MONOTONICALLY INCREASING index into the time-sorted event array are kept.
--   * For the next due event, ideal = start_ms + event.t_ms on the IDEAL
--     timeline, and the requested delay is (ideal - clock.now_ms()) / 1000.
--   * After the clock fires, the NEXT delay is recomputed from the ideal
--     timeline again -- never from the actual firing time.
--
-- A delay that was rounded UP is therefore compensated by a shorter next
-- request, so drift stays BOUNDED (about one rounding step) instead of growing
-- without limit.  This is the entire point of the module.
--
-- TEMPO REPRESENTABILITY AND THE CLAMP WARNING
-- ---------------------------------------------------------------------------
-- "Clamped" describes a REAL timing limitation: the song's NOMINAL tick
-- interval -- opts.tick_ms, i.e. 1000 / analysis.ticks_per_second -- is itself
-- shorter than MIN_TIMER_MS (0.05 s), so the injected clock cannot represent
-- the requested tempo and rounds every delay UP to the next world tick.  Only
-- then are events counted in stats.clamped_ticks (one per event scheduled
-- while the run is clamp-active) and reported ONCE per run via the optional
-- warn callback with the bare code CLAMP_WARN_CODE.  A sub-granularity event
-- is still scheduled, never rounded away or skipped; on a virtual clock the
-- delay is exact, on the real CC:T clock the primitive rounds it up.
--
-- A delay of zero or less is NOT a clamp: it means "this event is DUE NOW".
-- The first note of virtually every song sits at t_ms = 0, and every
-- simultaneous note of a chord shares its tick's deadline, so treating those
-- as clamped made the warning fire on almost every song and devalued it.
-- Such events are scheduled immediately and are neither counted nor warned
-- about -- that was the spurious-warning defect (B2).
--
-- opts.tick_ms is the AUTHORITATIVE nominal interval.  When a caller omits it
-- the scheduler derives the SMALLEST POSITIVE GAP between distinct event
-- times; distinct ticks are whole multiples of the nominal interval apart, so
-- that gap can never UNDER-estimate the interval and a genuinely
-- sub-granularity song still warns.
--
-- The nominal interval is assumed validated UPSTREAM: nbs/header.lua rejects
-- a non-positive stored tempo as E_BAD_TEMPO, so nbs.decode never yields a
-- song whose analysis has a non-finite tick_ms.  DEFENCE IN DEPTH applies
-- here anyway: tempo.new refuses a non-finite or non-positive opts.tick_ms
-- outright, and the scheduler refuses to hand the clock a non-finite delay.
-- A corrupt tempo must fail LOUDLY and IMMEDIATELY rather than silently
-- scheduling a callback that can never fire; a NaN deadline must never enter
-- the clock.  A tempo of 0 is corrupt input, not a slow song: it is NEVER
-- clamped into something playable.
--
-- THE CLOCK SEAM AND ITS CALLING CONVENTION (VERIFIED TRAP)
-- ---------------------------------------------------------------------------
-- The clock is INJECTED through opts.clock; there is NO default.  Refusing to
-- silently grab the real clock is deliberate: it keeps this module testable and
-- every test honest.  This module never calls os.startTimer / os.sleep /
-- os.epoch / os.pullEvent itself -- the injected clock is the ONLY time source.
--
-- player/clock.lua's methods are DOT-style and take NO explicit self:
--     clock.after(vc, 0.1, fn)  or  vc.after(0.1, fn)   -- correct
--     vc:after(0.1, fn)                                  -- WRONG
-- Calling a clock method with a colon passes the clock as `delay_sec` and
-- fails.  This is the OPPOSITE of player/speaker.lua, whose methods DO take
-- self and are called with a colon -- the two seams do NOT share a convention.
-- By contrast this module's OWN frozen interface IS colon-style (t:play,
-- t:cancel, t:stats).  Do not let the clock's dot-style trip you up.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No integer division, no bitwise
-- operators, no utf8, no blocking, no real sleeping.

local tempo = {}

-- The bare warning code emitted when the song's NOMINAL tick interval is below
-- MIN_TIMER_MS (see the header).  Never fired merely because one delay is 0.
tempo.CLAMP_WARN_CODE = "tempo-clamp"

-- The os.startTimer world-tick granularity, in milliseconds.  A NOMINAL tick
-- interval below this cannot be represented by the clock at all.
tempo.MIN_TIMER_MS = 50

-- is_finite_number(value): true for a real, finite number; rejects NaN (the
-- only value not equal to itself) and both infinities.
local function is_finite_number(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
end

-- bad_tick_ms(origin, value): the typed refusal for a corrupt nominal interval.
-- The decoder rejects a non-positive stored tempo first (E_BAD_TEMPO); this is
-- the tempo module's own backstop for a caller that hands the interval over
-- directly.
local function bad_tick_ms(origin, value)
  return {
    code = "E_BAD_TICK_MS",
    msg = origin .. ": the nominal tick interval must be a finite, positive "
      .. "number of milliseconds (a zero/NaN tempo is corrupt input, not a "
      .. "slow song); got " .. tostring(value),
    value = value,
  }
end

-- tempo.tick_ms(analysis) -> number
--
-- The nominal duration of one tick, exposed for consumers.  Analysis reports
-- ticks_per_second directly; the tempo itself is its reciprocal.  The backstop
-- above applies: a non-finite or non-positive rate is refused loudly instead
-- of returning inf/NaN to a scheduler.
function tempo.tick_ms(analysis)
  local ticks_per_second = analysis.ticks_per_second
  if not is_finite_number(ticks_per_second) or ticks_per_second <= 0 then
    error(bad_tick_ms("tempo.tick_ms", ticks_per_second), 2)
  end
  return 1000 / ticks_per_second
end

-- infer_tick_ms(sorted_events) -> number | nil
--
-- The smallest positive gap between the t_ms of consecutive events.  Because
-- distinct ticks are whole multiples of the nominal interval apart, this gap
-- is an UPPER BOUND on the true interval: it can never under-report a
-- sub-granularity tempo, so a caller that does not pass opts.tick_ms still
-- gets the clamp warning when the song genuinely needs it.  nil when no two
-- distinct event times exist.
local function infer_tick_ms(sorted_events)
  local smallest = nil
  for index = 2, #sorted_events do
    local gap = sorted_events[index].t_ms - sorted_events[index - 1].t_ms
    if gap > 0 and (smallest == nil or gap < smallest) then
      smallest = gap
    end
  end
  return smallest
end

-- stable_sort_by_t(events) -> array
--
-- Order events by ascending t_ms; events sharing a t_ms keep their original
-- ARRAY order (Lua's table.sort is not stable, so the original index is used
-- as the tie-break).  This is what lets the scheduler fire by ideal time while
-- preserving author-supplied order for simultaneous notes.
local function stable_sort_by_t(events)
  local indexed = {}
  for i = 1, #events do
    indexed[i] = { event = events[i], order = i }
  end
  table.sort(indexed, function(a, b)
    local ta = a.event.t_ms
    local tb = b.event.t_ms
    if ta ~= tb then
      return ta < tb
    end
    return a.order < b.order
  end)
  local sorted = {}
  for i = 1, #indexed do
    sorted[i] = indexed[i].event
  end
  return sorted
end

-- ---------------------------------------------------------------------------
-- Instance
-- ---------------------------------------------------------------------------

local Tempo = {}
Tempo.__index = Tempo

-- tempo.new(opts) -> t
--
--   opts.clock    REQUIRED.  The injected clock seam (see player/clock.lua).
--   opts.warn     optional function(code); called with a BARE code, at most
--                 once per code per run.
--   opts.on_event optional function(event); default callback for play().
--   opts.tick_ms  optional.  The song's NOMINAL tick interval in milliseconds
--                 (1000 / ticks_per_second) -- the value the clamp warning is
--                 derived from.  When supplied it MUST be a finite, positive
--                 number; a zero/NaN/infinite interval raises the typed table
--                 E_BAD_TICK_MS immediately (backstop for corrupt input, see
--                 the header).  When omitted the interval is inferred from the
--                 events passed to play() (smallest positive gap).
local function new(opts)
  opts = opts or {}
  local clock_obj = opts.clock
  if clock_obj == nil then
    error("tempo.new: opts.clock is required (no default clock; refusing to "
      .. "silently grab the real clock)", 2)
  end
  if type(clock_obj.now_ms) ~= "function" or type(clock_obj.after) ~= "function" then
    error("tempo.new: opts.clock must provide now_ms() and after(delay_sec, fn)", 2)
  end

  local tick_ms = opts.tick_ms
  if tick_ms ~= nil
    and (not is_finite_number(tick_ms) or tick_ms <= 0) then
    error(bad_tick_ms("tempo.new", tick_ms), 2)
  end

  local self = setmetatable({}, Tempo)
  self.clock = clock_obj
  self.warn = opts.warn
  self.on_event = opts.on_event
  self.tick_ms = tick_ms
  self.nominal_tick_ms = nil
  self.clamp_active = false

  self.events = {}
  self.run_callback = nil
  self.start_ms = 0
  self.index = 1
  self.handle = nil
  self.cancelled = false
  self.warned = false
  self.metrics = nil

  return self
end

-- _warn_once(): emit CLAMP_WARN_CODE at most once for the current run.
function Tempo:_warn_once()
  if self.warned then
    return
  end
  self.warned = true
  if self.warn ~= nil then
    self.warn(tempo.CLAMP_WARN_CODE)
  end
end

-- _schedule_next(): arm ONE timer for the next event not yet dispatched.
--
-- The delay is ALWAYS (ideal - now), recomputed from the cumulative ideal
-- timeline -- never tick_ms added to a previous delay.  This is the anti-drift
-- rule in action.
--
-- ONE TIMER PER DEADLINE, NOT PER EVENT.  When this timer fires, EVERY event
-- whose ideal time has arrived is dispatched together (see _on_fire).  The clock
-- can only advance in whole world ticks (0.05 s -- see the header), so a song
-- denser than 20 events per second CANNOT give each event a timer of its own.
-- Chaining one timer per event did exactly that, and pinned playback to 20
-- events/second: a real 148 events/second song therefore ran ~7.5x SLOW, measured
-- at 1087 s of wall clock for a 143 s song.  Grouping by deadline is what lets a
-- dense song play at its real tempo, and it costs nothing when events are sparse
-- -- such a song simply drains one event per firing, exactly as before.
function Tempo:_schedule_next()
  if self.cancelled then
    return
  end
  if self.index > #self.events then
    return
  end

  local event = self.events[self.index]
  local ideal = self.start_ms + event.t_ms
  local now = self.clock.now_ms()
  local delay_ms = ideal - now

  -- DEFENCE IN DEPTH (B4): a non-finite delay can never satisfy the clock's
  -- `deadline <= limit` test, so the session would hang forever.  Refuse it
  -- loudly here and let NOTHING reach the clock -- corrupt timing input must
  -- fail, not become a dead deadline.
  if not is_finite_number(delay_ms) then
    error({
      code = "E_BAD_DELAY",
      msg = string.format(
        "tempo: refusing to schedule a non-finite delay (%s ms) for t_ms=%s "
        .. "-- corrupt timing input, not a slow song",
        tostring(delay_ms), tostring(event.t_ms)),
      delay_ms = delay_ms,
      t_ms = event.t_ms,
    }, 0)
  end

  local self_ref = self
  -- DOT call: clock methods take no explicit self (see header).
  self.handle = self.clock.after(delay_ms / 1000, function()
    self_ref:_on_fire()
  end)
end

-- _on_fire(): a deadline was reached -- dispatch every event that is now due.
--
-- Three phases, in this order, and each order is load-bearing:
--
--   A. TAKE every event whose ideal time has arrived, advancing the index and
--      recording the metrics as each is taken.
--   B. ARM the next timer from the ideal timeline -- BEFORE running any user
--      callback.  This is why taking and dispatching are separate steps: the
--      chain must be intact before on_event can raise, or a single bad callback
--      would stall every remaining event in the song.
--   C. DISPATCH the events that were taken.
--
-- Each callback is pcall'd individually so that one raising note cannot discard
-- the OTHER notes that share its deadline.  The first raise is re-thrown at the
-- end, so the clock still captures exactly one error and playback continues --
-- the same observable contract as before.
function Tempo:_on_fire()
  if self.cancelled then
    return
  end

  local actual = self.clock.now_ms()

  -- A. Take the next event UNCONDITIONALLY, then every further event now due.
  --
  -- Taking the FIRST unconditionally is what GUARANTEES PROGRESS, and it is not a
  -- convenience -- it is required.  A firing can arrive a hair EARLY: the clock
  -- rounds its requested delay, and a positive delay can round to ZERO steps, so
  -- the callback runs at the very instant it was armed.  A plain "is this event
  -- due?" guard takes nothing in that case, and the chain then re-arms the same
  -- deadline at the same instant -- forever.  Consuming one event per firing bounds
  -- the number of firings by the number of events.
  --
  -- The per-event scheduler this replaced behaved the same way: whatever deadline
  -- fired, that event was dispatched.  An event may therefore fire up to one
  -- rounding step early, and max_drift_ms reports that honestly.
  local due = {}
  while self.index <= #self.events do
    local event = self.events[self.index]
    local ideal = self.start_ms + event.t_ms
    if #due > 0 and ideal > actual then
      break
    end

    local drift = math.abs(actual - ideal)
    if drift > self.metrics.max_drift_ms then
      self.metrics.max_drift_ms = drift
    end

    self.index = self.index + 1
    self.metrics.ticks_scheduled = self.metrics.ticks_scheduled + 1
    if self.index > #self.events then
      self.metrics.ideal_end_ms = ideal
      self.metrics.actual_end_ms = actual
    end

    -- B2: whether an event is "clamped" is a property of the song's NOMINAL
    -- tempo, never of this delay.  A zero/negative delay simply means the event
    -- is due now (the first note, or a chord's later notes) and is NOT counted.
    -- In a genuinely sub-granularity song every DISPATCHED event counts, because
    -- the clock cannot represent the requested tempo at all.
    if self.clamp_active then
      self.metrics.clamped_ticks = self.metrics.clamped_ticks + 1
      self:_warn_once()
    end

    due[#due + 1] = event
  end

  -- B. Arm the next deadline before dispatching anything.
  self:_schedule_next()

  -- C. Dispatch, one pcall each, re-throwing the first raise.
  if self.run_callback ~= nil then
    local first_error = nil
    for index = 1, #due do
      local ok, err = pcall(self.run_callback, due[index])
      if not ok and first_error == nil then
        first_error = err
      end
    end
    if first_error ~= nil then
      error(first_error, 0)
    end
  end
end

-- t:play(events, on_event) -> handle
--
-- Begin scheduling.  Each event is placed at start_ms + event.t_ms on the IDEAL
-- timeline; simultaneous events fire in array order.  Does NOT block: it only
-- schedules on the injected clock and returns the handle (self).
function Tempo:play(events, on_event)
  -- Make play idempotent-safe: cancel any previous run before starting a new one.
  self:cancel()

  self.events = stable_sort_by_t(events or {})
  self.run_callback = on_event or self.on_event
  self.start_ms = self.clock.now_ms()
  self.index = 1
  self.handle = nil
  self.cancelled = false
  self.warned = false
  self.metrics = {
    ticks_scheduled = 0,
    ideal_end_ms = 0,
    actual_end_ms = 0,
    max_drift_ms = 0,
    clamped_ticks = 0,
  }

  -- The NOMINAL tick interval decides clamping (see the header).  An explicit
  -- opts.tick_ms is authoritative; otherwise derive the smallest positive gap
  -- between distinct event times.  A non-finite interval is corrupt input:
  -- refuse it before a single deadline is computed.
  local nominal = self.tick_ms
  if nominal == nil then
    nominal = infer_tick_ms(self.events)
  end
  if nominal ~= nil and (not is_finite_number(nominal) or nominal <= 0) then
    error(bad_tick_ms("tempo.play", nominal), 0)
  end
  self.nominal_tick_ms = nominal
  self.clamp_active = nominal ~= nil and nominal < tempo.MIN_TIMER_MS

  self:_schedule_next()
  return self
end

-- t:cancel()
--
-- Stop scheduling; idempotent.  Cancels the one pending clock handle (if any)
-- and flips a flag that makes any in-flight callback a no-op.
function Tempo:cancel()
  self.cancelled = true
  if self.handle ~= nil and self.clock.cancel ~= nil then
    self.clock.cancel(self.handle)
  end
  self.handle = nil
end

-- t:stats() -> table
--
-- Live metrics for the current (or most recent) run.  `clamped_ticks` counts
-- events scheduled while the song's NOMINAL tick interval was below
-- MIN_TIMER_MS -- i.e. events whose delay the clock cannot represent
-- faithfully -- NOT events that merely happened to be due immediately.
function Tempo:stats()
  return self.metrics
end

tempo.new = new

return tempo
