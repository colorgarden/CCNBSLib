-- player/plan.lua
--
-- **纯**事件计划器：把已解码的 NBS 歌曲变成一份**完整有序**的定时扬声器事件列表。
-- 本模块是播放器的**确定性锚点**。
--
-- 冻结的公共接口
--   local plan = require("player.plan")
--   plan.plan(song, analysis) -> <事件数组>
--
--   song      nbs.decode 产出的值（这里用到的字段：header、layers、notes）。
--             **从不**被修改。
--   analysis  nbs.analyze 产出的值（这里用到的字段：tick_ms）。
--
--   每个事件表的键**精确**如下：
--     t_ms          number   = tick_index * analysis.tick_ms
--     tick_index    integer  该音符的 tick
--     layer_index   integer  该音符的图层（从 0 起算）
--     note_index    integer  它在自己那个 (tick, layer) 组内的序号（从 1 起算）
--     instrument    integer  原始 NBS 乐器 id
--     key           integer
--     kind          "play_note" | "play_sound" | "custom"  （来自 instrument_table）
--     name          字符串；恰好当 kind == "custom" 时为 nil
--     custom_index  整数；除非 kind == "custom"，否则为 nil
--     volume        number，0..3（mapping.speaker_volume 作用于合成音量）
--     pitch         整数，半音，**不夹取**（mapping.pitch_semitones）
--     pitch_cents   number，cents 残量（mapping.cents_to_semitones）
--     layer_volume  整数，来源图层的音量（缺失时默认 100）
--
-- ===========================================================================
-- 冻结的全序 —— 最重要的一条要求
-- ===========================================================================
-- 事件按元组**升序**排序
--
--     (tick_index, layer_index, note_index)
--
-- note_index 是**第三**个、也是最后一个键。它**不是**全局唯一 id：它是每个
-- (tick_index, layer_index) 组内从 1 起算的位置（见下），所以它正是「调用方输入数组的
-- 顺序」抵达输出的那个字段。同一个 (tick, layer) 组里的两个音符，按它们在 `song.notes`
-- 里出现的顺序排；计划器**不**在组内重新排序。对于处在**不同**组的两个音符，输入顺序
-- 无关紧要。
-- 排序用一个**显式**的比较函数完成（见 less_event）：**不要**因为假设输入已经排好序就
-- 把它「优化」掉，也**不要**只按 t_ms 排（t_ms 是 tick_index 的函数，不增加任何信息，
-- 还会丢掉 layer/note 这两个并列判据）。
--
-- *** 给将来的编辑者的警告 ***
-- Tier-2 集成测试断言的是计划产出的扬声器调用的**有序序列**。那个比较之所以有意义，
-- 完全是因为本模块确定性地固定了顺序。引入任何对哈希表遍历顺序（`pairs`）或时钟的
-- 依赖，都会让那些集成断言变得时灵时不灵。对于**组内**的 note_index，输入数组的顺序是
-- **刻意**有意义的，但必须从数组的**位置**读出——绝不能来自一次无序的表遍历。本模块必须
-- 保持是一个纯的、完备的、确定性的函数：没有时钟、没有外设、没有 I/O、没有全局变量、
-- 不修改输入。对**同一个**输入数组调用两次 plan(song, analysis)，必须得到逐字节相同的
-- 输出。
--
-- note_index 是怎么算出来的
--   note_index 属于一个 (tick, layer) **组**，每进入新组就从 1 重新开始。本模块先构造
--   一份由 (tick, layer, 输入内的位置) 作键的可排序列表，对它排一次序，然后按序走一遍：
--   相邻项共享同一个 (tick, layer) 时把计数器加一，否则重置为 1。输入位置是**已经在
--   同一个 (tick, layer) 组里**的音符的并列判据；而由于这个位置变成了 note_index ——
--   第三个排序键 —— 它**确实**决定了同组音符的发出顺序。计划器从不在组内重新排序；
--   想要特定组内顺序的调用方必须在 `song.notes` 里就把那个顺序给出来。
--
-- t_ms 是**推导**出来的，从不累加
--   t_ms = tick_index * analysis.tick_ms，对每个事件按它自己的 tick 计算。它刻意**不是**
--   用 `previous_t_ms + tick_ms` 递推出来的：逐次相加会累积浮点舍入误差，破坏后面某个
--   模块依赖的漂移保证。当 tick_ms 是循环小数（例如 1000/3）时，第 N 个 tick 报出的仍
--   恰好是 N * tick_ms。
--
-- 被静音与非 solo 的图层**不**参与计划
--   规范里叫 "Layer lock" 的那个 NBS 每层字节，实际上是 mute/solo 开关
--   （0 未锁、1 静音、2 solo —— 证据见 nbs/layers.lua）。被静音的图层、以及任何图层是
--   solo 时的所有非 solo 图层，**完全不**贡献事件。
--
--   静音意味着**缺席**，而不是音量 0。一个被静音的音符绝不能花掉一次扬声器调用：
--   CC:Tweaked 限制每个扬声器每游戏 tick 8 个音符
--   （`SpeakerPeripheral.playNote` 超过 `Config.maxNotesPerTick` 返回 false），所以一个
--   音量 0 的事件会挤掉本该发声的音符。
--
--   这是本模块对「一个音符是否可听」所做的**唯一**决定，而且用的是 nbs/analyze.lua 用的
--   **同一条**规则，所以计划与容量分析永远不会在「哪些音符会播」上产生分歧。
--
-- 自定义音符**仍然**被发出
--   除了上面的可听性规则，本模块不决定一个音符是否**被播放**；它做的是**计划**。自定义
--   乐器变成一个 kind == "custom"、name == nil、带 custom_index 的事件。派发层稍后会
--   拒绝它。把它发出来，才能让计划成为**可听**歌曲的忠实投影——而这正是一份
--   「计划 vs 录音」对比之所以有意义的原因。
--
-- 缺失图层
--   解码后的图层数组是 1 起算的，所以 layer_index L 读的是 layers[L + 1]。引用了已解码
--   列表之外图层（或整首歌一个图层都没有）的音符**不会**被丢掉、也**不会**抛错：图层
--   音量默认 100，这个替换被记录在事件自己的 layer_volume 字段里，而事件仍会出现在顺序
--   中它正确的位置上。
--
-- 音量
--   先 mapping.combined_volume(layer_volume, note.velocity)（NBS 合成公式），
--   再 mapping.speaker_volume(combined)（0..3 的扬声器缩放），按这个顺序。
--
-- 本文件遵守的 Lua 5.2 / Cobalt 约束：不用 `//`、不用位运算、不用 utf8.*、不用
-- math.maxinteger、不用 collectgarbage、不用 string.dump、不用 os.exit。
-- 本模块任何地方都不对哈希表使用 `pairs`。

local mapping = require("player.mapping")
local instrument_table = require("nbs.instrument_table")
-- mute/solo 规则。它住在 nbs/layers.lua、紧挨着读那个字节的代码，因为 nbs/analyze.lua
-- 需要**同一条**规则——见那里的说明。
local layer_format = require("nbs.layers")

local plan = {}

-- 当音符引用了已解码歌曲里不存在的图层时所替换的图层音量。100 是 NBS 的中性满音量；
-- 事件会把替换后的值记录下来，好让这个默认行为在计划里可见。
local DEFAULT_LAYER_VOLUME = 100

-- less_event(a, b)：冻结的全序，(tick, layer, note) 升序。
-- 这是**唯一**用于已发出事件的比较函数；note_index 之后没有并列判据，因为 note_index
-- 在任何 (tick, layer) 组内都是唯一的。
local function less_event(a, b)
  if a.tick_index ~= b.tick_index then
    return a.tick_index < b.tick_index
  end
  if a.layer_index ~= b.layer_index then
    return a.layer_index < b.layer_index
  end
  return a.note_index < b.note_index
end

-- less_grouped(a, b)：构造期顺序，(tick, layer, 输入内的位置)。
-- 只用于确定性地指派 note_index；发出顺序随后由 less_event 固定。
local function less_grouped(a, b)
  if a.record.tick ~= b.record.tick then
    return a.record.tick < b.record.tick
  end
  if a.record.layer ~= b.record.layer then
    return a.record.layer < b.record.layer
  end
  return a.position < b.position
end

-- plan.plan(song, analysis) -> 事件数组。对已解码歌曲而言是纯的、完备的；
-- 完整契约见文件头。
-- plan.plan(song, analysis, opts) -> 事件数组
--
-- opts.out_of_range  播放策略。`"shift"` 会把落在自己录音八度之外的一个音符，改经一个
--                    八度偏移的音效文件播放——这是唯一能让它以正确音高被听到的办法：
--                    客户端会把普通音高夹到 0.5..2.0，再远的都变成边界音。
--                    `"passthrough"` 保持旧行为，对**没有**材质包的客户端才是对的选择，
--                    因为偏移后的名字解析不到东西，音符会是**静音**而不是仅仅音高不准。
--
-- 这个决定是 `mapping.route` 的，与 nbs/analyze.lua 共用，所以容量数字与事件不可能
-- 产生分歧。
function plan.plan(song, analysis, opts)
  local notes = song.notes or {}
  local layers = song.layers or {}
  local header = song.header or {}
  local vanilla_instrument_count = header.vanilla_instrument_count
  local tick_ms = analysis.tick_ms
  local out_of_range = type(opts) == "table" and opts.out_of_range
    or mapping.DEFAULT_OUT_OF_RANGE

  -- opts.from_ms（seek）：只保留 t_ms >= from_ms 的事件。
  --
  -- **绝不改写 t_ms。** t_ms 是冻结的（t_ms = tick_index * tick_ms），seek 只做取舍、
  -- 不做平移；平移会破坏计划的公共契约，也会破坏 Tier-2 那条「有序调用序列」断言。
  --
  -- 非有限或负数一律视为「未提供」（与 opts.from_ms 缺省时逐字节相同）。把它读成
  -- 「过滤掉一切」是最容易犯的错：那会让一次误传的 from_ms 静默变成一首空歌。
  local from_ms = nil
  if type(opts) == "table" then
    local candidate = opts.from_ms
    if type(candidate) == "number" and candidate == candidate
      and candidate ~= math.huge and candidate ~= -math.huge and candidate >= 0 then
      from_ms = candidate
    end
  end

  -- 这首歌是否处于 SOLO 模式。**一次**算完，遍历整个图层数组，因为任何图层上的 solo
  -- 都会让所有非 solo 图层静音——所以这不可能逐音符决定。
  local any_solo = layer_format.any_solo(layers)

  -- 那些**确实可听**的音符的可排序副本。输入数组本身只被读取；`position` 是从 1 起算的
  -- 输入下标，纯粹用于在**已经相等**的 (tick, layer) 组内打破并列。
  --
  -- 在这里过滤而不是在发出循环里过滤，能让 `total` 保持诚实，也意味着下面的分组
  -- 只会看到将被发出的音符。
  local grouped = {}
  local total = 0
  for index = 1, #notes do
    local record = notes[index]

    -- ROUTE 在这里、只在这里决定一次，并被带进发出循环——所以过滤与事件不可能对同一个
    -- 音符有不同看法。决定权归 `mapping.route`；这里只是照它行动。
    local route = mapping.route(
      instrument_table.bucket_of(record.instrument, vanilla_instrument_count),
      record.key, out_of_range)

    -- 被 DROP 的音符在这里就被过滤掉，而不是「发出后再忽略」，所以它不占扬声器槽。
    -- 这与被静音图层得到的待遇相同，也正是 `analyze` 把一个被丢掉的音符计为「什么都不
    -- 是」时所假定的。
    if route ~= "dropped" and layer_format.audible_at(layers, any_solo, record.layer) then
      total = total + 1
      grouped[total] = { record = record, position = index, route = route }
    end
  end
  table.sort(grouped, less_grouped)

  local events = {}

  -- note_index 的记账：上一个 (tick, layer) 及其运行计数。
  local group_tick = nil
  local group_layer = nil
  local group_count = 0

  for index = 1, total do
    local record = grouped[index].record
    local route = grouped[index].route
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

    -- 图层音量：layers 是 1 起算，layer_index 是 0 起算。缺失的图层（或没有数值音量的
    -- 图层）默认 100，并且仍然发出。
    local source_layer = layers[layer + 1]
    local layer_volume = DEFAULT_LAYER_VOLUME
    if type(source_layer) == "table"
      and type(source_layer.volume) == "number" then
      layer_volume = source_layer.volume
    end

    -- 先做 NBS 合成，再做 0..3 的扬声器缩放。
    local combined = mapping.combined_volume(layer_volume, record.velocity)

    -- 扬声器必须发哪种调用。resolve() 拥有 v5-vs-v6 的边界；SHIFT 决定归
    -- mapping.route，它把 key 与策略一起折了进来。
    local resolved = instrument_table.resolve(record.instrument,
      vanilla_instrument_count)

    -- `kind` 与 `name` 来自过滤阶段已经决定好的 ROUTE，而不是对 key 的第二次解读——
    -- 两者按构造就必须一致。
    local kind = resolved.kind
    local name = resolved.name
    local ratio = nil

    -- 作为**路由结果**的 "play_sound" 有两个来源，而其中只有一个会改名字。
    --
    --   乐器本身            一个 v6 小号音符天生就是 playSound，名字已经是
    --                       "minecraft:block.note_block.<...>"，而且它的 key 落在原生
    --                       范围内
    --   因 SHIFT 而来        一个离自己录音太远的原生音符，变成一个播放**偏移录音**的
    --                       playSound
    --
    -- `shift_for_key` 对原生范围内的 key 返回 nil，所以第一种情况**不能**去解引用它
    -- ——那样做会让每一个 v6 小号音符都抛错。问一下有没有 shift，正是区分两者的办法，
    -- 而只有非 nil 的答案才会改任何名字。
    local shift = mapping.shift_for_key(record.key)
    if kind == "play_note" and route == "play_sound" and shift ~= nil then
      -- 八度来自**另一份录音**，而倍率只需覆盖剩下的 ±1 个八度。`ratio` 就是派发要发
      -- 的东西；像 v5-vs-v6 那条路径那样从 key 反推一个，会差一到两个八度。
      kind = "play_sound"
      name = mapping.shifted_sound_name(name, shift.suffix)
      ratio = shift.ratio
    elseif kind == "play_note" and out_of_range == mapping.OUT_OF_RANGE_CLAMP then
      -- CLAMP 策略：仍然是 playNote，但落在最近的原生音高上，所以结果不取决于客户端
      -- 拿到越界值会做什么。
      kind = "play_note"
    end

    local event = {
      t_ms = tick * tick_ms, -- 每个事件各自推导；从不累加
      tick_index = tick,
      layer_index = layer,
      note_index = note_index,
      instrument = record.instrument,
      key = record.key,
      kind = kind,
      name = name,
      custom_index = resolved.custom_index,
      volume = mapping.speaker_volume(combined),
      -- CLAMP 会压到原生边界；其他每个策略都保留原始半音（shift 会把它们传下去，但派发
      -- 更看重 `ratio` 而忽略它们；passthrough 把它们送出去由客户端夹取；drop 根本到不了
      -- 这里）。
      pitch = (out_of_range == mapping.OUT_OF_RANGE_CLAMP)
        and mapping.clamped_pitch(record.key)
        or mapping.pitch_semitones(record.key),
      pitch_cents = mapping.cents_to_semitones(record.pitch),
      layer_volume = layer_volume,
      -- 非 nil 恰好当 kind == "play_sound" **且**本模块选了倍率时。v5-vs-v6 的
      -- play_sound 路径让它保持 nil、由派发去推导，所以两个来源永远不会撞车。
      ratio = ratio,
    }

    -- from_ms 过滤发生在这里、而不是在 grouped 里：t_ms 是每个事件各自推导的，只有
    -- 构造出 event 才知道它落在哪。分组与 note_index 都**不受**过滤影响，所以被保留
    -- 事件的 note_index 仍与未过滤时相同。
    if from_ms == nil or event.t_ms >= from_ms then
      events[#events + 1] = event
    end
  end

  -- 显式地强制那条冻结的全序。不要指望 `grouped` 已经是这个顺序。
  table.sort(events, less_event)

  return events
end

return plan
