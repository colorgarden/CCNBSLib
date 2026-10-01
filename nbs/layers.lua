-- nbs/layers.lua
--
-- NBS layers 分节解析器。
--
-- layers 是 .nbs 文件里**唯一**布局随歌曲版本变化的部分，所以本模块只是在共享字节
-- 游标（nbs/reader.lua）上做一次按版本分支的薄遍历。它**自己不做任何解码**：每个
-- 字段都经游标读取，任何越界都以游标的带类型 E_TRUNCATED 表浮出。
--
-- 冻结的公共接口
--   local layers = require("nbs.layers")
--   layers.parse(r, version, layer_count) -> <图层记录数组>
--
--   r           来自 nbs.reader.new(bytes) 的游标
--   version     歌曲版本，已由 header 解析器读出
--   layer_count 后面跟的图层记录数，**不可信**
--
-- 每条返回记录的键**精确**如下：
--   name     字符串，**逐字节精确**（CP1252 字节，此处从不转码）
--   lock     0 = 未锁，1 = 静音，2 = SOLO；version < 4 时为 nil
--   volume   整数 0..100
--   panning  整数 0..200（100 = 居中）；version < 2 时为 nil
--
-- 记录布局（按顺序读 layer_count 次）
--   str name                          -- i32 长度 + 原始字节
--   u8  lock     -- 仅当 version >= 4
--   u8  volume   -- 0..100
--   u8  panning  -- 仅当 version >= 2  （0..200，100 = 居中）
--
-- 版本矩阵：
--   v0, v1        name + volume
--   v2, v3        name + volume + panning
--   v4 及以上     name + lock + volume + panning
--
-- lock 字节与 panning 字节在旧版本上是**不存在**的。无条件读它们会吃掉下一个字段
-- （或下一条记录），把整个分节**静默地**读错位，所以下面两个分支都写得很明确。
--
-- LOCK 语义 —— 三个值，不是两个
--   公开文档只提到 0（未锁）和 1（锁住），但真实格式还会用 2 = SOLO。本解析器把原始
--   整数**原样**暴露出来；既不拒绝 2，也不把它并入 0 或 1。怎么处理 solo 是**播放**
--   层面的关注点，归后面的层管。
--
-- 安全性
--   layer_count 来自文件、不可信（格式文档警告超过 200 层会让某些 NBS 版本崩溃）。
--   每条记录至少消耗 5 字节——4 字节字符串长度加至少 1 字节 volume——所以大于剩余
--   字节预算的计数不可能是诚实的。下面的守卫在**任何表被分配、任何记录被读取之前**
--   就拒绝这种计数；它抛出带类型的表：
--     { code = "E_BAD_LAYER_COUNT", msg = <string>,
--       layer_count = <n>, remaining = <n> }
--   用 error(table, 0) 抛出，对齐读取器的带类型错误契约，好让边界层按 `.code` 分支。
--   于是恶意计数**永远**无法驱动一次大分配或长时间循环。
--
-- Cobalt / Lua 5.2 约束：不用 `//`、不用位运算、不用 goto、不用 utf8.*、不用
-- math.maxinteger、不用 collectgarbage。只使用算术、string 与 table 操作。

local layers = {}

-- 单条图层记录可能的最小磁盘尺寸：4 字节字符串长度（名字可以为空，但长度前缀永远
-- 存在）加 1 字节 volume。写在这里供读者参考；守卫用的是更简单、也**严格更弱**的
-- 界限 `layer_count <= remaining`，它足以让循环及其分配受输入规模约束。
local MIN_RECORD_BYTES = 5

-- layers.parse(r, version, layer_count) -> 图层记录数组。
--
-- 在下列情况下抛出带类型的错误表：
--   * layer_count 不合理  -> { code = "E_BAD_LAYER_COUNT", ... }
--   * 名字/标量被截断     -> { code = "E_TRUNCATED", ... }（来自 reader）
function layers.parse(r, version, layer_count)
  -- 不可信计数守卫。必须在循环之前、以及在任何数组按 `layer_count` 分配之前运行：
  -- 如果调用方承诺的记录数多于描述它们所需的剩余字节（每条记录至少要
  -- MIN_RECORD_BYTES，尤其至少要 1 个字节），这个计数就是不可能的。
  local remaining = r:remaining()
  if layer_count > remaining then
    error({
      code = "E_BAD_LAYER_COUNT",
      msg = string.format(
        "layer_count %d exceeds the %d byte(s) remaining for the section",
        layer_count, remaining),
      layer_count = layer_count,
      remaining = remaining,
    }, 0)
  end

  local result = {}
  local index = 1
  while index <= layer_count do
    local name = r:read_string()

    local lock = nil
    if version >= 4 then
      lock = r:u8()
    end

    local volume = r:u8()

    local panning = nil
    if version >= 2 then
      panning = r:u8()
    end

    result[index] = {
      name = name,
      lock = lock,
      volume = volume,
      panning = panning,
    }
    index = index + 1
  end

  return result
end

-- ---------------------------------------------------------------------------
-- lock 字节到底是什么意思（它是**静音/solo 开关**，不是编辑权限）
-- ---------------------------------------------------------------------------
-- NBS 规范把这个字节叫作 "Layer lock"，只写了「1 = locked」，读起来像是编辑器里的
-- 便捷功能。OpenNBS 项目自己的 issue 更正了这一点
-- （OpenNBS/NoteBlockStudio#307）：
--
--   "The 'Layer lock' field, originally intended to be a boolean, may actually
--    assume values 0-2 (0= unlocked, 1=locked, 2=solo). This is currently
--    undocumented in the NBS specification..."
--
-- 同一条帖子里的开发者说，这个字段就是人们用来「把没写完的段落静音、或把某些图层
-- 单独挑出来听」的东西。
--
-- 决定性的论据是 **SOLO**：值为 2 是一个**播放**概念，而 solo 不可能没有对应的
-- mute。所以 1 是静音，忽略它的播放器会把作者**故意静掉**的声音播出来。在一首真实
-- 歌曲上实测（THE KING.nbs，65 层）：3 个图层带着 lock=1、共 903 个音符，**全部**都
-- 被播了出来。
--
-- 规则就住在这里、紧挨着读这个字节的代码，是因为有**两个模块**需要它，且它们必须
-- 一致：player/plan.lua 决定哪些音符变成事件，nbs/analyze.lua 预测那些事件需要几个
-- 扬声器。两者一旦不一致，分析就会为一个永远不会播的音符规划扇出。

-- 这个字节可以取的三个值。
layers.UNLOCKED = 0
layers.MUTED = 1
layers.SOLO = 2

-- layers.any_solo(layer_array) -> boolean
--
-- 当歌曲里**任何**图层是 solo 时为真。某个图层上的 solo 会让所有非 solo 图层静音，
-- 所以这是**歌曲**的属性、不是某个图层的属性，而且必须在判断任何单个音符之前就
-- 知道。
function layers.any_solo(layer_array)
  if type(layer_array) ~= "table" then
    return false
  end
  for index = 1, #layer_array do
    local record = layer_array[index]
    if type(record) == "table" and record.lock == layers.SOLO then
      return true
    end
  end
  return false
end

-- layers.audible(lock, any_solo) -> boolean
--
-- 带着这个 lock 字节的图层是否贡献音符。
--
--   lock 为 nil   v0-v3 文件根本没有 lock 字节，所以 nil **必须**读作「未静音」；
--                 把它当作真值会把所有老歌都静音
--   lock = 0      未锁：会播，除非别的图层是 solo
--   lock = 1      **静音**：永不播
--   lock = 2      **SOLO**：会播，并让所有非 solo 图层静音
--
-- 写成函数而不是行内表达式，是因为这条规则有四种情况，而行内版本恰恰是下一个读代码
-- 的人最容易搞错的地方。
function layers.audible(lock, any_solo)
  if any_solo then
    -- solo 会让一切**不是** solo 的东西静音——包括普通的未锁图层，也因此包括已静音
    -- 的图层。
    return lock == layers.SOLO
  end
  return lock ~= layers.MUTED
end

-- layers.audible_at(layer_array, any_solo, layer_index) -> boolean
--
-- 对音符记录里那个 **0 起算**的 layer_index 做同样的判定。layer_array 是 1 起算的，
-- 所以图层 L 是 layer_array[L + 1]。引用的图层如果解码后的歌曲里不存在，它就没有
-- lock 字节，于是按**未锁**判定——这保持了既有的「缺失图层照样发声」契约，并且在
-- solo 下会正确地让它保持静音，因为它自己不是 solo。
function layers.audible_at(layer_array, any_solo, layer_index)
  if type(layer_index) ~= "number" then
    return true
  end
  local record = nil
  if type(layer_array) == "table" then
    record = layer_array[layer_index + 1]
  end
  local lock = nil
  if type(record) == "table" then
    lock = record.lock
  end
  return layers.audible(lock, any_solo)
end

return layers
