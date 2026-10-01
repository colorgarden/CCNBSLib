-- nbs/header.lua
--
-- Note Block Studio (.nbs) **header 分节**的解析器，同时覆盖旧的 v0 布局与
-- Open Note Block Studio 的 v1..v6 布局。
--
-- 冻结的公共接口（其他模块依赖这个精确形状）：
--
--   local reader = require("nbs.reader")
--   local header = require("nbs.header")
--   local h = header.parse(reader.new(bytes))
--
--   header.parse(reader) -> header_table，字段名**精确**如下：
--     version                  整数 0..6；0 表示旧格式
--     vanilla_instrument_count 整数；自定义乐器从这里开始编号
--     song_length              整数，v1/v2 为 nil
--     layer_count              整数
--     name, author, original_author, description   字符串，**逐字节精确**
--     midi_filename            字符串（可能是 ""）
--     tempo_raw                整数；原始的有符号 i16（每秒百分之一个 tick）
--     tempo_ticks_per_second   number = tempo_raw / 100
--     autosave                 整数
--     autosave_duration        整数
--     time_signature           整数
--     minutes_spent, left_clicks, right_clicks, blocks_added, blocks_removed
--     loop                     整数 0/1；version < 4 时为 nil
--     max_loop_count           整数；version < 4 时为 nil
--     loop_start_tick          整数；version < 4 时为 nil
--     format                   v0 为 "legacy"，其余为 "new"
--
-- 格式识别 -------------------------------------------------------------------
-- 第一个字段是一个 i16，分两种情况：
--   * 为 0      -> **新格式**。下一个字节是 u8 版本号，再下一个 u8 是
--                  vanilla_instrument_count。
--   * 非 0      -> **旧格式 v0**。那个 i16 本身就是歌曲长度；**没有**版本字节、
--                  也**没有** vanilla instrument 字节。version = 0、
--                  format = "legacy"、vanilla_instrument_count = 10。
--
-- 字段顺序 -------------------------------------------------------------------
-- 新格式（v1..v6），紧跟在版本字节之后：
--   u8  vanilla_instrument_count
--   i16 song_length        -- 仅当 version >= 3
--   i16 layer_count
--   str name
--   str author
--   str original_author
--   str description
--   i16 tempo_raw
--   u8  autosave
--   u8  autosave_duration
--   u8  time_signature
--   i32 minutes_spent
--   i32 left_clicks
--   i32 right_clicks
--   i32 blocks_added
--   i32 blocks_removed
--   str midi_filename
--   u8  loop               -- 仅当 version >= 4
--   u8  max_loop_count     -- 仅当 version >= 4
--   i16 loop_start_tick    -- 仅当 version >= 4
-- （v1/v2 没有 song_length -> 该字段为 nil。真正的长度稍后由**另一个模块**从音符分节
-- 推出；本解析器从不做这件事。）
--
-- 旧格式 v0，紧跟在第一个 i16（那个是歌曲长度）之后：
--   i16 layer_count
--   str name / author / original_author / description
--   i16 tempo_raw
--   u8  autosave / autosave_duration / time_signature
--   i32 minutes_spent / left_clicks / right_clicks / blocks_added / blocks_removed
--   str midi_filename
-- （旧格式没有 loop 字段。）
--
-- 有符号 int16 的回绕 ---------------------------------------------------------
-- song_length 存成有符号 i16，但长曲子可以超过 32767 tick，所以存进去时是被回绕到
-- 负数区间的，必须重建。这里对齐参考实现 OpenNBS/nbs.js
-- （src/formats/binary/BinaryReader.ts，processHeader）：
--
--     const difference = -1 * (BufferReader.MIN_SHORT - size) + 2;
--     size = BufferReader.MAX_SHORT + difference;
--
-- 其中 nbs.js 定义 MIN_SHORT = -32767、MAX_SHORT = 32767（src/buffer/wrapper.ts）。
-- 代数上它正好就是**按无符号重新解释**，即 size + 65536，也就是「本意的无符号值」：
--   raw 0x8000 (-32768) -> 32768
--   raw 0xFFFF (-1)     -> 65535
-- 这个重建在旧格式路径和新格式 v3+ 路径上**都会**应用，但**不**应用于 loop_start_tick。
--
-- 错误 -----------------------------------------------------------------------
--   * 越界**不在这里**捕获：它们从 nbs.reader 原样向上传递，形如
--     { code = "E_TRUNCATED", ... }。
--   * 版本字节大于 6 时通过 error(tbl, 0) 抛出**带类型的错误表**
--     { code = "E_UNSUPPORTED_VERSION", msg = <string>, version = <n> }，并立即停止
--     解析。
--   * layer_count 为**负**时通过 error(tbl, 0) 抛出**带类型的错误表**
--     { code = "E_BAD_LAYER_COUNT", msg = <string>, layer_count = <n>,
--       version = <n> }，并立即停止解析。
--     layer_count 按规范是有符号 i16，所以原始计数 >= 32768 会回绕成负数；真实文件
--     不可能是这样，于是这里就拒绝它，而不是接受——（负数会让 layers.parse 的
--     `layer_count > remaining` 守卫为假，跑零轮循环，让损坏文件解码成"成功"）。
--     错误码**与** layers.parse 早已为不可承受的计数抛出的那个相同，这样调用方只需
--     按一个一致的 `.code` 分支。
--   * tempo_raw **非正**（<= 0）时通过 error(tbl, 0) 抛出**带类型的错误表**
--     { code = "E_BAD_TEMPO", msg = <string>, tempo_raw = <n>, version = <n> }，
--     并立即停止解析。
--     tempo_raw 按规范是有符号 i16，所以 0 和负值在磁盘上都是可表示的。下游
--     tick_ms = 1000 / (tempo_raw / 100)：存 0 会让 tick_ms 变成**无穷**，tick-0
--     事件的 t_ms 随之成为 NaN，于是调度器会请求一个永远无法触发的截止时间，会话
--     永不结束；负 tempo 得到负的（同样不可用的）tick_ms。tempo <= 0 是**损坏输入**，
--     不是慢歌，所以在第一次信任这个值的点上就拒绝它，而不是把它夹成某个能播的东西。
--
-- 本文件遵守的 Lua 5.2 / Cobalt 约束：不用 `//`、不用位运算、不用 math.maxinteger、
-- 不用 collectgarbage、不用 string.dump、不用 os.exit、不用 utf8.*。
-- 只使用普通算术、string.char 和读取器。

local header = {}

-- nbs.js 的 BufferWrapper 常量（见上面的回绕说明）。注意 MIN_SHORT 刻意是
-- -32767 而不是 -32768：配合公式里的 "+ 2" 项，它才让重建成为精确的无符号重解释。
local MIN_SHORT = -32767
local MAX_SHORT = 32767

-- 抛出那个冻结的「不支持的版本」错误。用**表**抛出，好让 `.code` 穿过 pcall 存活；
-- level 0 让错误位置停在调用方。
local function unsupported_version(version)
  error({
    code = "E_UNSUPPORTED_VERSION",
    msg = string.format(
      "unsupported NBS version %d (supported range: 0..6, where 0 is the legacy format)",
      version),
    version = version,
  }, 0)
end

-- 把回绕过的有符号 i16 歌曲长度重建成本意的无符号 tick 数。
-- 形状与 nbs.js 完全一致，好让意图可以并排审计。
local function reconstruct_song_length(value)
  if value < 0 then
    local difference = -1 * (MIN_SHORT - value) + 2
    return MAX_SHORT + difference
  end
  return value
end

-- header.parse(reader) -> header_table
--
-- 从 `reader` 精确消耗掉 header 各字段；游标停在音符分节的第一个字节。
-- 冻结的形状见文件头。
function header.parse(r)
  -- 格式识别 ------------------------------------------------------------------
  local first = r:i16()

  local version
  local vanilla_instrument_count
  local format
  local song_length

  if first == 0 then
    -- 新格式（v1..v6）：下一个字节是版本号。
    version = r:u8()
    if version > 6 then
      unsupported_version(version)
    end
    format = "new"
    vanilla_instrument_count = r:u8()
    if version >= 3 then
      song_length = reconstruct_song_length(r:i16())
    else
      -- v1 和 v2 不存长度；它稍后由音符推出。
      song_length = nil
    end
  else
    -- 旧格式 v0：第一个 i16 本身就是（可能已回绕的）歌曲长度。
    version = 0
    format = "legacy"
    vanilla_instrument_count = 10
    song_length = reconstruct_song_length(first)
  end

  -- 两种布局共有、顺序相同的字段 ------------------------------------------------
  local layer_count = r:i16()

  -- layer_count 为负是损坏数据。这个字段按规范是**有符号** i16，所以原始计数
  -- >= 32768 会回绕成负数（例如 60000 -> -5536、65535 -> -1）。在**读取点**这里
  -- 就拒绝：layers.parse 的字节预算守卫是 `layer_count > remaining`，对任何负数都为
  -- 假，于是负计数会跑**零**轮循环，让整个损坏文件解码成"成功"。复用 layers.parse
  -- 自己的错误码，好让调用方只看到一个一致的 `.code`。
  if layer_count < 0 then
    error({
      code = "E_BAD_LAYER_COUNT",
      msg = string.format(
        "negative layer_count %d (raw signed i16; corrupt header)",
        layer_count),
      layer_count = layer_count,
      version = version,
    }, 0)
  end

  local name = r:read_string()
  local author = r:read_string()
  local original_author = r:read_string()
  local description = r:read_string()
  local tempo_raw = r:i16()

  -- 存储的 tempo <= 0 是**损坏输入**，不是慢歌。这里是这个值**第一次被信任**的点：
  -- 下游 `tick_ms = 1000 / (tempo/100)` 在 0 时会是无穷，tick-0 事件的
  -- `t_ms = tick * tick_ms` 随之成为 NaN —— 一个调度器的时钟永远无法满足的截止时间，
  -- 于是会话永不结束。就在这里按其他 header 错误同样的带类型表约定拒绝它，好让
  -- nbs.decode 报出 E_BAD_TEMPO，而不是交出一首放不出来的歌。
  if tempo_raw <= 0 then
    error({
      code = "E_BAD_TEMPO",
      msg = string.format(
        "non-positive tempo_raw %d (raw signed i16, hundredths of a tick per "
        .. "second; corrupt header -- it would divide by zero downstream)",
        tempo_raw),
      tempo_raw = tempo_raw,
      version = version,
    }, 0)
  end

  local autosave = r:u8()
  local autosave_duration = r:u8()
  local time_signature = r:u8()
  local minutes_spent = r:i32()
  local left_clicks = r:i32()
  local right_clicks = r:i32()
  local blocks_added = r:i32()
  local blocks_removed = r:i32()
  local midi_filename = r:read_string()

  -- loop 元数据从 v4 才存在；旧格式 v0 从来没有。缺失时这三个字段是 nil（不是 0），
  -- 好让调用方区分出「未存储」。
  local loop = nil
  local max_loop_count = nil
  local loop_start_tick = nil
  if version >= 4 then
    loop = r:u8()
    max_loop_count = r:u8()
    loop_start_tick = r:i16() -- 刻意**不**重建
  end

  return {
    version = version,
    vanilla_instrument_count = vanilla_instrument_count,
    song_length = song_length,
    layer_count = layer_count,
    name = name,
    author = author,
    original_author = original_author,
    description = description,
    midi_filename = midi_filename,
    tempo_raw = tempo_raw,
    tempo_ticks_per_second = tempo_raw / 100,
    autosave = autosave,
    autosave_duration = autosave_duration,
    time_signature = time_signature,
    minutes_spent = minutes_spent,
    left_clicks = left_clicks,
    right_clicks = right_clicks,
    blocks_added = blocks_added,
    blocks_removed = blocks_removed,
    loop = loop,
    max_loop_count = max_loop_count,
    loop_start_tick = loop_start_tick,
    format = format,
  }
end

return header
