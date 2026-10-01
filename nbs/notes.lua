-- nbs/notes.lua
--
-- Note Block Studio (.nbs) 的音符分节解析器。
--
-- 音符分节用的是游程（run-length）「跳跃」编码：它不存储每个 (tick, layer) 对，
-- 而是存**到下一个被使用 tick 的差值**，以及同一 tick 内**到下一个被使用 layer 的
-- 差值**。差值为 0 表示当前层级结束：
--
--   tick = -1
--   循环：
--     jumps_to_next_tick = i16            -- 0 结束音符分节
--     if jumps_to_next_tick == 0 then break
--     tick = tick + jumps_to_next_tick
--     layer = -1
--     循环：
--       jumps_to_next_layer = i16         -- 0 进入下一个 tick
--       if jumps_to_next_layer == 0 then break
--       layer = layer + jumps_to_next_layer
--       instrument = u8
--       key        = u8
--       if version >= 4 then
--         velocity = u8
--         panning  = u8
--         pitch    = i16
--       else
--         velocity = 100 ; panning = 100 ; pitch = 0
--       end
--       产出 { tick, layer, instrument, key, velocity, panning, pitch }
--
-- 音符按**出现顺序**追加（tick 升序，同一 tick 内 layer 升序）；解析器**从不排序**。
--
-- 符号性 —— 公开的 NBS 规范自相矛盾，所以本模块沿用解码器其余部分已经冻结的解释：
--   * 跳跃量（i16）与 pitch（i16）是**有符号**的。
--   * instrument、key、velocity、panning 按**无符号**字节（u8）读。
--     panning 合法可达 200，若按有符号读会变成 -56。
--
-- 安全性 —— 播放器独占电脑唯一的线程，所以解析器绝不能在恶意输入上自旋或倒退：
--   * 负的跳跃量是损坏数据，立即抛 E_BAD_JUMP。
--   * 游标只会前进（每次读取都消耗字节）。
--   * 外层循环以 r:remaining() 为上限（每个 tick 至少消耗它那 2 字节跳跃量）；
--     tick 超过 32000 抛 E_TOO_MANY_TICKS —— 某些 NBS 版本过了这个点会崩溃。
--   * 绝对图层序号超过 200 抛 E_LAYER_OVERFLOW。
--   * 越界会原样向上传递读取器的带类型 E_TRUNCATED 错误。
--
-- 所有带类型的错误都是用 error(tbl, 0) 抛出的**表**，调用方按 `.code` 分支：
--   { code = "E_BAD_JUMP" | "E_LAYER_OVERFLOW" | "E_TOO_MANY_TICKS", msg, offset }
--
-- Lua 5.2 / Cobalt 约束：不用 `//`、不用位运算、不用 goto。

local notes = {}

-- 有记录的「实践中不安全」的 NBS 上限（见文件头）。
local MAX_LAYER = 200
local MAX_TICK = 32000

-- 带类型错误的辅助函数。`offset` 是有问题那个值**开始**的位置（即它被读之前
-- 的 r:pos()）。
local function raise(code, message, offset)
  error({ code = code, msg = message, offset = offset }, 0)
end

-- notes.parse(r, version) -> { notes = { <note>, ... }, song_length_from_notes = <int> }
--
-- `r` 是停在第一个 tick 跳跃量处的 nbs.reader 游标。`song_length_from_notes` 是
-- 带音符的**最高 tick 加一**（没有音符时为 0）；v1/v2 不存长度，就是这样恢复出来的。
function notes.parse(r, version)
  if type(version) ~= "number" then
    version = 0
  end
  local has_v4_fields = version >= 4

  -- 由字节数推导出的迭代上限：外层每轮至少消耗那 2 字节的 tick 跳跃量，所以
  -- tick 数多于剩余字节数对诚实输入是不可能的，只可能是损坏数据。
  local max_ticks = r:remaining()

  local parsed = {}
  local song_length = 0

  local tick = -1
  local ticks_seen = 0

  while true do
    ticks_seen = ticks_seen + 1
    if ticks_seen > max_ticks then
      raise("E_TOO_MANY_TICKS",
        string.format("tick count exceeded byte budget (%d) at offset %d",
          max_ticks, r:pos()), r:pos())
    end

    local tick_offset = r:pos()
    local jumps_to_next_tick = r:i16()
    if jumps_to_next_tick == 0 then
      break
    end
    if jumps_to_next_tick < 0 then
      raise("E_BAD_JUMP",
        string.format("negative tick jump %d at offset %d",
          jumps_to_next_tick, tick_offset), tick_offset)
    end

    tick = tick + jumps_to_next_tick
    if tick > MAX_TICK then
      raise("E_TOO_MANY_TICKS",
        string.format("tick %d exceeds safe ceiling %d at offset %d",
          tick, MAX_TICK, tick_offset), tick_offset)
    end

    local layer = -1
    while true do
      local layer_offset = r:pos()
      local jumps_to_next_layer = r:i16()
      if jumps_to_next_layer == 0 then
        break
      end
      if jumps_to_next_layer < 0 then
        raise("E_BAD_JUMP",
          string.format("negative layer jump %d at offset %d",
            jumps_to_next_layer, layer_offset), layer_offset)
      end

      layer = layer + jumps_to_next_layer
      if layer < 0 or layer > MAX_LAYER then
        raise("E_LAYER_OVERFLOW",
          string.format("layer index %d out of range 0..%d at offset %d",
            layer, MAX_LAYER, layer_offset), layer_offset)
      end

      local instrument = r:u8()
      local key = r:u8()
      local velocity, panning, pitch
      if has_v4_fields then
        velocity = r:u8()
        panning = r:u8()
        pitch = r:i16()
      else
        velocity = 100
        panning = 100
        pitch = 0
      end

      parsed[#parsed + 1] = {
        tick = tick,
        layer = layer,
        instrument = instrument,
        key = key,
        velocity = velocity,
        panning = panning,
        pitch = pitch,
      }

      if tick + 1 > song_length then
        song_length = tick + 1
      end
    end
  end

  return {
    notes = parsed,
    song_length_from_notes = song_length,
  }
end

return notes
