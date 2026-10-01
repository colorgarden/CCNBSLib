-- nbs/decode.lua
--
-- Note Block Studio (.nbs) 整文件解码的边界层。
--
-- 这是唯一按**文件顺序**组合四个分节解析器、捕获它们可能抛出的一切错误、并保证
-- 播放器在恶意或损坏文件上**既不崩溃也不卡死**的地方。
--
-- 冻结的公共接口
--   local decode = require("nbs.decode")
--
--   decode.decode(bytes) -> { ok = true,  song = <song> }
--                        | { ok = false, error = { code, msg, ... } }
--
--   decode.decode **从不抛错，也从不卡死**。非表错误（例如本文件某个 bug 抛出的
--   普通字符串）会被归一为 { code = "E_INTERNAL", msg = tostring(err) }。分节解析器
--   通过 error(tbl, 0) 抛出的**带类型表错误**会原样透传，所以它的 `.code`、`.msg`
--   以及任何额外字段（如 `.offset`）都被保留——错误绝不会被吞成一句固定的通用
--   消息。
--
--   song = {
--     header             = <nbs.header.parse 的结果>
--     layers             = <nbs.layers.parse 的结果>
--     notes              = <音符记录的裸数组>
--     custom_instruments = <nbs.instruments_custom.parse 的结果>
--     song_length        = <有效长度，整数>
--     song_length_source = "header" | "notes" | "empty"
--   }
--
-- 组合顺序（即磁盘上的布局）
--   header.parse(r)                              -- 游标停在 notes
--   notes.parse(r, header.version)               -- 游标停在 layers
--   layers.parse(r, header.version, layer_count)
--   instruments_custom.parse(r, header.version)  -- 允许缺失 / EOF
--
--   四次调用串的是**同一个游标**，让它在同一个缓冲上单调前进。自定义乐器分节是
--   可选的：游标已耗尽时得到空数组。
--
-- 有效歌曲长度
--   * header.song_length 对 v0（旧格式）与 v3..v6 非 nil；v1/v2 不存长度，留 nil。
--   * 为 nil 时回退到由音符推出的长度（最高音符 tick + 1）；若也没有音符则为 0，
--     来源记 "empty"。
--   * 「更短则重建」：header 里那个字段按文档只是参考值，可能过期；被回绕的有符号
--     i16 读回来也会偏小（见 nbs/header.lua）。当磁盘上的音符证明这首歌比 header
--     声称的更长时，**以字节为准**：用音符推出的值，来源记 "notes"。否则以存储值
--     为准。
--
-- 运行时间有界（防卡死保证）
--   * 在建立游标之前，先用字节预算前置检查拒绝任何短于 MIN_HEADER_BYTES 的输入。
--   * 每个分节解析器只推进游标（每次读取都消耗字节），负跳跃量立即被拒，音符循环
--     同时受剩余字节数与 tick 上限约束，layers / 自定义乐器计数也在任何分配之前被
--     拒绝。所以解析时间对输入规模是线性的，任何畸形文件都在远低于 1 秒内被拒。
--   * 组合完成后再校验游标消耗的位置是否合理。
--
-- 会上报的错误码（全部在各分节内定义，这里不另设一套）：
--   E_TRUNCATED、E_UNSUPPORTED_VERSION、E_BAD_JUMP、E_LAYER_OVERFLOW、
--   E_TOO_MANY_TICKS、E_BAD_LAYER_COUNT、E_BAD_INSTRUMENT_COUNT、E_BAD_TEMPO、
--   E_INTERNAL。
--   E_BAD_TEMPO 由 header.parse 在存储的 tempo ≤ 0（损坏的 header）时抛出；它和
--   其他分节解析器的表错误一样，经下面那个透传 pcall 原样到达调用方。
--
-- 本文件遵守的 Lua 5.2 / Cobalt 约束：不用 `//`、不用位运算、不用 utf8.*、不用
-- math.maxinteger、不用 collectgarbage、不用 string.dump、不用 os.exit。

local reader = require("nbs.reader")
local header = require("nbs.header")
local notes = require("nbs.notes")
local layers = require("nbs.layers")
local instruments_custom = require("nbs.instruments_custom")

local decode = {}

-- 任何完整 NBS header 的最小磁盘尺寸。旧的 v0 布局最小：
-- i16 song_length + i16 layer_count + 四个空字符串 (4*4) + i16 tempo + 三个 u8 +
-- 五个 i32 + 一个空字符串 = 49 字节。比这更短的装不下 header，所以迅速以
-- E_TRUNCATED 失败。
local MIN_HEADER_BYTES = 49

-- 构造一个归一后的内部错误。
local function internal_error(message)
  return { ok = false, error = { code = "E_INTERNAL", msg = message } }
end

-- 归一 pcall() 的失败值。带类型的错误表原样透传；其他一切（包括缺少可用 `.code`
-- 的表）都包成 E_INTERNAL，好让调用方看到的 `.code` 永远是字符串。
local function normalize_error(err)
  if type(err) == "table" then
    if type(err.code) == "string" and err.code ~= "" then
      return err
    end
    local message = type(err.msg) == "string" and err.msg
      or "internal error table without a code"
    return { code = "E_INTERNAL", msg = message }
  end
  return { code = "E_INTERNAL", msg = tostring(err) }
end

-- decode(bytes) -> { ok = true, song = ... } | { ok = false, error = ... }
-- decode(bytes, on_progress) -> 同上
--
-- `on_progress(done, total)` 可选。**按字节偏移**上报，`total` 恒为输入长度，`done` 单调
-- 递增、且最后一次就是全文件。作用是让调用方在大文件上能画一条进度条，而不是干等。
--
-- 它是**可选**的，而且非函数值会被忽略（不是报错）：解码是库的公共入口，多一个可选参数
-- 不应该让任何一个现有调用方开始抛错。
--
-- 上报来自音符分节——那是解码里唯一随文件增长的部分；header / layers / 自定义乐器都只看
-- 文件的一小段。所以进度会在音符分节开始时突然前进，然后平滑走完——这是真实的分布，不是
-- 缺陷。
function decode.decode(bytes, on_progress)
  local report = type(on_progress) == "function" and on_progress or nil
  if type(bytes) ~= "string" then
    return internal_error("decode expects a byte string, got " .. type(bytes))
  end

  local length = #bytes

  -- 字节预算合理性检查：header 不可能存在于少于 MIN_HEADER_BYTES 字节里，
  -- 所以在建游标之前先拒。
  if length < MIN_HEADER_BYTES then
    return {
      ok = false,
      error = {
        code = "E_TRUNCATED",
        msg = string.format(
          "input is too short to contain an NBS header: %d byte(s), minimum %d",
          length, MIN_HEADER_BYTES),
        offset = 0,
        want = MIN_HEADER_BYTES,
        have = length,
      },
    }
  end

  local r = reader.new(bytes)

  -- 组合整个文件。每个分节解析器都用 error(tbl, 0) 抛带类型的表；下面这一个
  -- pcall 抓住它们并透传。
  local ok, composed = pcall(function()
    local parsed_header = header.parse(r)
    local parsed_notes = notes.parse(r, parsed_header.version, report)
    local parsed_layers = layers.parse(r, parsed_header.version,
      parsed_header.layer_count)
    local parsed_custom =
      instruments_custom.parse(r, parsed_header.version)

    return {
      header = parsed_header,
      notes = parsed_notes,
      layers = parsed_layers,
      custom_instruments = parsed_custom,
      consumed = r:pos(),
    }
  end)

  if not ok then
    return { ok = false, error = normalize_error(composed) }
  end

  -- 整个文件读完，报一次 100%。音符分节之后还有 layers 与自定义乐器，所以音符分节最后
  -- 那次上报**到不了**文件末尾（实测差 7 字节）。没有这一下，调用方的进度条会停在离 100%
  -- 差一点的地方——「看起来快好了，其实早完了」，比不画进度条更让人困惑。
  if report ~= nil then
    report(length, length)
  end

  -- 组合后的合理性检查：必须消耗掉一个有效 header，且游标绝不能越过缓冲末尾。
  if composed.consumed < MIN_HEADER_BYTES or composed.consumed > length then
    return internal_error(string.format(
      "cursor consumed an implausible %d byte(s) of %d", composed.consumed,
      length))
  end

  -- 有效歌曲长度（理由见文件头）。
  local header_length = composed.header.song_length
  local notes_length = composed.notes.song_length_from_notes

  local song_length
  local song_length_source

  if header_length == nil then
    if notes_length > 0 then
      song_length = notes_length
      song_length_source = "notes"
    else
      song_length = 0
      song_length_source = "empty"
    end
  elseif notes_length > header_length then
    -- 「更短则重建」：音符证明这首歌比那个仅供参考的存储字段更长，所以以磁盘上的
    -- 字节为准。
    song_length = notes_length
    song_length_source = "notes"
  else
    song_length = header_length
    song_length_source = "header"
  end

  return {
    ok = true,
    song = {
      header = composed.header,
      layers = composed.layers,
      notes = composed.notes.notes,
      custom_instruments = composed.custom_instruments,
      song_length = song_length,
      song_length_source = song_length_source,
    },
  }
end

return decode
