-- nbs/cp1252.lua
--
-- CCNBSLib 的 CP1252（Windows-1252）→ UTF-8 显示映射。
--
-- 这个模块为什么存在
--   NBS v0-v5 把每个字符串按**一字节一字符**存成 CP1252，**不是** UTF-8。读取器
--   （nbs/reader.lua）逐字节原样读出，模型也逐字节原样保存：自定义乐器的音效文件路径
--   就是按原始字节存的，依赖这份保真度。但当曲名或图层名要**给人看**时，这些 CP1252
--   字节必须渲染成 UTF-8，终端才会打出真正的印刷字符、而不是乱码。
--
--   本模块是**唯一**允许做这个转换的地方。to_display() 是一个**纯显示变换**：它从不
--   修改输入，也**绝不**能用在存储字段或音效文件路径上。
--
-- 目标解释器
--   原版 Lua 5.2.4（项目本地的 Tier-1 解释器）。Lua 5.2 **没有** utf8 库（5.3 才有），
--   所以 UTF-8 字节序列是用 string.char() 手工拼的。本文件里不出现任何 utf8.* 调用。
--
-- 编码规则
--   * 0x00-0x7F -> 原样（ASCII 在 CP1252 与 UTF-8 里是同一个字节）。
--   * 0xA0-0xFF -> 码点相同（这一段 CP1252 与 Latin-1 一致）；
--                  各变成一个 2 字节的 UTF-8 序列 U+00A0..U+00FF。
--   * 0x80-0x9F -> CP1252 **专有**表（这一段与 Latin-1 **不同**）。
--   * CP1252 未定义的五个字节 0x81 0x8D 0x8F 0x90 0x9D -> U+FFFD **替换字符**。

local cp1252 = {}

-- U+FFFD 替换字符，用于 CP1252 未定义的那五个字节。
local REPLACEMENT = 0xFFFD

-- 0x80..0x9F 的权威 CP1252 映射，按字节顺序（下标 1 == 0x80）。
-- 未定义的槽位放 REPLACEMENT。
local CP1252_80_9F = {
  0x20AC, REPLACEMENT, 0x201A, 0x0192,  -- 0x80 0x81 0x82 0x83
  0x201E, 0x2026,     0x2020, 0x2021,  -- 0x84 0x85 0x86 0x87
  0x02C6, 0x2030,     0x0160, 0x2039,  -- 0x88 0x89 0x8A 0x8B
  0x0152, REPLACEMENT, 0x017D, REPLACEMENT, -- 0x8C 0x8D 0x8E 0x8F
  REPLACEMENT, 0x2018, 0x2019, 0x201C, -- 0x90 0x91 0x92 0x93
  0x201D, 0x2022,     0x2013, 0x2014,  -- 0x94 0x95 0x96 0x97
  0x02DC, 0x2122,     0x0161, 0x203A,  -- 0x98 0x99 0x9A 0x9B
  0x0153, REPLACEMENT, 0x017E, 0x0178, -- 0x9C 0x9D 0x9E 0x9F
}

-- 按字节索引的码点表：CODE_POINT[byte] -> Unicode 码点。
local CODE_POINT = {}

for byte = 0x00, 0x7F do
  CODE_POINT[byte] = byte -- ASCII：CP1252 与 UTF-8 完全相同。
end

for offset = 0, 0x1F do
  CODE_POINT[0x80 + offset] = CP1252_80_9F[offset + 1]
end

for byte = 0xA0, 0xFF do
  CODE_POINT[byte] = byte -- 0x9F 以上 CP1252 与 Latin-1 一致。
end

-- 把一个 Unicode 码点编码成它的 UTF-8 字节序列，不用 utf8.*。
local function encode(code_point)
  if code_point < 0x80 then
    return string.char(code_point)
  elseif code_point < 0x800 then
    return string.char(
      0xC0 + math.floor(code_point / 0x40),
      0x80 + (code_point % 0x40))
  elseif code_point < 0x10000 then
    return string.char(
      0xE0 + math.floor(code_point / 0x1000),
      0x80 + math.floor(code_point / 0x40) % 0x40,
      0x80 + (code_point % 0x40))
  else
    return string.char(
      0xF0 + math.floor(code_point / 0x40000),
      0x80 + math.floor(code_point / 0x1000) % 0x40,
      0x80 + math.floor(code_point / 0x40) % 0x40,
      0x80 + (code_point % 0x40))
  end
end

-- byte_to_utf8(byte) -> 单个 CP1252 字节值 0..255 对应的 UTF-8 字符串。
--
-- **公共辅助函数，不是死代码。** 下面的 to_display() 就是生产调用方（它把每个存储
-- 字节都过一遍这里），而这个函数被导出，是为了让只需要一个字节的调用方——例如单字符
-- 预览——可以直接用它。测试逐字节钉住了它的输出。
function cp1252.byte_to_utf8(byte)
  if type(byte) ~= "number" then
    error("cp1252.byte_to_utf8: expected a number, got " .. type(byte), 2)
  end
  byte = math.floor(byte)
  if byte < 0 or byte > 0xFF then
    error("cp1252.byte_to_utf8: byte out of range 0..255: " .. tostring(byte), 2)
  end
  return encode(CODE_POINT[byte])
end

-- to_display(bytes) -> 适合打印的 UTF-8 字符串。
-- 纯变换：输入字符串保持逐字节原样、不被修改。
function cp1252.to_display(bytes)
  if type(bytes) ~= "string" then
    error("cp1252.to_display: expected a string, got " .. type(bytes), 2)
  end
  if bytes == "" then
    return ""
  end
  local parts = {}
  for index = 1, #bytes do
    parts[index] = encode(CODE_POINT[string.byte(bytes, index)])
  end
  return table.concat(parts)
end

return cp1252
