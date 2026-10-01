-- player/fanout.lua
--
-- 确定性的多扬声器扇出，并带优雅降级。
--
-- 冻结的公共接口
--   local fanout = require("player.fanout")
--
--   fanout.assign(events, analysis, speakers) -> assignment
--   fanout.play(events, analysis, speakers, dispatch) -> {
--       calls_made, refused, dropped, results,
--   }
--
--   `events`   player/plan.lua 产出的计划数组（冻结的 (tick, layer, note) 顺序）。
--              **从不**被修改。
--   `analysis` nbs/analyze.lua 的结果。**从不**被修改。
--   `speakers` player/speaker.lua 产出的扬声器记录数组，**已经**按 side 升序排好
--              （speaker.discover 会排序）。**从不**被修改。
--   `dispatch` player/dispatch.lua 的派发器（`d:event(event, record)`）。
--
--   assignment = {
--     speakers       = <原样传进来的扬声器数组>,
--     required       = <整数>,   -- nbs.speakers.required_count(analysis)
--     found          = <整数>,   -- #speakers
--     dropped        = <整数>,   -- 放不下的事件（只算消耗容量的）
--     dropped_events = <数组>,   -- 被丢掉的事件，按丢弃顺序
--     by_speaker     = { [side] = <分配给该扬声器的事件数组，按冻结顺序> },
--     warning_code   = "speakers" | nil,   -- **裸**码
--     warning_args   = { peak, required, found, dropped } | nil,
--   }
--
--   `play` 返回 calls_made（某次扬声器方法返回了值）、refused（扬声器返回 false
--   —— 这是 CC:Tweaked **正常**的拒绝）、dropped，以及 results（派发结果，按调用顺序）。
--
-- ===========================================================================
-- 容量单位是一个**滑动的 50 ms 窗口** —— 不是桶，也不是 tick
-- ===========================================================================
-- 扬声器的每 tick 预算按**游戏**时间衡量，而一个 Minecraft 游戏 tick 是 50 ms ——
-- 与 NBS tick 是**不同的时钟**（见 nbs/analyze.lua）。所以这里的窗口是按 `event.t_ms`
-- 衡量的：两个事件争抢**同一个**扬声器 tick，恰好当它们的起始时间**严格**小于 50 ms
-- （`math.abs(t1 - t2) < 50`）。这与 nbs/analyze.lua 计算 `peak_concurrent` 用的是
-- **同一个**判据；两个模块绝不能跑偏，否则 fanout 会放置分析器根本没有为它做预算的
-- 事件（而扬声器拒绝第 9 次调用时，那些事件会被静默丢掉）。
--
-- 历史 —— 为什么这里不是 `floor(t_ms / 50)`：固定分桶与滑动判定**并不等价**。
-- t=40 与 t=50 落在桶 0 与桶 1，但它们只相隔 10 ms、确实在争抢同一个扬声器 tick，
-- 于是只要一个爆发跨过桶边界，分桶就会允许一个扬声器上有**九个**音符。下面的比较是
-- 对着**实际的已分配时间**做的，从来不是对着桶。恰好相隔 50 ms 会开启新跨度；49 ms 不会。
--
-- 逐事件、逐扬声器（与**已经分配给该扬声器**的事件比较）：
--   * 一个 `play_note` 消耗扬声器 MAX_NOTES_PER_TICK（8）个槽中的**一个**：
--     它要求在自己 50 ms 以内已经有的音符少于 8 个，且没有 play_sound；
--   * 一个 `play_sound` 在那个跨度里消耗**整个**扬声器 —— 它要求自己 50 ms 以内
--     **一个**事件都没有，然后把该扬声器对每个事件关闭，直到那个事件离它至少 50 ms。
--     如果没有扬声器空闲，它会**疏散**最便宜的那个（见下面的分配策略）；它是最受约束的
--     项，永远不会被「先被访问到」的音符饿死；
--   * 一个 `custom` 事件**什么都**不消耗。它在派发时被拒，所以它**绝不能**触发丢弃；
--     它被透传（分配给第一个扬声器），好让记录的调用顺序仍是计划的一份忠实投影。
--   * 未知/缺失的 `kind` 同样什么都不消耗。
--
-- 计划的冻结顺序按 (tick_index, layer_index, note_index) 升序，而
-- t_ms = tick_index * tick_ms，所以这次遍历看到的 t_ms 是**非递减**的。这让一个已经落后
-- 当前事件 50 ms（或更多）的条目可以被永久退役：它也落后于后面每一个事件。
--
-- 已知偏差（必读，不要在这里打补丁）
-- ---------------------------------
--   上面「一个 play_sound 消耗**整个**扬声器、并会把音符挤掉」这个模型，按源码是
--   **不成立**的：`SpeakerPeripheral.update()` 在同一个 tick 里刷新两个**互相独立**的
--   缓冲（`pendingNotes` 与 `pendingSound`），两个入口**互不查询**，所以一个扬声器能同时
--   播 8 个音符**加** 1 个 sound。也就是说，下面**整套疏散机制**是在化解一个并不存在的
--   冲突。正确的分配器会小得多：音符与 sound 从不竞争。
--
--   为什么还留着：nbs/speakers.lua 的公式是**保守**的（只多要、不少要），只要照做就
--   不会被丢事件。真正的重写是**有意延后**的——那是替换整个分配器，不是在这里改一处判断。
--   详见 nbs/speakers.lua 顶部的「已知偏差，刻意保留」。
--
-- ===========================================================================
-- 分配策略：稳定贪心「最少负载」，并列时按 side 升序
-- ===========================================================================
-- 按给定的（冻结）顺序遍历事件。对每个 `play_note`，挑出在它 50 ms 以内**已有音符最少**
-- 的扬声器；并列时给 `side` 排在最前的那一个。因为 `speakers` 已经按 side 升序，用严格
-- `<` 的改进判断从下标 1 开始遍历，就把并列判给了数组里最早的那个扬声器。
--
-- 一个 `play_sound` 需要一个在它 50 ms 以内**没有别的东西**的扬声器。若存在，第一个
-- （按 side 升序）胜出。否则这个 sound —— 最受**约束**的项，因为它独占一整个扬声器 tick
-- —— 会**疏散**最便宜的那个扬声器：把该扬声器的活跃音符搬迁走（按 side 升序选最少负载的
-- 目标，在每个音符自己的时间点上做精确的 50 ms 检查），而放不下的音符会被丢掉，好让这个
-- sound 拿到那个跨度。sound 永远优先于它跨度里的音符（nbs/speakers.lua 为每个 sound
-- 预算了整整一个扬声器）；这正是阻止「访问顺序」把它饿死的东西。在一个窗口里有 2 个普通
-- 音符和 1 个小号、而只有 2 个扬声器时，小号拿走一个扬声器、两个音符共用另一个，而不是
-- 因为音符先被访问到就让小号被丢掉。
--
-- 「sound 优先的两趟遍历」被**否决**过：只要某个扬声器本来就空闲，那会改变 sound 落在
-- **哪个 side** 上，而冻结的「逐 side 期望」（先被访问到的音符拿升序的那个扬声器；
-- sound 拿下一个空闲的）不能移动。上面这个修补让每一个**本来就成功**的放置保持不动。
--
-- 自定义/未知事件被透传给第一个扬声器；它们什么都不消耗，也从不触发丢弃。
--
-- ===========================================================================
-- 丢弃策略：确定性，并且它保住歌曲的**前半段**
-- ===========================================================================
-- 放不下的事件会被**丢弃**，而不是让某个扬声器超载。因为遍历是按冻结的
-- (tick_index, layer_index, note_index) 顺序，且更早的事件总是先占住自己的槽，输掉的
-- 是同一元组顺序里**更靠后**的那些。具体说：早 tick 优先于晚 tick，然后低图层优先于高图层，
-- 再然后小 note_index 优先于大的 —— 唯一的例外是 play_sound，它是最受约束的项，优先于
-- 被它疏散的那些音符；而那些音符在被疏散的扬声器上仍然是**最晚**的。`dropped_events`
-- 按计划的冻结顺序列出这些丢弃。
--
-- `dropped` 只统计**消耗容量**的事件（play_note / play_sound）：自定义事件永远不会被
-- 「丢弃」。只要 `dropped > 0` **或** `found < required`，`warning_code` 就是裸字符串
-- "speakers"，而 `warning_args` 带上 peak/required/found/dropped，好让调用方渲染出例如
-- 「需要 2 个，找到 1 个」。把码渲染成句子属于后面的模块。
--
-- ===========================================================================
-- 确定性就是这里的全部要点
-- ===========================================================================
-- Tier-2 集成测试断言一个**有序**的调用记录序列，以及重复运行下逐字节相同的输出。因此：
--   * 这里**从不**用 `pairs` —— 对事件、对扬声器、对 by_speaker 都不用。
--   * `by_speaker` 按 side 作键是为了调用方方便，但**发出**的调用顺序是按顺序遍历 events
--     数组、把每个事件路由到它被分配的扬声器产生的 —— 绝不是靠遍历一张表。
--   * 本模块做的是**分配**；它不负责同步时钟。CC:Tweaked 的多扬声器播放是尽力而为的，
--     那个限制是播放器的、不是这个分配器的。
--
-- 本文件遵守的 Lua 5.2 / Cobalt 约束：不用 `//`、不用位运算、不用 utf8.*、不用
-- math.maxinteger、不用 collectgarbage、不用 string.dump、不用 os.exit。

local nbs_speakers = require("nbs.speakers")

local fanout = {}

-- 一个 Minecraft 游戏 tick，单位毫秒。这就是容量窗口。
local WINDOW_MS = 50

-- 一个扬声器每窗口的 playNote 预算（8）。从那个冻结的公式模块读，而不是重新声明一遍。
local MAX_NOTES_PER_WINDOW = nbs_speakers.MAX_NOTES_PER_TICK

-- consumes(kind)：只对占用扬声器容量的 kind 为真。自定义与未知 kind 什么都不消耗，
-- 也绝不能导致丢弃。
local function consumes(kind)
  return kind == "play_note" or kind == "play_sound"
end

-- time_of(event)：事件的起始毫秒时间。缺失/非数值的 t_ms 按 0 处理，这样恶意输入
-- 永远不会抛错。
local function time_of(event)
  local t_ms = nil
  if type(event) == "table" then
    t_ms = event.t_ms
  end
  if type(t_ms) ~= "number" then
    t_ms = 0
  end
  return t_ms
end

-- within_window(a, b)：**那个**容量判据。两个事件争抢同一个扬声器 tick，恰好当它们的
-- 起始时间**严格**小于一个 50 ms 游戏 tick。这必须与 nbs/analyze.lua 里那个严格
-- `< 50` 判定保持**完全一致**；两者跑偏，正是让 fanout 让一个扬声器超载——而超出的量
-- 分析器早已做过预算——的原因。
local function within_window(a, b)
  return math.abs(a - b) < WINDOW_MS
end

-- allocate(events, speakers) -> owner，其中 owner[i] 是事件 i 被分配到的扬声器记录；
-- 当一个消耗容量的事件被丢掉时为 nil。自定义/未知事件只要至少有一个扬声器就分配给
-- speakers[1]。纯的、完备的、确定性的；从不抛错。
local function allocate(events, speakers, on_progress)
  local total_events = #events
  local total_speakers = #speakers

  -- 进度上报：按事件数，每 **1/64 的进度或每 256 个事件**报一次（两者取更早的那个）。
  --
  -- 为什么要节流：这个回调是从分配循环内部**同步**调用的，而调用方很可能在回调里直接画
  -- 屏幕。逐事件上报会把一次分配变成几万次 term.write，反而把停顿拉长——而这条进度条的
  -- 全部意义就是让那段时间不显得像卡死。
  --
  -- 为什么要按比例而不是固定事件数：一首 200 事件的歌与一首 20000 事件的歌要用同一个间隔，
  -- 就得让间隔随规模走。两者取更早的那个，于是小歌也有几次上报、大歌不会太稀。
  local report = type(on_progress) == "function" and on_progress or nil
  local report_step = nil
  if report ~= nil then
    report_step = math.floor(total_events / 64)
    if report_step > 256 then
      report_step = 256
    end
    if report_step < 1 then
      report_step = 1
    end
  end

  -- 逐扬声器的滑动窗口记账，按扬声器在数组里的位置索引，所以哈希表遍历永远碰不到它。
  --   times[k]   扬声器 k 各条目的起始时间（ms），按分配顺序
  --              （冻结的计划是升序的；搬迁会把被搬音符自己的——更早或相等的——时间
  --              追加进来，而窗口扫描能容忍这一点，因为它们总是重新检查真正的
  --              50 ms 判据）
  --   sounds[k]  平行标志：该条目是 play_sound 时为真
  --   ids[k]     平行的冻结事件下标（从 1 起算）：在 sound 需要这个扬声器时决定
  --              **哪个**音符被疏散——更晚的 (tick_index, layer_index, note_index) 输
  --   alive[k]   平行标志：条目被搬走之后变为 false（此后它只存在于新的扬声器上）
  --   head[k]    扬声器 k 第一个「不已知已超出触及范围」的条目的 1 起算下标；它之前的
  --              一切要么已死、要么至少落后当前事件 50 ms。
  local times = {}
  local sounds = {}
  local ids = {}
  local alive = {}
  local head = {}
  for k = 1, total_speakers do
    times[k] = {}
    sounds[k] = {}
    ids[k] = {}
    alive[k] = {}
    head[k] = 1
  end

  -- owner[i] 在事件 i 被放置时设置，在被分配的某个音符后来为 play_sound 被疏散时清空。
  -- 它声明在下面那些辅助函数之前，因为疏散闭包会清空它。
  local owner = {}

  -- append(k, t, is_sound, id)：在扬声器 k 上记录一个条目。
  local function append(k, t, is_sound, id)
    local list = times[k]
    local position = #list + 1
    list[position] = t
    sounds[k][position] = is_sound
    ids[k][position] = id
    alive[k][position] = true
  end

  -- retire(k, t)：把扬声器 k 的 head 推过已死条目、以及那些在时间 t 已经够不着的条目
  -- （至少落后它 50 ms）。遍历按 t_ms 非递减顺序进行，所以一个落后 t 达 50 ms 的条目
  -- 也落后后面每一个事件。判定用的是同一个严格 `< 50` 判据的边界，作用在实际时间上。
  local function retire(k, t)
    local list = times[k]
    local flags = alive[k]
    local first = head[k]
    while first <= #list do
      if not flags[first] then
        first = first + 1
      elseif list[first] <= t and not within_window(list[first], t) then
        first = first + 1
      else
        break
      end
    end
    head[k] = first
  end

  -- live_count(k, t)：扬声器 k 的**活跃**条目里有多少个与 t 共享一个 50 ms 跨度。
  -- retire() 之后剩下的就是活跃条目，所以那个 abs() 判定只是重新确认退役已经确立的事。
  local function live_count(k, t)
    local list = times[k]
    local flags = alive[k]
    local count = 0
    for index = head[k], #list do
      if flags[index] and within_window(list[index], t) then
        count = count + 1
      end
    end
    return count
  end

  -- live_sound(k, t)：扬声器 k 的**活跃**条目里有 play_sound 吗？
  local function live_sound(k, t)
    local list = times[k]
    local flags = alive[k]
    local flags_sound = sounds[k]
    for index = head[k], #list do
      if flags[index] and flags_sound[index]
        and within_window(list[index], t) then
        return true
      end
    end
    return false
  end

  -- count_within(k, t) / sound_within(k, t)：扫描扬声器 k 的**全部**历史。
  -- 一次搬迁可能把一个时间**更早**的音符挪到 k 上，比 k 的 head 已经退役的条目还早，
  -- 所以相对于 head 的扫描在那里不够用；必须拿这个音符自己的 50 ms 窗口去对 k 仍然
  -- 持有的**每一个**条目做检查。
  --
  -- 不要把它「优化」成只从 head[k] 开始扫描。这看起来等价，其实不是：搬迁正是那种会把
  -- 更早时间戳追加到末尾的操作，而 head 早已越过那些位置。
  local function count_within(k, t)
    local list = times[k]
    local flags = alive[k]
    local count = 0
    for index = 1, #list do
      if flags[index] and within_window(list[index], t) then
        count = count + 1
      end
    end
    return count
  end

  local function sound_within(k, t)
    local list = times[k]
    local flags = alive[k]
    local flags_sound = sounds[k]
    for index = 1, #list do
      if flags[index] and flags_sound[index]
        and within_window(list[index], t) then
        return true
      end
    end
    return false
  end

  -- live_notes_within(k, t)：扬声器 k 的**活跃** play_note 中与 t 共享 50 ms 跨度的
  -- 那些条目的数组下标，按冻结事件下标排序。用于为一个 play_sound 清空扬声器：最早的
  -- 音符优先挑走剩余容量，所以必须被丢掉的音符是它们当中**最晚**的
  -- (tick, layer, note)。跨度里若有活跃的 play_sound，该扬声器就不合格；调用方会先
  -- 探 live_sound()。
  local function live_notes_within(k, t)
    local list = times[k]
    local flags = alive[k]
    local flags_sound = sounds[k]
    local found = {}
    for index = head[k], #list do
      if flags[index] and not flags_sound[index]
        and within_window(list[index], t) then
        found[#found + 1] = index
      end
    end
    table.sort(found, function(a, b)
      return ids[k][a] < ids[k][b]
    end)
    return found
  end

  -- relocation_target(note_time, from)：**第一个**能在 note_time 再吃下一个 play_note 的
  -- 扬声器（按 side 升序，排除 `from`）——那个跨度里没有 play_sound，且已有音符少于 8 个。
  local function relocation_target(note_time, from)
    for k = 1, total_speakers do
      if k ~= from then
        retire(k, note_time)
        if not sound_within(k, note_time)
          and count_within(k, note_time) < MAX_NOTES_PER_WINDOW then
          return k
        end
      end
    end
    return nil
  end

  -- move(k, index, k2)：把扬声器 k 的条目 `index` 搬迁到扬声器 k2 上。
  -- owner 映射是搬迁的一部分：发出的调用从此路由到 k2。
  local function move(k, index, k2)
    local id = ids[k][index]
    append(k2, times[k][index], false, id)
    alive[k][index] = false
    owner[id] = speakers[k2]
  end

  -- free_for_sound(t)：挑出那个为 t 处的一个 play_sound 让出自己跨度的扬声器，疏散它的
  -- 活跃音符，并返回它的下标 —— 当每个扬声器在那个跨度里都已经持有一个活跃 play_sound
  -- 时返回 nil（此时这个 sound 没有任何扬声器可用，只能被丢掉）。
  --
  -- 怎么挑扬声器：挑**最便宜**的那个 —— 让「无处可去的音符」最少的那个（它的负载减去
  -- 其他扬声器上还剩下的空音符槽）。并列时取 side 升序，所以结果是确定性的。
  local function free_for_sound(t)
    local chosen = nil
    local chosen_drops = nil
    for k = 1, total_speakers do
      retire(k, t)
      if not live_sound(k, t) then
        local load = live_count(k, t)
        if load > 0 then
          local spare = 0
          for other = 1, total_speakers do
            if other ~= k and not live_sound(other, t) then
              local room = MAX_NOTES_PER_WINDOW - live_count(other, t)
              if room > 0 then
                spare = spare + room
              end
            end
          end
          local drops = load - spare
          if drops < 0 then
            drops = 0
          end
          if chosen == nil or drops < chosen_drops then
            chosen = k
            chosen_drops = drops
          end
        end
      end
    end
    if chosen == nil then
      return nil
    end

    -- 疏散：只要存在目标就把跨度里的每个活跃音符都搬走；把无处可放的驱逐掉。
    -- sound 是最受约束的项（独占一整个扬声器 tick），所以它优先于这些音符。
    local notes = live_notes_within(chosen, t)
    for index = 1, #notes do
      local position = notes[index]
      local note_time = times[chosen][position]
      local target = relocation_target(note_time, chosen)
      if target ~= nil then
        move(chosen, position, target)
      else
        alive[chosen][position] = false
        owner[ids[chosen][position]] = nil
      end
    end
    return chosen
  end

  for i = 1, total_events do
    -- 节流上报。放在循环**开头**，所以 done 是「已经开始处理多少个」，而循环走完后下面
    -- 还会**无条件**补报一次 total——不补的话最后一次会被节流吞掉，进度条永远差最后一格。
    if report ~= nil and (i % report_step == 1) then
      report(i - 1, total_events)
    end

    local event = events[i]
    local kind = nil
    if type(event) == "table" then
      kind = event.kind
    end
    local t = time_of(event)

    if kind == "play_note" then
      -- 稳定的贪心「最少负载」：数出已经在该事件 50 ms 以内的音符数；用严格 `<` 的
      -- 改进判断，让并列时保留最早（side 升序）的那个扬声器。
      local best = nil
      local best_count = nil
      for k = 1, total_speakers do
        retire(k, t)
        if not live_sound(k, t) then
          local load = live_count(k, t)
          if load < MAX_NOTES_PER_WINDOW
            and (best == nil or load < best_count) then
            best = k
            best_count = load
          end
        end
      end
      if best ~= nil then
        append(best, t, false, i)
        owner[i] = speakers[best]
      end

    elseif kind == "play_sound" then
      -- 一个空扬声器直接胜出（第一个空闲扬声器，按 side 升序），这让每一个本来就成功的
      -- 放置留在原地不动。一个都不空时，**疏散**最便宜的那个，好让一个合法装箱不会
      -- 仅仅因为音符先被访问到而错过。
      local best = nil
      for k = 1, total_speakers do
        retire(k, t)
        if live_count(k, t) == 0 then
          best = k
          break
        end
      end
      if best == nil then
        best = free_for_sound(t)
      end
      if best ~= nil then
        append(best, t, true, i)
        owner[i] = speakers[best]
      end

    else
      -- 自定义/未知：什么都不消耗。路由到第一个扬声器，好让记录的调用顺序保持忠实投影；
      -- 派发会拒绝它。
      if total_speakers >= 1 then
        owner[i] = speakers[1]
      end
    end
  end

  -- 无条件补报一次 total：节流会吞掉最后一次，没有这一下进度条永远差最后一格，而那段
  -- 「99% 卡住」看起来比不显示进度更像出了问题。
  if report ~= nil then
    report(total_events, total_events)
  end

  return owner
end

-- fanout.assign(events, analysis, speakers) -> assignment。纯的、完备的、确定性的：
-- 它只读自己的输入，且从不为了顺序而使用 `pairs`。
-- fanout.assign(events, analysis, speakers, on_progress) -> assignment
--
-- `on_progress(done, total)` 可选，**按事件数**上报。调用方拿它画一条进度条。
--
-- 为什么需要它。菜单选完之后、第一声响起之前，这里有一段**同步**的停顿：把整首歌的每个
-- 事件分配到某个扬声器。开销是 O(事件数 × 扬声器数)，实测 8000 音符 / 4 扬声器约 66ms、
-- 20000 音符 / 8 扬声器约 177ms——而那是**桌面 Lua**，真机上的 Cobalt 会明显更慢，正好是
-- 用户能感知到的「卡了一下」。
--
-- 与 decode 的进度同一种机制：这里也是同步阻塞的，调用方回不到自己的循环，所以进度只能由
-- 本函数在干活的过程中回调。**不能**沿用播放期那套定时重画——那一刻时钟根本不会被拉动。
--
-- 只读输入，回调也**不**影响分配结果：它是纯粹的旁路观察，加不加、抛不抛错都不改变 owner。
function fanout.assign(events, analysis, speakers, on_progress)
  if type(events) ~= "table" then
    events = {}
  end
  if type(speakers) ~= "table" then
    speakers = {}
  end
  if type(analysis) ~= "table" then
    analysis = {}
  end

  local owner = allocate(events, speakers, on_progress)

  -- 预先为每个 side 建好键，好让调用方按扬声器 side 索引时不必判 nil，包括那些没有
  -- 任何事件的 side。
  local by_speaker = {}
  for k = 1, #speakers do
    local side = speakers[k].side
    if type(side) == "string" and by_speaker[side] == nil then
      by_speaker[side] = {}
    end
  end

  local dropped_events = {}
  local dropped = 0
  for i = 1, #events do
    local event = events[i]
    local assigned = owner[i]
    if assigned ~= nil then
      local side = assigned.side
      if type(side) == "string" then
        local bucket = by_speaker[side]
        if bucket == nil then
          bucket = {}
          by_speaker[side] = bucket
        end
        bucket[#bucket + 1] = event
      end
    else
      local kind = nil
      if type(event) == "table" then
        kind = event.kind
      end
      if consumes(kind) then
        dropped = dropped + 1
        dropped_events[#dropped_events + 1] = event
      end
    end
  end

  local required = nbs_speakers.required_count(analysis)
  local found = #speakers

  local warning_code = nil
  local warning_args = nil
  if dropped > 0 or found < required then
    warning_code = "speakers"
    warning_args = {
      peak = analysis.peak_concurrent,
      required = required,
      found = found,
      dropped = dropped,
    }
  end

  return {
    speakers = speakers,
    required = required,
    found = found,
    dropped = dropped,
    dropped_events = dropped_events,
    by_speaker = by_speaker,
    warning_code = warning_code,
    warning_args = warning_args,
  }
end

-- fanout.play(events, analysis, speakers, dispatch) -> 播放汇总。
--
-- 复用与 assign() **同一套**分配，然后按冻结顺序遍历事件、把每个事件路由到它被分配的
-- 扬声器来发出调用。自定义事件会到达派发（由派发拒绝）但不产生调用。被丢掉的事件不派发。
-- `analysis` 是冻结签名的一部分，此外在这里未被使用。
function fanout.play(events, analysis, speakers, dispatch)
  if type(events) ~= "table" then
    events = {}
  end
  if type(speakers) ~= "table" then
    speakers = {}
  end

  local owner = allocate(events, speakers)

  local can_dispatch = type(dispatch) == "table"
    and type(dispatch.event) == "function"

  local calls_made = 0
  local refused = 0
  local dropped = 0
  local results = {}

  for i = 1, #events do
    local event = events[i]
    local assigned = owner[i]
    if assigned ~= nil and can_dispatch then
      local result = dispatch:event(event, assigned)
      results[#results + 1] = result
      if type(result) == "table" then
        if result.called then
          calls_made = calls_made + 1
        end
        if result.refused then
          refused = refused + 1
        end
      end
    else
      local kind = nil
      if type(event) == "table" then
        kind = event.kind
      end
      if consumes(kind) then
        dropped = dropped + 1
      end
    end
  end

  return {
    calls_made = calls_made,
    refused = refused,
    dropped = dropped,
    results = results,
  }
end

return fanout
