-- player/tempo.lua
--
-- 抗漂移的 tempo 调度器。
--
-- ---------------------------------------------------------------------------
-- 为什么存在这个模块
-- ---------------------------------------------------------------------------
-- CC:Tweaked 的 timer 原语（os.startTimer——被 CC:T 时钟适配器使用）会把请求的
-- delay **向上**取整到下一个 0.05 s 的世界 tick。所以一条 tick 时长并非 50 ms 整数
-- 倍的 tempo——例如每秒 15 tick，即每 tick 66.667 ms——**无法**被精确表示。如果一个
-- 调度器反复请求 after(tick_ms)，它会在每个 tick 上累积约 16.667 ms 的超调，歌曲会
-- 逐渐拖后：500 tick 之后，最后一个事件落在它应在位置之后约 500 * 16.667 = 8.3 s。
--
-- 累计理想时间线规则
-- ---------------------------------------------------------------------------
-- 调度器从不把 tick_ms 加到上一个 delay 上。取而代之：
--
--   * 保留一个**锚点**（start_ms = play() 开始时的时钟读数）和进入按时间排序的事件
--     数组的一个**单调递增**索引。
--   * 对下一个到期事件，ideal = start_ms + event.t_ms 是**理想**时间线上的时刻，
--     而请求的 delay 是 (ideal - clock.now_ms()) / 1000。
--   * 时钟触发之后，下一个 delay 再次从理想时间线重新计算——从不从实际的触发时刻算。
--
-- 因此一个被向上取整的 delay 会被一个更短的下一次请求补偿，于是漂移保持**有界**
-- （约一个取整步长），而不是无限制增长。这就是本模块的全部意义。
--
-- TEMPO 可表示性与 CLAMP 警告
-- ---------------------------------------------------------------------------
-- "Clamped" 描述的是一种**真实**的时序限制：歌曲的**标称** tick 间隔——
-- opts.tick_ms，即 1000 / analysis.ticks_per_second——本身就短于 MIN_TIMER_MS
-- （0.05 s），所以注入的时钟无法表示所请求的 tempo，会把每个 delay **向上**取整到
-- 下一个世界 tick。只有这时，事件才会被计入 stats.clamped_ticks（在运行处于
-- clamp 激活期间每调度一个事件计一次），并通过可选的 warn 回调以裸码
-- CLAMP_WARN_CODE 每次运行**至多报告一次**。亚粒度事件仍然会被调度，绝不丢弃或跳过；
-- 在虚拟时钟上 delay 是精确的，在真实 CC:T 时钟上原语会把它向上取整。
--
-- 零或负的 delay **不是** clamp：它意味着“这个事件现在就该到点”。几乎每首歌的第一个
-- 音符都位于 t_ms = 0，而一个和弦里同时发声的每个音符都共享其 tick 的截止时间，所以
-- 把这些当作 clamped 会让警告在几乎每首歌上触发，从而贬值。这类事件立即被调度，既不
-- 计数也不报警——那正是虚假警告缺陷（B2）。
--
-- opts.tick_ms 是**权威的**标称间隔。当调用方省略它时，调度器推导不同事件时间之间
-- **最小的正间隔**；不同的 tick 都是标称间隔的整数倍，所以那个间隔**不可能低估**真实
-- 间隔，一首真正亚粒度的歌依然会报警。
--
-- 标称间隔被假定已在**上游**校验过：nbs/header.lua 会把非正的存储 tempo 拒绝为
-- E_BAD_TEMPO，所以 nbs.decode 永远不会产出一首其分析带有非有限 tick_ms 的歌。这里
-- 仍然做**纵深防御**：tempo.new 直接拒绝非有限或非正的 opts.tick_ms，调度器也拒绝把
-- 非有限的 delay 交给时钟。损坏的 tempo 必须**立即且大声**地失败，而不是去静默调度
-- 一个永远无法触发的回调；NaN 截止时间绝不能进入时钟。tempo 为 0 是损坏的输入，不是
-- 一首慢歌：它**从不**被 clamp 成某种能播的东西。
--
-- 时钟接缝及其调用约定（已实测的陷阱）
-- ---------------------------------------------------------------------------
-- 时钟通过 opts.clock **注入**；**没有**默认值。拒绝静默抓取真实时钟是刻意的：它让
-- 本模块可测、让每个测试诚实。本模块自己从不调用 os.startTimer / os.sleep /
-- os.epoch / os.pullEvent——注入的时钟是**唯一**的时间来源。
--
-- player/clock.lua 的方法是**点号风格**，且**不**接受显式 self：
--     clock.after(vc, 0.1, fn)  或  vc.after(0.1, fn)   -- 正确
--     vc:after(0.1, fn)                                  -- 错误
-- 用冒号调用时钟方法会把时钟本身当作 `delay_sec` 传入，从而失败。这与
-- player/speaker.lua **相反**，后者的方法**确实**接受 self 并用冒号调用——两个接缝
-- **不**共享同一约定。相比之下，本模块**自己**的冻结接口**是**冒号风格（t:play、
-- t:cancel、t:stats）。别让时钟的点号风格把你绊倒。
--
-- 兼容性：Lua 5.2 / CC:Tweaked 的 Cobalt。不用整除、不用位运算、不用 utf8、不阻塞、
-- 不做真实 sleep。

local tempo = {}

-- 当歌曲的**标称** tick 间隔低于 MIN_TIMER_MS 时发出的裸警告码（见文件头）。
-- 绝不因为某一个 delay 为 0 就触发。
tempo.CLAMP_WARN_CODE = "tempo-clamp"

-- os.startTimer 的世界 tick 粒度，单位毫秒。低于此值的**标称** tick 间隔完全无法被
-- 时钟表示。
tempo.MIN_TIMER_MS = 50

-- is_finite_number(value)：对一个真实、有限的数字为 true；拒绝 NaN（唯一不等于自身的
-- 值）与两个无穷。
local function is_finite_number(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
end

-- bad_tick_ms(origin, value)：对一个损坏的标称间隔的带类型拒绝。解码器会先把非正的
-- 存储 tempo 拒绝为 E_BAD_TEMPO；这是 tempo 模块自己的兜底，针对直接把间隔交给它的
-- 调用方。
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
-- 一个 tick 的标称时长，暴露给消费者。Analysis 直接报告 ticks_per_second；tempo
-- 本身就是它的倒数。上面的兜底适用：非有限或非正的速率会被大声拒绝，而不是把
-- inf/NaN 交给调度器。
function tempo.tick_ms(analysis)
  local ticks_per_second = analysis.ticks_per_second
  if not is_finite_number(ticks_per_second) or ticks_per_second <= 0 then
    error(bad_tick_ms("tempo.tick_ms", ticks_per_second), 2)
  end
  return 1000 / ticks_per_second
end

-- infer_tick_ms(sorted_events) -> number | nil
--
-- 相邻事件 t_ms 之间最小的正间隔。因为不同的 tick 都是标称间隔的整数倍，所以这个
-- 间隔是真实间隔的**上界**：它绝不可能低估一个亚粒度 tempo，因此未传 opts.tick_ms
-- 的调用方在歌曲确实需要时仍能拿到 clamp 警告。当不存在两个不同的事件时间时为 nil。
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
-- 按 t_ms 升序排列事件；共享同一 t_ms 的事件保持它们原来的**数组**顺序（Lua 的
-- table.sort 不稳定，所以用原索引作为并列时的决胜键）。正是这一点让调度器按理想
-- 时间触发，同时为同时发声的音符保留作者提供的顺序。
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
-- 实例
-- ---------------------------------------------------------------------------

local Tempo = {}
Tempo.__index = Tempo

-- tempo.new(opts) -> t
--
--   opts.clock    必填。注入的时钟接缝（见 player/clock.lua）。
--   opts.warn     可选 function(code)；以**裸**码调用，每次运行同码至多一次。
--   opts.on_event 可选 function(event)；play() 的默认回调。
--   opts.tick_ms  可选。歌曲的**标称** tick 间隔，单位毫秒
--                 （1000 / ticks_per_second）——clamp 警告就是从这个值推导的。提供时
--                 它**必须**是一个有限正数；零/NaN/无穷的间隔会立即抛出带类型的表
--                 E_BAD_TICK_MS（对损坏输入的兜底，见文件头）。省略时，间隔从传给
--                 play() 的事件推得（最小的正间隔）。
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

-- _warn_once()：对当前运行至多发出一次 CLAMP_WARN_CODE。
function Tempo:_warn_once()
  if self.warned then
    return
  end
  self.warned = true
  if self.warn ~= nil then
    self.warn(tempo.CLAMP_WARN_CODE)
  end
end

-- _schedule_next()：为下一个尚未派发的事件武装**一个** timer。
--
-- delay **永远**是 (ideal - now)，从累计理想时间线重新计算——绝不是把 tick_ms 加到
-- 上一个 delay 上。这就是抗漂移规则在起作用。
--
-- **每个截止时间一个 timer，而不是每个事件一个**。当这个 timer 触发时，**每一个**理想
-- 时间已到达的事件会被一起派发（见 _on_fire）。时钟只能以整世界 tick（0.05 s——见
-- 文件头）前进，所以一首密于每秒 20 个事件的歌**无法**给每个事件各自的 timer。以往
-- 每个事件串一个 timer 恰恰就是这么做的，它把播放钉死在每秒 20 个事件：因此一首真实
-- 每秒 148 个事件的歌跑得慢了约 7.5 倍，实测一首 143 秒的歌花了 1087 秒墙钟。按截止
-- 时间分组，才是让密集的歌以其真实 tempo 播放的原因；而当事件稀疏时它没有任何代价——
-- 这样的歌每次触发只排空一个事件，与以往完全一样。
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

  -- 纵深防御（B4）：非有限的 delay 永远无法满足时钟的 `deadline <= limit` 判定，
  -- 所以会话会永远挂起。在这里大声拒绝它，让**任何东西**都无法到达时钟——损坏的时序
  -- 输入必须失败，而不是变成一个死掉的截止时间。
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
  -- 点号调用：时钟方法不接受显式 self（见文件头）。
  self.handle = self.clock.after(delay_ms / 1000, function()
    self_ref:_on_fire()
  end)
end

-- _on_fire()：一个截止时间到了——派发每一个现在到期的事件。
--
-- 三个阶段，顺序如此，且每个顺序都承重：
--
--   A. **取出**每一个理想时间已到达的事件，取出时推进索引并记录指标。
--   B. 从理想时间线**武装**下一个 timer——在运行任何用户回调**之前**。这正是取出与
--      派发要分成两步的原因：链条必须在 on_event 有机会抛错之前保持完整，否则一个
--      坏回调就会卡住歌里剩下的每一个事件。
--   C. **派发**已取出的事件。
--
-- 每个回调单独 pcall，好让一个抛错的音符不会丢弃与其共享截止时间的**其他**音符。
-- 第一个抛错在最后被重新抛出，所以时钟仍然恰好捕获到一个错误、播放继续进行——
-- 与以往相同的可观测契约。
function Tempo:_on_fire()
  if self.cancelled then
    return
  end

  local actual = self.clock.now_ms()

  -- A. **无条件**取出下一个事件，然后再取出每一个现在已经到期的后续事件。
  --
  -- 无条件取出**第一个**，才是**保证前进**的东西，这不是为了方便——而是必需。一次
  -- 触发可能来得**早**一点点：时钟会对请求的 delay 取整，而一个正 delay 可能被取整
  -- 成**零**步，于是回调就在它被武装的同一瞬间运行。此时一个单纯的“这个事件到期了
  -- 吗？”守卫什么都取不到，链条接着在同一瞬间重新武装同一个截止时间——永远如此。
  -- 每次触发消费一个事件，就把触发次数以事件数为上界约束住了。
  --
  -- 被它取代的逐事件调度器行为相同：无论哪个截止时间触发，那个事件就被派发。因此
  -- 一个事件至多可能提前一个取整步长触发，而 max_drift_ms 会如实地报告这一点。
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

    -- B2：一个事件是否“clamped”，是歌曲**标称** tempo 的属性，绝不是这个 delay 的
    -- 属性。零/负的 delay 只说明该事件现在就该到点（第一个音符，或和弦中靠后的
    -- 音符），**不**计入。在一首真正亚粒度的歌里，每一个**已派发**的事件都计数，因为
    -- 时钟根本无法表示所请求的 tempo。
    if self.clamp_active then
      self.metrics.clamped_ticks = self.metrics.clamped_ticks + 1
      self:_warn_once()
    end

    due[#due + 1] = event
  end

  -- B. 在派发任何东西之前先武装下一个截止时间。
  self:_schedule_next()

  -- C. 派发，每个单独 pcall，重新抛出第一个抛错。
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
-- 开始调度。每个事件被放在**理想**时间线的 start_ms + event.t_ms 处；同时发生的事件
-- 按数组顺序触发。**不**阻塞：它只在注入的时钟上调度并返回 handle（self）。
function Tempo:play(events, on_event)
  -- 让 play 对幂等安全：开始新的一次运行之前，先取消上一次。
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

  -- **标称** tick 间隔决定是否 clamp（见文件头）。显式的 opts.tick_ms 是权威的；
  -- 否则推导不同事件时间之间最小的正间隔。非有限的间隔是损坏输入：在计算出任何一个
  -- 截止时间之前就拒绝它。
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
-- 停止调度；幂等。取消那一个待处理的时钟 handle（如果有），并翻转一个标志，让任何
-- 正在途中的回调变成空操作。
function Tempo:cancel()
  self.cancelled = true
  if self.handle ~= nil and self.clock.cancel ~= nil then
    self.clock.cancel(self.handle)
  end
  self.handle = nil
end

-- t:stats() -> table
--
-- 当前（或最近一次）运行的实时指标。`clamped_ticks` 统计的是歌曲**标称** tick 间隔
-- 低于 MIN_TIMER_MS 期间所调度的事件——即时钟无法忠实表示其 delay 的事件——而**不是**
-- 那些刚好立即到期的事件。
function Tempo:stats()
  return self.metrics
end

tempo.new = new

return tempo
