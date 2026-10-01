-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 colorgarden
-- CCNBSLib 的一部分。以 GPL-2.0 授权；条款见 LICENSE。
--
-- install.lua
--
-- **安装器**：apt 风格，仅命令行。
--
--     install install              取回清单（manifest）并安装每一个文件
--     install update               刷新清单，不安装任何文件
--     install upgrade              只重新取回大小发生变化的文件
--     install verify               报告与清单不再一致的文件
--     install remove [--purge]     删除已安装的文件
--     install list                 显示已安装的内容
--     install mirror <sub>         list / add / remove / default / test
--
-- ===========================================================================
-- 为什么是单文件，以及为什么第一步要手动取回
-- ===========================================================================
-- 一台全新的 CC:Tweaked 电脑没有 `wget`、没有 `curl`、也没有包管理器，所以唯一的
-- 起点是手敲一条 `http.get` 再 `shell.run`。这个引导步骤只能有把握地取回**一个**
-- 文件，这就是它刻意做成单文件、而不是模块树的原因：
--
--     local r = http.get("<mirror>/raw.githubusercontent.com/colorgarden/CCNBSLib/main/install.lua")
--     local f = fs.open("install.lua", "w")  f.write(r.readAll())  f.close()
--     shell.run("install.lua install")
--
-- ===========================================================================
-- 文件清单来自仓库内已提交的 manifest，而不是来自 GitHub
-- ===========================================================================
-- api.github.com 经任何一个 GitHub 代理都是 403——这是实测，不是假设——而代理正是
-- 这个安装器存在的全部理由。所以文件清单随仓库一起、走 raw 分发，raw 经代理正常。
--
-- ===========================================================================
-- 每个文件都来自 main 分支，且与清单走同一个镜像
-- ===========================================================================
--  .../main/nbs/analyze.lua      可以
--
-- 一切都只有一个参照，因此没有第二处需要保持一致。
--
-- 撕裂是被**检测**出来的，而不是被阻止的。如果安装进行中有一次 push 落地，清单与
-- 文件就不再一致，逐文件字节数会把它抓住：安装以 E_SIZE 失败，用户重试即可。这是
-- 相较「钉住某个 commit」刻意的选择——钉住本来也需要从 `main` 读清单（commit 只有
-- 读了才知道），而且会让清单自身的新鲜度取决于它命名的那个 commit，对个人项目来说
-- 是多余的簿记。要紧的是这种不一致足够**响亮**：绝不出现一个由两个不同版本拼出来、
-- 却被报告为成功的目录树。
--
-- 因此完整性就是：逐文件字节数，下载后校验。不做内容哈希：CC:Tweaked 的 ROM 没有
-- 加密模块，SHA-256 得用纯 Lua 写，只为防一个 HTTPS 加字节数本就已覆盖的威胁。
--
-- 兼容性：Lua 5.2 / CC:Tweaked 的 Cobalt。不用整除、不用位运算、不用 utf8.*、不用
-- collectgarbage、不用 string.dump、不用 os.exit、不用 goto。每个 CC 全局都通过
-- 接缝（seam）**惰性**读取，所以本文件在普通桌面 Lua 里可 `require`，其纯函数部分
-- 可做单元测试。

local installer = {}

installer.VERSION = "1.0.0"

-- 文件来自哪个仓库，以及它们落在哪里。INSTALL_ROOT 与 README 记录的布局一致；
-- STATE_DIR 是一个子目录，这样库自己的命名空间里只会有属于库的文件。
installer.REPO = "colorgarden/CCNBSLib"
-- 一切内容的唯一取回参照。只命名一次，这样安装布局、清单与文件永远不会彼此漂移。
installer.BRANCH = "main"
installer.RAW_HOST = "https://raw.githubusercontent.com/"
installer.INSTALL_ROOT = "/lib"
installer.STATE_DIR = installer.INSTALL_ROOT .. "/ccnbs-install"
installer.SOURCES_PATH = installer.STATE_DIR .. "/sources.txt"
installer.INSTALLED_PATH = installer.STATE_DIR .. "/installed.txt"

-- 按顺序尝试的镜像，失败即轮换。gh.llkk.cc 与 ghproxy.net 是用户点名的两个；
-- `direct` 面向一台网络能直连的电脑，直达 GitHub 本身。
--
-- prefix 是最终 URL 真正的**前缀**，被拼在完整的 raw URL 之前：
--
--   代理：  "https://gh.llkk.cc/"  ->  https://gh.llkk.cc/https://raw.githubusercontent.com/...
--   直连：  ""                     ->  https://raw.githubusercontent.com/...
--
-- 所以 `direct` 的 prefix 是**空串**，而不是 raw 主机名。在那里写主机名会把它
-- 翻倍——prefix 加上本就以该主机名开头的 raw URL——而空串正是让同一套模板不用
-- 任何特判就能覆盖两种情况的原因。
installer.DEFAULT_MIRRORS = {
  { name = "gh.llkk.cc", prefix = "https://gh.llkk.cc/" },
  { name = "ghproxy.net", prefix = "https://ghproxy.net/" },
  { name = "ghfast.top", prefix = "https://ghfast.top/" },
  { name = "direct", prefix = "" },
}

-- ---------------------------------------------------------------------------
-- 接缝（seams）—— 每个宿主 API 都经由这些接缝访问，所以测试可以在没有网络、没有
-- 磁盘、没有终端的情况下驱动整个安装器
-- ---------------------------------------------------------------------------

local seams = {}

function installer.configure(opts)
  seams = type(opts) == "table" and opts or {}
  return installer
end

local function raw_global(name)
  return rawget(_G, name)
end

local function term_seam()
  return seams.term or raw_global("term")
end

local function fs_seam()
  return seams.fs or raw_global("fs")
end

local function http_seam()
  return seams.http or raw_global("http")
end

-- read_seam()：安装器如何向用户提问。
--
-- 通过接缝注入，好让测试来回答；`read` 是一个 CC 全局，而一条从未被跑过的交互路径
-- 正是 autorun 那个 bug 存活下来的方式（写了、从没运行、悄悄出错）。无法读取时
-- 返回 nil，每个调用方都把它当作「用户什么也没说」。
--
-- 调用 `read` **不传参数**。它的第一个参数是用来隐藏密码的**替换字符**
-- —— `read([replaceChar [, history [, completeFn [, default]]]])` —— 并且只取该
-- 字符串的第一个字符。因此写成 `read("number (blank to cancel): ")` 时**提示语不会
-- 显示**，而且每一次按键都会回显成字母 "n"。它没有提示语参数；提示语要先**写出**
-- 去（nbsplay.lua 里也有同一个 bug）。
local function read_seam()
  if type(seams.read) == "function" then
    return seams.read()
  end
  local reader = raw_global("read")
  if type(reader) ~= "function" then
    return nil
  end
  local ok, answer = pcall(reader)
  if not ok then
    return nil
  end
  return answer
end

-- installer.file_size(path) -> number | nil
--
-- 有 fs 接缝时用它，否则退回到普通 io，好让 spec 能在桌面上量真实文件的大小。返回
-- nil 而不是抛错，让调用方可以说「读不到」，而不是在一个运行中途消失的文件上崩掉。
function installer.file_size(path)
  local fs_api = fs_seam()
  if type(fs_api) == "table" and type(fs_api.getSize) == "function" then
    local ok, size = pcall(fs_api.getSize, path)
    if ok and type(size) == "number" then
      return size
    end
    return nil
  end

  local handle = io.open(path, "rb")
  if handle == nil then
    return nil
  end
  local size = handle:seek("end")
  handle:close()
  return size
end

-- ---------------------------------------------------------------------------
-- 输出
-- ---------------------------------------------------------------------------
-- 两种，混为一谈就会毁掉屏幕——与 nbsplay 采用的是同一种划分。永久行写一次，光标
-- 下移一行；实时行原地重绘。换行用 setCursorPos 推进，**不是** term.write("\n")，
-- 后者根本不会换行：它把 "\n" 当作普通字符存下，把光标移动一**列**，于是每条消息
-- 都会覆盖上一条。

local function make_writer()
  local term = term_seam()
  local printer = raw_global("print")

  local function plain(text)
    if type(printer) == "function" then
      printer(tostring(text))
    end
  end

  if type(term) ~= "table" or type(term.write) ~= "function"
    or type(term.getCursorPos) ~= "function"
    or type(term.setCursorPos) ~= "function" then
    return { line = plain, refresh = function() end }
  end

  local live = false

  local function advance()
    local _, row = term.getCursorPos()
    if type(row) ~= "number" then
      return
    end
    local height = row
    if type(term.getSize) == "function" then
      local ok, _, measured = pcall(term.getSize)
      if ok and type(measured) == "number" and measured > 0 then
        height = measured
      end
    end
    if row + 1 <= height then
      term.setCursorPos(1, row + 1)
    else
      term.setCursorPos(1, height)
      if type(term.scroll) == "function" then
        term.scroll(1)
      end
    end
  end

  return {
    line = function(text)
      if live then
        term.clearLine()
        live = false
      end
      term.write(tostring(text))
      advance()
    end,
    -- prompt：写在光标当前所在处，并把光标**留在**那里，因为用户就在这一行输入，
    -- 而 `read` 会从当前位置回显。
    --
    -- 它存在是因为 `read` **不接收**提示语参数——它的第一个参数是用于隐藏密码的
    -- 替换字符——所以提示语只能在这里写出去。
    prompt = function(text)
      if live then
        term.clearLine()
        live = false
      end
      term.write(tostring(text))
    end,
    refresh = function(text)
      local _, row = term.getCursorPos()
      if type(row) == "number" then
        term.setCursorPos(1, row)
      end
      term.clearLine()
      term.write(tostring(text))
      if type(row) == "number" then
        term.setCursorPos(1, row)
      end
      live = true
    end,
  }
end

-- ---------------------------------------------------------------------------
-- 纯函数：清单（manifest）
-- ---------------------------------------------------------------------------

-- installer.safe_path(path) -> boolean, reason
--
-- 清单从网络到达，所以它的路径**不可信**。一个把它们天真拼接起来的安装器可能写到
-- /startup，或覆盖用户拥有的任何东西。每一种逃逸形式都被拒绝、而不是被规范化，
-- 因为规范化意味着猜测作者的本意，而这里没有作者可问：
--
--   "../escape.lua"          向上级目录穿越
--   "nbs/../../escape.lua"   从子目录内部穿越
--   "/absolute.lua"          一个绝对路径
--   "C:/windows.lua"         一个 Windows 盘符
--   "nbs\\..\\..\\x.lua"     同一件事的反斜杠写法
--
-- 一个路径只有由朴素的组成部分构成时才被接受：字母、数字、点、短横、下划线，以单个
-- 正斜杠分隔，没有空组成部分，也没有 "." 或 ".." 组成部分。
function installer.safe_path(path)
  if type(path) ~= "string" or path == "" then
    return false, "path is empty"
  end
  if path:sub(1, 1) == "/" then
    return false, "path is absolute"
  end
  if path:sub(-1) == "/" then
    return false, "path ends with a separator"
  end
  if path:find("\\", 1, true) ~= nil then
    return false, "path contains a backslash"
  end
  if path:find(":", 1, true) ~= nil then
    return false, "path contains a colon"
  end
  if path:find("//", 1, true) ~= nil then
    return false, "path contains an empty component"
  end
  for component in path:gmatch("[^/]+") do
    if component == "." or component == ".." then
      return false, "path contains a relative component"
    end
    if component:find("^%s*$") then
      return false, "path contains a blank component"
    end
    if component:match("[^%w%._%-]") then
      return false, "path contains an unexpected character"
    end
  end
  return true
end

-- installer.parse_manifest(text) -> { version, files } | nil, error
--
-- 刻意只用两个扁平的关键字，这样解析器小到可以完整地推理，也不会被嵌套骗到：
--
--   # 注释
--   version 1.0.0
--   file    <path> <bytes>
--
-- `commit` 行是**接受并忽略**，而不是拒绝：老清单可能带着一行，而上一次安装写下的
-- 状态会用同一个解析器读回来，所以拒绝它会让 `install list` 在「格式变更之前就已
-- 安装」的电脑上坏掉。忽略它是诚实的——无论哪种情况文件都来自 `main`，所以一条被
-- 记录下来的 commit 描述不了任何本程序会据以行动的东西。
--
-- 每一次拒绝都是**拒绝**，不是警告：一份自相矛盾的清单（「同一个文件既是 10 字节
-- 又是 20 字节」）没有站得住脚的解释，而猜测会安装出一棵没人选过的目录树。
function installer.parse_manifest(text)
  if type(text) ~= "string" or text == "" then
    return nil, "the manifest is empty"
  end

  local version = nil
  local commit = nil
  local files = {}
  local seen = {}

  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local keyword, rest = line:match("^(%S+)%s*(.*)$")
      if keyword == "version" then
        if rest == "" then
          return nil, "the manifest has an empty version"
        end
        version = rest
      elseif keyword == "commit" then
        -- 接受并忽略；见上文说明。刻意不校验，这样一条被记录下来的 commit 永远
        -- 无法拦住一次合法安装。
        commit = rest
      elseif keyword == "file" then
        local path, size_text = rest:match("^(%S+)%s+(%S+)$")
        if path == nil then
          return nil, "malformed file line: " .. line
        end
        local ok, reason = installer.safe_path(path)
        if not ok then
          return nil, "unsafe path in the manifest (" .. reason .. "): " .. path
        end
        local size = tonumber(size_text)
        if size == nil or size < 0 or size ~= math.floor(size) then
          return nil, "the manifest's size for " .. path
            .. " is not a byte count: " .. tostring(size_text)
        end
        if seen[path] then
          return nil, "duplicate path in the manifest: " .. path
        end
        seen[path] = true
        files[#files + 1] = { path = path, size = size }
      else
        return nil, "unknown keyword in the manifest: " .. tostring(keyword)
      end
    end
  end

  if version == nil then
    return nil, "the manifest has no version line"
  end
  if #files == 0 then
    return nil, "the manifest lists no file lines"
  end

  -- 存在 `commit` 时把它带出去，好让调用方想显示就显示，但不依赖它。
  return { version = version, commit = commit, files = files }
end

-- installer.build_url(prefix, reference, path) -> string
--
-- 一套模板同时覆盖「有代理」与「无代理」：代理 prefix 与真正的 raw URL 拼接，而
-- `direct` 的 prefix 是**空串**，所以同一个表达式对两种情况都产出正确结果。
--
-- `reference` 是 raw URL 里仓库名之后的那一段——这里是 `main`。它做成参数而不是
-- 常量，是为了让这个值只存在于一处。
function installer.build_url(prefix, reference, path)
  local base = tostring(prefix or "")
  if base ~= "" and base:sub(-1) ~= "/" then
    base = base .. "/"
  end
  return base .. installer.RAW_HOST .. installer.REPO .. "/"
    .. tostring(reference) .. "/" .. tostring(path)
end

-- installer.next_mirror(mirrors, index) -> mirror
--
-- 第 `index` 次尝试该用的镜像，越界后**回绕**。单个不可达的镜像绝不能把用户留在
-- 「一个来源都没有」的境地，而回绕正是让重试循环有界的原因：`attempt = 1..#mirrors`
-- 会按顺序恰好访问每个镜像一次，从首选的那个开始。
function installer.next_mirror(mirrors, index)
  if type(mirrors) ~= "table" or #mirrors == 0 then
    return nil
  end
  local count = #mirrors
  local position = tonumber(index) or 1
  if position < 1 then
    position = 1
  end
  -- ((n - 1) % count) + 1 把任意正数 n 映射到 1..count，所以调用方不用做边界检查，
  -- 且尝试次数 == 镜像数恰好是一整轮。
  position = (position - 1) % count + 1
  return mirrors[position]
end

-- ---------------------------------------------------------------------------
-- 纯函数：命令行
-- ---------------------------------------------------------------------------

installer.COMMANDS = {
  install = true, update = true, upgrade = true, remove = true,
  list = true, verify = true, mirror = true, help = true,
}

-- installer.parse_command(argv) -> { command, args, flag } | nil, error
--
-- 旗标可以出现在任何位置。`--mirror` 取下一个词作为它的值，所以一个悬空的
-- `--mirror` 会被拒绝，而不是悄悄钉住一个名叫 "" 的镜像。
function installer.parse_command(argv)
  if type(argv) ~= "table" or #argv == 0 then
    return nil, "no command given"
  end

  local command = nil
  local args = {}
  local flag = {}

  local index = 1
  while index <= #argv do
    local value = argv[index]
    if type(value) == "string" and value:sub(1, 2) == "--" then
      local name = value:sub(3)
      if name == "purge" or name == "force" then
        flag[name] = true
        index = index + 1
      elseif name == "mirror" then
        local next_value = argv[index + 1]
        if type(next_value) ~= "string" or next_value == "" then
          return nil, "--mirror needs a mirror name"
        end
        flag.mirror = next_value
        index = index + 2
      else
        return nil, "unknown option: " .. value
      end
    elseif command == nil then
      if not installer.COMMANDS[value] then
        return nil, "unknown command: " .. tostring(value)
      end
      command = value
      index = index + 1
    else
      args[#args + 1] = value
      index = index + 1
    end
  end

  if command == nil then
    return nil, "no command given"
  end

  return { command = command, args = args, flag = flag }
end

-- ---------------------------------------------------------------------------
-- 取回（Fetching）
-- ---------------------------------------------------------------------------

-- choose_mirrors(flag_mirror) -> array
--
-- 被钉住的镜像**先**试，其余跟在后面，这样 `--mirror x` 既能诊断某个镜像，又不会
-- 把一次小故障变成一次失败。
local function choose_mirrors(flag_mirror)
  local list = installer.DEFAULT_MIRRORS
  if flag_mirror == nil then
    return list
  end
  local ordered = {}
  for index = 1, #list do
    if list[index].name == flag_mirror then
      ordered[#ordered + 1] = list[index]
    end
  end
  if #ordered == 0 then
    return nil, "no such mirror: " .. tostring(flag_mirror)
  end
  for index = 1, #list do
    if list[index].name ~= flag_mirror then
      ordered[#ordered + 1] = list[index]
    end
  end
  return ordered
end

-- fetch(url) -> body | nil, reason
--
-- http.get 在请求失败时**不抛错**——它返回 nil、message，可能还有一个失败的响应
-- 句柄。pcall 把这些都带出来，所以 reason 落在**第三个**槽位；只捕获第二个会把一个
-- 404 报成「请求失败」，对用户而言什么都没说。那个失败的句柄是一个真句柄，会被关闭，
-- 因为 CC 对打开文件数有上限。
local function fetch(url)
  local api = http_seam()
  if type(api) ~= "table" or type(api.get) ~= "function" then
    return nil, "this computer has no http API"
  end

  local ok, response, message, failing = pcall(api.get, url)
  if not ok then
    return nil, "the request raised: " .. tostring(response)
  end
  if response == nil then
    if type(failing) == "table" and type(failing.close) == "function" then
      pcall(failing.close)
    end
    local reason = message
    if type(reason) ~= "string" or reason == "" then
      reason = "the request failed"
    end
    return nil, reason
  end

  local chunks = {}
  while true do
    local read_ok, chunk = pcall(response.read, 8192)
    if not read_ok then
      pcall(response.close)
      return nil, "the response was interrupted"
    end
    if chunk == nil or chunk == "" then
      break
    end
    chunks[#chunks + 1] = chunk
  end
  pcall(response.close)

  local body = table.concat(chunks)
  if #body == 0 then
    return nil, "the server returned nothing"
  end
  return body
end

-- prefer_mirror(mirrors, chosen) -> 把 `chosen` 放到最前的数组
--
-- 刚刚服务过清单的镜像已经**证明**了自己可用，所以之后每个请求都该先试它，而不是
-- 那些已知很慢的。没有这一步，20 个文件每一个都会从列表顶端走一遍，而在好的镜像
-- 前面有两个死镜像时，那就是**每个文件**两次 30 秒的 http 超时——二十分钟的沉默，
-- 而原因安装器在第一个请求之后就已经知道了。
--
-- 其余镜像保持原有顺序，这样后来才开始失败的镜像仍然可达。
function installer.prefer_mirror(mirrors, chosen)
  if type(mirrors) ~= "table" or #mirrors == 0 or type(chosen) ~= "table" then
    return mirrors
  end
  local ordered = { chosen }
  for index = 1, #mirrors do
    if mirrors[index] ~= chosen then
      ordered[#ordered + 1] = mirrors[index]
    end
  end
  return ordered
end

-- ---------------------------------------------------------------------------
-- 磁盘
-- ---------------------------------------------------------------------------

local function read_file(path)
  local fs_api = fs_seam()
  if type(fs_api) == "table" and type(fs_api.open) == "function" then
    local ok, handle = pcall(fs_api.open, path, "r")
    if not ok or handle == nil then
      return nil
    end
    local text = handle.readAll()
    pcall(handle.close)
    return text
  end
  local handle = io.open(path, "r")
  if handle == nil then
    return nil
  end
  local text = handle:read("*a")
  handle:close()
  return text
end

local function write_file(path, text)
  local fs_api = fs_seam()
  if type(fs_api) == "table" and type(fs_api.open) == "function" then
    local ok, handle = pcall(fs_api.open, path, "w")
    if not ok or handle == nil then
      return false, "cannot write " .. path
    end
    handle.write(text)
    pcall(handle.close)
    return true
  end
  local handle = io.open(path, "wb")
  if handle == nil then
    return false, "cannot write " .. path
  end
  handle:write(text)
  handle:close()
  return true
end

-- make_dir(path)：创建 path 以及每一级缺失的父目录。
--
-- `/lib` 在 CraftOS 电脑上存在，但 `/lib/nbs` 与 `/lib/player` 不存在，状态目录也不
-- 存在。每个组成部分依次创建，因为 fs.makeDir 只创建**一层**。
local function make_dir(path)
  local fs_api = fs_seam()
  if type(fs_api) ~= "table" or type(fs_api.makeDir) ~= "function" then
    return true
  end
  local built = ""
  for component in tostring(path):gmatch("[^/]+") do
    built = built .. "/" .. component
    local exists = type(fs_api.exists) == "function" and fs_api.exists(built)
    if not exists then
      local ok, err = pcall(fs_api.makeDir, built)
      if not ok then
        return false, "cannot create " .. built .. ": " .. tostring(err)
      end
    end
  end
  return true
end

local function delete_file(path)
  local fs_api = fs_seam()
  if type(fs_api) ~= "table" or type(fs_api.delete) ~= "function" then
    return false, "this filesystem cannot delete"
  end
  local ok, err = pcall(fs_api.delete, path)
  if not ok then
    return false, tostring(err)
  end
  return true
end

-- ---------------------------------------------------------------------------
-- 磁盘上的镜像
-- ---------------------------------------------------------------------------

local function parse_sources(text)
  local mirrors = {}
  for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
    local clean = line:gsub("\r", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if clean ~= "" and clean:sub(1, 1) ~= "#" then
      -- prefix 可以**缺席**，`direct` 就是这么写的：空前缀表示「不前置任何东西」，
      -- 即按原样取回 raw URL。用 `%s*` 再接 `%S*`，好让只有名字的一行能被解析出来，
      -- 而不是被跳过。
      local name, prefix = clean:match("^(%S+)%s*(%S*)$")
      if name ~= nil then
        mirrors[#mirrors + 1] = { name = name, prefix = prefix or "" }
      end
    end
  end
  return mirrors
end

local function render_sources(mirrors)
  local lines = {
    "# CCNBSLib installer sources -- one mirror per line: <name> [prefix]",
    "# The prefix is prepended to the full raw URL; omit it to fetch GitHub directly.",
    "# The first entry is preferred; the rest are tried in order.",
  }
  for index = 1, #mirrors do
    local mirror = mirrors[index]
    if mirror.prefix == nil or mirror.prefix == "" then
      lines[#lines + 1] = mirror.name
    else
      lines[#lines + 1] = mirror.name .. " " .. mirror.prefix
    end
  end
  return table.concat(lines, "\n") .. "\n"
end

-- copy_mirrors(mirrors) -> 该数组的一个浅拷贝
--
-- load_mirrors 绝不能把 installer.DEFAULT_MIRRORS 本身交出去。`mirror add` 会向
-- 交给它的任何东西追加，所以返回模块常量会让一条命令在进程余下的生命周期里永久
-- 改写默认值——同一个进程里再跑一次就会看到更长的列表，反复 add 还会累积重复项。
-- 每个调用方拿一份拷贝，就让默认值在事实上不可变。
local function copy_mirrors(mirrors)
  local copy = {}
  for index = 1, #mirrors do
    copy[index] = mirrors[index]
  end
  return copy
end

local function load_mirrors()
  local text = read_file(installer.SOURCES_PATH)
  if text == nil then
    return copy_mirrors(installer.DEFAULT_MIRRORS)
  end
  local parsed = parse_sources(text)
  if #parsed == 0 then
    return copy_mirrors(installer.DEFAULT_MIRRORS)
  end
  return parsed
end

local function save_mirrors(mirrors)
  local ok = make_dir(installer.STATE_DIR)
  if not ok then
    return false, "cannot create " .. installer.STATE_DIR
  end
  return write_file(installer.SOURCES_PATH, render_sources(mirrors))
end

-- select_mirror(mirrors, out, opts) -> mirror | nil, reason
--
-- 编号菜单，由 `install` 与 `mirror pick` 共用，因为二者只在一件事上不同：空答案
-- **意味**着什么：
--
--   opts.allow_automatic = true   空答案意为「按自动顺序来」，并且不作抱怨地返回
--                                 nil。这是安装路径：用户按下回车是希望安装继续，
--                                 而不是被取消。
--   opts.allow_automatic = false  空答案即取消，reason 会说明这一点。这是
--                                 `mirror pick`——它存在的全部目的就是**修改**设置，
--                                 所以「什么都不改」是一个有效结果，必须被报告出来。
--
-- 被选中的镜像在返回之前会先测一遍：一个不可达的选择否则会用于每个文件、失败二十
-- 次。测试失败时返回 reason，由调用方决定——对安装而言这意味着继续走自动顺序，而
-- 自动顺序本来就会跳过死镜像。
local function select_mirror(mirrors, out, opts)
  opts = type(opts) == "table" and opts or {}

  out.line("")
  out.line("install: which mirror?")
  for index = 1, #mirrors do
    out.line(string.format("install:   %d) %-14s %s", index, mirrors[index].name,
      mirrors[index].prefix == "" and "(GitHub, no proxy)" or mirrors[index].prefix))
  end
  out.line("")

  local prompt
  if opts.allow_automatic then
    prompt = "number (blank = try them in order): "
  else
    prompt = "number (blank to cancel): "
  end

  -- 先写提示语，再读。`read` 没有提示语参数——它的第一个参数是替换字符——所以在这里
  -- 写出去是它唯一能出现的方式。
  out.prompt(prompt)
  local answer = read_seam()

  if type(answer) ~= "string" then
    -- 无法读取：不是错误，只是没什么可问的。
    return nil, "nothing was read"
  end

  local trimmed = answer:gsub("%s", "")

  if trimmed == "" then
    if opts.allow_automatic then
      return nil, nil
    end
    return nil, "cancelled -- nothing changed"
  end

  local choice = tonumber(trimmed)
  if choice == nil or choice ~= math.floor(choice)
    or choice < 1 or choice > #mirrors then
    if opts.allow_automatic then
      -- 不要因为一次笔误就中止安装；说明情况并自动继续。
      return nil, "not a listed number, so the automatic order is used"
    end
    return nil, "not a listed number, so nothing changed"
  end

  local chosen = mirrors[choice]
  out.refresh("testing " .. chosen.name .. " ...")
  local url = installer.build_url(chosen.prefix, installer.BRANCH, "manifest.txt")
  local body, reason = fetch(url)
  out.line("")

  if body == nil then
    if opts.allow_automatic then
      return nil, chosen.name .. " did not answer (" .. tostring(reason)
        .. "), so the automatic order is used"
    end
    return nil, chosen.name .. " did not answer: " .. tostring(reason)
  end

  return chosen, nil
end

-- ---------------------------------------------------------------------------
-- 命令
-- ---------------------------------------------------------------------------

local function human_bytes(count)
  local number = tonumber(count) or 0
  if number < 1024 then
    return tostring(number) .. " B"
  end
  if number < 1024 * 1024 then
    return string.format("%.1f KiB", number / 1024)
  end
  return string.format("%.1f MiB", number / (1024 * 1024))
end

-- installer.progress_line(done, total, label, columns) -> 一条**放得下**的行
--
-- 刻意保持严格**窄于**终端，因为 term.write **不会**折行：越过右边缘的文字会被
-- **裁剪**并丢失（实测；见 nbsplay，它是吃了苦头才学到这一点的）。计数器是最后才
-- 牺牲的东西，因为它就是进度本身。
--
-- 纯函数，所以这套算术由 spec 钉住，而不是靠信任。
function installer.progress_line(done, total, label, columns)
  local width = tonumber(columns)
  if width == nil then
    width = 51
    local term = term_seam()
    if type(term) == "table" and type(term.getSize) == "function" then
      local ok, measured = pcall(term.getSize)
      if ok and type(measured) == "number" then
        width = measured
      end
    end
  end

  local count = tonumber(total) or 0
  local index = tonumber(done) or 0
  local name = tostring(label or "install")

  -- "label [" + bar + "] " + "999/999" == #name + 2 + bar + 2 + digits + 1 + digits
  local numbers = tostring(index) .. "/" .. tostring(count)
  local overhead = #name + 2 + 2 + #numbers
  local bar_width = width - 1 - overhead
  if bar_width < 0 then
    bar_width = 0
  end

  local filled = 0
  if count > 0 then
    filled = math.floor(index / count * bar_width + 0.5)
  end
  if filled > bar_width then
    filled = bar_width
  end

  local text = name .. " [" .. string.rep("#", filled)
    .. string.rep("-", bar_width - filled) .. "] " .. numbers
  if bar_width == 0 then
    -- 连放一条进度条的地方都没有：光靠计数器也足以说明有事情在发生。
    text = name .. " " .. numbers
  end
  if #text > width - 1 then
    text = text:sub(1, width - 1)
  end
  return text
end

-- 一条严格保持**窄于**终端的进度行，因为 term.write 会
-- download_one(path, mirrors, log) -> body | nil, reason
--
-- 轮换就发生**这里**，逐文件：一个应答了清单的镜像对一个大文件仍可能不健康，而一次
-- 安装不该因为某个镜像中途挂掉就整场失败。
local function download_one(path, mirrors, log)
  local last_reason = nil
  for attempt = 1, #mirrors do
    local mirror = installer.next_mirror(mirrors, attempt)
    local url = installer.build_url(mirror.prefix, installer.BRANCH, path)
    log(string.format("  %s <- %s", path, mirror.name))
    local body, reason = fetch(url)
    if body == nil then
      last_reason = mirror.name .. ": " .. tostring(reason)
      log("  failed: " .. last_reason)
    else
      return body, nil, mirror
    end
  end
  return nil, last_reason or "every mirror failed", nil
end

-- manifest_from(mirrors, log, out) -> parsed | nil, reason, answered_mirror
--
-- 这里**不能没有**反馈。`http.get` 在放弃前会等最多 30 秒（HTTPAPI.java 里的
-- DEFAULT_TIMEOUT，而且宿主配置可以调高），所以静默地试四个镜像能让屏幕冻住两分钟。
-- 用户无法把它和「崩溃」区分开，自然的反应就是去按 Ctrl+T。所以每一次尝试都会在**同
-- 一条刷新行**上播报——哪个镜像、第几个、以及结果如何。
--
-- 应答过的镜像会被**返回**，好让调用方在之后每个请求里先试它。为什么这件事比看上去
-- 更重要，见 installer.prefer_mirror。
local function manifest_from(mirrors, log, out)
  local last_reason = nil
  local total = #mirrors

  for attempt = 1, total do
    local mirror = installer.next_mirror(mirrors, attempt)
    local url = installer.build_url(mirror.prefix, installer.BRANCH,
      "manifest.txt")

    out.refresh(string.format("looking for manifest.txt  [%d/%d] %s",
      attempt, total, mirror.name))
    log("manifest <- " .. mirror.name)

    local body, reason = fetch(url)
    if body ~= nil then
      local parsed, parse_err = installer.parse_manifest(body)
      if parsed == nil then
        return nil, "the manifest from " .. mirror.name .. " is unusable: "
          .. tostring(parse_err)
      end
      out.line(string.format("install: %s answered", mirror.name))
      return parsed, nil, mirror
    end

    last_reason = mirror.name .. ": " .. tostring(reason)
    log("  failed: " .. last_reason)
    out.refresh(string.format("looking for manifest.txt  [%d/%d] %s -- failed",
      attempt, total, mirror.name))
  end

  return nil, "no mirror served manifest.txt (last: " .. tostring(last_reason) .. ")"
end

local function download_all(parsed, mirrors, out, log, opts)
  local total = #parsed.files
  local bytes = 0
  for index = 1, total do
    local entry = parsed.files[index]
    out.refresh(installer.progress_line(index - 1, total, "install", nil))

    local existing = installer.file_size(installer.INSTALL_ROOT .. "/" .. entry.path)
    if opts and opts.skip_matching and existing == entry.size then
      bytes = bytes + entry.size
      log(string.format("  %s already current (%d bytes)", entry.path, entry.size))
    else
      local body, reason = download_one(entry.path, mirrors, log)
      if body == nil then
        return nil, "E_DOWNLOAD", entry.path .. " -- " .. tostring(reason)
      end
      if #body ~= entry.size then
        return nil, "E_SIZE", string.format(
          "%s arrived as %d bytes, the manifest says %d", entry.path, #body, entry.size)
      end
      local target = installer.INSTALL_ROOT .. "/" .. entry.path
      local dir = target:match("^(.*)/[^/]+$")
      if dir ~= nil then
        local ok, dir_err = make_dir(dir)
        if not ok then
          return nil, "E_WRITE", tostring(dir_err)
        end
      end
      local ok, write_err = write_file(target, body)
      if not ok then
        return nil, "E_WRITE", tostring(write_err)
      end
      bytes = bytes + #body
      log(string.format("  %s (%d bytes)", entry.path, #body))
    end

    out.refresh(installer.progress_line(index, total, "install", nil))
  end
  return true, nil, bytes
end

local function render_installed(parsed)
  local lines = {
    "# written by install.lua -- the state of the last successful install",
    "version " .. parsed.version,
  }
  for index = 1, #parsed.files do
    lines[#lines + 1] = string.format("file %s %d",
      parsed.files[index].path, parsed.files[index].size)
  end
  return table.concat(lines, "\n") .. "\n"
end

local function installed_state()
  local text = read_file(installer.INSTALLED_PATH)
  if text == nil then
    return nil
  end
  return installer.parse_manifest(text)
end

-- ---------------------------------------------------------------------------
-- run(argv, opts) -> 退出码
-- ---------------------------------------------------------------------------

function installer.run(argv, opts)
  opts = type(opts) == "table" and opts or {}

  -- read 接缝可以按次调用提供，测试就是靠它来回答一个提示的。
  if type(opts.read) == "function" then
    seams.read = opts.read
  end
  local out = make_writer()
  if type(opts.write) == "function" then
    out = {
      line = opts.write,
      refresh = opts.write,
      prompt = opts.write,
    }
  end

  local log = function(text)
    if opts.debug then
      out.line("install: . " .. tostring(text))
    end
  end

  local function say(text)
    out.line("install: " .. tostring(text))
  end
  local function fail(code, detail)
    out.line("install: " .. tostring(code) .. ": " .. tostring(detail or ""))
    return 1
  end
  local function usage()
    out.line("usage: install <command> [options]")
    out.line("  (installs CCNBSLib; no arguments means install)")
    out.line("  install              fetch and install every file")
    out.line("  update               refresh the manifest only")
    out.line("  upgrade              re-fetch files whose size changed")
    out.line("  verify               report files that differ from the manifest")
    out.line("  remove [--purge]     delete installed files (--purge also state)")
    out.line("  list                 show what is installed")
    out.line("  mirror list|add|remove|default|test|pick")
    out.line("options: --mirror <name>   --debug")
  end

  -- 没有参数就是 install。
  --
  -- 这正是让这个工具在一台全新电脑上成为一条命令的原因。CC:Tweaked 自带 `wget`，
  -- 它的 `run` 形式会下载一个文件并执行它，把剩下的词作为变参传进去：
  --
  --     wget run <url>              -- 本文件不带参数运行
  --     wget run <url> upgrade      -- ……带上 "upgrade"
  --
  -- 所以默认走 install 让最短的那条命令恰好就是用户想要的那件事。`help` 打印用法。
  --
  -- 空表由 `argv or {}` 构造、而不是直接透传，因为 parse_command **拒绝**非表，而一次
  -- 无人值守的运行不该依赖调用方是否提供过它。
  local parsed_command, command_error = installer.parse_command(argv)
  if parsed_command == nil then
    if type(argv) == "table" and #argv == 0 then
      parsed_command = { command = "install", args = {}, flag = {} }
    else
      say(command_error)
      usage()
      return 0
    end
  end

  local command = parsed_command.command
  local flag = parsed_command.flag

  if command == "help" then
    usage()
    return 0
  end

  local mirrors, mirror_error = choose_mirrors(flag.mirror)
  if mirrors == nil then
    return fail("E_USAGE", mirror_error)
  end

  -- ---------------------------------------------------------------- install
  if command == "install" then
    -- 先问。只有用户不愿选择时才走自动顺序，因为一台网络屏蔽掉这些主机的电脑没法
    -- 说出哪一个可用——而替代方案就是二十分钟的超时。
    local chosen, why = select_mirror(mirrors, out, { allow_automatic = true })
    if chosen ~= nil then
      mirrors = installer.prefer_mirror(mirrors, chosen)
      say("using " .. chosen.name)
    elseif type(why) == "string" then
      say(why)
    end

    local parsed, reason, answered = manifest_from(mirrors, log, out)
    if parsed == nil then
      fail("E_MANIFEST", reason)
      out.line("")
      say("try: install mirror pick    (choose one interactively)")
      return 1
    end
    -- 从这里开始，应答过的镜像被优先尝试。
    mirrors = installer.prefer_mirror(mirrors, answered)
    say(string.format("CCNBSLib %s -- %d files", parsed.version, #parsed.files))

    local ok, code, detail = download_all(parsed, mirrors, out, log,
      { skip_matching = not flag.force })
    if not ok then
      return fail(code, detail)
    end

    local state_ok, state_err = make_dir(installer.STATE_DIR)
    if not state_ok then
      return fail("E_WRITE", state_err)
    end
    write_file(installer.INSTALLED_PATH, render_installed(parsed))

    out.line("")
    say(string.format("done -- %s installed to %s", human_bytes(detail),
      installer.INSTALL_ROOT))
    return 0
  end

    -- ---------------------------------------------------------------- update
    if command == "update" then
      local parsed, reason, answered = manifest_from(mirrors, log, out)
      if parsed == nil then
        return fail("E_MANIFEST", reason)
      end
      mirrors = installer.prefer_mirror(mirrors, answered)
      local state_ok, state_err = make_dir(installer.STATE_DIR)
    if not state_ok then
      return fail("E_WRITE", state_err)
    end
    write_file(installer.INSTALLED_PATH, render_installed(parsed))
    say(string.format("manifest current: %s, %d files (nothing installed)",
      parsed.version, #parsed.files))
    return 0
  end

  -- ---------------------------------------------------------------- upgrade
  if command == "upgrade" then
    local current = installed_state()
    if current == nil then
      return fail("E_MISSING", "nothing is installed; run install first")
    end
      local parsed, reason, answered = manifest_from(mirrors, log, out)
      if parsed == nil then
        return fail("E_MANIFEST", reason)
      end
      mirrors = installer.prefer_mirror(mirrors, answered)

      local stale = {}
    for index = 1, #parsed.files do
      local entry = parsed.files[index]
      local size = installer.file_size(installer.INSTALL_ROOT .. "/" .. entry.path)
      if size ~= entry.size then
        stale[#stale + 1] = entry
      end
    end

    say(string.format("installed %s -> available %s; %d file(s) need updating",
      current.version, parsed.version, #stale))
    if #stale == 0 then
      say("already up to date")
      return 0
    end

    for index = 1, #stale do
      local entry = stale[index]
      out.refresh(installer.progress_line(index - 1, #stale, "upgrade", nil))
      local body, reason = download_one(entry.path, mirrors, log)
      if body == nil then
        return fail("E_DOWNLOAD", entry.path .. " -- " .. tostring(reason))
      end
      if #body ~= entry.size then
        return fail("E_SIZE", string.format("%s arrived as %d bytes, expected %d",
          entry.path, #body, entry.size))
      end
      local target = installer.INSTALL_ROOT .. "/" .. entry.path
      local dir = target:match("^(.*)/[^/]+$")
      if dir ~= nil then make_dir(dir) end
      local ok, write_err = write_file(target, body)
      if not ok then
        return fail("E_WRITE", write_err)
      end
      out.refresh(installer.progress_line(index, #stale, "upgrade", nil))
    end
    write_file(installer.INSTALLED_PATH, render_installed(parsed))
    out.line("")
    say(string.format("done -- %d file(s) updated to %s", #stale, parsed.version))
    return 0
  end

  -- ---------------------------------------------------------------- verify
  if command == "verify" then
    local state = installed_state()
    if state == nil then
      return fail("E_MISSING", "no install record; run install first")
    end
    local bad = {}
    local missing = {}
    for index = 1, #state.files do
      local entry = state.files[index]
      local size = installer.file_size(installer.INSTALL_ROOT .. "/" .. entry.path)
      if size == nil then
        missing[#missing + 1] = entry.path
      elseif size ~= entry.size then
        bad[#bad + 1] = string.format("%s is %d bytes, expected %d",
          entry.path, size, entry.size)
      end
    end
    for index = 1, #missing do
      out.line("install: missing: " .. missing[index])
    end
    for index = 1, #bad do
      out.line("install: differs: " .. bad[index])
    end
    if #missing == 0 and #bad == 0 then
      say(string.format("all %d files match %s", #state.files, state.version))
      return 0
    end
    return fail("E_VERIFY", string.format("%d missing, %d differ",
      #missing, #bad))
  end

  -- ---------------------------------------------------------------- remove
  if command == "remove" then
    local state = installed_state()
    if state == nil then
      return fail("E_MISSING", "nothing is installed")
    end
    local removed = 0
    for index = 1, #state.files do
      local target = installer.INSTALL_ROOT .. "/" .. state.files[index].path
      if installer.file_size(target) ~= nil then
        local ok = delete_file(target)
        if ok then
          removed = removed + 1
        else
          say("could not remove " .. state.files[index].path)
        end
      end
    end
    delete_file(installer.INSTALLED_PATH)
    -- sources.txt 是**用户**的偏好，不属于包，所以它在一次普通 remove 后存活——
    -- 与 `apt remove` 不动 sources.list 是同一个道理。
    if flag.purge then
      delete_file(installer.SOURCES_PATH)
      say("purged mirror settings as well")
    end
    say(string.format("removed %d file(s)", removed))
    return 0
  end

  -- ---------------------------------------------------------------- list
  if command == "list" then
    local state = installed_state()
    if state == nil then
      say("nothing is installed")
      return 0
    end
    say("CCNBSLib " .. tostring(state.version))
    local total = 0
    for index = 1, #state.files do
      local entry = state.files[index]
      local size = installer.file_size(installer.INSTALL_ROOT .. "/" .. entry.path)
      total = total + (size or 0)
      out.line(string.format("install:   %-32s %s",
        entry.path, size == nil and "MISSING" or human_bytes(size)))
    end
    say(string.format("%d files, %s on disk", #state.files, human_bytes(total)))
    return 0
  end

  -- ---------------------------------------------------------------- mirror
  if command == "mirror" then
    local sub = parsed_command.args[1]
    if sub == nil or sub == "list" then
      local list = load_mirrors()
      for index = 1, #list do
        out.line(string.format("install: %s%-14s %s",
          index == 1 and "* " or "  ", list[index].name, list[index].prefix))
      end
      say("the first entry is preferred; the rest are tried in order")
      say("use `install mirror pick` to choose one interactively")
      return 0
    end

    if sub == "add" then
      local name = parsed_command.args[2]
      local prefix = parsed_command.args[3]
      if name == nil or prefix == nil then
        return fail("E_USAGE", "mirror add <name> <prefix>")
      end
      if prefix:sub(1, 8) ~= "https://" and prefix:sub(1, 7) ~= "http://" then
        return fail("E_USAGE", "a mirror prefix must start with http:// or https://")
      end
      local list = load_mirrors()
      for index = 1, #list do
        if list[index].name == name then
          return fail("E_USAGE", "a mirror named " .. name .. " already exists")
        end
      end
      list[#list + 1] = { name = name, prefix = prefix }
      local ok, err = save_mirrors(list)
      if not ok then
        return fail("E_WRITE", err)
      end
      say("added mirror " .. name)
      return 0
    end

    if sub == "remove" then
      local name = parsed_command.args[2]
      if name == nil then
        return fail("E_USAGE", "mirror remove <name>")
      end
      local list = load_mirrors()
      local kept = {}
      local found = false
      for index = 1, #list do
        if list[index].name == name then
          found = true
        else
          kept[#kept + 1] = list[index]
        end
      end
      if not found then
        return fail("E_MISSING", "no mirror named " .. name)
      end
      if #kept == 0 then
        return fail("E_USAGE", "a mirror list cannot be empty")
      end
      local ok, err = save_mirrors(kept)
      if not ok then
        return fail("E_WRITE", err)
      end
      say("removed mirror " .. name)
      return 0
    end

    if sub == "default" then
      local name = parsed_command.args[2]
      if name == nil then
        return fail("E_USAGE", "mirror default <name>")
      end
      local list = load_mirrors()
      local chosen = nil
      local rest = {}
      for index = 1, #list do
        if list[index].name == name then
          chosen = list[index]
        else
          rest[#rest + 1] = list[index]
        end
      end
      if chosen == nil then
        return fail("E_MISSING", "no mirror named " .. name)
      end
      table.insert(rest, 1, chosen)
      local ok, err = save_mirrors(rest)
      if not ok then
        return fail("E_WRITE", err)
      end
      say("default mirror is now " .. name)
      return 0
    end

    if sub == "test" then
      local list = load_mirrors()
      local wanted = parsed_command.args[2]
      local healthy = 0
      for index = 1, #list do
        local mirror = list[index]
        if wanted == nil or mirror.name == wanted then
          local url = installer.build_url(mirror.prefix, "main", "manifest.txt")
          local body, reason = fetch(url)
          if body ~= nil then
            healthy = healthy + 1
            say(string.format("%-14s ok (%s)", mirror.name, human_bytes(#body)))
          else
            say(string.format("%-14s FAILED: %s", mirror.name, tostring(reason)))
          end
        end
      end
      if healthy == 0 then
        return fail("E_MIRROR", "no mirror answered")
      end
      return 0
    end

    if sub == "pick" then
      -- 改动已保存的顺序。空答案即取消，因为这条命令存在的唯一目的就是修改设置。
      local list = load_mirrors()
      local chosen, reason = select_mirror(list, out, { allow_automatic = false })

      if chosen == nil then
        say(reason or "nothing changed")
        return 1
      end

      local reordered = installer.prefer_mirror(list, chosen)
      local ok_save, save_err = save_mirrors(reordered)
      if not ok_save then
        return fail("E_WRITE", save_err)
      end
      say(chosen.name .. " answered and is now preferred")
      return 0
    end

    return fail("E_USAGE", "unknown mirror subcommand: " .. tostring(sub))
  end

  return fail("E_USAGE", "unknown command: " .. tostring(command))
end

-- ---------------------------------------------------------------------------
-- 自动运行（Autorun）
-- ---------------------------------------------------------------------------
-- 它在**什么时候**运行，以及这个守卫为什么长这样。
--
-- 它原本问的是 `shell.getRunningProgram():find("install")`——「我是作为一个程序
-- 被运行的吗？」——并**按名字**作答。这恰恰在用户最先遇到的那些场景里不可靠，而且
-- 失败得**悄无声息**，这是失败能有的最糟糕形态。实测，三种情形：
--
--   1. 从 shell 以 `install.lua install` 运行       -> 正常
--   2. 不带参数运行                                 -> 打印 usage，然后抛错
--   3. 从 Lua REPL 运行代码（文件最初就是这样下载的）-> getRunningProgram() 报的是
--                                                      rom/programs/lua.lua，守卫
--                                                      失败，文件走到它最后的
--                                                      `return`，却**什么都没打印**
--
-- 情形 3 就是用户报告的「它直接退了」。这个名字还会在重命名、`dofile` 或粘贴进
-- REPL 时改变，所以这个检查没法靠匹配得更狠来修好。
--
-- 因此守卫是「shell 存在，且没有人禁用它」。这与 nbsplay 已经采用的形式相同，并且它
-- 失败得**响亮**：一次误运行会打印 usage，而不是什么都不输出。想要模块而不想运行它
-- 的库消费者就设这个旗标，测试就是这么做的。
if rawget(_G, "__CCNBS_INSTALL_NO_AUTORUN") == nil
  and type(shell) == "table"
  and type(shell.getRunningProgram) == "function" then

  local code = installer.run({ ... })
  if code ~= 0 then
    -- 本项目里没有 os.exit（它被禁用了，而且 Cobalt 的实现不可靠），所以抛错就是
    -- 一个 CC 程序向 shell 报告失败的方式。消息里点出程序名，因为光有 "failed" 什么
    -- 都没告诉用户。
    error("install failed", 0)
  end
end

return installer
