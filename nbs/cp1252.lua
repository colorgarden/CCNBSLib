-- nbs/cp1252.lua
--
-- CP1252 (Windows-1252) -> UTF-8 display mapping for CCNBSLib.
--
-- WHY THIS MODULE EXISTS
--   NBS v0-v5 store every string as one byte per character in CP1252, NOT
--   UTF-8.  The reader (nbs/reader.lua) reads those bytes byte-exact and the
--   model keeps them byte-exact: custom-instrument sound-file paths are stored
--   as raw bytes and depend on that fidelity.  But when a song or layer name is
--   SHOWN to a human, those CP1252 bytes must be rendered as UTF-8 so the
--   terminal prints real typographic characters instead of mojibake.
--
--   This module is the SINGLE place where that conversion is allowed to happen.
--   to_display() is a PURE DISPLAY TRANSFORM: it never mutates its input and
--   must never be applied to a stored field or to a sound-file path.
--
-- TARGET INTERPRETER
--   Stock Lua 5.2.4 (the project's local Tier-1 interpreter).  Lua 5.2 has NO
--   utf8 library (that arrived in 5.3), so UTF-8 byte sequences are emitted by
--   hand with string.char().  No utf8.* call appears anywhere in this file.
--
-- ENCODING RULES
--   * 0x00-0x7F -> identity (ASCII is the same byte in CP1252 and UTF-8).
--   * 0xA0-0xFF -> identity code point (CP1252 agrees with Latin-1 there);
--                  each becomes a 2-byte UTF-8 sequence U+00A0..U+00FF.
--   * 0x80-0x9F -> CP1252-specific table (these DIFFER from Latin-1).
--   * The five undefined CP1252 bytes 0x81 0x8D 0x8F 0x90 0x9D -> U+FFFD
--     REPLACEMENT CHARACTER.

local cp1252 = {}

-- U+FFFD REPLACEMENT CHARACTER, used for the five undefined CP1252 bytes.
local REPLACEMENT = 0xFFFD

-- Authoritative CP1252 mapping for 0x80..0x9F, in byte order (index 1 == 0x80).
-- Undefined slots hold REPLACEMENT.
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

-- Byte-indexed code-point table: CODE_POINT[byte] -> Unicode code point.
local CODE_POINT = {}

for byte = 0x00, 0x7F do
  CODE_POINT[byte] = byte -- ASCII: identical in CP1252 and UTF-8.
end

for offset = 0, 0x1F do
  CODE_POINT[0x80 + offset] = CP1252_80_9F[offset + 1]
end

for byte = 0xA0, 0xFF do
  CODE_POINT[byte] = byte -- CP1252 agrees with Latin-1 above 0x9F.
end

-- Encode a Unicode code point as its UTF-8 byte sequence, without utf8.*.
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

-- byte_to_utf8(byte) -> UTF-8 string for a single CP1252 byte value 0..255.
--
-- PUBLIC HELPER, NOT DEAD CODE.  to_display() below is the production caller
-- (it encodes each stored byte through this), and the function is exported so
-- a caller that needs only one byte -- e.g. a single-character preview -- can
-- use it directly.  The test suite pins its output byte-for-byte.
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

-- to_display(bytes) -> UTF-8 string suitable for printing.
-- Pure transform: the input string is left byte-exact and unmodified.
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
