-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 colorgarden
-- Part of CCNBSLib. Licensed under GPL-2.0; see LICENSE.
--
-- install.lua
--
-- THE INSTALLER: apt-shaped, terminal only.
--
--     install install              fetch the manifest and install every file
--     install update               refresh the manifest, install nothing
--     install upgrade              re-fetch only the files whose size changed
--     install verify               report files that no longer match the manifest
--     install remove [--purge]     delete the installed files
--     install list                 show what is installed
--     install mirror <sub>         list / add / remove / default / test
--
-- ===========================================================================
-- WHY A SINGLE FILE, AND WHY IT IS FETCHED BY HAND FIRST
-- ===========================================================================
-- A fresh CC:Tweaked computer has no `wget`, no `curl` and no package manager, so
-- the ONLY way to start is a hand-typed `http.get` followed by `shell.run`. That
-- bootstrap can only fetch ONE file with any confidence, which is why this is
-- deliberately a single file rather than a module tree:
--
--     local r = http.get("<mirror>/raw.githubusercontent.com/colorgarden/CCNBSLib/main/install.lua")
--     local f = fs.open("install.lua", "w")  f.write(r.readAll())  f.close()
--     shell.run("install.lua install")
--
-- ===========================================================================
-- THE FILE LIST COMES FROM A COMMITTED MANIFEST, NOT FROM GITHUB
-- ===========================================================================
-- api.github.com is 403 through every GitHub proxy -- measured, not assumed -- and
-- a proxy is the whole reason this installer exists. So the list of files ships WITH
-- the repository, over raw, which proxies fine.
--
-- ===========================================================================
-- EVERY FILE COMES FROM THE main BRANCH, THROUGH THE SAME MIRROR AS THE MANIFEST
-- ===========================================================================
--  .../main/nbs/analyze.lua      yes
--
-- One reference for everything, so there is no second thing to keep in step.
--
-- TEARING IS DETECTED, NOT PREVENTED. If a push lands while an install is running,
-- the manifest and the files stop agreeing and the per-file byte count catches it:
-- the install fails with E_SIZE and the user retries. That was a deliberate choice
-- over pinning a commit -- pinning needs the manifest to be read from `main` anyway
-- (the commit is only known after reading it) and it makes the manifest's own
-- freshness depend on the commit it names, which is more bookkeeping than a personal
-- project needs. The important part is that the mismatch is LOUD: never a tree
-- assembled from two different versions and reported as success.
--
-- Integrity is therefore: a per-file byte count, checked after download. No content
-- hashing: a CC:Tweaked ROM has no crypto module, so SHA-256 would be pure Lua for
-- the privilege of defending against a threat HTTPS and the byte count already
-- cover.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt. No integer division, no bitwise
-- operators, no utf8.*, no collectgarbage, no string.dump, no os.exit, no goto.
-- Every CC global is read LAZILY through a seam, so this file is `require`-able in
-- plain desktop Lua and its pure parts are unit-testable.

local installer = {}

installer.VERSION = "1.0.0"

-- The repository the files come from, and where they land. INSTALL_ROOT matches the
-- layout README documents; STATE_DIR is a subdirectory so the library's own
-- namespace contains only files that belong to the library.
installer.REPO = "colorgarden/CCNBSLib"
-- The one reference everything is fetched from. Named once so the installation
-- layout, the manifest and the files can never drift apart.
installer.BRANCH = "main"
installer.RAW_HOST = "https://raw.githubusercontent.com/"
installer.INSTALL_ROOT = "/lib"
installer.STATE_DIR = installer.INSTALL_ROOT .. "/ccnbs-install"
installer.SOURCES_PATH = installer.STATE_DIR .. "/sources.txt"
installer.INSTALLED_PATH = installer.STATE_DIR .. "/installed.txt"

-- Mirrors tried in order, and rotated on failure. gh.llkk.cc and ghproxy.net are the
-- two the user named; `direct` reaches GitHub itself for a computer that can.
--
-- A prefix is a genuine PREFIX of the final URL, prepended to the complete raw URL:
--
--   proxy:  "https://gh.llkk.cc/"  ->  https://gh.llkk.cc/https://raw.githubusercontent.com/...
--   direct: ""                     ->  https://raw.githubusercontent.com/...
--
-- So `direct`'s prefix is EMPTY, not the raw host. Writing the host there would
-- double it -- prefix + the raw URL already starts with that host -- and the empty
-- string is what makes one template cover both cases with no special-casing.
installer.DEFAULT_MIRRORS = {
  { name = "gh.llkk.cc", prefix = "https://gh.llkk.cc/" },
  { name = "ghproxy.net", prefix = "https://ghproxy.net/" },
  { name = "ghfast.top", prefix = "https://ghfast.top/" },
  { name = "direct", prefix = "" },
}

-- ---------------------------------------------------------------------------
-- Seams -- every host API is reached through these, so a test can drive the whole
-- installer without a network, a disk or a terminal
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

-- read_seam(): how the installer asks the user a question.
--
-- Injected through the seam so a test can answer it; `read` is a CC global, and an
-- interactive path that was never exercised is exactly how the autorun bug survived
-- (written, never run, silently wrong). Returns nil when there is no way to read,
-- which every caller treats as "the user said nothing".
local function read_seam(prompt)
  if type(seams.read) == "function" then
    return seams.read(prompt)
  end
  local reader = raw_global("read")
  if type(reader) ~= "function" then
    return nil
  end
  local ok, answer = pcall(reader, prompt)
  if not ok then
    return nil
  end
  return answer
end

-- installer.file_size(path) -> number | nil
--
-- Uses the fs seam when there is one, and falls back to plain io so the spec can
-- size real files on a desktop. Returning nil rather than raising lets a caller say
-- "could not read" instead of crashing on a file that vanished mid-run.
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
-- Output
-- ---------------------------------------------------------------------------
-- Two kinds, and conflating them wrecks the screen -- the same split nbsplay uses.
-- A permanent line is written once and the cursor moves DOWN a row; a live line is
-- redrawn in place. The row is advanced with setCursorPos, NOT term.write("\n"),
-- which does not make a newline at all: it stores "\n" as an ordinary character and
-- moves the cursor one COLUMN, so every message would overwrite the last.

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
-- Pure: manifest
-- ---------------------------------------------------------------------------

-- installer.safe_path(path) -> boolean, reason
--
-- A manifest arrives over the network, so its paths are UNTRUSTED. An installer that
-- joined them naively could write to /startup or overwrite anything the user owns.
-- Every escape form is refused rather than normalised, because normalising means
-- guessing what the author meant, and there is no author here to ask:
--
--   "../escape.lua"          parent traversal
--   "nbs/../../escape.lua"   traversal from inside a subdirectory
--   "/absolute.lua"          an absolute path
--   "C:/windows.lua"         a Windows drive
--   "nbs\\..\\..\\x.lua"     the backslash form of the same thing
--
-- A path is accepted only if it is made of plain components: letters, digits, dot,
-- dash, underscore, separated by single forward slashes, with no empty component and
-- no "." or ".." component.
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
-- Deliberately two flat keywords, so the parser is small enough to reason about
-- completely and cannot be fooled by nesting:
--
--   # comment
--   version 1.0.0
--   file    <path> <bytes>
--
-- A `commit` line is ACCEPTED AND IGNORED, not rejected: an older manifest may carry
-- one, and the state written by a previous install is read back with this same
-- parser, so refusing it would break `install list` on a computer that was installed
-- before this format changed. Ignoring it is honest -- the files come from `main`
-- either way, so a recorded commit describes nothing this program acts on.
--
-- Every refusal is a REFUSAL, not a warning: a manifest that says something
-- contradictory ("the same file is 10 bytes and 20 bytes") has no defensible reading,
-- and guessing would install a tree nobody chose.
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
        -- Accepted and ignored; see the note above. Deliberately not validated, so a
        -- recorded commit can never block a legitimate install.
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

  -- `commit` is carried through when present so a caller can display it if it wants
  -- to, but nothing depends on it.
  return { version = version, commit = commit, files = files }
end

-- installer.build_url(prefix, reference, path) -> string
--
-- One template covers a proxy AND no proxy: a proxy prefix is concatenated with the
-- real raw URL, and `direct`'s prefix is the EMPTY string, so the same expression
-- produces the right thing for both.
--
-- `reference` is whatever comes after the repository name in a raw URL -- `main`
-- here. It is a parameter rather than a constant so the value lives in one place.
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
-- The mirror to try on attempt number `index`, WRAPPING past the end. A single
-- unreachable mirror must not leave the user with no source at all, and wrapping is
-- what lets the retry loop be bounded: `attempt = 1..#mirrors` visits every mirror
-- exactly once, in order, starting with the preferred one.
function installer.next_mirror(mirrors, index)
  if type(mirrors) ~= "table" or #mirrors == 0 then
    return nil
  end
  local count = #mirrors
  local position = tonumber(index) or 1
  if position < 1 then
    position = 1
  end
  -- ((n - 1) % count) + 1 maps any positive n onto 1..count, so the caller needs no
  -- bounds check and attempt count == mirror count is exactly one full pass.
  position = (position - 1) % count + 1
  return mirrors[position]
end

-- ---------------------------------------------------------------------------
-- Pure: command line
-- ---------------------------------------------------------------------------

installer.COMMANDS = {
  install = true, update = true, upgrade = true, remove = true,
  list = true, verify = true, mirror = true, help = true,
}

-- installer.parse_command(argv) -> { command, args, flag } | nil, error
--
-- Flags may appear anywhere. `--mirror` takes the next word as its value, so a bare
-- trailing `--mirror` is refused rather than silently pinning a mirror named "".
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
-- Fetching
-- ---------------------------------------------------------------------------

-- choose_mirrors(flag_mirror) -> array
--
-- A pinned mirror is tried FIRST and the rest follow, so `--mirror x` diagnoses a
-- mirror without turning a hiccup into a failure.
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
-- http.get does NOT raise on a failed request -- it returns nil, message, and
-- possibly a failing response handle. pcall carries all of that through, so the
-- reason arrives in the THIRD slot; capturing only the second reports "the request
-- failed" for a 404, which tells the user nothing. The failing handle is a real
-- handle and is closed, because CC caps open files.
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

-- prefer_mirror(mirrors, chosen) -> array with `chosen` first
--
-- A mirror that just served the manifest has PROVEN it works, so every later request
-- should try it before the ones already known to be slow. Without this, each of the
-- 20 files walks the whole list from the top, and with two dead mirrors ahead of the
-- good one that is two 30-second http timeouts PER FILE -- twenty minutes of silence
-- for a reason the installer already knew after the first request.
--
-- The rest keep their order, so a mirror that starts failing later is still reachable.
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
-- Disk
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

-- make_dir(path): create path and every missing parent.
--
-- `/lib` exists on a CraftOS computer, but `/lib/nbs` and `/lib/player` do not, and
-- neither does the state directory. Each component is created in turn because fs.makeDir
-- only makes ONE level.
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
-- Mirrors on disk
-- ---------------------------------------------------------------------------

local function parse_sources(text)
  local mirrors = {}
  for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
    local clean = line:gsub("\r", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if clean ~= "" and clean:sub(1, 1) ~= "#" then
      -- The prefix may be ABSENT, which is how `direct` is written: an empty prefix
      -- means "prepend nothing", i.e. fetch the raw URL as-is. `%s*` then `%S*` so a
      -- line that is only a name parses rather than being skipped.
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

-- copy_mirrors(mirrors) -> a shallow copy of the array
--
-- load_mirrors must NEVER hand out installer.DEFAULT_MIRRORS itself. `mirror add`
-- appends to whatever it is given, so returning the module constant let one command
-- permanently edit the defaults for the rest of the process -- a second run in the
-- same process then saw a longer list, and repeated adds accumulated duplicates. A
-- copy per caller makes the defaults immutable in practice.
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
-- The numbered menu, shared by `install` and `mirror pick` because they differ only
-- in what a blank answer MEANS:
--
--   opts.allow_automatic = true   blank means "use the automatic order" and returns
--                                 nil without complaint. This is the install path: a
--                                 user pressing enter wants the install to proceed,
--                                 not to be cancelled.
--   opts.allow_automatic = false  blank cancels, and the reason says so. This is
--                                 `mirror pick`, a command whose entire purpose is to
--                                 CHANGE the setting, so "change nothing" is a valid
--                                 outcome that has to be reported.
--
-- The chosen mirror is tested before it is returned: an unreachable choice would
-- otherwise be used for every file and fail twenty times. When the test fails the
-- reason is returned and the caller decides -- for an install that means carrying on
-- with the automatic order, which skips dead mirrors anyway.
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

  local answer = read_seam(prompt)

  if type(answer) ~= "string" then
    -- No way to read: not an error, just nothing to ask.
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
      -- Do not abort an install over a typo; say so and carry on automatically.
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
-- Commands
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

-- installer.progress_line(done, total, label, columns) -> a line that FITS
--
-- Kept strictly NARROWER than the terminal, because term.write does NOT wrap: text
-- past the right edge is CLIPPED and lost (measured; see nbsplay, which learned this
-- the hard way). The counter is the last thing to go, since it is the progress.
--
-- Pure, so the arithmetic is pinned by the spec rather than trusted.
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
    -- No room for a bar at all: the counter alone still says something is happening.
    text = name .. " " .. numbers
  end
  if #text > width - 1 then
    text = text:sub(1, width - 1)
  end
  return text
end

-- A progress line kept strictly NARROWER than the terminal, because term.write does
-- download_one(path, mirrors, log) -> body | nil, reason
--
-- Rotation happens HERE, per file: a mirror that answered the manifest may still be
-- unhealthy for a large file, and an install should not fail outright because one
-- mirror went down mid-way.
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
-- FEEDBACK IS NOT OPTIONAL HERE. `http.get` waits up to 30 seconds before it gives up
-- (DEFAULT_TIMEOUT in HTTPAPI.java, and the host config can raise it), so trying four
-- mirrors in silence can leave the screen frozen for two minutes. A user cannot tell
-- that from a crash, and the natural response is to hit Ctrl+T. So every attempt is
-- announced on ONE refreshed line -- which mirror, which number, and how it ended.
--
-- The mirror that answered is RETURNED, so the caller can try it first for every later
-- request. See installer.prefer_mirror for why that matters more than it looks.
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
-- run(argv, opts) -> exit code
-- ---------------------------------------------------------------------------

function installer.run(argv, opts)
  opts = type(opts) == "table" and opts or {}

  -- The read seam can be supplied per call, which is how a test answers a prompt.
  if type(opts.read) == "function" then
    seams.read = opts.read
  end
  local out = make_writer()
  if type(opts.write) == "function" then
    out = { line = opts.write, refresh = opts.write }
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

  -- NO ARGUMENTS MEANS INSTALL.
  --
  -- This is what makes the tool one command on a fresh computer. CC:Tweaked ships
  -- `wget`, whose `run` form downloads a file and executes it, passing any remaining
  -- words through as varargs:
  --
  --     wget run <url>              -- this file runs with no arguments
  --     wget run <url> upgrade      -- ...with "upgrade"
  --
  -- so defaulting to install makes the shortest possible command the one that does the
  -- thing a user wants. `help` prints the usage.
  --
  -- The empty table is built from `argv or {}` rather than passed straight through,
  -- because parse_command REFUSES a non-table and an unattended run must not depend on
  -- the caller having supplied one.
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
    -- ASK FIRST. The automatic order is tried only if the user declines to choose,
    -- because a computer whose network blocks most of these hosts has no way to say
    -- which one works -- and the alternative is twenty minutes of timeouts.
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
    -- The mirror that answered is tried first from here on.
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
    -- sources.txt is the USER'S preference, not part of the package, so it survives
    -- a plain remove -- the same reason `apt remove` leaves sources.list alone.
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
      -- Change the saved order. A blank answer CANCELS, because this command exists
      -- only to change the setting.
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
-- Autorun
-- ---------------------------------------------------------------------------
-- WHEN THIS RUNS, AND WHY THE GUARD LOOKS LIKE THIS.
--
-- It used to ask `shell.getRunningProgram():find("install")` -- "am I being run as a
-- program?" -- and answer by NAME. That is unreliable in exactly the situations a
-- user hits first, and it fails SILENTLY, which is the worst shape a failure can
-- take. Measured, in three cases:
--
--   1. run from the shell as `install.lua install`  -> worked
--   2. run with no arguments                        -> usage, then a raised error
--   3. code run from the Lua REPL (which is how the file is downloaded in the first
--      place)                                       -> getRunningProgram() names
--                                                      rom/programs/lua.lua, the
--                                                      guard failed, and the file
--                                                      reached its final `return`
--                                                      having printed NOTHING
--
-- Case 3 is a user's report of "it just exits". The name can also change under a
-- rename, `dofile`, or a paste into the REPL, so the check cannot be repaired by
-- matching harder.
--
-- The guard is therefore "a shell exists and nobody disabled it". That is the same
-- shape nbsplay already uses, and it fails LOUDLY: an accidental run prints the
-- usage instead of nothing at all. A library consumer that wants the module without
-- running it sets the flag, which is what the tests do.
if rawget(_G, "__CCNBS_INSTALL_NO_AUTORUN") == nil
  and type(shell) == "table"
  and type(shell.getRunningProgram) == "function" then

  local code = installer.run({ ... })
  if code ~= 0 then
    -- No os.exit in this project (it is forbidden, and Cobalt's is unreliable), so a
    -- raised error is how a CC program reports failure to the shell. The message
    -- names the program because "failed" alone told the user nothing.
    error("install failed", 0)
  end
end

return installer
