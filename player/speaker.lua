-- player/speaker.lua
--
-- **可注入的扬声器接缝**。
--
-- 播放器的其余部分**从不**直接去够全局的 `peripheral` 表。所有硬件访问都汇集经过
-- 这个模块，于是**同一份**播放器代码可以由三个不同的层级驱动：
--
--   1. 纯 Lua 单元测试，那里根本没有 `peripheral` 全局；
--   2. 一个 CraftOS-PC 无头测试台，它用一个记录器替换 `peripheral` API —— 见
--      speaker.mock，它按顺序捕获每一次调用；
--   3. 真实 Minecraft，那里 `peripheral` 是活的 CC:Tweaked API。
--
-- 冻结的公共接口（dispatch、扇出与 Tier-2 层依赖这些**精确**的名字）：
--
--   local speaker = require("player.speaker")
--
--   speaker.discover()             -> 扬声器记录数组，按 side 排序
--   speaker.wrap(side, obj)        -> 适配一个活外设的扬声器记录
--   speaker.mock(side)             -> 一个**记录**调用的扬声器记录
--
-- 一条扬声器记录：
--   { side        = "left",
--     play_note   = function(self, name, volume, pitch) -> boolean,
--     play_sound  = function(self, name, volume, pitch) -> boolean,
--     stop        = function(self) }
--
-- mock 记录额外带：
--   record.calls  = array of { method = "play_note"|"play_sound"|"stop",
--                              args   = { ... } }
--   record.drain() -> 返回累积的调用并**清空**缓冲区。
--
-- 硬性规则（由测试套件强制）：
--
--   * 本模块**不得**硬编码调用外设的类型搜索捷径（find 辅助）。发现（discovery）
--     只用 getNames() 与 getType()；外设全局上的任何其他键，运行时核心都不得染指。
--   * 本模块**不得**在模块作用域捕获 `peripheral` 全局。这个全局只在函数体内惰性
--     读取，并做 nil 检查，所以在没有 `peripheral` 的纯 Lua 5.2 下 require 本文件
--     是安全的。
--
-- **拒绝不是错误**。一个 CC:Tweaked 扬声器每游戏 tick 可能只接受屈指可数的几次
-- playNote 调用，所以 playNote/playSound 返回 false 是正常拒绝，不是失败。因此
-- 适配器**原样转发**这个布尔值 —— 它**绝不能**被吞掉或被归一化。
--
-- 兼容性：Lua 5.2 / CC:Tweaked 的 Cobalt。不用整除、不用位运算、不用 utf8、
-- 不用 string.dump、不用 os.exit。

local speaker = {}

-- ---------------------------------------------------------------------------
-- 惰性访问全局 peripheral 表
-- ---------------------------------------------------------------------------

-- 只在被调用时读取这个全局，绝不在模块作用域读。纯 Lua 单元测试里它完全缺失，
-- 那里每个入口都必须优雅降级。
local function live_peripheral()
  return rawget(_G, "peripheral")
end

-- ---------------------------------------------------------------------------
-- speaker.mock(side) -> 记录型记录
-- ---------------------------------------------------------------------------

-- 把一次记录到的调用追加到记录的缓冲区。`self` 是调用方在其上调用方法的记录；
-- `buffer_owner` 是闭包捕获的记录，作为回退，以便在 drain() 换掉表之后缓冲区仍
-- 然存活。
local function append_call(self, buffer_owner, method, ...)
  local calls = (self and self.calls) or buffer_owner.calls
  calls[#calls + 1] = { method = method, args = { ... } }
end

-- speaker.mock(side)：一条不做任何 I/O 的扬声器记录。每个方法按调用顺序记录
-- { method = ..., args = {...} } 并返回 true：mock 从不拒绝。单元测试与 Tier-2
-- 无头测试台都会用它。
function speaker.mock(side)
  local record = {
    side = side,
    calls = {},
  }

  function record.play_note(self, name, volume, pitch)
    append_call(self, record, "play_note", name, volume, pitch)
    return true
  end

  function record.play_sound(self, name, volume, pitch)
    append_call(self, record, "play_sound", name, volume, pitch)
    return true
  end

  function record.stop(self)
    append_call(self, record, "stop")
    return true
  end

  -- drain()：交还累积的调用并开一个全新缓冲区，这样每个 Tier-2 步骤都能在干净的
  -- 起点上做断言。
  function record.drain()
    local drained = record.calls
    record.calls = {}
    return drained
  end

  return record
end

-- ---------------------------------------------------------------------------
-- speaker.wrap(side, peripheral_object) -> 适配器记录
-- ---------------------------------------------------------------------------

-- 查一个 camelCase 的外设方法。缺少方法的外设必须响亮而明确地失败，并点名 side
-- 与方法，而不是稍后因 nil 索引而崩溃。每次调用都检查，所以一个只暴露了 playNote
-- 却没有 playSound 的外设，仍然能弹音符。
local function require_method(peripheral_object, side, camel, snake)
  local fn = peripheral_object[camel]
  if type(fn) ~= "function" then
    error(string.format(
      "speaker.wrap: peripheral on side %q is missing method %q (needed by %s)",
      tostring(side), camel, snake), 2)
  end
  return fn
end

-- speaker.wrap(side, peripheral_object)：适配一个已经拿到手的外设对象。
-- CC:Tweaked 的扬声器暴露 camelCase 的 playNote / playSound / stop；这里把接缝的
-- snake_case 方法映射到它们上面，并把 playNote/playSound 的布尔返回值原样转发
-- （拒绝必须到达调用方）。
--
-- **外设的方法不接受 `self` —— 必须用点号调用。**
--
-- 这与 AGENTS.md 第 3 节为 http 响应句柄记录的是同一条调用约定，而在这里弄错它是
-- 一次真实、静默的缺陷：每个音符都被传成
-- `playNote(peripheral_object, name, volume, pitch)`，于是 `instrumentA` 收到的
-- 是一张**表**而不是乐器名。扬声器为此抛出 "Invalid instrument"，dispatch 把这个
-- 抛错兜在 pcall 里，播放因此正常地走完整首歌却**完全无声** —— 进度条是对的，
-- 但什么都听不见。
--
-- 依据是证据，不是猜测：
--   * Java 签名是
--       public final boolean playNote(ILuaContext context, String instrumentA,
--                                     Optional<Double> volumeA, Optional<Double> pitchA)
--     而 ILuaContext 是**注入**的，不是 Lua 参数，所以从 Lua 看这个方法恰好只收
--     (instrument, volume, pitch) 三个参数；
--   * CC:Tweaked 自己的用法是 `speaker.playSound("entity.creeper.primed")`。
--
-- 反过来看本函数返回的**记录**：它们是 Lua 表，其方法接受 `self` 并以冒号调用
-- （`record:play_note(...)`）。一个模块里两种约定，而接缝边界正是它们切换的地方。
function speaker.wrap(side, peripheral_object)
  if type(peripheral_object) ~= "table" then
    error(string.format(
      "speaker.wrap: expected a peripheral object for side %q, got %s",
      tostring(side), type(peripheral_object)), 2)
  end

  local record = { side = side }

  function record.play_note(self, name, volume, pitch)
    local fn = require_method(peripheral_object, side, "playNote", "play_note")
    -- 点号调用：不传 self。见上面的说明。
    return fn(name, volume, pitch)
  end

  function record.play_sound(self, name, volume, pitch)
    local fn = require_method(peripheral_object, side, "playSound", "play_sound")
    -- 点号调用：不传 self。
    return fn(name, volume, pitch)
  end

  function record.stop(self)
    local fn = require_method(peripheral_object, side, "stop", "stop")
    -- 点号调用：不传 self。
    return fn()
  end

  return record
end

-- ---------------------------------------------------------------------------
-- speaker.discover() -> 每个已挂载扬声器对应一条记录的数组
-- ---------------------------------------------------------------------------

-- 一条被发现的记录在首次方法调用时，通过全局 peripheral.wrap(side) 惰性地解析它
-- 的活对象。所以 discover() 本身**只**读 getNames/getType —— 从不用 find 辅助，
-- 从不用 wrap —— 这正是规范里「运行时核心不得硬编码 find」这条守卫所检查的。
local function discovered_record(side)
  local record = { side = side }
  local wrapped = nil

  local function live()
    if wrapped == nil then
      local peripheral = live_peripheral()
      if peripheral == nil or type(peripheral.wrap) ~= "function" then
        error(string.format(
          "speaker.discover: peripheral.wrap is unavailable for side %q",
          tostring(side)), 2)
      end
      local object = peripheral.wrap(side)
      if object == nil then
        error(string.format(
          "speaker.discover: no speaker is attached on side %q any more",
          tostring(side)), 2)
      end
      wrapped = speaker.wrap(side, object)
    end
    return wrapped
  end

  function record.play_note(self, name, volume, pitch)
    local target = live()
    return target.play_note(target, name, volume, pitch)
  end

  function record.play_sound(self, name, volume, pitch)
    local target = live()
    return target.play_sound(target, name, volume, pitch)
  end

  function record.stop(self)
    local target = live()
    return target.stop(target)
  end

  return record
end

-- speaker.discover()：枚举已挂载外设，只留下扬声器，并按 side 名**升序**返回它们
-- 的记录（稳定、可复现的扇出与 Tier-2 录制）。在**完全没有** `peripheral` 全局时
-- ——纯 Lua 单元测试——它返回一个**空数组**而不是抛错。每次 getType 调用都有 pcall
-- 守护：一个类型查询**抛错**的外设会被跳过，而不是让它中断对健康扬声器的发现。
function speaker.discover()
  local peripheral = live_peripheral()
  if peripheral == nil then
    return {}
  end

  local get_names = peripheral.getNames
  if type(get_names) ~= "function" then
    return {}
  end

  local get_type = peripheral.getType
  if type(get_type) ~= "function" then
    return {}
  end

  local names = get_names()
  local records = {}
  if type(names) == "table" then
    for _, side in ipairs(names) do
      -- 一个不配合的外设不能中断对其余外设的发现：抛错的 getType（外设缺失/出错）
      -- 会被当作「不是扬声器」，扫描继续。最后按 side 升序的排序无论如何都让发现
      -- 保持确定性。
      local ok, kind = pcall(get_type, side)
      if ok and kind == "speaker" then
        records[#records + 1] = discovered_record(side)
      end
    end
  end

  table.sort(records, function(a, b)
    return a.side < b.side
  end)

  return records
end

return speaker
