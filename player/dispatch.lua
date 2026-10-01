-- player/dispatch.lua
--
-- 路由层：给一个已经编排好的事件和一条扬声器记录，决定到底该发出哪一种
-- 调用 —— 以及什么时候要**拒绝**。
--
-- 冻结的公共接口
--   local dispatch = require("player.dispatch")
--
--   dispatch.new(opts)              -> d             （opts 预留；被忽略）
--   d:event(event, speaker_record)  -> result        （从不抛错）
--   d:warnings()                    -> 按产生顺序排列的警告码数组
--   d:reset()                       -> 清空警告台账
--
--   dispatch.WARN_CUSTOM_INSTRUMENT = "custom-instrument"
--   dispatch.WARN_PLAY_SOUND_PITCH  = "play-sound-pitch"
--   dispatch.WARN_NOTES_DROPPED     = "notes-dropped"   （在这里声明，由
--                                                       ccnbslib.play 上报，
--                                                       这样它才带得上计数）
--
--   result = {
--     called        boolean,        -- 调用了扬声器方法时为 true
--     method        "play_note" | "play_sound" | nil,
--     speaker_side  string | nil,
--     refused       boolean | nil,  -- 扬声器返回 false（一次正常的拒绝）
--     warning_code  string | nil,   -- 裸码；WARN[...] 归 player/warnings.lua 负责
--     error_message string | nil,   -- 仅用于抛出/不可用的调用
--   }
--
-- ---------------------------------------------------------------------------
-- dispatch 不做任何重新解析
-- ---------------------------------------------------------------------------
-- player/plan.lua **已经**解析好了乐器路由（`kind`、`name`、`custom_index`），
-- 也**已经**映射好了音量（0..3）和 playNote 音高（整数半音，**不夹取**）。所以
-- dispatch：
--   * **从不**调用 nbs.instrument_table.resolve（不做乐器重路由）；
--   * **从不**调用 mapping.speaker_volume（不做音量重映射）；
--   * 把 event.volume 与 event.pitch **原样**转发。
-- dispatch 剩下的唯一一件数值工作，是 playSound 的**倍率**（分支 2），而 plan.lua
-- 刻意没有把它烤进 `pitch`（那个字段装的是半音）。
--
-- ---------------------------------------------------------------------------
-- 三条路由分支
-- ---------------------------------------------------------------------------
-- 1. kind == "play_note"
--      speaker:play_note(event.name, event.volume, event.pitch)
--      音高**原样**传递。它**可能为负**（扩展音域）：不加夹取地透传，正是那个
--      映射决定的意义所在。我们**不**夹取、**不**设防、**不**为此报警。
--
-- 2. kind == "play_sound"   （v6 小号）
--      speaker:play_sound(event.name, event.volume, ratio)
--      `ratio` 是 playSound 的**音高倍率**，不是半音，由 event.key 经
--      mapping.play_sound_pitch 算出（允许：dispatch 可以调用它）。
--      playSound 只接受 0.5..2.0，所以离 key-45 参考点太远的小号无法忠实表达。
--      mapping.play_sound_pitch 替我们夹取；当**理想**倍率
--      （2 ^ ((key - 45) / 12)）落在 0.5..2.0 **之外**时，我们发出
--      WARN_PLAY_SOUND_PITCH，让用户知道那个音符的音高只是近似值。判定靠比较：
--      夹取后的值与理想值不同，恰好就是发生了夹取。
--
-- 3. kind == "custom"
--      **拒绝**。完全不调用扬声器（called = false，method = nil），并发出
--      WARN_CUSTOM_INSTRUMENT。我们**从不**抛错，也**从不**把自定义名字传给
--      play_sound。
--
-- 无法识别/缺失的 `kind` 同样是拒绝，且**不带**警告。
--
-- ---------------------------------------------------------------------------
-- 每个警告码只报一次的策略
-- ---------------------------------------------------------------------------
-- 一个 dispatcher 为一次播放携带一本小台账。d:warnings() 按**发出顺序**返回目前
-- 已发出的码；无论多少事件触发，同一个码**至多出现一次**。d:reset() 清空台账，
-- 让新的一次播放能够重新报警。这样 UI 就能每首歌把每条警告恰好打印一次，而
-- dispatcher 完全不需要知道「打印」这件事。
--
-- **两层台账** —— 都是刻意的，不是重复。公共播放器（ccnbslib.lua）**不**调用
-- d:warnings() 或 d:reset()；它自己维护一份「每个码一次」的汇总，把每个裸码
-- **一次**转发给它的 opts.on_warning 回调。本 dispatcher 的台账是独立的、更低的
-- 一层：它为任何**直接**使用 dispatch 的人保证「每个实例只报一次」，与调用方在其上
-- 如何汇总无关。所以 d:warnings()/d:reset() 没有生产调用方，却仍属于**冻结**的
-- 公共接口，并由测试套件断言。
--
-- ---------------------------------------------------------------------------
-- 拒绝 vs 错误  （这个区分是刻意的，且可观测）
-- ---------------------------------------------------------------------------
--   refused = true,  called = true,  error_message = nil
--       扬声器被调用了，但**返回 false**。在**真实** CC:Tweaked 扬声器上这是
--       **正常**的 —— 每 tick 8 个音符的预算经常触发拒绝 —— 所以 dispatch 把它
--       转发出去，从不把它当成失败。
--
--   refused = false, called = false, error_message = <string>
--       调用无法完成：扬声器**抛错**、不存在，或没有那个方法。抛错被 pcall
--       兜住，所以 dispatcher 永远不会被污染，且对**任何**输入，d:event 都
--       **从不**抛错。
--
-- 格式错误的事件（不是表、play_note/play_sound 缺 name……）就是一次普通拒绝：
-- called = false，不带警告也不带 error_message。
--
-- 兼容性：Lua 5.2 / CC:Tweaked 的 Cobalt。不用整除、不用位运算、不用 utf8、
-- 不用 string.dump、不用 os.exit、不用全局变量。

local mapping = require("player.mapping")

local dispatch = {}

-- 裸警告**码**。格式化（WARN[...] 包装）归 player/warnings.lua（后续任务）；
-- dispatch 只负责给这些码起名。
dispatch.WARN_CUSTOM_INSTRUMENT = "custom-instrument"
dispatch.WARN_PLAY_SOUND_PITCH = "play-sound-pitch"

-- 由**库**（ccnbslib.play）发出，不是这里，这样它才能带上**计数**。
--
-- 当当前游戏 tick 里已经排入的 note 超过 `maxNotesPerTick` 个时，CC:Tweaked
-- 扬声器会拒绝这个 note —— 默认 8 个，直接来自 SpeakerPeripheral.playNote 里的
-- Config.maxNotesPerTick。它靠**返回 FALSE** 而不是抛错来表达这一点，于是一个密集
-- 的段落会**静默地**丢音符：扬声器本来就没有义务把它收到的每个音符都播出来。这
-- 就是为什么计数只有在歌曲跑完之后才存在，也是为什么这个一次只看一个事件的模块
-- 无法靠自己上报它。
--
-- 这里 dispatcher 的职责只是让这次拒绝**可观测**：一次拒绝以
-- `called = true, refused = true` 的形式到达，ccnbslib.play 统计它，并在每次
-- 会话里以 { count = <dropped> } 上报一次。
dispatch.WARN_NOTES_DROPPED = "notes-dropped"

-- playSound 的倍率参考点：key 45 (F#4) 对应倍率 1.0。对应 player/mapping.lua 的
-- 规则 (4)；**仅**用于检测返回的倍率是否被夹取过（见上面分支 2）。
local RATIO_REFERENCE_KEY = 45

-- ---------------------------------------------------------------------------
-- 结果构造器 —— 处处只有一种形状，调用方可以依赖它。
-- ---------------------------------------------------------------------------

-- 一次**没有发起调用**的拒绝：custom、未知 kind，或格式错误的事件。`refused`
-- 保持 nil（没有任何东西可被拒绝），也没有 error。
local function no_call(speaker_side, warning_code)
  return {
    called = false,
    method = nil,
    speaker_side = speaker_side,
    refused = nil,
    warning_code = warning_code,
  }
end

-- 一次完成的调用。`refused` 是扬声器自己的布尔信号：它返回 false 时为 true。
-- 一次成功的调用带的是 refused = false，而不是 nil，这样「被拒」和「被接受」
-- 始终可区分。
local function completed(method, speaker_side, refused)
  return {
    called = true,
    method = method,
    speaker_side = speaker_side,
    refused = refused,
    warning_code = nil,
  }
end

-- 一次不可用的调用：扬声器抛错、缺失，或没有那个方法。它刻意**不是**拒绝
-- （refused = false），并带上原因。
local function unusable(message, speaker_side)
  return {
    called = false,
    method = nil,
    speaker_side = speaker_side,
    refused = false,
    warning_code = nil,
    error_message = message,
  }
end

-- 扬声器的 side；当它是一条带字符串 side 的可用记录时才有值。
local function side_of(record)
  if type(record) == "table" and type(record.side) == "string" then
    return record.side
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- 每个警告只报一次的台账
-- ---------------------------------------------------------------------------

-- 若 `code` 尚未记录，则记录它并返回它；否则返回 nil（已经发过）。首次发出的
-- 顺序会被保留。
local function warn_once(self, code)
  if self._warn_seen[code] then
    return nil
  end
  self._warn_seen[code] = true
  self._warn_order[#self._warn_order + 1] = code
  return code
end

-- ---------------------------------------------------------------------------
-- pcall 边界：调用扬声器方法并对结果分类
-- ---------------------------------------------------------------------------

-- method_name 是接缝名（"play_note" / "play_sound"）；args 最多装三个位置参数。
-- 总是返回一张结果表；从不抛错。
local function invoke(record, speaker_side, method_name, args)
  if type(record) ~= "table" then
    return unusable(
      "dispatch: no speaker record supplied for " .. method_name, speaker_side)
  end

  local fn = record[method_name]
  if type(fn) ~= "function" then
    return unusable(
      "dispatch: speaker on side " .. tostring(speaker_side)
        .. " has no " .. method_name .. " method", speaker_side)
  end

  -- 显式传 `self`：扬声器记录的方法带一个 self 参数。
  local ok, value = pcall(fn, record, args[1], args[2], args[3])
  if not ok then
    return unusable(
      "dispatch: " .. method_name .. " raised: " .. tostring(value), speaker_side)
  end

  -- 扬声器返回 false 是一次**正常**拒绝，原样转发。
  return completed(method_name, speaker_side, value == false)
end

-- ---------------------------------------------------------------------------
-- 分支 1：play_note
-- ---------------------------------------------------------------------------

local function route_play_note(event, record, speaker_side)
  if type(event.name) ~= "string" then
    return no_call(speaker_side, nil)
  end
  -- volume 与 pitch **原样**转发；pitch 可能为负（不夹取）。
  return invoke(record, speaker_side, "play_note",
    { event.name, event.volume, event.pitch })
end

-- ---------------------------------------------------------------------------
-- 分支 2：play_sound（v6 小号 —— 倍率在 0.5..2.0）
-- ---------------------------------------------------------------------------

local function route_play_sound(self, event, record, speaker_side)
  if type(event.name) ~= "string" or type(event.key) ~= "number" then
    return no_call(speaker_side, nil)
  end

  -- 事件自带倍率时，就用事件里的倍率。
  --
  -- 偏移音符（用偏移录音演奏的音符）的倍率由 player/plan.lua 算好，因为只有编排器
  -- 知道选了哪一份录音。下面那套老推导对 v5-vs-v6 的 play_sound 路径是对的——那条
  -- 路径的名字指的是乐器自身的音高——但用在偏移音符上，它就是个**错的数**：
  -- key 69 会要 2^((69-45)/12) = 4.0，被夹到 2.0，离本来规划的音符差了一整个八度。
  local ratio
  if type(event.ratio) == "number" then
    ratio = event.ratio
    local result = invoke(record, speaker_side, "play_sound",
      { event.name, event.volume, ratio })
    -- 不报警：规划好的倍率按构造就在 0.5..2.0 内，所以没什么好抱怨的。
    return result
  end

  local ideal = 2 ^ ((event.key - RATIO_REFERENCE_KEY) / 12)
  ratio = mapping.play_sound_pitch(event.key)
  local result = invoke(record, speaker_side, "play_sound",
    { event.name, event.volume, ratio })

  -- 只有真正发起了调用、且倍率确实被夹取时才报警（那种情况下夹取后的值与理想值
  -- 恰好不同）。
  if result.called and ratio ~= ideal then
    result.warning_code = warn_once(self, dispatch.WARN_PLAY_SOUND_PITCH)
  end
  return result
end

-- ---------------------------------------------------------------------------
-- 公共构造器与方法
-- ---------------------------------------------------------------------------

-- dispatch.new(opts) -> d。`opts` 为向前兼容而预留，当前被忽略。每个 dispatcher
-- 拥有**自己**的警告台账，所以两个并发的播放不会共享「只报一次」的状态。
function dispatch.new(opts)
  local d = {
    _warn_order = {},
    _warn_seen = {},
  }

  -- d:event(event, speaker_record) -> result。全定义、不抛错：它能处理 nil/非表的
  -- 事件、未知 kind、缺失的扬声器，以及会抛错的扬声器方法，而从不向外传播错误。
  function d:event(event, record)
    local speaker_side = side_of(record)

    if type(event) ~= "table" then
      return no_call(speaker_side, nil)
    end

    local kind = event.kind
    if kind == "play_note" then
      return route_play_note(event, record, speaker_side)
    elseif kind == "play_sound" then
      return route_play_sound(self, event, record, speaker_side)
    elseif kind == "custom" then
      return no_call(speaker_side,
        warn_once(self, dispatch.WARN_CUSTOM_INSTRUMENT))
    end

    -- 未知或缺失的 kind：一次不带警告的拒绝。
    return no_call(speaker_side, nil)
  end

  -- d:warnings() -> 已发出码的一份拷贝，按发出顺序。
  function d:warnings()
    local copy = {}
    for index = 1, #self._warn_order do
      copy[index] = self._warn_order[index]
    end
    return copy
  end

  -- d:reset() -> 清空「只报一次」台账，让新的一次播放能重新报警。
  function d:reset()
    self._warn_order = {}
    self._warn_seen = {}
  end

  return d
end

return dispatch
