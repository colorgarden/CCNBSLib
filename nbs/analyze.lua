-- nbs/analyze.lua
--
-- 对已解码的 Note Block Studio 歌曲做一次**纯**的加载期分析。
--
-- 冻结的公共接口
--   local analyze = require("nbs.analyze")
--   analyze.analyze(song) -> result
--
--   `song` 是 nbs.decode 产出的值（本模块用到的字段：header、notes）；`result` 的
--   字段名**精确**如下：
--     total_notes              整数  #song.notes
--     ticks_per_second         number  header.tempo_ticks_per_second
--     tick_ms                  number  1000 / ticks_per_second
--     peak_concurrent          整数  所报窗口内的音符数
--     peak_window_ms           整数  50（常量）
--     vanilla_notes_at_peak    整数  所报窗口内分类为 "vanilla" 的音符数
--     play_sound_notes_at_peak 整数  所报窗口内分类为 "play_sound" 的音符数
--     custom_notes_at_peak     整数  所报窗口内分类为 "custom" 的音符数
--     has_extended_range       布尔  只要**有任何一个** key 落在 33..57 之外即为真
--     min_key, max_key         整数  遍历全部音符（没有音符时为 0 与 0）
--     all_notes_custom         布尔  歌曲有音符、但**没有**任何一个是 vanilla/play_sound
--                                     —— 即每一个音符在播放时都会被拒
--     loop = { loop, max_loop_count, loop_start_tick }  从 header 拷来
--
--   **所报窗口**是让「消耗容量的音符」（vanilla + play_sound）数量最大的那个 50 ms
--   窗口；并列时取**最早**的窗口。自定义音符在播放时会被拒，所以它们**不**参与窗口
--   选择——一大堆自定义音符绝不能掩盖别处真正的 vanilla/小号爆发、从而低估需求。
--   `custom_notes_at_peak` 把恰好落在所报窗口里的那些被拒音符暴露出来，于是
--     vanilla_notes_at_peak + play_sound_notes_at_peak + custom_notes_at_peak
--       == peak_concurrent
--   而 vanilla_notes_at_peak + play_sound_notes_at_peak 就是整首歌所有 50 ms 窗口里
--   消耗容量音符数的最大值。
--
--   一首**没有**任何消耗容量音符的歌没有可最大化的需求，所以所报窗口退化为「全音符」
--   的最大爆发；此时两个桶与需求量都保持 0，而 peak_concurrent 仍然描述这首歌的密度。
--
-- 本模块是一个**纯函数**：不读时钟、不碰外设、不做文件 I/O、不依赖任何全局可变状态，
-- 所以对同一首歌调两次得到逐字节相同的值。它只**读** `song`，从不修改输入。
--
-- ===========================================================================
-- 最容易被做错的那条不变量：NBS tick ≠ 50 ms 游戏 tick
-- ===========================================================================
-- NBS 把 tempo 存成 `tempo_raw`，单位是「每秒 tick 数」的百分之一，所以
--
--     ticks_per_second = tempo_raw / 100
--     一个 NBS TICK     = 1000 / ticks_per_second  毫秒
--
-- Minecraft 扬声器的天花板（每游戏 tick 每乐器一个音符）是按**游戏** tick 算的，而
-- 一个游戏 tick 是 50 ms —— 与 NBS tick 是**两个不同的时钟**。把两者混为一谈，是本
-- 模块最容易犯的错。
--
-- 例子：在每秒 10 个 NBS tick 下，`tick_ms` 是 100，于是每个 NBS tick 横跨**两个**
-- 50 ms 游戏窗口。同一个 NBS tick 上的十个音符共享同一个瞬间（一个窗口，峰值 10），
-- 而**连续**十个 NBS tick 上的十个音符相隔 100 ms（十个不同窗口，峰值 1）。窗口判定
-- 看的是毫秒时间，**从不**看 tick 距离。
--
-- 峰值算法
--   1. 把每个音符映射成毫秒起始时间：t = note.tick * tick_ms，并用
--      instrument_table.bucket_of 对它分类**一次**。
--   2. 把这些时间升序排序。
--   3. 双指针滑动窗口：对每个左下标 i，推进右下标 j，直到
--      times[j] - times[i] < 50（**严格** `<`，所以恰好相隔 50 ms 会开启新窗口）。
--   4. **所报**窗口是让窗口内「消耗**容量**的音符」（vanilla + play_sound）数量最大的
--      那个 —— **不是**音符总数最大的那个。自定义音符不消耗容量且在播放时被拒，所以
--      让它们赢得选择，正是那个「报出 required == 0、而别处的 vanilla 爆发会被丢掉」
--      的 bug。给容量标志做一次前缀和，就能让每个窗口的容量计数降到 O(1)。把左边界
--      锚在某个音符上是完备的：所有 50 ms 窗口上的最大值一定在某个左边界落在音符上的
--      窗口取到，而把一个最优窗口的左边界向右滑到它第一个消耗容量的音符上，会让所有
--      这类音符都留在窗口内。
--   5. peak_concurrent 是所报窗口里**全部**音符的数量（含自定义）—— 那是这个字段冻结
--      的含义。当整首歌一个消耗容量的音符都没有时，第 4 步没有最大值可找，于是退化为
--      「全音符」的最大爆发；两个桶与需求量保持 0。
--
-- 乐器分桶（只对所报窗口分类）
--   分类规则只有**一个**归属处：nbs/instrument_table.bucket_of —— player/plan.lua 也是
--   通过 resolve() 走到同一个分类器。这里曾经自己重新实现过（硬编码 0..15 / 16..19
--   常量），结果在 vanilla 计数为 10 和 17..19 时与 resolve **不一致**：给 v6 小号少算
--   扬声器，并为旧格式的自定义 id 造出一个假的 "speakers" 警告。委托出去，就能让分析器
--   的预算与播放器实际会发出的调用完全相同：
--     vanilla     低于文件的 vanilla 边界，id 0..15
--     play_sound  该边界以下的 16..19（v6 "trumpet" 原生音效）
--     custom      其他一切 —— 播放时被拒，所以它**两个桶都不算**、也不参与峰值选择；
--                 当它恰好与被计算需求的窗口重合时，单独以 custom_notes_at_peak 报出。
--
-- 并列处理（确定性）
--   当多个不同窗口取得相同的最大**容量**计数时，所报的拆分取自时间上**最早**的那个窗口
--   （最小的左下标）。选择循环只在**严格**变大时才替换记录的峰值，所以第一个达到最大值的
--   窗口胜出。
--
-- 本文件遵守的 Lua 5.2 / Cobalt 约束：不用 `//`、不用位运算、不用 utf8.*、不用
-- math.maxinteger、不用 collectgarbage、不用 string.dump、不用 os.exit。

local instrument_table = require("nbs.instrument_table")
local mapping = require("player.mapping")
-- mute/solo 规则，与 player/plan.lua 共用，这样分析与计划永远不会在「哪些音符会播」
-- 上产生分歧。nbs/layers.lua 不 require 任何东西，所以这里不会引入循环依赖。
local layers_module = require("nbs.layers")

local analyze = {}

-- 一个 Minecraft 游戏 tick，单位毫秒。这就是扬声器天花板的窗口。
local PEAK_WINDOW_MS = 50
-- 一个扬声器每个游戏 tick 接受的 `playNote` 调用数。从 nbs.speakers 读，好让数字 8
-- 在整个代码库里只存在**一处** —— 本模块的窗口选择和那个模块的需求公式，绝不能对
-- 「一个音符的代价」有不同看法。
local speakers_module = require("nbs.speakers")
local PEAK_NOTES_PER_TICK = speakers_module.MAX_NOTES_PER_TICK

-- 原生两个八度的 key 范围（33 = F#3、45 = F#4、57 = F#5），含端点。
-- 这两个**数字**只在**一处**拥有：player/mapping.lua 的公开常量
-- NATIVE_MIN_KEY / NATIVE_MAX_KEY。在这里引用它们，能让分析器的扩展音域边界与播放器
-- 所用的映射完全一致；mapping.lua 不 require 任何东西，所以不产生 require 循环。

-- analyze.analyze(song) -> result
-- analyze.analyze(song, opts) -> result
--
-- opts.out_of_range  播放策略，与 player/plan.lua 的对应，因为两者**必须**一致：
--                    `mapping.route` 决定一个音符消耗的是 playNote 槽（每个扬声器 tick
--                    8 个）还是 playSound 槽（**一个**）。在这里把它当成便宜的那个来算，
--                    会低报扬声器需求，于是播放时有音符被丢掉。
function analyze.analyze(song, opts)
  local header = song.header or {}
  local notes = song.notes or {}
  local layers = song.layers or {}
  local total_notes = #notes

  local ticks_per_second = header.tempo_ticks_per_second
  local tick_ms = 1000 / ticks_per_second

  -- 被静音与非 solo 的图层被排除，用的是 player/plan.lua 决定「哪些音符变成事件」的
  -- **同一条**规则（归属在 nbs/layers.lua）。两者一旦不一致，下面每一个容量数字都会
  -- 描述永远不会播的音符：扇出是按 `peak_concurrent` 与
  -- nbs.speakers.required_count(analysis) 定尺寸的，所以虚高的峰值意味着一个假的
  -- "not enough speakers" 警告与被丢掉的事件。
  --
  -- `total_notes` 刻意仍然数**文件**里的音符——它是关于这首歌的事实，不是播放预测——
  -- 所以在有静音图层的歌上，它比计划器产出的重大是合理的。
  local any_solo = layers_module.any_solo(layers)
  local out_of_range = type(opts) == "table" and opts.out_of_range
    or mapping.DEFAULT_OUT_OF_RANGE

  -- key 范围 + 扩展音域扫描（遍历每一个**可听**音符，与 50 ms 窗口无关），外加**一趟**
  -- 分类：每个音符的桶在这里由规则唯一的归属处（instrument_table.bucket_of）决定，
  -- 而**同一个**判断被留到下面的窗口遍历复用——所以窗口选择与所报拆分永远不会分歧。
  local min_key = 0
  local max_key = 0
  local has_extended_range = false
  -- 播放器实际上能调度的音符数（vanilla 或 play_sound）。两者都不是的是自定义乐器，
  -- 播放时会被拒；在一首非空歌曲上这个值保持 0，意味着整首歌都是静音的。
  local playable_notes = 0
  -- 有多少音符**消耗**扬声器容量（vanilla + play_sound）。自定义不消耗，所以它们绝不能
  -- 影响报出的是哪个窗口。
  local capacity_notes = 0
  local items = {}
  -- 是否已经见过一个**可听**音符，与 `#items` 分开保存。
  --
  -- 曾经用 `#items == 0` 表示「这是第一个可听音符」来给 key 范围播种，那在每个可听音符
  -- 都会追加进 `items` 时是成立的。当越界的 DROP 策略开始过滤音符后它就不成立了：
  -- 被丢掉的音符永远到不了 `items`，于是播种条件一直为真，后面每个音符都**重置**范围
  -- 而不是扩展它。有两个被丢掉的音符时，歌曲报出的 key 是 45..69 而不是 20..69。
  --
  -- 单独的标志也让**意图**变得明确：这个范围描述每一个可听音符——只看 mute/solo——
  -- 并刻意忽略播放策略，因为那个警告的存在是为了说「这首歌需要扩展音域材质包」，
  -- 而无论用户是否选择播放那些音符，这句话都成立。
  local saw_audible = false
  for index = 1, total_notes do
    local note = notes[index]

    if layers_module.audible_at(layers, any_solo, note.layer) then
      local key = note.key
      if not saw_audible then
        -- 由**第一个可听**音符播种范围，而不是文件里的第一个音符：被静音的音符绝不能
        -- 定义这首歌的 key 跨度。
        saw_audible = true
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
      -- **有效的**桶，而不是乐器自带的桶。`mapping.route` 是「这个音符变成哪种调用」
      -- 的唯一归属处，而它把 shift 策略也折了进来：一个离自己录音八度太远的 vanilla
      -- 音符会变成 playSound，代价是独占一整个扬声器 tick，而不是八分之一。
      local instrument_bucket = instrument_table.bucket_of(note.instrument,
        header.vanilla_instrument_count)
      local bucket = mapping.route(instrument_bucket, note.key, out_of_range)
      -- "dropped" 刻意**不**算消耗：这个音符永远到不了扬声器，把它算进去会高报需求。
      -- 它也不算 "playable"，所以它不会让这首歌看起来有东西可播。
      local consumes = bucket == "play_note" or bucket == "play_sound"
      if consumes then
        playable_notes = playable_notes + 1
        capacity_notes = capacity_notes + 1
      end
      if bucket ~= "dropped" then
        items[#items + 1] = {
          t = note.tick * tick_ms,
          bucket = bucket,
          consumes = consumes,
        }
      end
    end
  end

  table.sort(items, function(a, b)
    return a.t < b.t
  end)

  -- 下面的窗口遍历跑在**可听**音符上，也就是 `items` 里装的东西。它是**紧凑**的，所以
  -- 它有 `audible_notes` 项，用文件的音符数去索引它会越过末尾。`total_notes` 对报出的
  -- 字段来说仍是文件的数量，而两者在任何没有静音图层的歌上相等——也就是所有 fixture，
  -- 所以测试套件**不可能**发现这个差别。暴露它的是真实的那首 65 层带静音图层的歌。
  local audible_notes = #items

  -- 在已排序的时间上做双指针滑动窗口。`j` 单调：左边界向右移动时窗口只会伸展、不会
  -- 回缩，所以单趟前进就是精确的。
  --
  -- 窗口在最大化什么：当歌里有任何消耗容量的音符时，所报窗口是容纳它们最多的那个
  -- （自定义不算数，绝不能赢得选择）；并列时保留**最早**的窗口。
  -- peak_span 是那个窗口里**全部**音符的数量——也就是 peak_concurrent 一直以来的含义。
  local peak_capacity = 0
  local peak_left = nil
  local peak_span = 0
  if capacity_notes > 0 then
    -- **两个**前缀和，因为两种音符消耗扬声器的量**不同**。一个 play_note 和另外七个
    -- 共用一个 tick；一个 play_sound 独占整个 tick。所以需要最多扬声器的窗口**不是**
    -- 音符最多的那个窗口，而按原始计数选择——也就是这里以前的做法——一旦歌里混了两种，
    -- 就会选错。
    --
    -- 分歧的例子：一个含 1 个 play_note 与 2 个 play_sound 的窗口需要
    -- ceil(1/8) + 2 = 3 个扬声器，而一个含 3 个 play_note 的窗口只需要
    -- ceil(3/8) = 1 个。按音符计数会把后者排得更前。
    --
    -- 这里的代价函数**就是** nbs.speakers.required_count 的公式，所以它选出的窗口正是
    -- 那条公式在描述的那个。
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
      -- 与 speakers.required_count 相同的算术，只是作用在这个窗口上。
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
    -- 整首歌没有任何消耗容量的音符：什么都调度不了，所以没有可最大化的需求。
    -- 退化为「全音符」的最大爆发，好让 peak_concurrent 仍能报出这首歌的密度；
    -- 两个桶与需求量保持 0。
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

  -- 给所报窗口分类。选择循环里用的是严格 `>`，所以被记录下的是**最早**达到最大值的
  -- 窗口。
  local vanilla_at_peak = 0
  local play_sound_at_peak = 0
  local custom_at_peak = 0
  if peak_left ~= nil and peak_span > 0 then
    for index = peak_left, peak_left + peak_span - 1 do
      -- **一个**分类器已经在上面跑过了：正是 player/plan.lua 通过
      -- instrument_table.resolve 走到的同一个函数，所以分析器与分配器永远不会在
      -- 「哪些音符要 playNote、哪些要 playSound」上产生分歧。
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
    -- **所报**窗口里的音符数，含自定义。窗口本身是按消耗容量的计数选出来的，所以
    -- vanilla + play_sound + custom == peak_concurrent，而 vanilla + play_sound 就是
    -- 这首歌每一个 50 ms 窗口里消耗容量音符数的最大值。
    peak_concurrent = peak_span,
    peak_window_ms = PEAK_WINDOW_MS,
    vanilla_notes_at_peak = vanilla_at_peak,
    play_sound_notes_at_peak = play_sound_at_peak,
    -- 所报窗口的音符里有多少是自定义（播放时被拒）：它们被排除在选择之外、也排除在
    -- 扬声器需求之外。
    custom_notes_at_peak = custom_at_peak,
    has_extended_range = has_extended_range,
    min_key = min_key,
    max_key = max_key,
    -- 对一首非空、但**每一个**音符在播放时都会被拒（自定义乐器 id）的歌为真。
    -- 一个纯布尔值，由**整首歌**推导——**不是**由所报窗口推导，后者的桶在一首别处仍有
    -- 可播音符的歌上可能是 0/0。
    --
    -- 依据的是**可听**音符数，而不是文件里的：一首每个图层都被静音的歌同样什么都播不了，
    -- 把它报成「所有音符都是自定义乐器」会指错原因。
    all_notes_custom = audible_notes > 0 and playable_notes == 0,
    loop = {
      loop = header.loop,
      max_loop_count = header.max_loop_count,
      loop_start_tick = header.loop_start_tick,
    },
  }
end

return analyze
