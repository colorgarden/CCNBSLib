-- nbs/instruments_custom.lua
--
-- Note Block Studio (.nbs) 文件里**可选**的自定义乐器分节解析器。这个分节位于
-- layers 分节之后；把游标（nbs/reader.lua）定位到它的第一个字节是**调用方**的责任。
--
-- 线上布局
--   u8 count
--   然后重复 `count` 次：
--     str name        （i32 小端长度，随后是那么多**原始**字节）
--     str sound_file  （i32 小端长度，随后是那么多**原始**字节）
--     u8  key
--     u8  press_key
--   所以每条记录至少花 4 + 4 + 1 + 1 = 10 字节。
--
-- 返回形状
--   一个记录的**数组**，每条记录的键**精确**如下：
--     name       字符串，逐字节精确
--     sound_file 字符串，逐字节精确（相对 NBS 的 /Sounds 文件夹的路径）
--     key        整数，原样（预期 0..87；45 是这个格式文档里的"未设置"默认值，
--                这里**不**替它兜底）
--     press_key  整数，原样（0 或 1）
--
-- 可选分节
--   如果游标已经耗尽（r:eof()），说明分节不存在，parse() 返回空数组，**不抛错**。
--
-- 计数上限（随版本变化）
--   `count` 是按**无符号**字节读的，但真正的上限是 240、绝不是 255，因为 16 个 vanilla
--   乐器加上自定义 id 还必须能塞进一个字节。文档上的各版本上限是：
--     version 0      -> 9
--     version 1..4   -> 18
--     version 5..6   -> 240
--   超过上限的计数会通过 error(table, 0) 抛出带类型的表
--     { code = "E_BAD_INSTRUMENT_COUNT", msg, count, cap, version }
--   而且是在**任何数组被分配之前**。未知/更高的版本沿用 240 这个上限。
--
-- 缓冲预检
--   即便计数合法，它也可能超出剩余缓冲。由于每条记录至少需要 10 字节，只要
--   count * 10 > r:remaining() 就立即用同一个 E_BAD_INSTRUMENT_COUNT 表拒绝——这比
--   一直循环到一次截断读取、最后浮出一个笼统的 E_TRUNCATED 要好得多。
--
-- 逐字节保真
--   sound_file 是一条**不透明路径**。它用读取器的逐字节 read_string() 读出并原样保存：
--   不做 UTF-8 解码、不做 CP1252 → UTF-8 显示转换（nbs/cp1252.lua 只用于显示，
--   **绝不能**用在这里）、不拆分/归一化斜杠、不剥离扩展名、也不对任何 Minecraft 音效
--   注册表做校验。消费方在播放时会拒绝自定义乐器，但保存下来的路径在诊断里仍必须能被
--   忠实打印。
--
-- 目标解释器
--   原版 Lua 5.2 / CC:Tweaked Cobalt：不用 utf8.*、不用位运算、不用整除、不用 os.exit。

local instruments_custom = {}

-- 单条记录的最小线上尺寸：两个 i32 长度前缀 + 两个字节。
local MIN_RECORD_BYTES = 10

-- 随版本变化的计数上限（见文件头）。
local function cap_for(version)
  if version <= 0 then
    return 9
  elseif version <= 4 then
    return 18
  end
  return 240
end

-- 抛出带类型的计数错误。`context` 只在给人看的 `msg` 里区分两种受守卫的情况
-- （超上限 vs. 缓冲太小）；`.code`、`.count`、`.cap`、`.version` 完全相同，所以调用方
-- 只需按一个错误码分支。
local function raise_bad_count(count, cap, version, context)
  error({
    code = "E_BAD_INSTRUMENT_COUNT",
    msg = string.format(
      "bad custom-instrument count: count=%d cap=%d version=%d (%s)",
      count, cap, version, context),
    count = count,
    cap = cap,
    version = version,
  }, 0)
end

-- parse(r, version) -> 自定义乐器记录数组。
--
-- `r` 是定位到分节第一个字节的 nbs.reader 游标，`version` 是歌曲格式版本（0..6）。
-- 分节不存在时返回空数组。计数不可能时抛出带类型的表；流确实被截断时原样向上传递
-- 读取器的带类型 E_TRUNCATED。
function instruments_custom.parse(r, version)
  -- 可选分节：游标已耗尽意味着「没有自定义乐器」。
  if r:eof() then
    return {}
  end

  version = version or 0
  local cap = cap_for(version)

  -- `count` 是**无符号**字节；在分配任何东西**之前**先按版本上限校验。
  local count = r:u8()
  if count > cap then
    raise_bad_count(count, cap, version, "exceeds version cap")
  end

  -- 预检剩余缓冲，好让「合法但无法满足」的计数迅速失败，而不是一路循环到截断读取。
  if count * MIN_RECORD_BYTES > r:remaining() then
    raise_bad_count(count, cap, version, "buffer cannot satisfy count")
  end

  local records = {}
  for index = 1, count do
    -- 读取顺序与线上布局完全一致。
    records[index] = {
      name = r:read_string(),
      sound_file = r:read_string(),
      key = r:u8(),
      press_key = r:u8(),
    }
  end
  return records
end

return instruments_custom
