-- SPDX-License-Identifier: MIT
-- Copyright (C) 2026 colorgarden
-- CCNBSLib 的一部分。以 MIT 授权；见 LICENSE。
--
-- nbsplay.lua
--
-- 最小播放器：一个 URL、一首歌、一条进度条。
--
--     nbsplay <url>
--
-- `<url>` 是指向 `.nbs` 文件的**直链**。这里没有播放列表、不扫描本地文件、也不
-- 搜索——解析与调度都由库负责，本文件存在的意义只有：取回一首歌、交给库、显示它
-- 播到哪儿了。
--
-- ===========================================================================
-- 为什么下载要分块流式读，而不是一次阻塞调用
-- ===========================================================================
-- `http.get` 返回的 handle 可以分次读取，响应通常也会声明 Content-Length。分块读
-- 而不是一次 `read("*a")`，只多两行代码，却能把「几百 KiB 正在传输」这段干等的
-- 终端换成真实的下载百分比。
--
-- ===========================================================================
-- 为什么它建立在 `ccnbs` 之上，而不是自带解析器
-- ===========================================================================
-- 解析、分析、调度、扬声器路由——每一个字节都属于库。本文件只管三件事：拉取、
-- 画进度条、退出时安全地停掉扬声器。只要它重新实现了流水线的任何一部分，CLI 与库
-- 就会开始漂移。
--
-- 兼容性：Lua 5.2 / CC:Tweaked Cobalt。不用整除、不用位运算、不用 utf8.*、不用
-- collectgarbage、不用 string.dump、不用 os.exit。所有 CC 全局都是**惰性**读取的，
-- 所以本文件在桌面版普通 Lua 里也能 `require`，它的纯函数部分可以单元测试。

local cli = {}

cli.VERSION = "1.0.0"

-- 读取一个 CC 全局，但不让它变成加载期依赖。
local function raw_global(name)
  local ok, value = pcall(rawget, _G, name)
  if ok then
    return value
  end
  return nil
end

-- 前向声明，不在这里定义。`cli.choose_out_of_range` 会用到它，而 Lua 在**编译期**
-- 按词法解析名字——所以如果 `local function read_seam` 声明在更下面，上面那处引用
-- 就会变成一次 GLOBAL 查找，结果是 nil，交互菜单一旦走到那里就会抛错。本项目历史上
-- 有两个 bug 正是这个形状（`terminal` 和 `log`）。
local read_seam

-- `try(ok, value)` 解包一次受保护调用。写成带字面量名字的 `pcall(require, "x")`，
-- 这样依赖扫描工具能看见它。
local function try(ok, value)
  if ok and type(value) == "table" then
    return value
  end
  return nil
end

-- 默认值。写成 `pcall(require, "字面量")` 是为了让依赖扫描能看见它们，并保存在
-- local 变量里，好让下面的接缝访问器覆盖——一条无法从测试驱动的流水线只有编译期的
-- 保证，这里堵上的就是这个缺口。
local default_ccnbs = try(pcall(require, "ccnbslib"))
local default_runtime = try(pcall(require, "player.runtime"))
local default_clock = try(pcall(require, "player.clock"))

-- ---------------------------------------------------------------------------
-- 纯函数部分 —— 规格驱动测试针对的正是它们，因为这里的错误是**静默**的
-- （进度条永远填不满、时钟永远显示 0:00）
-- ---------------------------------------------------------------------------

-- 四种越界策略，每条附一句用户做选择时需要的话。**值**归库所有
-- （player/mapping.lua）；这张表只管**措辞**，因为呈现选项是 CLI 的职责，而库
-- 从不写句子。
cli.OUT_OF_RANGE_CHOICES = {
  {
    value = "shift",
    label = "shift        -- play a different RECORDING, two octaves up/down",
    note = "correct pitch, but the client needs the extranotes resource pack",
  },
  {
    value = "passthrough",
    label = "passthrough  -- send the raw pitch and let the client flatten it",
    note = "always audible, but everything beyond one octave becomes the edge note",
  },
  {
    value = "clamp",
    label = "clamp        -- flatten it ourselves to the native range",
    note = "predictable and in range, but the pitch is still wrong",
  },
  {
    value = "drop",
    label = "drop         -- do not play the note at all",
    note = "nothing is heard, and the note costs no speaker slot",
  },
}

-- cli.usage() -> 用户用错时看到的那几行。
function cli.usage()
  return "usage: nbsplay [--debug] [--policy <name>] [-f] <url>",
    "  <url> is a direct link to a .nbs file",
    "  --policy " .. table.concat(cli.policy_names(), "|")
      .. "  how to play notes outside the native range",
    "           (default: ask, unless there are none)",
    "  -f, --force   play even if there are too few speakers (drops notes)",
    "  --debug  writes " .. cli.LOG_PATH,
    "  during playback, click the progress bar's row to seek (advanced computers)"
  end

-- cli.parse_url(argv) -> url | nil, error
--
-- **第一个**看起来像 URL 的参数胜出，所以一个走失的 flag 不会被误当成 URL。不是
-- http/https 的一律在这里拒绝、而不是去拉取，因为一个笔误只该换来一条消息，而不是
-- 一次网络往返。
function cli.parse_url(argv)
  if type(argv) ~= "table" then
    return nil, "no arguments"
  end
  for index = 1, #argv do
    local value = argv[index]
    if type(value) == "string" then
      if value:match("^https?://%S+$") then
        return value, nil
      end
    end
  end
  return nil, "no http:// or https:// URL given"
end

-- 原生 key 范围：库若暴露了就取自库，否则退回 NBS 自己文档里的边界。读取而非硬编码，
-- 这样 CLI 就不会与真正决定「什么算在范围内」的那份映射漂移。
local function native_range()
  local module_ok, mapping = pcall(require, "player.mapping")
  if module_ok and type(mapping) == "table"
    and type(mapping.NATIVE_MIN_KEY) == "number" then
    return mapping.NATIVE_MIN_KEY, mapping.NATIVE_MAX_KEY
  end
  return 33, 57
end

local function native_bounds()
  local min_key, max_key = native_range()
  return min_key, max_key
end

-- cli.describe_warning(code, args) -> string
--
-- 库交出来的是**裸码**、从不给句子——这是契约，散文渲染器是随界面一起**故意**删掉的。
-- 所以「把码变成人能据以行动的话」是 CLI 的活，而这里是唯一知道怎么干的地方。
--
-- **纯函数**，所以每条消息都能被规格钉住，不需要真的放一首歌。
function cli.describe_warning(code, args)
  args = type(args) == "table" and args or {}

  if code == "extended-range" then
    -- 同一个码背后有两种成因，给出的建议也不同。高于原生范围时 extranotes 材质包注册
    -- 的是 `_1`；低于时是 `_-1`。库报告的是歌曲的 key；到底哪一端越界，决定了装上
    -- 材质包有没有用。
    local native_min, native_max = native_bounds()
    return string.format(
      "notes reach key %s..%s, outside the native %s..%s -- install the extranotes "
        .. "resource pack to hear them at the right pitch",
      tostring(args.min_key), tostring(args.max_key),
      tostring(native_min), tostring(native_max))
  end
  if code == "speakers" then
    return string.format(
      "not enough speakers: this needs %s, found %s, so %s note(s) were dropped",
      tostring(args.required), tostring(args.found), tostring(args.dropped))
  end
  if code == "tempo-clamp" then
    return "this song's tempo is finer than the 50 ms timer, so some notes land on "
      .. "the nearest tick"
  end
  if code == "notes-dropped" then
    return string.format(
      "%s note(s) were refused by a speaker (max 8 per tick per speaker)",
      tostring(args.count))
  end
  if code == "custom-instrument" then
    return string.format(
      "%s custom-instrument note(s) were skipped -- a speaker can only play the "
        .. "vanilla instruments", tostring(args.count))
  end
  if code == "play-sound-pitch" then
    return "a trumpet note was clamped to the speaker's 0.5..2.0 speed range"
  end

  -- 无法识别的码仍然要被报出来：一条没人提起过的警告，比一条措辞简短的警告更糟。
  return "warning: " .. tostring(code)
end

-- cli.choose_out_of_range(opts, probe, say, emit) -> policy string
--
-- **交互式选择**，以及它存在的理由：一个超出自身录音八度的音符没有唯一正解。播一份
-- 偏移录音音高是对的，但需要材质包；原样透传一定能听见，但客户端会把它压平；夹取
-- 可预期却是错的；丢弃就是静音。只有用户知道自己想要哪个，所以去问用户。
--
-- `probe` 是用 PASSTHROUGH 算出来的分析，所以报告的 key 范围始终是歌曲自身的，
-- 与之后的任何选择无关。
--
-- **任何非答案都退回 SHIFT**，也就是库自己的默认值。空行、读不进来的输入、或一个
-- 笔误，都不该中断用户主动要求的播放——安装器的镜像菜单用的也是同一套理由。
function cli.choose_out_of_range(opts, probe, say, emit, prompt)
  local min_key, max_key = native_bounds()

  emit("")
  say(string.format(
    "this song reaches keys %s..%s; the native range is %s..%s",
    tostring(probe.min_key), tostring(probe.max_key),
    tostring(min_key), tostring(max_key)))
  say("how should notes outside it be played?")
  emit("")

  for index = 1, #cli.OUT_OF_RANGE_CHOICES do
    local choice = cli.OUT_OF_RANGE_CHOICES[index]
    emit(string.format("nbsplay:   %d) %s", index, choice.label))
    emit(string.format("nbsplay:        %s", choice.note))
  end
  emit("")

  -- 提示语由**我们自己写出**，`read` 则裸调用。
  --
  -- `read` 的第一个参数是**替换字符**，不是提示语，所以旧代码
  -- `read("choose 1-4 (blank = shift): ")` **不显示**任何提示，并且把每次按键都
  -- 回显成字母 "c"——那个字符串的第一个字符。两个看得见的症状，同一个成因。
  if type(prompt) == "function" then
    prompt("choose 1-4 (blank = shift): ")
  end
  local answer = read_seam(opts)
  if type(answer) ~= "string" then
    say("nothing was read, so shift is used")
    return "shift"
  end

  local trimmed = answer:gsub("%s", "")
  if trimmed == "" then
    say("using shift")
    return "shift"
  end

  local pick = tonumber(trimmed)
  if pick == nil or pick ~= math.floor(pick)
    or pick < 1 or pick > #cli.OUT_OF_RANGE_CHOICES then
    say("not a listed number, so shift is used")
    return "shift"
  end

  local chosen = cli.OUT_OF_RANGE_CHOICES[pick].value
  say("using " .. chosen)
  return chosen
end

-- cli.parse_argv(argv) -> url | nil, debug, error
--
-- 与 parse_url 分开，是为了让 URL 规则保持被测过的样子：flag 在这里被**摘掉**，
-- 而不是在 URL 匹配器内部被容忍，这样将来新增的任何 flag 都无法悄悄改变「什么算
-- URL」。
-- cli.parse_argv(argv) -> url | nil, debug, policy | nil, error
--
-- flag 可以出现在任意位置。`--policy <name>` 会**跳过**交互式越界菜单，因为无人值守
-- 的调用方——启动文件、脚本——无法回答它。交互式仍是默认，因为这个选择真的取决于
-- 听者有没有材质包、以及他们更愿意听什么。
--
-- 未知的策略名一律拒绝而不是忽略：静默回退会用一种不同于所求的方式播放歌曲。
function cli.parse_argv(argv)
  local debug = false
  local policy = nil
  local force = false
  local rest = {}

  if type(argv) == "table" then
    local index = 1
    while index <= #argv do
      local value = argv[index]
      if value == "--debug" or value == "-debug" or value == "-D" then
        debug = true
        index = index + 1
      elseif value == "--force" or value == "-f" then
        -- 即使扬声器装不下整首歌也照播。用户一旦看见了数字，丢音符就是他们的决定；
        -- 这就是他们做决定的方式。
        force = true
        index = index + 1
      elseif value == "--policy" then
        local name = argv[index + 1]
        if type(name) ~= "string" or not cli.is_policy(name) then
          return nil, debug, nil, false,
            "--policy needs one of: " .. table.concat(cli.policy_names(), ", ")
        end
        policy = name
        index = index + 2
      elseif type(value) == "string" and value:sub(1, 8) == "--policy" then
        -- "=form" 形式：--policy=shift
        local name = value:sub(10)
        if not cli.is_policy(name) then
          return nil, debug, nil, false,
            "--policy needs one of: " .. table.concat(cli.policy_names(), ", ")
        end
        policy = name
        index = index + 1
      else
        rest[#rest + 1] = value
        index = index + 1
      end
    end
  end

  local url, err = cli.parse_url(rest)
  return url, debug, policy, force, err
end

-- cli.policy_names() -> 被接受的策略名，按菜单顺序。
function cli.policy_names()
  local names = {}
  for index = 1, #cli.OUT_OF_RANGE_CHOICES do
    names[index] = cli.OUT_OF_RANGE_CHOICES[index].value
  end
  return names
end

-- cli.is_policy(value) -> boolean
function cli.is_policy(value)
  if type(value) ~= "string" then
    return false
  end
  for index = 1, #cli.OUT_OF_RANGE_CHOICES do
    if cli.OUT_OF_RANGE_CHOICES[index].value == value then
      return true
    end
  end
  return false
end

-- cli.format_time(ms) -> "M:SS"，夹到零，并容忍无意义输入。
function cli.format_time(ms)
  local value = tonumber(ms) or 0
  if value < 0 then
    value = 0
  end
  local seconds = math.floor(value / 1000)
  local minutes = math.floor(seconds / 60)
  return string.format("%d:%02d", minutes, seconds - minutes * 60)
end

-- cli.render_bar(frac, width) -> 恰好 `width` 个字符的字符串。
--
-- 调用方把它画进自己的方括号之间；本函数只产格子，所以这段算术不需要终端就能断言。
-- 非数值或越界的比例会被夹取——一根溢出自身宽度的进度条是**渲染** bug，看起来却像
-- **进度** bug。
function cli.render_bar(frac, width)
  local cells = math.floor(tonumber(width) or 0)
  if cells < 1 then
    return ""
  end
  local value = tonumber(frac) or 0
  if value < 0 then
    value = 0
  elseif value > 1 then
    value = 1
  end
  local filled = math.floor(value * cells + 0.5)
  if filled > cells then
    filled = cells
  end
  return string.rep("#", filled) .. string.rep("-", cells - filled)
end

-- cli.percent(frac) -> 0..100 的整数，用于进度条旁边的标签。
function cli.percent(frac)
  local value = tonumber(frac) or 0
  if value < 0 then
    value = 0
  elseif value > 1 then
    value = 1
  end
  return math.floor(value * 100 + 0.5)
end

-- `terminal` 在下面与其他接缝一起定义；它在这里**前向声明**，因为 progress_line
-- 会读它，而 Lua 在**编译期**按词法解析 local——一个更靠后的 `local function`
-- 会让这里变成一次全局查找，结果是 nil。
local terminal

-- cli.speaker_count(n) -> "<n> speaker" / "<n> speakers"。
-- 裸的 "%d speaker(s)" 就是那种永远不会被清理的东西，所以它是个函数，因而可测。
function cli.speaker_count(count)
  local number = tonumber(count) or 0
  if number < 0 then
    number = 0
  end
  if number == 1 then
    return "1 speaker"
  end
  return tostring(number) .. " speakers"
end

-- cli.display_width(text) -> text 占用的**列数**
--
-- 不是字符数：在 CC:T 终端上一个 CJK 字形占**两格**。按字符计数会让一行中文通过宽度
-- 检查、随后被裁掉——这正是本函数要防的失败——而歌曲名与图层名经常是 CJK，所以这
-- 不是假设出来的情形。
--
-- 判定用的是常见宽字符区间（CJK 与全角形式），而不是一整张 Unicode East Asian Width
-- 表：一个跑在 1 MB 电脑磁盘上的 Lua 模块不该放那种东西，而且 .nbs 文件携带的一切
-- 无非是 ASCII、CP1252 或那个区间。
function cli.display_width(text)
  local value = tostring(text or "")
  local columns = 0
  for index = 1, #value do
    local byte = value:byte(index)
    if byte < 0x80 then
      columns = columns + 1
    elseif byte >= 0xE0 and byte <= 0xEF then
      -- 三字节 UTF-8 序列：一个字符，两列。
      columns = columns + 2
    elseif byte >= 0x80 and byte < 0xC0 then
      -- 一个**续接字节**，已经随它的首字节一起计过。
      columns = columns + 0
    else
      -- 两字节或四字节序列：算一列，这对拉丁/希腊/西里尔字母是对的，在 BMP 之外
      -- 也够用。
      columns = columns + 1
    end
  end
  return columns
end

-- cli.wrap_text(text, width) -> 行数组
--
-- `term.write` **不折行**。AGENTS.md 第 3 节记录了那次实测，而 `TextBuffer.write`
-- 会对越过右边缘的部分做边界检查，于是溢出的内容干脆**消失**。所以一个 51 列的终端上
-- 一条 77 字符的菜单会读成 "…-- play a different RECO"，用户根本无从得知选项是什么。
--
-- 所以 CLI 自己折行：
--   * 尽量在**空格**处折，让句子保持可读；
--   * 单词比整行还长时**硬折**——URL 或音效名里没有空格，溢出就会被裁掉，而那正是
--     要修掉的失败；
--   * 已有的 "\n" 开始新的一行；
--   * 非正宽度绝不会死循环：退回一列。
function cli.wrap_text(text, width)
  local limit = tonumber(width) or 0
  if limit < 1 then
    limit = 1
  end

  local source = tostring(text or "")
  local out = {}

  -- 先按换行拆：一个显式的换行就是一次换行。
  for paragraph in (source .. "\n"):gmatch("([^\n]*)\n") do
    -- 顺带处理 CR，这样用 CRLF 拼出来的消息不会带着一个多余字符。
    paragraph = paragraph:gsub("\r", "")

    if cli.display_width(paragraph) <= limit then
      out[#out + 1] = paragraph
    else
      local line = ""
      for word in paragraph:gmatch("%S+") do
        local separator = (#line > 0) and " " or ""
        local candidate = line .. separator .. word

        if cli.display_width(candidate) <= limit then
          line = candidate
        else
          if #line > 0 then
            out[#out + 1] = line
            line = ""
          end

          -- 这个单词单独拿出来可能仍然太长：按字符把它拆开。
          while cli.display_width(word) > limit do
            local piece = ""
            local consumed = 0
            for index = 1, #word do
              local char = word:sub(index, index)
              if cli.display_width(piece .. char) > limit then
                break
              end
              piece = piece .. char
              consumed = index
            end

            if consumed == 0 then
              -- 单个字符比整行还宽。把它单独吐出，而不是永远转下去；裁掉一个字符好过
              -- 卡死。
              out[#out + 1] = word:sub(1, 1)
              word = word:sub(2)
            else
              out[#out + 1] = piece
              word = word:sub(consumed + 1)
            end
          end

          line = word
        end
      end
      if #line > 0 then
        out[#out + 1] = line
      end
    end
  end

  if #out == 0 then
    out[1] = ""
  end
  return out
end

-- cli.progress_line(label, frac, extras, columns) -> 一条**装得下**的行。
--
-- 除了在未给出 `columns` 时读取终端尺寸之外，它是**纯函数**，所以这段算术不需要终端
-- 就能断言。
--
-- 这一行被刻意保持**严格短于**终端，好让任何东西都不被**裁掉**。`term.write` 不折行
-- （实测：写完 width + 5 个字符后行没变、光标停在 57 列）——文本只是直接越过右边缘，
-- 而 TextBuffer.write 会做边界检查，于是它丢失了，但不致命。所以「装得下」要解决的是
-- 不丢字符，这在这里很重要，因为百分比和时钟正是这一行的重点。
--
-- 进度条和百分比永远不会被丢掉，因为它们**就是**进度。`extras` 是按优先级排列的尾部
-- 片段（最重要的在前），会从末尾开始逐个丢弃直到这一行装得下。如果连一小段进度条都
-- 装不下，就退化成只有百分比，而标签只在万不得已时才缩短。
function cli.progress_line(label, frac, extras, columns)
  local text = tostring(label or "")
  local width = tonumber(columns)

  if width == nil then
    width = 51
    local term = terminal()
    if type(term) == "table" and type(term.getSize) == "function" then
      local ok, value = pcall(term.getSize)
      if ok and type(value) == "number" then
        width = value
      end
    end
  end

  local fragments = {}
  if type(extras) == "table" then
    for index = 1, #extras do
      if type(extras[index]) == "string" then
        fragments[#fragments + 1] = extras[index]
      end
    end
  end

  -- 最长的在前，这样被采用的版本是装得下的最有信息量的那个。
  for count = #fragments, 0, -1 do
    local tail = table.concat(fragments, "", 1, count)
    -- 固定字符要**一项一项**去数，而不是当成一个总数。这里差一位曾经错了两回，而后果
    -- 是字符被静默地从右边缘丢出去——所以宁可把它写清楚，也不靠「应该没错」：
    --
    --   " ["      2   进度条之前
    --   "] "      2   进度条之后
    --   "100%"    4   `%3d%%` 对 0 到 999 的每个值都是四个字符
    --   tail      #tail
    local fixed = 2 + 2 + 4 + #tail
    local room = width - 1 - #text - fixed
    if room >= 4 then
      return text .. " [" .. cli.render_bar(frac, room) .. "] "
        .. string.format("%3d%%", cli.percent(frac)) .. tail
    end
  end

  -- 什么都装不下：只有百分比也仍然告诉用户有事在发生，若连它都会溢出，就缩短标签。
  local bare = string.format("%3d%%", cli.percent(frac))
  local room = width - 2 - #bare
  if room < 0 then
    room = 0
  end
  local name = text
  if #name > room then
    name = name:sub(1, room)
  end
  if name == "" then
    return bare
  end
  return name .. " " .. bare
end

-- cli.bar_row(frac, columns) -> 一条**恰好占满整行**的进度条，含方括号。
--
-- 与 cli.progress_line 的区别在于它**独处一行**：没有标签、没有百分比、没有尾随片段。
-- 方括号把进度条与空白区分开来——当进度为 0 时整条都是 `-`，没有括号就看不出进度条
-- 的范围到哪里为止。
--
-- 内部委托给 cli.render_bar，而不是自己拼一遍 `#`/`-`：那套钳制逻辑（frac 越界、非数字
-- 输入、宽度为 0）已经被 render_bar 的测试钉住了，抄第二遍只会多一个会腐烂的副本。
function cli.bar_row(frac, columns)
  local width = tonumber(columns) or 51
  if width < 3 then
    width = 3
  end
  return "[" .. cli.render_bar(frac, width - 2) .. "]"
end

-- 暂停按钮的两段文案，画在**进度条底下那一行的行首**。
--
-- 纯 ASCII 且都以 `[` 开头：按钮占几列必须等于 `#label`，点击命中区域才与看到的东西
-- 对齐——中文按 1 列算会错位、按 2 列算会让命中宽度与字符串长度说的不是一回事
-- （cli.display_width 就是为这种场合存在的，但按钮不需要那份复杂度）。
cli.PAUSE_LABEL = "[Pause]"
cli.RESUME_LABEL = "[Resume]"

-- cli.button_label(paused) -> 当前该画的按钮文案。
function cli.button_label(paused)
  if paused then
    return cli.RESUME_LABEL
  end
  return cli.PAUSE_LABEL
end

-- cli.hits_button(x, paused) -> 列号 x 是否落在按钮上。
--
-- 按钮只占行首那几列；同一行其余部分是空白，点了必须**什么都不发生**——把整行都
-- 当成按钮会让「点了一下按钮右边」变成暂停，而屏幕上那里什么都没有。
function cli.hits_button(x, paused)
  local column = tonumber(x)
  if column == nil or column < 1 then
    return false
  end
  return column <= #cli.button_label(paused)
end

-- cli.playback_position(base_ms, anchor_ms, now_ms, duration_ms) -> number
--
-- 播放位置（毫秒）= 锚点位置 + 从锚点起流逝的时间，夹在 [0, duration_ms] 之内。
--
-- **为什么需要它。** 进度条与时间原来只在 `on_progress` 里更新，而那个回调是**事件驱动**
-- 的——只有派发一个音符时才触发。于是长音或休止（几秒没有事件）期间，进度条与时间**完全
-- 不动**，然后在下一个音符处猛地跳一格；看起来就像它们「和 note 进度绑定」。位置改由
-- **时钟**推导之后，刷新频率就与音符密度无关了。
--
-- 锚点在播放开始或一次 seek 时设定，所以同一个公式覆盖了两种情况。
--
-- 纯函数，所以这段算术不需要终端、时钟或歌曲就能钉住。
function cli.playback_position(base_ms, anchor_ms, now_ms, duration_ms)
  local base = tonumber(base_ms) or 0
  local anchor = tonumber(anchor_ms) or 0
  local now = tonumber(now_ms) or 0
  local duration = tonumber(duration_ms) or 0

  local position = base + (now - anchor)
  if position < 0 then
    position = 0
  end
  if duration > 0 and position > duration then
    position = duration
  end
  return position
end

-- cli.click_fraction(x, columns) -> 0..1
--
-- 把点击的**列号**映射成进度。进度条占满整行（见 cli.bar_row），所以列号本身**就是**
-- 进度轴：第 1 列 = 0，最后一列 = 1，中间线性——不需要知道进度条的内部几何。
--
-- 纯函数，钳制越界列；宽度 <= 1 时返回 0（没有可映射的跨度，而不是除零）。
function cli.click_fraction(x, columns)
  local width = tonumber(columns)
  local column = tonumber(x)
  if width == nil or column == nil or width <= 1 then
    return 0
  end
  local fraction = (column - 1) / (width - 1)
  if fraction < 0 then
    return 0
  end
  if fraction > 1 then
    return 1
  end
  return fraction
end

-- cli.duration_ms(events) -> 歌曲长度（毫秒），取自最后一个事件。
function cli.duration_ms(events)
  if type(events) ~= "table" or #events == 0 then
    return 0
  end
  local last = events[#events]
  local value = type(last) == "table" and tonumber(last.t_ms) or nil
  if value == nil or value < 0 then
    return 0
  end
  return value
end

-- ---------------------------------------------------------------------------
-- 默认接缝 —— 由规格注入，在这里惰性读取
-- ---------------------------------------------------------------------------

local seams = {}

function cli.configure(opts)
  if type(opts) ~= "table" then
    seams = {}
    return cli
  end
  seams = opts
  return cli
end

local function http_api()
  return seams.http or raw_global("http")
end

terminal = function()
  return seams.term or raw_global("term")
end

-- library() -> ccnbslib 表，注入的或真实的那份。run() 里**每一处**使用都走这里，
-- 所以测试可以喂一个假库：没有扬声器、没有时钟、不用等待，整条路径都变得可断言。
local function library()
  if type(seams.ccnbs) == "table" then
    return seams.ccnbs
  end
  return default_ccnbs
end

-- runtime_module() -> player.runtime，注入的或真实的那份。
local function runtime_module()
  if type(seams.runtime) == "table" then
    return seams.runtime
  end
  return default_runtime
end

-- current_clock() -> 为播放计时的那个时钟。
--
-- 时钟必须被**泵动**，不是交出去就算完。`after()` 只是装上定时器；回调只有在有人把
-- `timer` 事件取出来、派发对应 handle 时才会跑。
--
-- 做这件事的是播放段的循环，用 **`pull_once()`** 而不是 `run_due()`：后者内部是
-- `os.pullEvent("timer")`，而带过滤的 pullEvent 会把不匹配的事件（点击）**丢掉**
-- ——见 player/clock.lua 的 pull_once 说明。
--
-- 用 os.sleep 轮询同样**不**可行：os.sleep 会把事件全部拉走并丢弃，直到自己的定时器
-- 触发，于是歌曲的定时器被消费掉、回调从未被调用——静音，却报告为成功。
local function current_clock()
  if type(seams.clock) == "table" then
    return seams.clock
  end
  if default_clock ~= nil and type(default_clock.new_os) == "function" then
    return default_clock.new_os()
  end
  return nil
end

-- read_seam(prompt)：CLI 向用户提问的方式。
--
-- 通过 opts.read 注入，好让测试来回答。一条从未被走过的交互路径，正是 autorun bug
-- 存活下来的原因——写了、从没跑过、静默地错。无法读取时返回 nil，调用方把它当作
-- 「什么也没说」。
read_seam = function(opts)
  if type(opts) == "table" and type(opts.read) == "function" then
    return opts.read()
  end
  local reader = raw_global("read")
  if type(reader) ~= "function" then
    return nil
  end
  -- 不传任何参数。`read` 的第一个参数是**替换字符**（用于隐藏密码），不是提示语——
  -- `read([replaceChar [, history [, completeFn [, default]]]])`——而且它只取那个
  -- 字符串的第一个字符。所以按 `read("choose 1-4: ")` 调用时，它什么都不渲染，并且
  -- 把每次按键都回显成字母 "c"，也就是那个「为什么输入 1 显示 c」的 bug。
  --
  -- 根本没有提示语参数可传。提示语必须先被**写出**，这正是 writer 上 `prompt` 的
  -- 用途，也是 CC 自己文档里的做法：`write("> "); local msg = read()`。
  local ok, answer = pcall(reader)
  if not ok then
    return nil
  end
  return answer
end

-- ---------------------------------------------------------------------------
-- 输出
-- ---------------------------------------------------------------------------
-- 有一行是**原地重写**而不是追加的，因为一根被追加的进度条就只是一份日志。每一行都
-- 经过 `make_writer` 返回的 writer——或者调用方提供 `opts.write` 时经过它——这样测试
-- 就能捕获到确切的字符串，也让「一行是怎么往下走的」只有一个地方知道。
--
-- 输出只有一种形状
--
--   nbsplay: <status>            一条永久行；光标下移一行
--   nbsplay: E_CODE: <detail>    一次失败；进程非零退出
--   <bar>  <pct>  <detail>       一条实时行，原地刷新
--   usage: ...                   帮助文本，无前缀
--
-- 永久行永远不会被覆盖：光标会越过它往下走，所以它留了下来。实时行在同一行上重画，
-- 所以进度条是动的，而不是把它走过的每一步都填满屏幕。
--
-- 「下移一行」**不是** `term.write("\n")`，后者根本做不到这件事——实测见 `make_writer`
-- 上的长注释。
--
-- **每一条失败路径都打印 `E_CODE: detail`。** 本项目的约定是：机器可读的输出是**裸码**，
-- 措辞由调用方负责——库返回 `{code = "E_..."}`、从不返回句子。CLI 遵循同一条规则，这样
-- 脚本可以按码分支，码也稳定到足以断言。全部 ASCII，全部可 grep：
--
--   E_USAGE          命令行上没有可用的 URL
--   E_NO_LIBRARY     ccnbslib.lua 没有安装
--   E_HTTP_DISABLED  这台电脑没有 http API
--   E_HTTP           请求本身失败；后面跟着 CC 自己的原因，例如
--                    `E_HTTP: Domain not permitted` 或 `E_HTTP: Not Found`
--   E_DOWNLOAD       读取响应途中失败
--   E_EMPTY          服务器什么也没返回
--   E_DECODE         库拒绝了这些字节（后面跟着它的码）
--   E_NO_SPEAKER     没有接上任何 speaker 外设
--   E_NO_CLOCK       player.clock 缺失，或无法被驱动
--   E_CLOCK_FROZEN   时钟不随真实时间前进
--   E_CLOCK_SCALE    时钟的单位不是真实毫秒
--   E_DISPATCH       时钟提前停了，或某个定时器回调抛了错
--   E_PLAY           库没有返回可用的会话

-- make_writer() -> { line = fn, refresh = fn }
--
-- **两种输出**，把它们混为一谈会毁掉屏幕：
--
--   line(text)     **永久**消息：写一次，然后光标**下移**一行。之后写什么都擦不掉它。
--   refresh(text)  **实时**行，原地重写：光标被留在同一行的行首，所以进度条是动的，
--                  而不是把它走过的每一步都填满屏幕。
--
-- 换行**不是** `term.write("\n")`。在 CraftOS-PC 2.8.3 上**实测**，因为动手写之前
-- 文档与行为必须先对上：
--
--   after write("AAAA")     x=5  y=1
--   after write("\n")       x=6  y=1     <- 行**没有**变
--   after write("BBBB")     x=10 y=1     <- 于是两者都落在第 1 行
--
-- `term.write` 的文档写明它不处理 "line breaks or word wrapping"，TermAPI.java 也一致
-- ——它做的是 `setCursorPos(getCursorX() + text.length(), getCursorY())`。所以经由它
-- 发出的一个 "\n" 会被当作普通字符存下来，只把**列**推进一格。上一个版本每条永久行都以
-- 它结尾，于是每条消息都覆盖了前一条：用户只看到一行——最后那一行。`bios.lua` 自己的
-- `write` 展示了真正该怎么做——setCursorPos(1, y + 1)，或在底部时先
-- setCursorPos(1, height) 再 scroll(1)。
--
-- `term.write` 也**不**折行（实测：写完 width + 5 个字符后光标停在 57 列、行没变）。
-- 越过右边缘的文本会被直接**裁掉**——TextBuffer.write 做边界检查且不抛错——所以进度行
-- 仍然力求**装得下**，但这只是为了不让内容被切掉，**不是**因为长行会让屏幕滚动。它不会。
--
-- clearLine() 清的是**整行**，而不只是光标之后的部分（同样实测过），这正是「先清后写」
-- 是正确组合的原因。
local function make_writer()
  local term = terminal()
  local printer = raw_global("print")

  local function plain(text)
    if type(printer) == "function" then
      printer(tostring(text))
    end
  end

  if type(term) ~= "table" or type(term.write) ~= "function"
    or type(term.getCursorPos) ~= "function"
    or type(term.setCursorPos) ~= "function" then
    -- 没有光标控制，所以 refresh **无法**覆盖：它会每次都变成新的一行。对它什么都不
    -- 打印，能让真实输出保持可读，而永久行仍然承载结果。
    return {
      line = plain,
      wrapped = plain,
      -- 没有光标控制，就没有可供输入的行；`plain` 是错得最少的答案，何况这个分支
      -- 本来也没有交互式读取器。
      prompt = plain,
      refresh = function() end,
      refresh_bar = function() end,
      refresh_button = function() end,
    }
  end

  -- 三条**实时行**固定在屏幕底部，日志区收缩到它们上方：
  --
  --     info_row    = height - 2   信息行（百分比、时间、音符计数）
  --     bar_row     = height - 1   进度条，**独占一行**
  --     button_row  = height       暂停按钮，行首（只在播放期间画）
  --     log_bottom  = height - 3   永久行只能落在 1..log_bottom
  --
  -- 进度条独自占一整行，所以整行就是进度轴：第 1 列 = 0%、最后一列 = 100%。点击映射
  -- 因此不需要知道进度条的几何——见 cli.click_fraction。按钮单独占下面一行，点它与点
  -- 进度条是两件事，靠行号区分。
  local height = 19
  if type(term.getSize) == "function" then
    local ok, _, measured = pcall(term.getSize)
    if ok and type(measured) == "number" and measured > 0 then
      height = measured
    end
  end
  local button_row = height
  local bar_row = height - 1
  local info_row = height - 2
  local log_bottom = height - 3
  if log_bottom < 1 then
    log_bottom = 1
  end
  if info_row < 1 then
    info_row = 1
  end
  if bar_row < 1 then
    bar_row = 1
  end

  -- 第一条永久行写在哪（1 起算）；大于 log_bottom 表示「需要先滚动」。
  --
  -- **从光标的下一行开始，不是从第 1 行、也不覆盖光标所在的那一行。**
  --
  -- 程序启动时屏幕上往往已经有内容：`wget run` 留下了 shell 自己的输出，而用户是在提示符
  -- 后面敲的 `nbsplay <url>`——命令就在光标那一行上。直接 `setCursorPos(1, 1)` 会把它们
  -- 全部压掉（真机上实测到的重叠就是这么来的），而清掉光标那一行又会把用户刚敲的命令擦掉。
  --
  -- 所以：移到下一行；已经在最后一行则先滚动，把已有内容整体推上去。两者都不破坏已有输出。
  local here = 1
  if type(term.getCursorPos) == "function" then
    local ok, _, row = pcall(term.getCursorPos)
    if ok and type(row) == "number" and row > 0 then
      here = row
    end
  end

  local log_row = here + 1
  if log_row > log_bottom then
    -- 没有空行可用了：滚动一行腾出位置。光标先落到可写区的最后一行，再 scroll(1)，
    -- 于是原有内容整体上移一行、而底部空出一行。
    term.setCursorPos(1, log_bottom)
    if type(term.scroll) == "function" then
      term.scroll(1)
    end
    log_row = log_bottom
  end
  term.setCursorPos(1, log_row)
  term.clearLine()

  -- 已经画过实时行吗？清与重画都以它为准，不必每次去读光标位置。
  local live = false

  -- 光标最终必须停在**日志区**，不能停在实时行上；否则下一条永久行会写到实时行上，
  -- 或被下一次 refresh 覆盖。
  local function park_cursor()
    local row = log_row
    if row > log_bottom then
      row = log_bottom
    end
    if row < 1 then
      row = 1
    end
    term.setCursorPos(1, row)
  end

  -- 清掉三条实时行。**必须在任何滚动之前调用**：`term.scroll(1)` 会把整屏内容上移一行，
  -- 若不清，进度条的残影会被带到 info_row 上面去。清掉之后，下一次 refresh 会把它们
  -- 重画回来。
  local function clear_live()
    if not live then
      return
    end
    term.setCursorPos(1, info_row)
    term.clearLine()
    if bar_row ~= info_row then
      term.setCursorPos(1, bar_row)
      term.clearLine()
    end
    if button_row ~= info_row and button_row ~= bar_row then
      term.setCursorPos(1, button_row)
      term.clearLine()
    end
    live = false
  end

  -- 终端有多少列，只测量一次。无法报告自身尺寸的终端，退回 CC:T 的默认值而不是零，
  -- 后者会把每条消息都折成一行一个字符。
  local columns = 51
  if type(term.getSize) == "function" then
    local ok, measured = pcall(term.getSize)
    if ok and type(measured) == "number" and measured > 0 then
      columns = measured
    end
  end

  local function write_line(text)
    -- 先清实时行：一次滚动会把它们拖走。清掉之后，下一次 refresh 会把它们重画回来。
    clear_live()

    -- 在日志区底部还要再要一行时，先把整屏上滚一行。`term.write` 自己**不会**滚动
    -- （Terminal.write 只在当前行内写），所以这一步必须由我们做——它是从 bios.lua 的
    -- `write` 内部那个 `newLine` 辅助函数抄来的，而那是这件事的权威。
    if log_row > log_bottom then
      term.setCursorPos(1, log_bottom)
      if type(term.scroll) == "function" then
        term.scroll(1)
      end
      log_row = log_bottom
    end

    term.setCursorPos(1, log_row)
    term.clearLine()
    term.write(tostring(text))

    if log_row < log_bottom then
      log_row = log_row + 1
    else
      log_row = log_bottom + 1 -- 下一次写入之前需要先滚动
    end
    park_cursor()
  end

  return {
    line = write_line,
    -- 几何：调用方（点击映射）必须与实际画出来的那一行、那一列完全一致，所以由这里
    -- **量一次**并交出去，而不是让调用方再测一次——两次测量之间终端可能已改变尺寸。
    columns = columns,
    bar_row = bar_row,
    -- 一条**折行**到终端的消息。
    --
    -- `term.write` 是裁剪而不是折行，所以任何长过屏幕的内容都会静默地丢掉右端。越界
    -- 菜单证明了这一点：它的行是 77 到 80 个字符，默认终端是 51 列，用户看到的就是
    -- "…-- play a different RECO"，且无从得知选项到底是什么。
    wrapped = function(text)
      local lines = cli.wrap_text(text, columns)
      for index = 1, #lines do
        write_line(lines[index])
      end
    end,
    -- 一条**提示语**：写出来，并把光标**留在这一行**，因为用户就在它后面输入，而 `read`
    -- 从当前位置回显。若下移一行，答案就会落到下一行，提示语则被孤零零留在原地。
    --
    -- 它之所以存在，是因为 `read` 不接受提示语参数——见 read_seam——所以提示语必须由
    -- 我们自己写出。
    prompt = function(text)
      clear_live()
      local row = log_row
      if row > log_bottom then
        row = log_bottom
      end
      term.setCursorPos(1, row)
      term.clearLine()
      term.write(tostring(text))
      -- 用户的回答会占用这一行，所以下一条永久行要写到它下面一行。
      log_row = row + 1
    end,
    -- 信息行（height - 2）。进度百分比、时间与音符计数都在这里。
    refresh = function(text)
      live = true
      term.setCursorPos(1, info_row)
      term.clearLine()
      term.write(tostring(text))
      park_cursor()
    end,
    -- 进度条行（height - 1）。**独占一行、整行都是进度轴**，所以点击任意一列都能直接映射成
    -- 进度——这就是 cli.click_fraction 只用列号的原因。文本由 cli.bar_row 生成，宽度恰好
    -- 等于终端列数。
    refresh_bar = function(text)
      live = true
      term.setCursorPos(1, bar_row)
      term.clearLine()
      term.write(tostring(text))
      park_cursor()
    end,
    -- 暂停按钮行（height，最底下一行）。只有行首那几列是按钮（见 cli.hits_button），
    -- 所以画的是标签本身、不是一条填满整行的东西。
    refresh_button = function(text)
      live = true
      term.setCursorPos(1, button_row)
      term.clearLine()
      term.write(tostring(text))
      park_cursor()
    end,
    button_row = button_row,
  }
end

-- ---------------------------------------------------------------------------
-- 拉取
-- ---------------------------------------------------------------------------

-- cli.fetch(url, on_progress) -> body | nil, code, detail
--
-- 分块读取，好让调用方显示百分比。没有 Content-Length 的响应只是「没有总数」地上报
-- 进度，这就是 `on_progress` 收到 `(received, total)`、而 total 可以为 nil 的原因。
--
-- **这个 handle 的方法不接收 `self`——必须用点号调用。**
--
-- CC:Tweaked 在**没有** self 参数的 Java 方法上以 @LuaFunction 注册它们
-- （HttpResponseHandle.java），ROM 自己的例子就是 `request.readAll()`。在 CraftOS-PC
-- 上对着一个 **FILE** handle 实测过——响应 handle 的 javadoc 说它与文件 handle 共用
-- 方法，走的是同一套机制：
--
--     h.read(5)      -> "01234"   五个字符                -- 正确
--     h.read(h, 5)   -> "0"       table 变成了 count      -- 错误
--
-- 所以把 handle 传回去，会让 `read` 在一个本该是数字的位置收到一张表。在真实
-- CC:Tweaked 上这会抛错，调用方看到的就是一次下载失败——而这正是当初反着写时发生的
-- 事情。
function cli.fetch(url, on_progress)
  local api = http_api()
  if type(api) ~= "table" or type(api.get) ~= "function" then
    return nil, "E_HTTP_DISABLED", "HTTP is disabled on this computer"
  end

  -- http.get 在请求失败时**不抛错**——它**返回失败**：
  --
  --     handle                            成功时
  --     nil, message, failing_response    失败时
  --
  -- 而 `pcall` 会把它们每一个都带上，所以 message 落在**第三个**槽位。只捕获第二个
  -- ——`local ok, response = pcall(...)`——是一个真实的缺陷：原因被丢掉，每一次失败
  -- 都报成 "the request failed"，等于什么都没告诉用户。它还会泄漏那个失败响应的
  -- handle，而它是一个必须被关闭的真实 handle。
  --
  -- 在 CraftOS-PC 2.8.3 上**实测**。用 `table.pack` 读取形状，因为 table **构造器**
  -- 会丢掉尾部的 nil，而 `#` 在有空洞时是未定义的——第一次测量因此报了 "1 value"，
  -- 是错的：
  --
  --   success   pcall n=2  true, <response>
  --   404       pcall n=4  true, nil, "Not Found",                      <response>
  --   dead host pcall n=4  true, nil, "SSL connection unexpectedly closed", nil
  --   bad host  pcall n=4  true, nil, "No message received",            nil
  --   bad scheme pcall n=4 true, nil, "Invalid protocol 'gopher'",      nil
  --   malformed pcall n=4  true, nil, "Must specify http or https",     nil
  local ok, response, message, failing = pcall(api.get, url)
  if not ok then
    -- pcall 只有在 http.get 自己抛错时才会失败——例如 Java 侧的 "Too many ongoing
    -- HTTP requests"——这与「请求被拒绝」是两回事，所以分开上报。
    return nil, "E_HTTP", "the request raised: " .. tostring(response)
  end
  if response == nil then
    -- 失败的响应仍然是一个 **handle**（404 的情况下会返回一个），所以在这里关掉而不是
    -- 泄漏——CC 对打开的文件数量有上限。
    if type(failing) == "table" and type(failing.close) == "function" then
      pcall(failing.close)
    end
    local reason = message
    if type(reason) ~= "string" or reason == "" then
      reason = "the request failed"
    end
    return nil, "E_HTTP", reason
  end

  local total = nil
  if type(response.getResponseHeaders) == "function" then
    local headers_ok, headers = pcall(response.getResponseHeaders)
    if headers_ok and type(headers) == "table" then
      total = tonumber(headers["Content-Length"] or headers["content-length"])
    end
  end

  local chunks = {}
  local received = 0
  while true do
    local read_ok, chunk = pcall(response.read, 8192)
    if not read_ok then
      pcall(response.close)
      return nil, "E_DOWNLOAD", "the download was interrupted"
    end
    if chunk == nil or chunk == "" then
      break
    end
    chunks[#chunks + 1] = chunk
    received = received + #chunk
    if type(on_progress) == "function" then
      pcall(on_progress, received, total)
    end
  end
  pcall(response.close)

  local body = table.concat(chunks)
  if #body == 0 then
    return nil, "E_EMPTY", "the server returned nothing"
  end
  return body
end

-- ---------------------------------------------------------------------------
-- 调试日志
-- ---------------------------------------------------------------------------
-- 除非给了 --debug，否则**关闭**；失败时也保持沉默：一个把被诊断的程序搞崩的诊断，
-- 比没有诊断更糟。写文件用 file:write，在那里 "\n" **就是**换行——不像 term.write，
-- 后者把它当作普通字符存下来（见 make_writer）。
cli.LOG_PATH = "nbsplay-debug.log"

-- cli.describe_argv(argv) -> 一行可读的文本，写进日志。
function cli.describe_argv(argv)
  if type(argv) ~= "table" then
    return "(" .. type(argv) .. ")"
  end
  local parts = {}
  for index = 1, #argv do
    parts[#parts + 1] = tostring(argv[index])
  end
  return #parts .. " arg(s): " .. table.concat(parts, " ")
end

-- make_logger(enabled, path) -> log, close
--
-- 关闭时返回一个空操作 logger，这样调用方永远不必为「日志是否开着」而分支。
local function make_logger(enabled, path, term)
  if not enabled then
    local function noop() end
    return noop, noop
  end

  local file = nil
  if type(fs) == "table" and type(fs.open) == "function" then
    local ok, handle = pcall(fs.open, path, "w")
    if ok and handle ~= nil then
      file = handle
    end
  end

  local lines = {}
  -- 点号调用，不传 self。CC:Tweaked 把 handle 的方法注册在**没有** `self` 参数的 Java
  -- 方法上（AGENTS.md 第 3 节），所以 `file.write(file, text)` 会把 handle 当作 text
  -- 交出去。这正是这个 logger 曾经建了日志文件、却让它停在 0 字节的原因：打开成功了
  -- （fs 是 API 表，所以 fs.open(path, mode) 是对的），而每一次写入都在 pcall 里默默
  -- 失败。
  local write_failed = nil

  local function log(text)
    local line = tostring(text)
    lines[#lines + 1] = line
    if file == nil then
      return
    end
    local ok, err = pcall(file.write, line .. "\n")
    if not ok then
      write_failed = tostring(err)
      return
    end
    if type(file.flush) == "function" then
      pcall(file.flush)
    end
  end

  -- 一个写不进去的 logger 值得被知道，好让调用方把它说出来，而不是交回一个空文件。
  local function why_empty()
    if file == nil then
      return "the log file could not be opened"
    end
    if write_failed ~= nil then
      return "writing to the log failed: " .. write_failed
    end
    if #lines == 0 then
      return "nothing was logged"
    end
    return nil
  end

  local function close()
    if file ~= nil then
      pcall(file.close)
      file = nil
    end
  end

  return log, close, why_empty
end

-- instrument_clock(clock, log) -> 一个会把收到的每次调用都记进日志的时钟。
--
-- 把每次调用都转发给**真实**时钟，所以这次运行什么都不变——变的只有记录。这就是
-- 「测量」与「建模」的区别：一个假时钟只会告诉我们我假设了什么，而假设正是之前四次
-- 误诊的来源。
local function instrument_clock(clock, log)
  local wrapped = {}
  wrapped.errors = clock.errors

  function wrapped.now_ms()
    local value = clock.now_ms()
    log(string.format("clock.now_ms() -> %s", tostring(value)))
    return value
  end

  function wrapped.after(delay_sec, fn)
    log(string.format("clock.after(%.6fs)   [now_ms=%s]", tonumber(delay_sec) or -1,
      tostring(clock.now_ms())))
    local handle = clock.after(delay_sec, function()
      log(string.format("  FIRED                [now_ms=%s]",
        tostring(clock.now_ms())))
      return fn()
    end)
    return handle
  end

  function wrapped.cancel(handle)
    if type(clock.cancel) == "function" then
      return clock.cancel(handle)
    end
    return false
  end

  function wrapped.run_due()
    local ran = clock.run_due()
    log(string.format("clock.run_due() -> %s callbacks", tostring(ran)))
    return ran
  end

  -- 转发 pull_once。**必须转发**：--debug 正是用来查「点了没反应」这类问题的，若包装器
  -- 不转发，调试模式下的点击会静默失效——工具把问题藏起来是最糟的形态。
  --
  -- 非 timer 事件（鼠标）不写日志：一次播放里点击可能很多，逐条记录只会把日志淹掉，
  -- 而「点击是否到达」由定时器序列本身就看得出来。
  function wrapped.pull_once()
    local name, p1, p2, p3 = clock.pull_once()
    return name, p1, p2, p3
  end

  return wrapped
end

-- cli.rate_verdict(real_ms, clock_ms) -> ok, code, detail
--
-- **纯函数**，所以阈值由规格钉住，而不是靠争论。
--
--   real_ms    流逝掉的已知区间——一个 os.sleep 的时长
--   clock_ms   注入时钟的 now_ms() 在这段时间里前进了多少
--   ratio      clock_ms / real_ms —— 1.0 才是对的
--
-- 一个不随真实时间前进的时钟会让每个延迟都错，而且是**不抛错**地错——对调度器来说这是
-- 最糟的失败形态。在一台真实机器上、世界的昼夜循环关闭时实测：
--
--   CLOCK RATE: real=296ms clock_now_ms=0ms  ratio=0.000
--   clock.now_ms() -> 109436400     ... 整段运行都是这个值
--
-- 于是 `delay = ideal - now` 不再是一个区间，而变成了每个事件自己的绝对 t_ms，不断累积，
-- 直到一首 143 秒的歌永远播不完。反方向的坏法一样严重：昼夜循环**开着**时
-- os.epoch("ingame") 每真实秒前进 72000 ms（一个 Minecraft 日是 20 真实分钟），于是每个
-- 事件都瞬间逾期，整首歌一次性全部派发出去。
--
--   real_ms    流逝掉的已知区间（一个 os.sleep 的时长）
--   clock_ms   注入时钟的 now_ms() 在那段时间里前进了多少
--   ratio      clock_ms / real_ms —— 1.0 才是对的
function cli.rate_verdict(real_ms, clock_ms)
  if type(real_ms) ~= "number" or type(clock_ms) ~= "number"
    or real_ms ~= real_ms or clock_ms ~= clock_ms or real_ms <= 0 then
    return true, nil, "the clock could not be measured"
  end

  local ratio = clock_ms / real_ms

  if ratio < 0.5 then
    return false, "E_CLOCK_FROZEN", string.format(
      "the clock advanced %d ms while %d ms of real time passed (%.2fx). A clock "
        .. "that barely moves makes every delay absolute, so the song never "
        .. "finishes. This is what os.epoch('ingame') does when the world's "
        .. "daylight cycle is off; the clock must come from os.epoch('utc').",
      clock_ms, real_ms, ratio)
  end

  if ratio > 10 then
    return false, "E_CLOCK_SCALE", string.format(
      "the clock advanced %d ms while %d ms of real time passed (%.0fx too fast). "
        .. "Its unit is not milliseconds of real time, so every delay is wrong by "
        .. "that factor and the song will finish far too early. This is what "
        .. "os.epoch('ingame') does when the daylight cycle is ON -- a Minecraft "
        .. "day is 20 real minutes, so it runs 72000 ms per real second.",
      clock_ms, real_ms, ratio)
  end

  return true, nil, string.format("the clock tracks real time (%.2fx)", ratio)
end

-- check_clock_health(clock, log) -> ok, code, detail
--
-- 跑一次探测并套用判定。读不到真实时间时跳过（没有 os.epoch / 没有 os.sleep——桌面版
-- 普通 Lua 就是这种情况，测试套件正是在它之下运行的），因为一个什么都测不了的检查
-- 不该拦住一次运行。
local function check_clock_health(clock, log)
  local os_api = raw_global("os")
  if type(os_api) ~= "table"
    or type(os_api.epoch) ~= "function"
    or type(os_api.sleep) ~= "function"
    or type(clock.now_ms) ~= "function" then
    log("clock check: skipped (no os.epoch/os.sleep, so real time is unreadable)")
    return true, nil, nil
  end

    -- 参照物是 os.sleep，而不是再读一次时钟。
    --
    -- 这个检查的第一个版本是在 sleep 前后各读一次 os.epoch("utc")，拿去和
    -- clock.now_ms() 比较——但 now_ms **就是** os.epoch("utc")，所以它是在拿时钟和
    -- **它自己**比，永远只能报出 1.0。一个不可能失败的检查比没有检查更糟，因为它
    -- 看起来像一个检查。
    --
    -- os.sleep 借游戏自己的计时器阻塞一段已知的真实时间，这是一个与 now_ms 从哪来
    -- **无关**的参照物。时钟健康时它会前进差不多这么多；冻结时它纹丝不动；单位错了时
    -- 它会按错误倍数前进。
    local SLEEP_MS = 200

    local ok, clock_ms = pcall(function()
      local clock_0 = clock.now_ms()
      os_api.sleep(SLEEP_MS / 1000)
      return clock.now_ms() - clock_0
    end)

    if not ok then
      log("clock check: could not run: " .. tostring(clock_ms))
      return true, nil, nil
    end

    -- rate_verdict(real_ms, clock_ms)：时钟实际走了多远，对照它在那段已知区间里
    -- **本该**走多远。
    local healthy, code, detail = cli.rate_verdict(SLEEP_MS, clock_ms)
    log(string.format("clock check: slept %dms, now_ms advanced %sms -> %s",
      SLEEP_MS, tostring(clock_ms), healthy and "OK" or tostring(code)))
    if not healthy then
      return false, code, detail
    end
    return true, nil, nil
  end

-- cli.breathe(opts) —— 在同步长工作期间把控制权还给 CC 的调度器。
--
-- 为什么非有不可：CC:Tweaked 会杀掉任何**连续运行超过 `timeout`（默认 7 秒）而没有
-- 让出**的协程，报 `Too long without yielding`。`decode` 与 `fanout.assign` 都是同步
-- 调用——它们跑的时候回不到泵循环、时钟也不被拉动——所以唯一能让出的时机就是它们
-- **自己的进度回调**。真机实测：46764 个音符 × 117 个扬声器的压测曲死在分配的 61%
-- （`player/fanout.lua:263`）。
--
-- `os.sleep(0)` 让出一次（0 秒的定时器下一个调度周期就到期，不等游戏 tick），于是
-- 「两次让出之间」的工作量从「整段同步扫描」变成「两次回调之间」：桌面实测那是 5910
-- 字节的解码或 256 个事件的分配，真机上零点几秒，远在 7 秒之内。
--
-- 让出期间队列里的事件可能被 sleep 消费掉（它是带过滤的拉取），但这两个阶段本来就没
-- 有泵在读事件，唯一会被吃掉的是一次尚未处理的点击——而把「下载/分配期间的点击」当
-- 成跳转本来就是错的。`terminate` 不受过滤影响，Ctrl+T 在这里照常中止。
--
-- 桌面版 Lua 没有 `os.sleep`，于是默认路径安静地什么都不做；`opts.breathe` 是测试
-- 用来**数**让出次数的接缝——没有它，「让出过」这件事在测试里是不可观测的。
function cli.breathe(opts)
  if type(opts) == "table" and type(opts.breathe) == "function" then
    opts.breathe()
    return
  end
  local os_table = raw_global("os")
  if type(os_table) == "table" and type(os_table.sleep) == "function" then
    os_table.sleep(0)
  end
end

-- ---------------------------------------------------------------------------
-- run(argv, opts) -> 退出码
-- ---------------------------------------------------------------------------

function cli.run(argv, opts)
  opts = type(opts) == "table" and opts or {}

  -- 前向声明，不在这里声明：`say` 和 `fail` 定义在下面并引用它，而 Lua 在**编译期**
  -- 按词法解析名字。声明在它们之后的 `local` 会让那些引用变成全局查找，结果是 nil，
  -- 于是每条消息都会抛错而不是打印出来。
  local log, close_log, log_empty

  local out = make_writer()
  if type(opts.write) == "function" then
    -- 一个被注入的接收器同时接收**两种**输出，这样测试看到的正是终端会看到的那个有序
    -- 序列：刷新也在内。
    out = {
      line = opts.write,
      refresh = opts.write,
      refresh_bar = opts.write,
      -- 暂停按钮也走同一个接收器：注入写手的测试正是靠它看到 [Pause]/[Resume]
      -- 的先后顺序，而没有这一项，按钮就成了不可观测的行为。
      refresh_button = opts.write,
      wrapped = opts.write,
      prompt = opts.write,
    }
  end

  -- 进度条与按钮的行号、终端列数。**优先用写手量出来的值**：进度条与按钮就是按那些
  -- 行号画出来的，点击映射必须与画出来的东西完全对应。只有在没有写手几何时（测试注入的
  -- 接收器）才自己量一次——那时的行号是按同一套几何（bar = height-1、button = height）
  -- 推出来的，好让注入接收器那条路测到与生产路径相同的映射。
  local columns = tonumber(out.columns)
  local bar_row = tonumber(out.bar_row)
  local button_row = tonumber(out.button_row)
  if columns == nil or bar_row == nil then
    local measured_columns, measured_height = 51, 19
    local term_geom = terminal()
    if type(term_geom) == "table" and type(term_geom.getSize) == "function" then
      local ok, measured_w, measured_h = pcall(term_geom.getSize)
      if ok then
        if type(measured_w) == "number" and measured_w > 0 then
          measured_columns = measured_w
        end
        if type(measured_h) == "number" and measured_h > 0 then
          measured_height = measured_h
        end
      end
    end
    if columns == nil then
      columns = measured_columns
    end
    if bar_row == nil then
      bar_row = measured_height > 1 and (measured_height - 1) or 1
    end
    if button_row == nil then
      button_row = measured_height
    end
  end
  local lib = library()
  local rt = runtime_module()

  -- 每条永久行都是 `nbsplay: ...`，所以输出可 grep、且只有一种形状；每次失败都是
  -- `nbsplay: E_CODE: detail`，所以它既可读、又机器可读。这与库交出 `{code = "E_..."}`
  -- 而不是一句句子时遵循的是同一条规则。
  -- 每条永久行都经过 `wrapped`，所以本程序打印的任何内容都不会被比消息更窄的终端裁掉。
  -- 越界菜单就是原因：它的行是 77 到 80 个字符，而默认终端是 51 列，用户因此读到了
  -- "…-- play a different RECO"。
  local function say(text)
    out.wrapped("nbsplay: " .. tostring(text or ""))
    log("say: " .. tostring(text or ""))
  end
  local function fail(code, detail)
    out.wrapped("nbsplay: " .. tostring(code) .. ": " .. tostring(detail or ""))
    log(string.format("FAIL %s: %s", tostring(code), tostring(detail or "")))
  end
  -- live(info, bar)：信息行 + 进度条行。`bar` 可省略——下载阶段就没有独立的进度条行，
  -- 它的百分比与字节数都在同一条信息里。
  local function live(info, bar)
    out.refresh(info)
    if bar ~= nil then
      out.refresh_bar(bar)
    end
  end

  local url, debug, policy, force, parse_error = cli.parse_argv(argv)
  log, close_log, log_empty = make_logger(debug, cli.LOG_PATH)
  if debug then
    log("nbsplay debug log -- " .. os.date("%Y-%m-%d %H:%M:%S"))
    log("argv: " .. cli.describe_argv(argv))
  end
  if url == nil then
    fail("E_USAGE", parse_error)
    -- 帮助文本：不加前缀，因为给它每一行都加前缀只是噪音。
    --
    -- **逐行迭代，不硬编码参数个数。** 这里原来解构的是 `first..fourth`，于是 `usage()`
    -- 后来加上的第 5、6 行（`-f, --force` 与 `--debug`）**从未出现在帮助里**——而帮助是
    -- 用户唯一能发现这些选项的地方。返回几行就打印几行，两者就不会再各走各的。
    --
    -- **走 `wrapped`，不是 `line`。** `out.line` 用 `term.write`，它是**裁剪**而不是折行
    -- （AGENTS.md §3 记了实测），而帮助里有好几行远宽于 51 列的终端：`--policy` 那行 83
    -- 列、`-f, --force` 69 列。用 `line` 打印等于把右端静默切掉——「…-- play a different
    -- RECO」正是这么来的。`wrapped` 就是为这种情况存在的。
    local usage_lines = table.pack(cli.usage())
    for index = 1, usage_lines.n do
      out.wrapped(usage_lines[index])
    end
    return 1
  end

  if lib == nil then
    fail("E_NO_LIBRARY", "ccnbslib.lua is not installed")
    return 1
  end

  say("fetching " .. url)
  local body, fetch_code, fetch_detail = cli.fetch(url,
    function(received, total)
      if total ~= nil and total > 0 then
        local kib = string.format("  %d/%d KiB",
          math.floor(received / 1024), math.floor(total / 1024))
        live(cli.progress_line("download", received / total, { kib }))
      else
        -- 没有 Content-Length，就没有比例可画——报告计数，而不是凭空编一个比例。
        live(string.format("download  %d KiB", math.floor(received / 1024)))
      end
    end)
  if body == nil then
    fail(fetch_code, fetch_detail)
    return 1
  end

  say("decoding")
  -- **解码期只能靠这个回调画。** 与播放期不同：decode 是**同步阻塞**的，它跑的时候泵回不到
  -- 循环里，时钟定时器根本不会被拉动——播放期那套「定时重画」在这里是死的。唯一能做事的
  -- 时机，就是 decode 自己回调的时候。
  --
  -- 按**百分比变化**节流重画：库每 4096 字节报一次，一首 8 MB 的歌就是约两千次回调，逐次
  -- 重画等于把 term.write 变成解码之外的第二大开销。百分比是屏幕上唯一会变的东西，所以
  -- 「变了才画」既省又看不出差别。
  local last_decode_percent = -1
  local decoded = lib.decode(body, function(done, total)
    -- **先让出，再谈画不画。** 见 cli.breathe：这一行必须在下面的百分比节流**之前**，
    -- 否则百分比没变的那些回调（真歌里占多数）就不再让出，看门狗照样会杀过来。
    cli.breathe(opts)
    local percent = 0
    if type(done) == "number" and type(total) == "number" and total > 0 then
      percent = math.floor(done / total * 100)
      if percent < 0 then percent = 0 end
      if percent > 100 then percent = 100 end
    end
    if percent == last_decode_percent then
      return
    end
    last_decode_percent = percent
    live(
      string.format("decoding  %d%%", percent),
      cli.bar_row(percent / 100, columns))
  end)
  if type(decoded) ~= "table" or decoded.ok ~= true then
    local code = type(decoded) == "table" and decoded.error
      and decoded.error.code or "unknown"
    -- 库**自己的**带类型码被原样透传，而不是重述一遍：它是契约里机器可读的那一半，
    -- 好让脚本按它分支。
    fail("E_DECODE", code)
    return 1
  end

  local song = decoded.song

  -- 哪些音符越界，用 PASSTHROUGH 来问，因为这个策略不改变任何事件的 kind：每个可听
  -- 音符都仍是 play_note，所以计数就是真正会发声的音符数，答案与用户即将做出的选择
  -- 无关。
  local probe = lib.analyze(song,
    { out_of_range = "passthrough" })
  local has_out_of_range = probe.has_extended_range == true

  local out_of_range = "passthrough"
  if has_out_of_range then
    if policy ~= nil then
      -- 一个无人值守的调用方点名了策略，于是菜单被跳过——但它仍会被**说出**，这样日志
      -- 和屏幕对「这首歌是怎么播的」保持一致。
      out_of_range = policy
      say("out-of-range notes: " .. policy)
    else
      out_of_range = cli.choose_out_of_range(opts, probe, say, out.wrapped,
      out.prompt)
    end
  end

  -- 策略在编排**之前**就定下来，因为它决定事件的 kind、进而决定扬声器需求——之后再选
  -- 就会按错误的成本去规划扇出。
  local analysis = lib.analyze(song, { out_of_range = out_of_range })

  -- plan 是解码之后**最大**的一段同步工作（46764 音符实测 0.399 s 桌面、真机约 3 倍
  -- 以上），而它自己没有进度回调——唯一能在它之前重置看门狗计时的地方就是这里。少了
  -- 这一下，「解码最后一次让出 → 分配第一次让出」会连成一段（探测 + 两次 analyze +
  -- plan，真机最坏约 6 秒），下一个更大的文件就会死在 plan 里而分配还没开始。
  cli.breathe(opts)
  local events = lib.plan(song, analysis, { out_of_range = out_of_range })
  local duration = cli.duration_ms(events)

  if debug then
    local header = type(song.header) == "table" and song.header or {}
    log(string.format(
      "decoded: version=%s tempo_raw=%s ticks_per_second=%s tick_ms=%s",
      tostring(header.version), tostring(header.tempo_raw),
      tostring(analysis.ticks_per_second), tostring(analysis.tick_ms)))
    log(string.format("decoded: song_length=%s ticks, notes=%s, events=%s",
      tostring(header.song_length), tostring(#(song.notes or {})), tostring(#events)))
    log(string.format("duration from the PLAN: %d ms (%s)",
      duration, cli.format_time(duration)))
    -- 不重复的到期时刻：按时限调度的调度器所需的定时器数量。
    local seen, distinct = {}, 0
    for index = 1, #events do
      local key = events[index].t_ms
      if not seen[key] then
        seen[key] = true
        distinct = distinct + 1
      end
    end
    log(string.format("events per second: %.1f   distinct deadlines: %d",
      duration > 0 and (#events / (duration / 1000)) or 0, distinct))
    for index = 1, math.min(6, #events) do
      log(string.format("  event[%d] t_ms=%s tick=%s layer=%s kind=%s",
        index, tostring(events[index].t_ms), tostring(events[index].tick_index),
        tostring(events[index].layer_index), tostring(events[index].kind)))
    end
    if #events > 0 then
      log(string.format("  event[%d] (last) t_ms=%s tick=%s", #events,
        tostring(events[#events].t_ms), tostring(events[#events].tick_index)))
    end
  end

  -- 文件里若有标题就显示出来，这样用户能确认拿到的是自己想听的那首歌。CP1252 字节
  -- **只为显示**而转换，这正是库那个转换器的用途；歌曲本身保留自己的字节。
  local title = type(song.header) == "table" and song.header.name or nil
  if type(title) == "string" and title ~= "" and lib.cp1252 ~= nil
    and type(lib.cp1252.to_display) == "function" then
    local ok, shown = pcall(lib.cp1252.to_display, title)
    if ok and type(shown) == "string" then
      title = shown
    end
  end
  if type(title) ~= "string" or title == "" then
    title = "(untitled)"
  end

  local speakers = lib.discover_speakers()
  local found = type(speakers) == "table" and #speakers or 0

  -- **两个数字都要给。** 只报告接了多少个只回答了一半问题：用户无法判断两个扬声器够
  -- 不够。需求数字来自库，且跟随刚选定的策略，所以必须在那次选择**之后**读取——这里
  -- 正是如此。
  local needed = 0
  if lib.speaker_requirement ~= nil then
    needed = lib.speaker_requirement(analysis) or 0
  end

  local summary = string.format("%s -- %s",
    cli.speaker_count(found),
    found >= needed and "enough" or ("needs " .. tostring(needed)))
  say(string.format("\"%s\"  %d notes  %s  %s",
    title, analysis.total_notes or 0, cli.format_time(duration), summary))

  if debug then
    for index = 1, found do
      log(string.format("  speaker[%d] side=%s", index, tostring(speakers[index].side)))
    end
    log(string.format("  required=%d found=%d", needed, found))
  end

  if found == 0 then
    fail("E_NO_SPEAKER", "attach a speaker to a side of the computer, then retry")
    return 1
  end

  -- 在任何昂贵工作之前，先拒绝一首扬声器装不下的歌。
  --
  -- 在默认 shift 策略下于 `RushE.nbs` 实测：同时 109 个 play_sound 的峰值，于是在只
  -- 接了 43 个扬声器的地方需要 117 个。分配器花了**十一秒**去挪动音符、为它永远放不下
  -- 的声音腾位置——无论怎么重排音符，43 个扬声器都装不下 109 个并发声音——而在真实电脑
  -- 上这已经超过看门狗时限，于是它不是播完、而是崩了。
  --
  -- 缺口在这里就已经知道，所以拒绝不要任何成本，白费的工作根本不会开始。`--force` 照样
  -- 播放：一旦用户看见了数字，丢音符就是他们的决定。
  --
  -- **数字缺失不等于有缺口。** 一个更旧或残缺的库不暴露 `speaker_requirement`，而把
  -- 「未知」当作「需要非常多」会拒绝掉每一首歌。只有确定的缺口才拦。
  if needed > found and not force then
    fail("E_NOT_ENOUGH_SPEAKERS", string.format(
      "this needs %d speakers but %d are attached", needed, found))
    say(string.format(
      "a speaker holds 8 notes per tick but only 1 sound, and this song peaks at %d "
        .. "simultaneous ones", analysis.play_sound_notes_at_peak or 0))
    say("options:")
    say("  -f, --force       play anyway, dropping whatever does not fit")
    say("  --policy passthrough   needs far fewer speakers, at the cost of pitch "
      .. "accuracy")
    say("  attach more speakers and retry")
    return 1
  end

  if needed > found then
    -- 强制播放是一个刻意的选择，所以要说出来：用户不该被迫记住自己要求过丢掉音符。
    say(string.format(
      "forced: needs %d speakers, %d attached -- notes that do not fit will be dropped",
      needed, found))
  end

  -- 缺口**不**在这里再报一遍：库已经带着数字（required、found、dropped）发出了它的
  -- `speakers` 警告，而换一套说法把同一件事说两遍，正是一条消息变成噪音的方式。上面的
  -- 摘要行已经带了计数，播放继续——丢音符是用户的决定，不是拒绝一首他们想听的歌的理由。

  local clock = current_clock()
  if clock == nil then
    fail("E_NO_CLOCK", "player.clock is missing, so playback cannot be timed")
    return 1
  end
  if type(clock.pull_once) ~= "function" then
    -- 拒绝而不是降级：轮询驱动不了这个时钟，而且退回 run_due() 会**静默丢掉点击**——
    -- 那正是「进度条正常、点了没反应」这类不可见失效。宁可在这里停住。
    fail("E_NO_CLOCK", "this clock cannot be driven (no pull_once)")
    return 1
  end

  -- **每次运行都检查时钟**，不只是 --debug 时；一个不跟随真实时间的时钟会**拒绝**这
  -- 首歌。照播会得到一个静默错误的结果——要么一首永远播不完的歌，要么一首几秒就结束
  -- 的歌——而且再怎么盯着进度条也解释不了原因。
  log("--- clock: measuring rate before playback (0.2 s pause) ---")
  local clock_ok, clock_code, clock_detail = check_clock_health(clock, log)
  if not clock_ok then
    fail(clock_code, clock_detail)
    if close_log ~= nil then close_log() end
    return 1
  end

  -- 定时重画用的是**未包装**的时钟。--debug 会把时钟包一层，而包装器把每一次 after /
  -- now_ms 都记进调试日志；刷新是每秒 20 次的常规动作，逐条记进去只会把真正的时序线索
  -- 淹掉。这与进度回调的限流是同一个考虑。
  local refresh_clock = clock

  if debug then
    log("--- instrumenting the clock; playback follows ---")
    clock = instrument_clock(clock, log)
  end

  -- --- seek 支撑 ------------------------------------------------------------------
  --
  -- 点击映射的分母：歌曲「时长」= 最后一个事件的 t_ms（cli.duration_ms）。seek 期间
  -- **恒定不变**；若从剩余计划重算，分母会变小，点击就会漂移。
  local duration_ms = duration

  -- 跨 seek 的**警告去重**。`session.cancel()` 会补发被推迟的 custom-instrument 计数
  -- 警告，所以不去重的话每跳一次就重印一遍同一句。库的「每个码每会话至多一次」保证不变，
  -- 这里只是 CLI 不多打印。
  local shown_warns = {}
  local function warn_to_screen(code, args)
    if shown_warns[code] then
      return
    end
    shown_warns[code] = true
    log(string.format("WARN %s", tostring(code)))
    say("warning: " .. cli.describe_warning(code, args))
  end

  -- --- 播放位置：按**时钟**推进，不按音符 --------------------------------------------
  --
  -- 两行实时区原来只在 `on_progress` 里更新，而那个回调是**事件驱动**的：只有派发一个音符
  -- 时才触发。于是长音或休止期间进度条与时间**完全不动**，然后在下一个音符处猛地跳一格。
  -- 位置改为从时钟推导——锚点位置 + 从锚点起流逝的时间——刷新频率就与音符密度无关了。
  local position_base_ms = 0
  local last_note_index = 0
  local last_note_total = #events

  -- 暂停状态。`paused_position_ms` 是**暂停那一刻**（或暂停中点进度条所指）的歌曲
  -- 位置；只要暂停着，显示的位置就冻结在它上面，与时钟走了多远无关。
  --
  -- `paused` 还兼着一件事：暂停时会话被推到歌尾，`is_playing()` 随之变假——若泵循环
  -- 只看它，暂停就等于退出。循环条件写的是 `is_playing() or paused`，所以暂停期间
  -- 泵照转、按钮照点，恢复时再 seek 回来。
  local paused = false
  local paused_position_ms = 0

  -- 时钟缺席时返回 0，而不是抛错：注入的测试时钟未必实现 now_ms，而「位置恒为锚点」是
  -- 那些测试本来就会看到的行为。
  local function clock_now()
    if type(refresh_clock.now_ms) == "function" then
      local ok, value = pcall(refresh_clock.now_ms)
      if ok and type(value) == "number" then
        return value
      end
    end
    return 0
  end

  -- 播放锚点：**出声那一刻**的时钟读数。`now - anchor` 就是从开播到现在流逝的歌曲时间。
  --
  -- **必须由 lib.play 之后的代码重新取一次**（见下面 `session = lib.play(...)` 之后）。
  -- lib.play 内部会同步跑完扬声器分配，真机上那是几百毫秒；若锚点在那之前就取下，这整段
  -- preparing 都会被算成播放进度——进度条在第一个音符响之前就已经跑了一截。
  -- 实测：模拟 900ms 的分配，首帧显示 `playing 90%`，而歌一个音符都还没播。
  --
  -- 初值只是占位：`lib.play` 之前不会有人调用 current_position_ms（preparing 期间画的是
  -- assign_handler 自己的百分比）。
  local anchor_at_ms = clock_now()

  local function current_position_ms()
    -- 暂停中位置是**冻结**的：时钟照走，但显示不许动，否则暂停按钮亮着而时间还在爬。
    if paused then
      return paused_position_ms
    end
    return cli.playback_position(position_base_ms, anchor_at_ms,
      clock_now(), duration_ms)
  end

  local function draw_playback(position_ms)
    local frac = duration_ms > 0 and (position_ms / duration_ms) or 0
    -- 信息量最大的在前：先是百分比与时钟，然后是音符计数。装不下的那个才被丢掉。
    live(
      string.format("playing  %d%%  %s/%s  note %d/%d",
        math.floor(frac * 100),
        cli.format_time(position_ms), cli.format_time(duration_ms),
        last_note_index, last_note_total),
      cli.bar_row(frac, columns))
    -- 按钮跟着每一帧重画：写永久行会滚动屏幕并清掉实时行，只在切换状态时画一次的话，
    -- 按钮会在下一次滚动后凭空消失。文案由 `paused` 决定，所以「谁画的」不重要。
    out.refresh_button(cli.button_label(paused))
  end

  local progress_logged = 0
  local function progress_handler(info)
    -- 音符计数只能从事件得知（那是事件侧的事实，时间推不出来），所以记下来供两次事件之间
    -- 的重画使用。而**时间轴由时钟推导**，不用 info.t_ms 画进度条——用它会立刻把进度条
    -- 绑回音符密度，也就是这次要修的那个问题。
    last_note_index = tonumber(info.index) or last_note_index
    last_note_total = tonumber(info.total) or last_note_total
    draw_playback(current_position_ms())
    -- 限流：21247 次回调会把日志淹掉。
    progress_logged = progress_logged + 1
    if progress_logged <= 10 or progress_logged % 200 == 0 then
      log(string.format("progress %d/%s  t_ms=%s (%s)",
        tonumber(info.index) or 0, tostring(info.total), tostring(info.t_ms),
        cli.format_time(tonumber(info.t_ms) or 0)))
    end
  end

  local session = nil

  -- 分配扬声器期间的进度：菜单选完之后、第一声响起之前的那段同步停顿。
  --
  -- 与解码进度同一个道理：`fanout.assign` 是同步阻塞的，那一刻回不到泵循环、时钟也不会被
  -- 拉动，所以只能靠它自己的回调用最朴素的方式画。按**百分比变化**节流，理由与解码相同。
  local last_assign_percent = -1
  local function assign_handler(done, total)
    -- **先让出，再谈画不画。** 与解码进度同一行注释的那份理由，而且这里更致命：
    -- fanout.assign 是整条流水线里最长的一段同步扫描（桌面 3.835 s / 真机 3~10 倍），
    -- 不让出就一定越过 7 秒的看门狗。放节流之后 = 真歌里大多数回调不再让出。
    cli.breathe(opts)
    if type(done) ~= "number" or type(total) ~= "number" or total <= 0 then
      return
    end
    local percent = math.floor(done / total * 100)
    if percent < 0 then percent = 0 end
    if percent > 100 then percent = 100 end
    if percent == last_assign_percent then
      return
    end
    last_assign_percent = percent
    live(
      string.format("preparing  %d%%", percent),
      cli.bar_row(percent / 100, columns))
  end

  -- 初次播放。`from_ms` **不再**需要：跳转现在是在活着的会话上重新锚定（session.seek），
  -- 而不是取消再重开一个带 from_ms 的会话。库仍然支持 from_ms（「从第 30 秒开始播」是
  -- 一个合法的起步位置），只是 CLI 的跳转不再走那条路。
  session = lib.play(events, {
    analysis = analysis,
    speakers = speakers,
    clock = clock,
    out_of_range = out_of_range,
    -- 警告曾被**丢弃**。库发出裸码、并期待调用方为它措辞；一个不传任何处理器的 CLI
    -- 会静默丢掉每一条，于是「没有警告出现」对「之前有没有出过问题」什么也说明不了。
    on_warning = warn_to_screen,
    on_progress = progress_handler,
    -- 分配扬声器的进度。见上面的 assign_handler。
    on_assign = assign_handler,
  })

  -- **现在**才取播放锚点。上面那次 lib.play 里同步跑完了扬声器分配（真机上几百毫秒），
  -- 而歌是从它返回之后才开始响的。早取一毫秒，那段 preparing 就多被算进播放进度一毫秒；
  -- 早取几百毫秒，进度条在第一个音符之前就凭空跑掉一大截。
  anchor_at_ms = clock_now()

  local function seek_to(target_ms)
    if target_ms < 0 then
      target_ms = 0
    end
    if target_ms > duration_ms then
      target_ms = duration_ms
    end

    -- 暂停中：只移动**显示**的位置。session.seek 会把定时器重新挂上，音符就会在暂停
    -- 期间响起来；真正的 seek 推迟到恢复那一刻（toggle_pause 的恢复分支），目标位置
    -- 记在 paused_position_ms 里。
    if paused then
      paused_position_ms = target_ms
      draw_playback(target_ms)
      return
    end

    if session ~= nil and type(session.seek) == "function" then
      -- 在**活着的会话**上重新锚定，O(log n)。分配与路由原样复用：它们是确定性的、对整首
      -- 歌已经算过，而此刻播的是那份计划的子集，所以每个扬声器的负载只会小于等于全量时的
      -- 负载——复用永远合法。
      --
      -- 这里**不**打永久行：一次拖动会产生几十个 seek，每次一条会把屏幕滚穿。进度条本身
      -- 就是反馈。
      --
      -- 跳到结尾也不需要特殊分支：把 target 定在 duration 上，seek 之后没有事件可派发，
      -- 于是 `is_playing()` 自然变假、循环退出。旧代码那条「显式跳尾分支」是因为它走的是
      -- 「过滤 + 重开」，而过滤 `t_ms >= duration` 会留下**一个**事件（duration 就是最后
      -- 一个事件的 t_ms），必须靠分支才能区分「到结尾」与「播最后一个音符」。
      session.seek(target_ms)

      -- **重设锚点**：目标时刻就是「现在」这一刻的歌曲位置。不重设的话，跳转后位置仍从旧
      -- 锚点推算，进度条会立刻跳回原处。
      position_base_ms = target_ms
      anchor_at_ms = clock_now()

      -- 立刻重画，不等下一个事件。跳到一段没有音符的地方时，否则进度条要过好几秒才跟上。
      draw_playback(target_ms)
    end
  end

  -- toggle_pause()：暂停 / 恢复。按钮在进度条**底下那一行的行首**，见 handle_mouse。
  --
  -- **暂停不重建会话。** 取消再重开要把整首歌的分配再跑一遍（真机上 46764 音符是几秒
  -- 级），而暂停/恢复会被反复点。这里只用已冻结的会话 API：
  --
  --   暂停   session.seek(duration + 1) 会话推到**最后一个事件之后** —— tempo 撤掉
  --                                       挂起的定时器、没有事件可发，于是一个音都不响。
  --                                       is_playing() 随之变假，由 `paused` 兜住泵循环。
  --
  -- **为什么是 duration + 1 而不是 duration。** tempo:seek 二分找的是第一个
  -- `t_ms >= target` 的事件（tempo_spec case 28：seek(100) 会重放 100 那个事件），而
  -- duration 恰恰就是最后一个事件的 t_ms——seek(duration) 会把最后一个音符**重新装上
  -- 膛**，delay 0 立刻派发：暂停瞬间计数跳成「总数/总数」，还多响一个音（用户实测
  -- 报的就是这个）。加 1 之后二分落到 #events + 1，什么都没剩。
  --
  --   恢复   session.seek(位置)          重新锚定、从暂停处继续；O(log n)，与点进度条
  --                                       跳转是同一条路，分配与路由原样复用。
  local function toggle_pause()
    if not paused then
      paused_position_ms = current_position_ms()
      paused = true
      session.seek(duration_ms + 1)
      log(string.format("paused at %s ms", tostring(paused_position_ms)))
    else
      paused = false
      position_base_ms = paused_position_ms
      anchor_at_ms = clock_now()
      session.seek(paused_position_ms)
      log(string.format("resumed at %s ms", tostring(paused_position_ms)))
    end
    -- 两种状态都要重画：信息行的时间要冻结/继续，按钮文案要从 [Pause] 换到 [Resume]。
    draw_playback(current_position_ms())
  end

  -- handle_mouse(name, button, x, y)：进度条行负责 seek，按钮行负责暂停，其余行不算。
  --
  -- **drag 必须处理。** 一次拖动 = 1 个 `mouse_click` + 几十个 `mouse_drag` + 1 个
  -- `mouse_up`（见 tweaked.cc 的 mouse_drag/mouse_up）。原来只处理 click，所以拖动
  -- 期间**完全没有反应**——进度条不动，松手也没有任何变化。
  --
  -- 现在逐事件 seek：seek 是 O(log n)，实测与歌曲规模无关，所以不需要防抖或合并。
  local function handle_mouse(name, button, x, y)
    if button ~= 1 then
      return
    end
    if name ~= "mouse_click" and name ~= "mouse_drag" then
      return
    end

    -- 按钮行：只有行首那段列是按钮，行里其余部分什么都没有，点了必须没反应。拖动也不
    -- 算——那是进度条的动作，暂停只由一次干净的点击触发。
    if y == button_row then
      if name == "mouse_click" and cli.hits_button(x, paused) then
        toggle_pause()
      end
      return
    end

    if y ~= bar_row then
      return
    end
    -- 进度条行**只有**进度条，所以整行都是进度轴、整行可点。
    seek_to(cli.click_fraction(x, columns) * duration_ms)
  end

  if type(session) ~= "table" then
    fail("E_PLAY", "the library did not return a playback session")
    return 1
  end

  -- --- 定时重画 ----------------------------------------------------------------------
  --
  -- **这是「进度条与时间不动」的正解。** 只靠 `on_progress` 不行：事件只在与音符相关的时刻
  -- 到达，长音或休止期间一个都没有，那两行就会僵住。所以另外按**固定间隔**重画一次，位置
  -- 从时钟推导。
  --
  -- 50 ms 是 CC 定时器的粒度下限（`os.startTimer` 取整到 0.05 s），也是游戏 tick 的长度，
  -- 所以它是能画得最密的间隔；再密没有意义，再疏会出现肉眼可见的停顿。
  local REFRESH_SECONDS = 0.05
  local refresh_handle = nil
  local playback_over = false

  local function stop_refresh()
    playback_over = true
    if refresh_handle ~= nil and type(refresh_clock.cancel) == "function" then
      refresh_clock.cancel(refresh_handle)
    end
    refresh_handle = nil
  end

  -- 自我重排：每次触发后重画一次再排下一个，直到播放结束。
  local function arm_refresh()
    if playback_over or type(refresh_clock.after) ~= "function" then
      return
    end
    refresh_handle = refresh_clock.after(REFRESH_SECONDS, function()
      refresh_handle = nil
      if playback_over then
        return
      end
      draw_playback(current_position_ms())
      arm_refresh()
    end)
  end

  -- 先画一帧：时钟没有 after（注入的测试时钟可能没有）时，这一步保证屏幕上至少不是空的。
  draw_playback(current_position_ms())
  arm_refresh()

  -- 驱动这首歌：**逐事件**从时钟取事件，而不是让 run_due() 一次排空。
  --
  -- 为什么不用 run_due()：它内部是 `os.pullEvent("timer")`，而**带过滤**的 pullEvent 会把
  -- 不匹配的事件从队列里丢掉（见 player/clock.lua 的 pull_once）——包括点击。结果就是
  -- 进度条一切正常、点上去毫无反应，而且**不抛错**。pull_once 不丢弃任何事件。
  local pump_failed = false
  if type(session.is_playing) ~= "function" then
    -- 没有 `is_playing` 的会话**无法**被逐事件驱动：循环条件无从判断什么时候停。旧代码用
    -- `run_due()` 一次排空、不依赖这个字段；换成 pull_once 的泵之后它成了必需项，所以这里
    -- 明确拒绝——否则循环一次都不执行，然后**谎报 done**。
    fail("E_PLAY",
      "the playback session has no is_playing(), so it cannot be pumped to completion")
    pump_failed = true
  else
    while session.is_playing() or paused do
      -- `or paused`：暂停时会话被推到歌尾，is_playing() 是假的——只看它，暂停就等于
      -- 退出并打印 done。暂停期间泵必须继续转，否则按钮再也点不动、恢复无从发生。
      local name, p1, p2, p3 = clock.pull_once()
      if name == nil then
        -- 一个不再产生事件的时钟会让这个循环**空转**到 CC 的看门狗（abortTimeout），看起来
        -- 像卡死。宁可大声失败。
        fail("E_NO_CLOCK", "the clock stopped producing events (pull_once returned nil)")
        pump_failed = true
        break
      end
      if name == "mouse_click" or name == "mouse_drag" then
        handle_mouse(name, p1, p2, p3)
      end
      -- mouse_up 不需要特殊处理：seek 发生在按下与拖动的每一个位置，松手时状态已经是
      -- 对的。刻意**不**在松手时再 seek 一次——那只会多一次无效果的重新锚定。
    end
  end

  -- 停止定时重画：否则一个已经结束的播放会继续每秒排 20 个定时器，而屏幕上那两行早已
  -- 没有意义。也顺带避免把 handle 留在时钟里。
  stop_refresh()

  -- **为什么这里没有「时钟提前停了」的守卫。**
  --
  -- 旧代码有那条守卫，因为 `run_due()` 的退出条件（时钟不再有待处理 handle）与「歌播完了」
  -- **无关**：它排空后就返回，此时会话可能仍在播放，那个不一致就是守卫要抓的东西。
  --
  -- 换成逐事件泵之后，循环的**退出条件本身就是** `is_playing() == false`，两者不可能不一致
  -- ——退出的两条路径（`pump_failed`、`is_playing()` 为假）里，前者被上面的条件挡掉，后者
  -- 与守卫的前提直接矛盾。写在这里只会是**死代码**，而一个无法失败的检查比没有检查
  -- 更糟，因为它看起来像检查。
  --
  -- 「时钟提前停」这个失效并没有消失，它换了表现形式：时钟不再派发时 `pull_once()` 会
  -- 返回 nil（或永远阻塞），那条路径已经由上面的 `E_NO_CLOCK` 抓住。

  -- 时钟没能继续供事件（上面 pump_failed）时不再往下走：这句 "done" 会是撒谎。
  if pump_failed then
    if rt ~= nil and type(rt.cleanup) == "function" then
      pcall(rt.cleanup, speakers, session)
    end
    if close_log ~= nil then close_log() end
    return 1
  end

  -- 抛错过的定时器回调是被**捕获**的，不是被传播的，所以没有这一步，一次坏掉的派发会
  -- 看起来和一首播完的歌一模一样。
  if type(clock.errors) == "table" and #clock.errors > 0 then
    local first = clock.errors[1]
    local message = type(first) == "table" and first.message or tostring(first)
    fail("E_DISPATCH", message)
    if rt ~= nil and type(rt.cleanup) == "function" then
      pcall(rt.cleanup, speakers, session)
    end
    if close_log ~= nil then close_log() end
    return 1
  end

  -- **每一条**路径上都要停掉扬声器，包括这一条，因为一个还在播放的扬声器会在程序结束后
  -- 继续响。
  if rt ~= nil and type(rt.cleanup) == "function" then
    pcall(rt.cleanup, speakers, session)
  end
  say("done")
  log("done")
  if close_log ~= nil then close_log() end
  if debug and log_empty ~= nil then
    local why = log_empty()
    if why ~= nil then
      out.line("nbsplay: WARN: the debug log is unusable -- " .. why)
    end
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Autorun —— 只在作为程序执行时触发，被测试 require 时永不触发
-- ---------------------------------------------------------------------------
do
  local first = (...)
  local looks_like_a_module = type(first) == "string"
    and first:match("^[%a_][%w_%.]*$") ~= nil
  local has_cc_env = type(rawget(_G, "fs")) == "table"
  local opted_out = rawget(_G, "__CCNBS_NBSPLAY_NO_AUTORUN") == true
  if has_cc_env and not looks_like_a_module and not opted_out then
    cli.run({ ... })
  end
end

return cli
