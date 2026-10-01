-- player/mapping.lua
--
-- NBS 数字 → CC:Tweaked 扬声器参数的唯一转换点，且全部是纯函数。
--
-- 为什么必须集中在一处：后续每一层（plan / speaker / dispatch / fanout）都会对
-- 本模块交给 `speaker.playNote` / `speaker.playSound` 的**具体数值**做断言。
-- 所以这里是一组**纯函数**（没有状态、没有 I/O、可重复调用），并且**不做任何
-- 「顺手修正」**——下面的两个决定反直觉，但必须原样保留。
--
-- ---------------------------------------------------------------------------
-- 1. 音量公式
-- ---------------------------------------------------------------------------
-- NBS 里图层音量（0..100）和音符力度（0..100）是分开存的，实际响度是二者乘积：
--
--     combined_volume = (layer_volume * note_velocity) / 100
--
-- 老格式（v0-v3）的音符没有力度字段，解码器补 100（乘法单位元），于是
-- combined_volume(layer, 100) == layer。
--
-- 扬声器自己的音量参数是 0.0..3.0 的标量：
--
--     speaker_volume(v) = clamp(round_half_up(v / 100 * 3), 0, 3)
--
-- 取整是**四舍五入**（`floor(x + 0.5)`），所以 1.5 → 2。这一条被测试钉住。
-- 超出 0..100 的输入会被夹取。
--
-- ---------------------------------------------------------------------------
-- 2. 音高**不夹取** —— 这是产品决定，不是疏漏
-- ---------------------------------------------------------------------------
--     pitch_semitones(key) = key - 33
--
-- NBS 的 key 33(F#3) 是半音 0、45(F#4) 是 12、57(F#5) 是 24，即**两个八度**的
-- 原生范围。但 Minecraft 音符盒的音高参数接受越界值，社区的「扩展音域」材质包
-- 会补上额外采样的声音。
--
-- 所以这里**故意不夹到 0..24**：key 20 → -13、key 90 → 57 都原样透传。
-- 在这里夹取会让扩展音域这个功能静默失效。越界音符由**单独的警告层**上报，
-- 本模块只负责换算，不决定「什么能播」。
--
-- 注意区分两件事：**服务端** CC 不校验音高（`SpeakerPeripheral.playNote` 只调
-- `checkFinite`），**客户端** 才会夹——见本文件第 5 节。
--
-- ---------------------------------------------------------------------------
-- 3. 声场（panning）**被丢弃** —— CC:Tweaked 没有逐音符声场参数
-- ---------------------------------------------------------------------------
-- NBS 图层带 panning（0..200），但 `speaker.playNote` / `playSound` 都**没有**
-- 这个参数。所以整块丢弃：本模块**不提供**任何 panning 函数，调用方也不许自己
-- 发明一个额外参数。立体声位置在这里无法表达。
--
-- ---------------------------------------------------------------------------
-- 4. playSound 的音高限制（ratio，夹到 0.5..2.0）
-- ---------------------------------------------------------------------------
--     play_sound_pitch(key) = clamp(2 ^ ((key - 45) / 12), 0.5, 2.0)
--
-- `speaker.playSound` 收的是**倍率**，窗口 0.5..2.0（约 ±1 个八度），以 key 45
-- (F#4) 为 1.0。key 落在窗口外就无法忠实表示，于是夹取——**音高会错，但至少
-- 出声**。这比抛错好，而错配由警告层上报，不在这里藏起来。
--
-- cents_to_semitones(c) = c / 100 把 NBS 的 cents 微调暴露成一个显式残量。
-- `playNote` 的音高参数是**整数**半音，所以调用方会**丢掉**这个残量——这个丢弃
-- 是有意的，且单独放在这里（而不是混进 pitch_semitones），好让它可见、可测。
--
-- 兼容性：Lua 5.2 / CC:Tweaked 的 Cobalt。不用整除、不用位运算、不用 utf8、
-- 无状态。

local mapping = {}

-- 原生 NBS key 范围的边界（两个八度）。这里是**唯一定义处**：
-- nbs/analyze.lua 用这两个值判断是否越界，测试也断言它们，所以整个代码库里
-- 33 / 57 只出现这一份。
--
-- 注意：这不是 pitch_semitones 的夹取边界，见文件头第 2 节。
mapping.NATIVE_MIN_KEY = 33
mapping.NATIVE_MAX_KEY = 57

-- playSound 倍率的参考 key：key 45 (F#4) 对应倍率 1.0。
local RATIO_REFERENCE_KEY = 45
-- playSound 的倍率窗口（约 ±1 个八度）。
local RATIO_MIN = 0.5
local RATIO_MAX = 2.0

-- clamp(value, lo, hi)：把 value 夹进 [lo, hi]。
-- 只用于**有界输出**；pitch_semitones 刻意不夹。
local function clamp(value, lo, hi)
  if value < lo then
    return lo
  end
  if value > hi then
    return hi
  end
  return value
end

-- round_half_up(x)：floor(x + 0.5)，即四舍五入。
-- 边界例：17/100*3 = 0.51 是第一个进位到 1 的音量（16/100*3 = 0.48 舍到 0），
-- 而 1.5 → 2 出现在音量 50。测试里有对应的边界表。
local function round_half_up(x)
  return math.floor(x + 0.5)
end

-- mapping.speaker_volume(volume_0_to_100) -> 0..3
--
-- 把 NBS 的 0..100 音量换算成扬声器的 0.0..3.0 参数，四舍五入并夹取越界输入。
-- 见文件头第 1 节。
function mapping.speaker_volume(volume_0_to_100)
  return clamp(round_half_up(volume_0_to_100 / 100 * 3), 0, 3)
end

-- mapping.pitch_semitones(key) -> 整数，key - 33，**不夹取**
--
-- 把 NBS key 换算成 playNote 的半音偏移。刻意不夹：越界音高在装了扩展音域材质包
-- 时是有意义的，而「要不要抱怨」由警告层决定，不由这里决定。见文件头第 2 节。
function mapping.pitch_semitones(key)
  return key - 33
end

-- mapping.combined_volume(layer_volume, note_velocity) -> 0..100
--
-- 用乘积公式合并两个 0..100 的 NBS 音量，再夹到 0..100。
-- 老格式音符缺力度时，解码器补 100。
function mapping.combined_volume(layer_volume, note_velocity)
  return clamp((layer_volume * note_velocity) / 100, 0, 100)
end

-- mapping.play_sound_pitch(key) -> 倍率，夹进 0.5..2.0
--
-- 理想倍率是 2 ^ ((key - 45) / 12)，以 key 45 为 1.0；再夹进 playSound 的
-- 0.5..2.0 窗口。离 45 太远的 key 仍然出声，但音高是错的——这是有记录的取舍，
-- 见文件头第 4 节。
function mapping.play_sound_pitch(key)
  local ideal = 2 ^ ((key - RATIO_REFERENCE_KEY) / 12)
  return clamp(ideal, RATIO_MIN, RATIO_MAX)
end

-- mapping.cents_to_semitones(pitch_cents) -> number，pitch_cents / 100
--
-- 把 NBS 的 cents 微调暴露成一个显式残量。调用方在构造整数 playNote 音高时会
-- **丢掉**它；把它放在这里（而不是塞进 pitch_semitones）是为了让这个丢弃可见、
-- 可测。
function mapping.cents_to_semitones(pitch_cents)
  return pitch_cents / 100
end

-- ---------------------------------------------------------------------------
-- 5. 扩展音域：换**录音**，不是换音高
-- ---------------------------------------------------------------------------
-- 要绕开的限制在哪。（依据是源码，不是推测。）
--
-- 服务端**不管**：CC 的 `SpeakerPeripheral.playNote` 只调 `checkFinite`，然后就
-- 把音高原样换算成倍率交给客户端。
--
-- **客户端**才夹：`SoundEngine.calculatePitch` 里是
-- `Mth.clamp(pitch, PITCH_MIN, PITCH_MAX)`，即 0.5..2.0。所以**一份录音只能覆盖
-- 它自身音高上下各一个八度**，再远的音符会被听成边界音——「所有越界音符听起来
-- 都是同一个高/低音」就是这个原因。
--
-- 出路：八度由**放哪个文件**决定，不由音高决定。OpenNBS 官方的 extranotes 材质包
-- 把同样的乐器另外录了两份，分别高/低两个八度：
--
--     block.note_block.<乐器>_1     比原版高两个八度
--     block.note_block.<乐器>_-1    比原版低两个八度
--
-- 于是拿 `_1` 配 0.5..2.0 的倍率，正好覆盖原生范围**上方**两个八度；`_-1` 覆盖
-- 下方两个八度。合计六个八度，key 9..81（NBS 自身是 0..87）。
--
-- `speaker.playSound` 能点名这些音效。CC **不校验**音效是否已注册——
-- `tryGetRegistryObject` 只用来挡音乐唱片，返回 null 就放过——所以名字会到达客户端，
-- 由客户端在自己的材质包里解析。
--
-- 这也带来一个必须说清的取舍：**客户端没装材质包时，偏移后的名字解析不到，音符是
-- 静音**；而原样透传至少能出声（音高被夹）。所以这个选择权交给调用方，见下面的策略。

-- 录音覆盖的 key 区间：原生两个八度，上下各再一个。
mapping.SHIFTED_LOW_KEY = 9    -- key 9  -> 半音 -24 -> 用 _-1
mapping.SHIFTED_HIGH_KEY = 81  -- key 81 -> 半音  48 -> 用 _1

-- 两份录音之间的跨度，单位半音：两个八度。
local RECORDING_SPAN = 24

-- mapping.shifted_sound_name(name, suffix) -> string
--
-- `name` 是 instrument_table 已经产出的乐器名（harp / bass / pling …）。这 16 个
-- 名字与材质包注册的**完全一致**（比对过材质包自己的 sounds.json），所以不需要
-- 任何翻译表。
function mapping.shifted_sound_name(name, suffix)
  return "block.note_block." .. tostring(name) .. tostring(suffix)
end

-- mapping.shift_for_key(key) -> { suffix = "_-1" | "_1", ratio = <number> } | nil
--
-- 返回 nil 表示「这个 key 在原生范围内」，即**继续用 playNote**——这是便宜的路，
-- 每个扬声器每 tick 能放 8 个。返回非 nil 表示这个音符必须走 playSound 换一份录音，
-- 而每个这样的音符要独占一个扬声器 tick。
--
-- 倍率用现成的 `play_sound_pitch`，只是把 key 平移一个录音跨度，让算术留在唯一
-- 该管它的地方：
--
--   _1  录音本身高 24 半音，所以问一个低 24 的 key
--   _-1 录音本身低 24 半音，所以问一个高 24 的 key
--
-- 在两个偏移区间内，这个倍率恰好铺满 0.5000..2.0000（已实测），这就是「每两个
-- 八度补一份录音」刚刚够、且区间内不需要夹取的原因。
function mapping.shift_for_key(key)
  if type(key) ~= "number" then
    return nil
  end
  if key >= mapping.NATIVE_MIN_KEY and key <= mapping.NATIVE_MAX_KEY then
    return nil
  end
  if key > mapping.NATIVE_MAX_KEY then
    return { suffix = "_1", ratio = mapping.play_sound_pitch(key - RECORDING_SPAN) }
  end
  return { suffix = "_-1", ratio = mapping.play_sound_pitch(key + RECORDING_SPAN) }
end

-- 越界音符的**四种处理策略**。之所以有四种，是因为这件事没有唯一正确答案：
-- 取决于客户端有没有额外资材包，以及听的人更在意什么。
--
--   SHIFT        换一份偏移录音 —— 音高正确，但需要材质包
--   PASSTHROUGH  原样发出半音，让客户端夹到 0.5..2.0
--   CLAMP        我们自己夹到原生 0..24
--   DROP         干脆不播这个音符
--
-- SHIFT 与 PASSTHROUGH 的区别在于「要不要材质包」；CLAMP 与 DROP 面向的是
-- 「反正这个音高都是错的，我要一个可预期的结果」。
-- DROP 会把音符**整个从计划里去掉**，所以不占扬声器槽——和被静音的图层一样待遇。
mapping.OUT_OF_RANGE_SHIFT = "shift"
mapping.OUT_OF_RANGE_PASSTHROUGH = "passthrough"
mapping.OUT_OF_RANGE_CLAMP = "clamp"
mapping.OUT_OF_RANGE_DROP = "drop"

-- 全部合法策略，按菜单该给的顺序：先给能修正音高的，再给两个用音高换可听性的，
-- 最后是静音。
mapping.OUT_OF_RANGE_POLICIES = {
  mapping.OUT_OF_RANGE_SHIFT,
  mapping.OUT_OF_RANGE_PASSTHROUGH,
  mapping.OUT_OF_RANGE_CLAMP,
  mapping.OUT_OF_RANGE_DROP,
}

-- mapping.DEFAULT_OUT_OF_RANGE —— 默认是 SHIFT，这是刻意的。
--
-- 如果默认 PASSTHROUGH，材质包就永远不起作用：越界音符照样以普通音高发出、照样被
-- 客户端夹掉，扩展音域这个功能就只存在于代码里，而不在耳朵里。要让材质包有意义，
-- 这个功能必须默认开着。
--
-- 代价是真的，也正是警告存在的理由：客户端没装材质包时，偏移后的名字解析不到，
-- 音符**静音**，而不是「音高不准但能听见」。播放开始时的 `extended-range` 警告会
-- 说明这一点。想优先保证「一定能听见」的调用方可以传 `"passthrough"`。
mapping.DEFAULT_OUT_OF_RANGE = mapping.OUT_OF_RANGE_SHIFT

-- mapping.clamped_pitch(key) -> 0..24 的整数
--
-- 把 `pitch_semitones` 夹到原生边界。这是 CLAMP 策略：音符照常播，落在最近的原生
-- 音高上，所以结果是可预期的，而不是取决于客户端拿到越界音高会做什么。
function mapping.clamped_pitch(key)
  local pitch = mapping.pitch_semitones(key)
  if type(pitch) ~= "number" then
    return 0
  end
  if pitch < 0 then
    return 0
  end
  if pitch > 24 then
    return 24
  end
  return pitch
end

-- mapping.route(bucket, key, out_of_range) -> "play_note" | "play_sound" | "custom"
--                                              | "dropped"
--
-- 「这个音符该变成哪种调用」的**唯一裁定处**。有两个模块需要这个答案，且它们
-- **必须一致**：
--
--   player/plan.lua    决定事件的 kind，也就是实际发出哪种调用
--   nbs/analyze.lua    统计有多少音符占用扬声器 tick，即需要几个扬声器
--
-- 一旦两者不一致，分析就会按**不同于实际开销**的成本去规划扇出——告诉用户
-- 「两个扬声器够了」，而实际有音符被丢掉。所以规则只写在这里一份，两边都调它。
--
-- `bucket` 是 instrument_table 的分类（"vanilla" | "play_sound" | "custom"）；
-- `out_of_range` 是调用方选的策略。
function mapping.route(bucket, key, out_of_range)
  if bucket == "custom" then
    -- 自定义乐器在播放时会被拒绝，不占任何开销。
    return "custom"
  end
  if bucket == "play_sound" then
    -- 本来就是按名字发声的音效，策略不改变这一点。
    return "play_sound"
  end

  -- 落在自己录音八度内的普通音符，任何策略都不影响它。
  if mapping.shift_for_key(key) == nil then
    return "play_note"
  end

  if out_of_range == mapping.OUT_OF_RANGE_SHIFT then
    -- 由**另一份录音**承载八度，所以这变成一个 playSound，代价是独占一个扬声器
    -- tick，而不是和另外 7 个音符共用一个。
    return "play_sound"
  end
  if out_of_range == mapping.OUT_OF_RANGE_DROP then
    -- "dropped" 是第四种**结果**，不是一种调用：player/plan.lua 不为它产出事件，
    -- nbs/analyze.lua 也不计成本，于是被丢掉的音符完全不占扬声器槽。
    return "dropped"
  end

  -- PASSTHROUGH 与 CLAMP 都仍然是 playNote，差别只在音高参数——那个由
  -- player/plan.lua 选择。
  return "play_note"
end

return mapping
