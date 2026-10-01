-- player/clock.lua
--
-- 可注入的时钟接缝。
--
-- ---------------------------------------------------------------------------
-- 为什么必须存在这个模块
-- ---------------------------------------------------------------------------
-- CraftOS-PC 没有任何办法控制或伪造时钟：os.clock、os.epoch、os.time 与 os.day
-- 全部直接读取真实的系统时钟。如果 tempo 调度器自己去调这些原语，确定性就不可能
-- 达成：测一首三分钟的歌要花三分钟的真实时间，而且每一条时序断言都会时好时坏。
-- 所以时间是一个**依赖**，以一个时钟值的形式注入：
--
--   * clock.new_virtual(start_ms) -> 一个确定性时钟，只有测试推进它时才走。测试
--     瞬间跑完整首歌，并对精确的毫秒数做断言。
--   * clock.new_os() -> 架在游戏时钟之上的生产适配器。
--
-- 本模块是 os.epoch、os.startTimer、os.pullEvent（用于 timer）与 os.sleep 的**唯一**
-- 许可调用方。其他每个模块都接收一个时钟，且绝不允许自己去碰真实时钟。
--
-- ---------------------------------------------------------------------------
-- 时钟协议
-- ---------------------------------------------------------------------------
--   now_ms()              -> number，单调不减的毫秒数
--   after(delay_sec, fn)  -> handle，在 delay_sec 秒后运行一次 fn
--   cancel(handle)        -> boolean，当且仅当该 handle 仍在等待时为 true
--   run_due()             -> integer，运行每一个已经到期的回调
--   pending_count()       -> integer，仍在等待截止时间的 handle 数
--   sleep_until(deadline_ms)   -- 仅限 CC:T 适配器，且**不被**生产环境的 tempo
--                                调度器使用（见下）
--
-- clock.advance_to(vclock, target_ms) -> integer
--   把一个**虚拟**时钟推进到 target_ms，运行每一个已到达截止时间的回调，并返回运行
--   了多少个。回调按**截止时间升序**触发；共享同一截止时间的 handle 按调度顺序触发
--   （稳定）。比较是**包含**边界。advance_to 分步推进，并在每个回调之后重新扫描，
--   所以在同一区间内由某个回调再调度出的新回调也会被兑现——这正是 tempo 调度器在
--   回调内部重新调度自己时做的事。目标时间**早于**当前时间是空操作，返回 0；时钟
--   永不倒退。advance_to 从不 sleep。
--
-- 错误策略
--   抛错的回调被 pcall 捕获，追加到 `<vclock>.errors`
--   （条目形如 { message = <string>, deadline = <number>, seq = <number> }），并且
--   **永不**从 run_due / advance_to 向外传播。一个坏回调不应损坏时钟或卡死队列；
--   时钟保持可用，而被捕获的错误让测试能精确断言到底哪里出了问题。
--
-- ---------------------------------------------------------------------------
-- CC:T 适配器的取整注意事项
-- ---------------------------------------------------------------------------
  -- 适配器映射到 CC:Tweaked 的原语：
  --     now_ms()            = os.epoch("utc")              -- 整数毫秒
  --     after(delay, fn)    = os.startTimer(delay)        -- timer id
  --     run_due()           = os.pullEvent("timer") 排空
  --     sleep_until(d_ms)   = os.sleep(max(0, d_ms - now_ms()) / 1000)
  --                           （一个适配器便利项；tempo.lua 不用它）
  --
  -- now_ms 使用 os.epoch("utc")：真实墙钟毫秒，是这里唯一既有毫秒分辨率、又不可能
  -- 被世界扭曲的时钟。另外两个候选都实测过，且都以**静默**的方式出错：
  --
  --   os.epoch("ingame")  **游戏内**的日钟。doDaylightCycle 关闭时它根本不走——
  --                       在一台真实机器上实测，整个运行过程钉在 109436400——于是
  --                       `delay = ideal - now` 不再是区间，而变成每个事件自己的
  --                       绝对 t_ms，不断累积，直到一首 143 秒的歌永远播不完。
  --                       循环打开时，OSAPI.java 按
  --                       `day * 86400000 + time * 3600000` 计算，而一个 Minecraft
  --                       日是 20 真实分钟，所以它每真实秒推进 72000 ms：快 72 倍，
  --                       每个事件瞬间就过期了。
  --
  --   os.clock()          电脑运行时长——OSAPI.java 里的 `clock * 0.05`，与
  --                       os.startTimer 计量所用的**同一个**逐 tick 计数器。它和
  --                       timer 完全自洽，但以整 50 ms tick 前进，所以一个 delay 在
  --                       timer 自身取整之上还会额外带上最多一个 tick 的量化误差。
  --                       保留它，作为没有 os.epoch 的构建的回退方案。
  --
  -- 注意两者**都不能**改善可达到的时序：os.startTimer 无论如何都取整到最近的
  -- 0.05 s，所以 50 ms 是二者共同的下限。选择 utc 是因为它不会被世界扭曲，不是
  -- 因为它的分辨率。
--
-- 注意事项：os.startTimer 把 delay **向上**取整到下一个 0.05 s（一个世界 tick）的
-- 边界，所以适配器的唤醒只是**近似**——请求 0.13 s 的 timer 大约在 0.15 s 触发。
-- 因此不能信任适配器去做到精确的音乐时序。player/tempo.lua——真正的消费者——用
-- **累计的理想截止时间**（start_ms + event.t_ms）来补偿：对每个事件，它通过注入
-- 时钟的 `after` 重新请求一个 (ideal - clock.now_ms()) / 1000 的 delay，于是取整
-- 误差永远不会累积。它**不**用 sleep_until：那个方法仍然是给想按绝对截止时间阻塞
-- 的调用方的适配器便利项，而调度器完全通过 after()/now_ms() 自我调速。
--
-- new_os() 只在它的函数**内部**读取全局 `os`，从不在 require 时读，所以本模块可以
-- 在 os.epoch 并不存在的纯桌面 Lua 里被 require（并使用其虚拟时钟）。单元测试从不
-- 泵动适配器的事件（纯 Lua 里没有事件循环）；它们只针对被 stub 的全局 os，断言其
-- 构造、接口形状与参数算术。
--
-- 兼容性：Lua 5.2 / CC:Tweaked 的 Cobalt。不用整除、不用位运算、不用 utf8、虚拟
-- 时钟内部不做真实 sleep。

local clock = {}

-- ---------------------------------------------------------------------------
-- 虚拟（确定性）时钟
-- ---------------------------------------------------------------------------

-- clock.new_virtual(start_ms) -> 虚拟时钟
--
-- start_ms 默认为 0。返回时钟的 now_ms() **只**在调用 clock.advance_to（或
-- run_due）时前进；它从不查询真实时钟。
function clock.new_virtual(start_ms)
  if start_ms == nil then
    start_ms = 0
  end

  local state = {
    now = start_ms,
    pending = {}, -- handle 数组
    seq = 0,      -- 调度序号，用于稳定排序
  }

  local vclock = {}
  vclock.errors = {} -- 捕获到的回调错误，最早的在最前

  -- earliest_due(limit)：返回 deadline <= limit 且 (deadline, seq) 最小的待处理
  -- handle，没有则返回 nil。已触发或已取消的 handle 会**从 state.pending 中退出**
  -- （见 drain / cancel），所以数组里只留仍然存活的 handle，这个线性扫描在一首
  -- 很长的歌里也不会无界增长。
  local function earliest_due(limit)
    local best = nil
    local best_index = nil
    for index = 1, #state.pending do
      local handle = state.pending[index]
      if not handle.fired and not handle.cancelled and handle.deadline <= limit then
        if best == nil
          or handle.deadline < best.deadline
          or (handle.deadline == best.deadline and handle.seq < best.seq) then
          best = handle
          best_index = index
        end
      end
    end
    return best, best_index
  end

  -- drain(limit)：运行每一个在 `limit` 或之前到期的 handle，沿途把 state.now 推进
  -- 到每个已触发的截止时间，并在每个回调之后重新扫描，好让区间内新调度的工作得到
  -- 兑现。返回运行的回调数。回调抛出的错误被捕获，不向外抛。
  local function drain(limit)
    local ran = 0
    while true do
      local handle, index = earliest_due(limit)
      if handle == nil then
        break
      end
      handle.fired = true
      -- 退出：该 handle 已触发，所以现在就把它从 pending 数组里删掉。一首很长的歌
      -- 绝不能每个事件都累积一个 handle（那会让之后每一次“最早到期”扫描越来越贵）。
      table.remove(state.pending, index)
      if handle.deadline > state.now then
        state.now = handle.deadline
      end
      local ok, err = pcall(handle.fn)
      if not ok then
        vclock.errors[#vclock.errors + 1] = {
          message = tostring(err),
          deadline = handle.deadline,
          seq = handle.seq,
        }
      end
      ran = ran + 1
    end
    return ran
  end

  -- advance(target)：把时钟向前推进到 `target`，运行一切到期的东西。
  function vclock.advance_to(target)
    if target < state.now then
      return 0 -- 永不倒退
    end
    local ran = drain(target)
    if target > state.now then
      state.now = target
    end
    return ran
  end

  function vclock.now_ms()
    return state.now
  end

  function vclock.after(delay_sec, fn)
    state.seq = state.seq + 1
    local handle = {
      deadline = state.now + delay_sec * 1000,
      seq = state.seq,
      fn = fn,
      fired = false,
      cancelled = false,
    }
    state.pending[#state.pending + 1] = handle
    return handle
  end

  function vclock.cancel(handle)
    if handle == nil or handle.fired or handle.cancelled then
      return false
    end
    handle.cancelled = true
    -- 退出：同样把已取消的 handle 从 pending 数组里删掉，这样一次取消大量 handle
    -- 的运行也不会让列表增长。
    for index = 1, #state.pending do
      if state.pending[index] == handle then
        table.remove(state.pending, index)
        break
      end
    end
    return true
  end

  function vclock.run_due()
    return drain(state.now)
  end

  -- pending_count()：还有多少个 handle 在等待截止时间。已触发和已取消的 handle
  -- 在被解决时就退出了，所以无论一次长运行已经调度过多少事件，这个数都保持很小。
  -- 暴露出来，既供测试套件做上界断言，也供诊断使用。
  function vclock.pending_count()
    return #state.pending
  end

  return vclock
end

-- clock.advance_to(vclock, target_ms) -> integer
--
-- 冻结接口要求的模块级入口点。委托给虚拟时钟自己的 advance_to；非虚拟时钟（例如
-- os 适配器）没有 advance_to，会被大声拒绝。
function clock.advance_to(vclock, target_ms)
  if type(vclock) ~= "table" or type(vclock.advance_to) ~= "function" then
    error("clock.advance_to: expected a clock returned by clock.new_virtual", 2)
  end
  return vclock.advance_to(target_ms)
end

-- ---------------------------------------------------------------------------
-- CC:T（CraftOS）适配器
-- ---------------------------------------------------------------------------

-- clock.new_os() -> 架在真实游戏时钟之上的时钟
--
-- 全局 `os` 在每个函数内部读取（从不在 require 时捕获），所以本模块能在纯 Lua 里
-- 加载。时序是近似的，因为 os.startTimer 会向上取整到 0.05 s 的世界 tick——见头部
-- 注意事项。
function clock.new_os()
  local adapter = {}
  adapter.errors = {}

  -- timer_id -> handle，记录我们创建的 timer。
  local pending = {}

  local function active_count()
    local count = 0
    for _, handle in pairs(pending) do
      if not handle.fired and not handle.cancelled then
        count = count + 1
      end
    end
    return count
  end

  -- now_ms()：**真实**时间的毫秒数，架在一个世界无法扭曲的时钟之上。为什么首选 utc、
  -- 每个备选错在哪里，见本文件顶部的长注；简而言之，一个冻结或被缩放的时钟会让每一个
  -- delay 都出错**却不抛错**，这是调度器最糟糕的失效方式。
  function adapter.now_ms()
    if type(os) == "table" then
      -- 首选：真实墙钟毫秒。不会冻结（昼夜循环碰不到它），也不会被缩放。
      if type(os.epoch) == "function" then
        local ok, value = pcall(os.epoch, "utc")
        if ok and type(value) == "number" then
          return value
        end
      end
      -- 回退：电脑运行时长的秒数——与 timer 所用的同一个逐 tick 计数器，量化到 50 ms。
      if type(os.clock) == "function" then
        local ok, seconds = pcall(os.clock)
        if ok and type(seconds) == "number" then
          return seconds * 1000
        end
      end
    end
    return 0
  end

  function adapter.after(delay_sec, fn)
    local timer_id = os.startTimer(delay_sec)
    local handle = {
      timer_id = timer_id,
      fn = fn,
      fired = false,
      cancelled = false,
    }
    pending[timer_id] = handle
    return handle
  end

  function adapter.cancel(handle)
    if handle == nil or handle.fired or handle.cancelled then
      return false
    end
    handle.cancelled = true
    if handle.timer_id ~= nil then
      pending[handle.timer_id] = nil
    end
    return true
  end

  -- run_due()：排空 `timer` 事件并派发匹配的待处理 handle，直到没有存活的 handle
  -- 为止。它按设计阻塞在 os.pullEvent 上——在游戏里，程序就是这样等待的。timer
  -- 回调抛出的错误被捕获进 adapter.errors，而不向外传播。
  function adapter.run_due()
    local ran = 0
    while active_count() > 0 do
      local _, timer_id = os.pullEvent("timer")
      local handle = pending[timer_id]
      if handle ~= nil then
        pending[timer_id] = nil
        if not handle.cancelled and not handle.fired then
          handle.fired = true
          local ok, err = pcall(handle.fn)
          if not ok then
            adapter.errors[#adapter.errors + 1] = { message = tostring(err) }
          end
          ran = ran + 1
        end
      end
    end
    return ran
  end

  -- sleep_until(deadline_ms)：阻塞到一个绝对截止时间。剩余 delay 被夹在 0，所以
  -- 一个已经过去的截止时间永远不会产生负的 sleep。
  --
  -- 生产环境不用，但**有意保留**。player/tempo.lua——这个适配器唯一的真实消费者——
  -- 通过 after()/now_ms() 自我调速（见头部注意事项），从不调用它。它仍然是一个
  -- **公开的适配器便利项**，给想按绝对截止时间阻塞的调用方使用；测试套件钉住了它的
  -- 算术。
  function adapter.sleep_until(deadline_ms)
    local remaining = (deadline_ms - adapter.now_ms()) / 1000
    if remaining < 0 then
      remaining = 0
    end
    os.sleep(remaining)
  end

  return adapter
end

return clock
