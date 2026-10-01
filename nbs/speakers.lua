-- nbs/speakers.lua
--
-- 计算一首歌需要多少个 CC:Tweaked `speaker` 外设的**纯公式**，以及播放器用来对
-- 「外设不够」发出警告的对比。
--
-- 冻结的公共接口
--   local speakers = require("nbs.speakers")
--
--   speakers.MAX_NOTES_PER_TICK               -- 8
--   speakers.required_count(analysis)         -> 整数 >= 0
--   speakers.assess(analysis, found_count)    -> {
--     required, found, sufficient, shortfall,
--     peak, vanilla_at_peak, play_sound_at_peak,
--   }
--
-- `analysis` 正是 nbs.analyze 产出的那个值。本模块是一个**纯公式**：它**从不**重算
-- 峰值并发、也**不**重新切分乐器桶——analyze 已经做过了。它只读
-- `vanilla_notes_at_peak` 与 `play_sound_notes_at_peak` 两个字段（对 assess 还读
-- `peak_concurrent`，原样拷贝）。它不读时钟、不做 I/O、不持有可变状态、从不修改输入，
-- 所以调它两次得到同一个答案。
--
-- ===========================================================================
-- 公式 —— 以及为什么第二项是**相加**而不是相除
-- ===========================================================================
--   required = ceil(vanilla_notes_at_peak / 8) + play_sound_notes_at_peak
--
-- 一个 CC:Tweaked 扬声器每个游戏 tick 最多接受 `max_notes_per_tick`（8）次
-- `playNote` 调用，但每个游戏 tick 只接受**一次** `playSound` 调用。所以单个
-- playSound 音符（v6 的 "trumpet" 家族）自己就吃掉**整个**扬声器 tick。由此得出的
-- 两条将来会有人想「优化」掉、但**不许**动的结论：
--
--   * playSound 计数是**整份**相加的。把它除以 8 是错的：扬声器没法把八次
--     playSound 调用塞进一个 tick。
--   * 它**不**被并入 playNote 计数的同一个天花板。先加再取天花板
--     （ceil((vanilla + playSound) / 8)）也是错的：一个普通音符加一个小号音符需要
--     **两个**扬声器，不是一个。
--
-- 已知偏差，刻意保留（必读）
-- --------------------------
--   上面最后那一句是**错的**。源码说的是另一回事：`SpeakerPeripheral.update()` 在
--   **同一个 tick** 里刷新两个**互相独立**的缓冲——`pendingNotes`（最多 8 次
--   playNote，一次性广播）与 `pendingSound`（一个 sound）。而两个入口各管各的：
--   `playNote` 只在 `pendingNotes.size() >= maxNotesPerTick` 时拒绝，`playSound` 只在
--   `pendingSound != null` 时拒绝，**互不查询**。所以一个扬声器可以在同一个 tick 里
--   播 8 个音符**加** 1 个 sound，正确公式应是
--   `max(ceil(vanilla / 8), play_sound)`。
--
--   为什么还留着不动：这条公式是**保守**的——只会多要扬声器、绝不会少要，所以只要
--   照做就什么都不会被静默丢掉。真正的修正不是改一行：player/fanout.lua 把扬声器
--   建模成「8 个槽的单一池子，一个 sound 会顶掉音符」，而它**整套疏散机制**就是为
--   化解一个并不存在的冲突而写的。正确的分配器更小：音符与 sound 从不竞争。那次重写
--   是**有意延后**的。
--
--   代价：simple.nbs 被告知需要 3 个扬声器，其实 2 个就够。
--
-- 下面是公式自己的算术示例（不是平台行为）：
--   (vanilla=1, playSound=1) -> 2
--   (vanilla=8, playSound=1) -> 2
--   (vanilla=8, playSound=2) -> 3
--   (vanilla=0, playSound=8) -> 8   -- 八个独立的扬声器 tick
--   (vanilla=0, playSound=0) -> 0   -- ceil(0/8) + 0 == 0：静音不需要扬声器
--
-- **自定义乐器不计数。** 自定义乐器的音符在播放时会被拒绝，所以它不能让需求虚高。
-- `vanilla_notes_at_peak` 与 `play_sound_notes_at_peak` 已经排除了自定义乐器 id，所以
-- 这里**刻意没有**第三项。一个全由自定义音符构成的峰值会给出 required == 0，哪怕
-- `peak_concurrent` 很大；公式**绝不能**读 `peak_concurrent`。
--
-- 本文件遵守的 Lua 5.2 / Cobalt 约束：不用整除、不用位运算、不用 utf8.*、不用
-- math.maxinteger、不用 collectgarbage、不用 string.dump、不用 os.exit —— 并且这里
-- 用显式的基于 math.floor 的天花板代替 math.ceil，好让算术无歧义且对 Cobalt 安全。

local speakers = {}

-- 一个扬声器每个游戏 tick 最多接受的 `playNote` 调用数。
speakers.MAX_NOTES_PER_TICK = 8

-- a/b 的整数天花板（a >= 0、b > 0），不用 math.ceil、也不用整除。
-- 写成算术形式，好让它在 Lua 5.2 / Cobalt 上无歧义：
--   ceil(a / b) == floor(a / b) + （有余数时为 1，否则 0）
local function ceil_div(a, b)
  return math.floor(a / b) + (a % b > 0 and 1 or 0)
end

-- required_count(analysis) -> 整数 >= 0
function speakers.required_count(analysis)
  local vanilla = analysis.vanilla_notes_at_peak or 0
  local play_sound = analysis.play_sound_notes_at_peak or 0

  -- vanilla 音符：最多 MAX_NOTES_PER_TICK 个共用一个扬声器 tick。
  -- playSound 音符：**每个**独占一整个扬声器 tick —— 故有这项相加。
  return ceil_div(vanilla, speakers.MAX_NOTES_PER_TICK) + play_sound
end

-- assess(analysis, found_count) -> 汇总表
--
-- 把公式和播放器需要的对比捆在一起：`found_count` 是实际挂载的扬声器数。
-- `found_count` 为 0 是合法的。
function speakers.assess(analysis, found_count)
  local found = found_count or 0
  local required = speakers.required_count(analysis)

  local shortfall = required - found
  if shortfall < 0 then
    shortfall = 0
  end

  return {
    required = required,
    found = found,
    sufficient = found >= required,
    shortfall = shortfall,
    peak = analysis.peak_concurrent,
    vanilla_at_peak = analysis.vanilla_notes_at_peak,
    play_sound_at_peak = analysis.play_sound_notes_at_peak,
  }
end

return speakers
