-- nbs/instrument_table.lua
--
-- 把 NBS 乐器 id 映射成 CC:Tweaked 扬声器**必须**发出的那次精确调用。
--
-- 本模块只回答一个问题：「发哪种调用、名字是什么」。它不持有音量、也不持有音高
-- ——那些归 player/mapping.lua——所以调用方可以拿这里的名字搭配自己的音量/音高参数。
--
-- 冻结的公共接口（后续层依赖这些精确形状）
--   instrument_table.PLAY_NOTE_NAMES    16 个旧乐器名的数组；
--                                       下标 i（1..16）== 乐器 id（i-1）
--   instrument_table.PLAY_NOTE_COUNT    16
--   instrument_table.play_note_name(id)   -> 名字字符串；0..15 之外为 nil
--   instrument_table.play_sound_name(id)  -> 音效事件字符串，或 nil
--   instrument_table.bucket_of(id, vanilla_instrument_count)
--     -> "vanilla" | "play_sound" | "custom"   （**唯一**的分类器）
--   instrument_table.resolve(id, vanilla_instrument_count)
--     -> { kind = "play_note",  name = <16 个之一> }
--     |  { kind = "play_sound", name = "minecraft:block.note_block.<...>" }
--     |  { kind = "custom",     custom_index = <整数> }
--
-- 分类只有**一个**归属处
--   bucket_of 是唯一的分类器；resolve() 把它的答案映射成一次调用，nbs/analyze.lua
--   则用它来切自己的乐器桶。在别处重新实现这条规则，正是当初 analyze 与 resolve 在
--   vanilla 计数为 10 和 17..19 时**互相不一致**的原因——那会给 v6 小号少算扬声器，
--   并为一个旧格式的自定义 id 凭空报出 "speakers" 警告。
--
-- vanilla_instrument_count 缺失时
--   nil（或其他任何非数值）按文档默认值 16 处理——即 v1..v5 的边界：id 0..15 是
--   vanilla，id 16+ 是自定义。bucket_of 与 resolve 都不会因此抛错，而这正是 analyze
--   早已对缺失计数所做的分类，所以两个模块即便面对畸形输入也保持一致。
--
-- 为什么 id 16..19 是 **playSound 专属**
--   speaker.playNote 只接受 PLAY_NOTE_NAMES 里那**恰好** 16 个名字，其他任何字符串都
--   会**抛错**。Minecraft 26/26.1 的小号音符盒音效（NBS id 16..19）**不在**那个集合
--   里，所以把它们交给 playNote 会在游戏内抛错。它们因此只能通过 speaker.playSound
--   配一个完整的音效事件 id 到达。把它们挡在 PLAY_NOTE_NAMES **之外**，正是防止游戏内
--   抛错的关键。
--
-- 为什么「小号还是自定义」由**文件自己的** vanilla_instrument_count 决定
--   id 16..19 是「v6 小号」还是「第一个自定义乐器」，**只**取决于该文件自己 header 里
--   那个计数，绝不只看 id：
--     * v6 文件声明 20 -> id 16..19 是 vanilla 小号（playSound），id 20+ 是自定义。
--     * v5 文件声明 16 -> id 16..19 **本来就是**自定义（custom_index 0..3）。把它们
--       当成小号，会凭空造出文件从未引用过的音效。
--   所以自定义判定（`id >= vanilla_instrument_count`）必须**先**跑，在小号查表之前。
--   把顺序倒过来，正是本模块存在的理由所要避免的那个隐蔽 bug。
--
-- 那些刻意为之、**不是**拼写错误的名称不对称
--   * id 4 是 `hat`（NBS 界面里把它叫作 "Click"）。
--   * id 2 是 `basedrum`，**一个词**；id 3 是 `snare`。
--   已对 tryashtar/nbs-functions 的 nbsreader/Model.cs（GetInstrumentName）与
--   koca2000/NoteBlockAPI 的 getSoundNameByInstrument 核实，两者都把 2 -> basedrum、
--   3 -> snare（那张把两者掉换的对照表是错的）。
--
-- 目标解释器
--   原版 Lua 5.2 / CC:Tweaked Cobalt：不用 utf8.*、不用位运算、不用整除、不用 os.exit。

local instrument_table = {}

-- speaker.playNote 接受的 16 个名字，下标这样排：PLAY_NOTE_NAMES[id + 1] 就是乐器
-- id `id`（0..15）对应的名字。
local PLAY_NOTE_NAMES = {
  "harp",           -- id 0
  "bass",           -- id 1
  "basedrum",       -- id 2  (one word)
  "snare",          -- id 3
  "hat",            -- id 4  (NBS calls this "Click")
  "guitar",         -- id 5
  "flute",          -- id 6
  "bell",           -- id 7
  "chime",          -- id 8
  "xylophone",      -- id 9
  "iron_xylophone", -- id 10
  "cow_bell",       -- id 11
  "didgeridoo",     -- id 12
  "bit",            -- id 13
  "banjo",          -- id 14
  "pling",          -- id 15
}

-- 四个 v6 小号音效事件，直接按 id 16..19 索引。它们是 playSound 专属（见文件头）。
local PLAY_SOUND_NAMES = {
  [16] = "minecraft:block.note_block.trumpet",
  [17] = "minecraft:block.note_block.trumpet_exposed",
  [18] = "minecraft:block.note_block.trumpet_weathered",
  [19] = "minecraft:block.note_block.trumpet_oxidized",
}

-- 旧 playNote id 的数量（0..15）。
local PLAY_NOTE_COUNT = 16

instrument_table.PLAY_NOTE_NAMES = PLAY_NOTE_NAMES
instrument_table.PLAY_NOTE_COUNT = PLAY_NOTE_COUNT

-- play_note_name(id) -> playNote 名字；`id` 不在 0..15 时为 nil。
-- 从不抛错：调用方可以安全地探测任意 id（例如某个越界音符）。
function instrument_table.play_note_name(id)
  if type(id) == "number" and id >= 0 and id <= 15 then
    return PLAY_NOTE_NAMES[id + 1]
  end
  return nil
end

-- play_sound_name(id) -> 小号音效事件 id；否则 nil。只有 id 16..19 有 playSound
-- 形式；旧 id 是 playNote 专属，这里返回 nil。
function instrument_table.play_sound_name(id)
  if type(id) == "number" and id >= 16 and id <= 19 then
    return PLAY_SOUND_NAMES[id]
  end
  return nil
end

-- 调用方没有给出可用的 vanilla 乐器计数（nil，或其他任何非数值）时所假定的边界。
-- v1..v5 布局（16 个 vanilla 乐器，id 16+ 自定义）是旧格式的默认值，也与 analyze 历来
-- 对缺失计数的处理一致，所以两个模块的判断相同。
local DEFAULT_VANILLA_INSTRUMENT_COUNT = 16

-- 最后一个 vanilla v6 小号的 id（16..19）。放在分类器旁边：这是分类器自己持有的
-- 唯一数值边界。
local PLAY_SOUND_MAX_ID = 19

-- vanilla_count(vanilla_instrument_count) -> 一个可供边界比较使用的数值。
-- 缺失/非数值的计数回退到文档默认值。
local function vanilla_count(vanilla_instrument_count)
  if type(vanilla_instrument_count) == "number" then
    return vanilla_instrument_count
  end
  return DEFAULT_VANILLA_INSTRUMENT_COUNT
end

-- bucket_of(instrument_id, vanilla_instrument_count) -> "vanilla" |
-- "play_sound" | "custom"。分类规则的**唯一**归属处；analyze.lua 与 resolve()
-- 都调它，所以两者永远不会跑偏。
--
-- 顺序很重要。自定义判定先跑，比对的是**文件自己的** vanilla 计数，所以 v5 文件
-- （计数 16）会把 id 16..19 分类成自定义、而不是小号。只有低于 vanilla 边界的 id
-- 才可能是旧音符或 v6 小号。
function instrument_table.bucket_of(instrument_id, vanilla_instrument_count)
  local count = vanilla_count(vanilla_instrument_count)

  -- 自定义：大于等于文件的 vanilla 计数。非数值 id 永远无法对应一次可调度的调用，
  -- 所以也算自定义。
  if type(instrument_id) ~= "number" or instrument_id >= count then
    return "custom"
  end

  -- 边界以下：16 个旧音符盒 id 是 vanilla 的 playNote。
  if instrument_id >= 0 and instrument_id < PLAY_NOTE_COUNT then
    return "vanilla"
  end

  -- 边界以下的 id 16..19 是 v6 小号（playSound 专属）。
  if instrument_id >= PLAY_NOTE_COUNT and instrument_id <= PLAY_SOUND_MAX_ID then
    return "play_sound"
  end

  -- 边界以下、但没有已知调用的 id（只有在计数畸形且大于 20 时才可达）。analyze 历来
  -- 把这种 id 排除在两个桶之外；"custom" 让分类保持诚实——它们永远无法被调度。
  return "custom"
end

-- resolve(instrument_id, vanilla_instrument_count) -> 一个调用描述符。
-- 分类委托给 bucket_of；本函数只把桶映射成精确的调用形状。
function instrument_table.resolve(instrument_id, vanilla_instrument_count)
  local bucket = instrument_table.bucket_of(instrument_id,
    vanilla_instrument_count)

  if bucket == "custom" then
    -- 后面的层在播放时会拒绝这些，只需要 custom_index 做诊断。非数值 id 没有可报的
    -- 下标。
    local custom_index = nil
    if type(instrument_id) == "number" then
      custom_index = instrument_id - vanilla_count(vanilla_instrument_count)
    end
    return { kind = "custom", custom_index = custom_index }
  end

  if bucket == "vanilla" then
    return { kind = "play_note", name = PLAY_NOTE_NAMES[instrument_id + 1] }
  end

  return { kind = "play_sound", name = PLAY_SOUND_NAMES[instrument_id] }
end

return instrument_table
