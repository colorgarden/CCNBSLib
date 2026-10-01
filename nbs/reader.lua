-- nbs/reader.lua
--
-- Note Block Studio (.nbs) 文件的小端（little-endian）字节游标。
--
-- 解码器里每个分节解析器（header、notes、layers、自定义乐器……）都通过本模块读
-- 自己的字段，所以这里的语义是一份**冻结的契约**：
--
--   * 所有多字节整数都是**小端**。这是 NBS 格式的约定，已对三方实现核实：
--     pynbs(file.py)、nbs.js(BinaryReader.ts)、NBS4j(NBSReader.java)。
--   * read_string() 先读一个 i32 字节数，再读**恰好这么多原始字节**并原样返回。
--     NBS v0-v5 的字符串是 CP1252，即一字节一字符；0x80-0xFF 区间的字节必须原样
--     保留，自定义乐器的音效路径才有效。本模块**从不**做 UTF-8 解码——显示转换是
--     另一件事（nbs/cp1252.lua）。
--   * 任何越界读取都通过 error(table) 抛出**带类型的错误表**：
--     { code = "E_TRUNCATED", msg = <string>, offset = <0 起算的位置>,
--       want = <请求字节数>, have = <可用字节数> }
--     刻意**不用** error() 的字符串形式：上层是按结构化的 `.code` 分支的。绝不返回
--     短字符串，游标也绝不越过末尾。
--
-- i64 精度说明
-- -------------
-- Cobalt 跟随 Lua 5.2，数字是 IEEE-754 双精度、53 位有效位。所以完整的 64 位有
-- 符号值在超过 2^53 时无法精确往返。i64() 按「尽力而为」实现：读 8 个小端字节，
-- 再用 double 重建数值——对规范断言的那些小数值和 -1 是精确的，但对极端量级会丢
-- 精度。这是可以接受的，因为 NBS 里唯一的 i64 字段是统计计数器（累计分钟数 /
-- 点击次数），播放器从不拿它做运算。**不要**依赖 i64() 得到精确的大数值。
--
-- 本文件遵守的 Lua 5.2 / Cobalt 约束：不用 `//`、不用位运算、不用
-- math.maxinteger、不用 collectgarbage、不用 string.dump、不用 os.exit。只使用
-- string.byte / string.sub 和算术。

local reader = {}

-- 游标对象 ---------------------------------------------------------------------

local Cursor = {}
Cursor.__index = Cursor

-- reader.new(bytes) -> cursor
-- `bytes` 是一个 Lua 字符串（原始字节缓冲）；游标从偏移 0 开始。
function reader.new(bytes)
  if type(bytes) ~= "string" then
    error("nbs.reader.new: expected a string, got " .. type(bytes), 2)
  end
  return setmetatable({ bytes = bytes, len = #bytes, _pos = 0 }, Cursor)
end

-- 越界错误（带类型） -----------------------------------------------------------
--
-- 用**表**抛出，好让 `.code` 能穿过 pcall 存活。`offset` 是那次失败读取尝试时
-- 的 0 起算位置。
local function truncated(offset, want, have)
  error({
    code = "E_TRUNCATED",
    msg = string.format(
      "truncated read at offset %d: wanted %d byte(s), %d available",
      offset, want, have),
    offset = offset,
    want = want,
    have = have,
  }, 0)
end

-- 通用的定宽小端解码器。
--
-- 从当前位置读 `n` 个字节，按无符号整数解释；当 `signed` 为真时按二补码有符号
-- 整数解释（最高字节，即小端序里的**最后一个**字节，承载符号）。任何字节被触碰
-- 之前先做边界检查，且只有成功后才推进游标。
function Cursor:_read_int(n, signed)
  local p = self._pos
  local available = self.len - p
  if n > available then
    truncated(p, n, available)
  end

  -- 从**最高**字节开始，好让符号扩展靠普通算术完成（double 上没有位运算符）。
  local top = string.byte(self.bytes, p + n)
  local value
  if signed and top >= 128 then
    value = top - 256
  else
    value = top
  end

  local i = n - 1
  while i >= 1 do
    value = value * 256 + string.byte(self.bytes, p + i)
    i = i - 1
  end

  self._pos = p + n
  return value
end

-- 无符号标量 --------------------------------------------------------------------

function Cursor:u8()
  return self:_read_int(1, false)
end

function Cursor:u16()
  return self:_read_int(2, false)
end

function Cursor:u32()
  return self:_read_int(4, false)
end

-- 有符号标量 --------------------------------------------------------------------

function Cursor:i8()
  return self:_read_int(1, true)
end

function Cursor:i16()
  return self:_read_int(2, true)
end

function Cursor:i32()
  return self:_read_int(4, true)
end

-- 见本文件顶部的 i64 精度说明。
function Cursor:i64()
  return self:_read_int(8, true)
end

-- 原始字节读取 ------------------------------------------------------------------

-- read(n) -> string：恰好 n 个**原始**字节，逐字节精确，越界则抛 E_TRUNCATED。
-- read(0) 返回 "" 且不推进。
function Cursor:read(n)
  if type(n) ~= "number" then
    error("nbs.reader:read: expected a number, got " .. type(n), 2)
  end
  if n < 0 then
    truncated(self._pos, n, self.len - self._pos)
  end
  if n == 0 then
    return ""
  end

  local p = self._pos
  local available = self.len - p
  if n > available then
    truncated(p, n, available)
  end

  local out = string.sub(self.bytes, p + 1, p + n)
  self._pos = p + n
  return out
end

-- read_string() -> string：先读 i32 小端字节数，再读这么多**原始**字节，逐字节精确
-- 且不做任何转码（见文件头）。声明的长度会在**任何分配或切片之前**与真正可用的字节
-- 校验，所以像 0x7FFFFFFF 这样的恶意长度会迅速失败。
function Cursor:read_string()
  -- 先读有符号 i32 长度；这一步会跨过那 4 个长度字节。
  local n = self:_read_int(4, true)

  if n < 0 then
    truncated(self._pos, n, self.len - self._pos)
  end

  local available = self.len - self._pos
  if n > available then
    truncated(self._pos, n, available)
  end

  if n == 0 then
    return ""
  end

  local out = string.sub(self.bytes, self._pos + 1, self._pos + n)
  self._pos = self._pos + n
  return out
end

-- 游标记账 ----------------------------------------------------------------------

-- skip(n)：前进 n 个字节，带边界检查；越界抛 E_TRUNCATED。
function Cursor:skip(n)
  if type(n) ~= "number" then
    error("nbs.reader:skip: expected a number, got " .. type(n), 2)
  end
  if n < 0 then
    truncated(self._pos, n, self.len - self._pos)
  end

  local available = self.len - self._pos
  if n > available then
    truncated(self._pos, n, available)
  end
  self._pos = self._pos + n
end

function Cursor:pos()
  return self._pos
end

function Cursor:remaining()
  return self.len - self._pos
end

function Cursor:eof()
  return self._pos >= self.len
end

return reader
