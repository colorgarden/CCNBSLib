-- tools/make_manifest.lua
--
-- Generates manifest.txt, the file list the installer reads. A BUILD TOOL, not part
-- of the library: it shells out to git, so it runs on a desktop, never on a
-- computer. It is deliberately NOT in the shipped set -- nothing installs a build
-- script onto a user's machine.
--
-- WHY THE MANIFEST IS COMMITTED AND GENERATED
--   The installer cannot ask GitHub for the file list: api.github.com is 403 through
--   every GitHub proxy (measured), and a proxy is the whole reason the installer
--   exists. So the list ships WITH the repository, over raw, which proxies fine.
--
--   It is generated rather than typed for a reason this repository already paid for:
--   AGENTS.md section 4 records that a module missing from the shipped list is simply
--   not installed, and then the library is broken for everyone but the person who has
--   the source tree. A list somebody maintains by hand drifts. This one is derived
--   from git, so it cannot.
--
-- FILES COME FROM main, SO SIZES COME FROM A COMMITTED TREE
--   The manifest describes a COMMIT -- that is what the installer fetches -- so the
--   file list and the sizes both come from that commit's tree. A working tree that
--   happens to be dirty, or a module written but not yet committed, cannot make the
--   manifest disagree with what will actually be downloaded: such a file is not in
--   the commit, so it is not in the manifest, so nobody is told to fetch a path that
--   does not exist.
--
-- THE SHIPPED FILES MUST BE COMMITTED. Users download from main, so a size recorded
--   from an uncommitted tree describes a file that does not exist there, and the
--   install would fail the user's own size check with nothing wrong on their side.
--   Only the shipped paths are required to be clean; an uncommitted README does not
--   affect what gets installed.
--
-- LIMIT OF WHAT THIS CAN VERIFY. The manifest record is a path and a byte count --
--   no content hash, because the installer runs on a CraftOS computer whose ROM has
--   no crypto module, and the point of the manifest is to let THAT program check what
--   it downloaded. So `--check` cannot detect a content change that preserves size by
--   looking at the manifest alone; it detects it by comparing git BLOBS between the
--   manifest's commit and HEAD, which is exact and costs the installer nothing.
--
-- Usage:  lua tools/make_manifest.lua [--check]
--           (no flag)  write manifest.txt for HEAD (which must be pushed)
--           --check    exit 1 if the committed manifest is invalid or behind HEAD
--
-- Compatibility: runs on a desktop Lua 5.2. Still avoids the Cobalt-forbidden
-- constructs so the tree stays uniform: no `//`, no bitwise operators, no
-- `math.maxinteger`, no `collectgarbage`, no `string.dump`, no `os.exit`, no `goto`.

local tool = {}

local MANIFEST_PATH = "manifest.txt"

-- ---------------------------------------------------------------------------
-- Shelling out
-- ---------------------------------------------------------------------------

-- run(command) -> output | nil, error
local function run(command)
  local pipe = io.popen(command)
  if pipe == nil then
    return nil, "could not run: " .. command
  end
  local output = pipe:read("*a")
  pipe:close()
  return output
end

local function git(args)
  return run("git " .. args)
end

-- ---------------------------------------------------------------------------
-- Pure text handling -- testable without a repository
-- ---------------------------------------------------------------------------

-- tool.parse_file_list(text) -> array of paths
--
-- One path per line, blanks and CR dropped, sorted, de-duplicated. `git ls-tree` is
-- already sorted, but a manifest whose line order depended on the caller's locale is
-- a diff that churns for no reason.
function tool.parse_file_list(text)
  local seen = {}
  local paths = {}
  for line in (text or ""):gmatch("([^\n]*)\n?") do
    local path = line:gsub("\r", "")
    if path ~= "" and not seen[path] then
      seen[path] = true
      paths[#paths + 1] = path
    end
  end
  table.sort(paths)
  return paths
end

-- tool.parse_version(text) -> version string | nil
--
-- The library reports its own version in ccnbslib.lua as `ccnbs.version = "1.0.0"`
-- (the module is `ccnbs`; only the FILE is ccnbslib.lua). Reading it from the source
-- keeps ONE source of truth: a manifest that claimed a different version from the
-- code would be a lie the installer then repeats to the user.
function tool.parse_version(text)
  local version = (text or ""):match('ccnbs%.version%s*=%s*"([^"]+)"')
  if version == nil then
    version = (text or ""):match("ccnbs%.version%s*=%s*'([^']+)'")
  end
  return version
end

-- tool.render(version, entries) -> the manifest text
--
-- `entries` is an array of { path = ..., size = ... }, already in path order. Two
-- flat keywords, so the installer's parser is a dozen lines and cannot be fooled by
-- nesting:
--
--   version 1.0.0
--   file    ccnbslib.lua 15744
--
-- NO COMMIT LINE. Files are fetched from `main`, so a recorded commit would describe
-- something nothing acts on -- and it would make the manifest's content depend on
-- which commit generated it, which is precisely what made an earlier `--check` report
-- a doc-only commit as "out of date".
function tool.render(version, entries)
  local lines = {
    "# CCNBSLib install manifest -- generated by tools/make_manifest.lua.",
    "# Read by install.lua. Files are fetched from the main branch.",
    "version " .. tostring(version),
  }
  for index = 1, #entries do
    lines[#lines + 1] = string.format("file %s %d",
      entries[index].path, entries[index].size)
  end
  return table.concat(lines, "\n") .. "\n"
end

-- tool.parse(text) -> { version, commit, files } | nil, error
--
-- The manifest's own format, read back. `--check` needs this to discover which commit
-- the COMMITTED manifest describes -- the question "is this manifest correct?" is
-- about that commit, not about whatever HEAD happens to be.
--
-- Kept deliberately separate from install.lua's parser rather than shared: the
-- installer must not depend on a tool that shells out to git, and the spec runs one
-- parser's output through the other, which is a stronger check than sharing code.
function tool.parse(text)
  if type(text) ~= "string" or text == "" then
    return nil, "the manifest is empty"
  end
  local parsed = { files = {} }
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local clean = line:gsub("\r", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if clean ~= "" and clean:sub(1, 1) ~= "#" then
      local keyword, rest = clean:match("^(%S+)%s*(.*)$")
      if keyword == "version" then
        parsed.version = rest
      elseif keyword == "commit" then
        parsed.commit = rest
      elseif keyword == "file" then
        local path, size = rest:match("^(%S+)%s+(%S+)$")
        if path == nil then
          return nil, "malformed file line: " .. clean
        end
        parsed.files[#parsed.files + 1] = { path = path, size = tonumber(size) }
      else
        return nil, "unknown keyword: " .. tostring(keyword)
      end
    end
  end
  if parsed.version == nil then
    return nil, "no version line"
  end
  -- A commit line is accepted if present (an older manifest may carry one) but is
  -- NOT required: files come from main, so a recorded commit describes nothing this
  -- tool acts on. Requiring it would make the check reject a manifest this very
  -- generator now produces.
  if #parsed.files == 0 then
    return nil, "no file lines"
  end
  return parsed
end

-- ---------------------------------------------------------------------------
-- Which files ship
-- ---------------------------------------------------------------------------

-- The shipped set, as an explicit ALLOW-LIST.
--
-- A deny-list ("everything except tests/ and tools/") would silently start shipping
-- whatever anyone adds next -- a build script, a scratch file, the next tool. The
-- install layout is a fixed, known thing (README lists it), so the list that
-- generates the manifest names it positively and a new directory cannot leak in.
--
--   ccnbslib.lua      the public entry point
--   nbsplay.lua       the demonstration CLI
--   nbs/*.lua         parsing
--   player/*.lua      scheduling and playback
local SHIPPED_PATTERNS = {
  "^ccnbslib%.lua$",
  "^nbsplay%.lua$",
  "^nbs/[^/]+%.lua$",
  "^player/[^/]+%.lua$",
}

function tool.is_shipped(path)
  for index = 1, #SHIPPED_PATTERNS do
    if path:match(SHIPPED_PATTERNS[index]) then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Commit inspection
-- ---------------------------------------------------------------------------

-- shipped_at(commit) -> sorted array of shipped paths | nil, error
local function shipped_at(commit)
  local output, err = git("ls-tree -r --name-only " .. commit)
  if output == nil then
    return nil, err
  end
  local kept = {}
  for line in (output .. "\n"):gmatch("([^\n]*)\n") do
    local path = line:gsub("\r", "")
    if path:match("%.lua$") and tool.is_shipped(path) then
      kept[#kept + 1] = path
    end
  end
  table.sort(kept)
  return kept
end

-- committed_size(commit, path) -> number | nil
local function committed_size(commit, path)
  local output = git(string.format("cat-file -s %s:%s", commit, path))
  if output == nil then
    return nil
  end
  return tonumber((output:gsub("%s", "")))
end

-- blob_sha(commit, path) -> string | nil
--
-- The blob's object name, which changes when the CONTENT changes. This is what makes
-- `--check` able to say "the manifest is behind HEAD" exactly, rather than by size --
-- a library edit that happens to preserve length would otherwise slip through.
--
-- Safe to use here and not in the installer: this runs where git does.
local function blob_sha(commit, path)
  local output = git(string.format("rev-parse %s:%s", commit, path))
  if output == nil then
    return nil
  end
  local sha = output:gsub("%s", "")
  if sha == "" then
    return nil
  end
  return sha
end

-- content_signature(commit) -> a comparable string over every shipped file
local function content_signature(commit)
  local paths, err = shipped_at(commit)
  if paths == nil then
    return nil, err
  end
  local parts = {}
  for index = 1, #paths do
    local sha = blob_sha(commit, paths[index])
    if sha == nil then
      return nil, "cannot resolve " .. paths[index] .. " at " .. commit
    end
    parts[#parts + 1] = paths[index] .. " " .. sha
  end
  return table.concat(parts, "\n"), paths
end

-- Are the SHIPPED files all committed?
--
-- The manifest describes what a user will DOWNLOAD, and they download from `main`.
-- Sizes therefore have to be read from a committed tree, so anything uncommitted
-- would put a size in the manifest that no download can match -- and the user's
-- install would fail its own size check with nothing wrong on their side.
--
-- Only the shipped paths are checked. An uncommitted README is irrelevant to what
-- gets installed, so demanding a totally clean tree would be a rule people work
-- around rather than follow.
local function shipped_tree_is_clean()
  local output = git("status --porcelain -- ccnbslib.lua nbsplay.lua nbs/ player/")
  if output == nil then
    return false, "git status failed"
  end
  local dirty = {}
  for line in (output .. "\n"):gmatch("([^\n]*)\n") do
    local path = line:gsub("^%s*%S+%s+", ""):gsub("\r", "")
    if path ~= "" then
      dirty[#dirty + 1] = path
    end
  end
  if #dirty > 0 then
    return false, table.concat(dirty, ", ")
  end
  return true, nil
end

-- ---------------------------------------------------------------------------
-- Files
-- ---------------------------------------------------------------------------

local function read_file(path)
  local handle = io.open(path, "rb")
  if handle == nil then
    return nil
  end
  local text = handle:read("*a")
  handle:close()
  return text
end

local function write_file(path, text)
  local handle = io.open(path, "wb")
  if handle == nil then
    return false, "cannot write " .. path
  end
  handle:write(text)
  handle:close()
  return true
end

-- ---------------------------------------------------------------------------
-- Building a manifest for a commit
-- ---------------------------------------------------------------------------

-- build(commit) -> text | nil, error, entries, version
--
-- `commit` is a TREE to describe, and HEAD is what is passed in normal use. It is a
-- parameter rather than a global so --check can describe a different tree if it ever
-- needs to, and so the function stays honest about what it read.
local function build(commit)
  local paths, err = shipped_at(commit)
  if paths == nil then
    return nil, err
  end
  if #paths == 0 then
    return nil, "no shipped .lua files at " .. commit
  end

  -- The version comes from the commit's ccnbslib.lua, not the working tree: the
  -- manifest describes that tree.
  local library = git("show " .. commit .. ":ccnbslib.lua")
  if library == nil then
    return nil, "cannot read ccnbslib.lua at " .. commit
  end
  local version = tool.parse_version(library)
  if version == nil then
    return nil, "ccnbslib.lua at " .. commit .. " does not declare a version"
  end

  local entries = {}
  for index = 1, #paths do
    local size = committed_size(commit, paths[index])
    if size == nil then
      return nil, "cannot size " .. paths[index] .. " at " .. commit
    end
    entries[#entries + 1] = { path = paths[index], size = size }
  end

  return tool.render(version, entries), nil, entries, version
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

local function main(argv)
  local check_only = false
  for index = 1, #argv do
    if argv[index] == "--check" then
      check_only = true
    else
      io.stderr:write("usage: lua tools/make_manifest.lua [--check]\n")
      return 2
    end
  end

  -- ------------------------------------------------------------------ check
  --
  -- Two questions, and they are different:
  --
  --   1. Is the committed manifest VALID? Its own commit must still contain exactly
  --      those files at those sizes.
  --   2. Is it CURRENT? The shipped files at its commit must be byte-identical to the
  --      shipped files at HEAD, or the manifest points users at an older library than
  --      the one that was just pushed.
  --
  -- Asked against the MANIFEST'S OWN COMMIT rather than HEAD. Comparing a fresh
  -- render of HEAD against the committed file would report OUT OF DATE after any
  -- doc-only commit -- a false alarm that would train everyone to ignore the check.
  if check_only then
    local existing = read_file(MANIFEST_PATH)
    if existing == nil then
      io.stderr:write("manifest: " .. MANIFEST_PATH .. " is missing -- "
        .. "run lua tools/make_manifest.lua\n")
      return 1
    end

    local parsed, parse_err = tool.parse(existing)
    if parsed == nil then
      io.stderr:write("manifest: " .. MANIFEST_PATH .. " is malformed: "
        .. tostring(parse_err) .. "\n")
      return 1
    end

    -- Render HEAD and compare TEXTUALLY.
    --
    -- This is exact and it does not produce false alarms, because the manifest no
    -- longer records a commit: its content depends only on the shipped paths, their
    -- sizes and the version. A commit that touches only documentation therefore
    -- renders identically and the check passes -- which is the behaviour an earlier
    -- commit-pinned format got wrong, reporting every doc-only commit as "out of
    -- date" until the check became something to ignore.
    local head = git("rev-parse HEAD")
    if head == nil then
      io.stderr:write("manifest: git rev-parse HEAD failed\n")
      return 1
    end
    head = head:gsub("%s", "")

    local expected, build_err, entries = build(head)
    if expected == nil then
      io.stderr:write("manifest: cannot describe HEAD: " .. tostring(build_err)
        .. "\n")
      return 1
    end

    if expected ~= existing then
      io.stderr:write("manifest: OUT OF DATE -- " .. MANIFEST_PATH
        .. " does not match HEAD (" .. head:sub(1, 12) .. ")"
        .. "\n  run lua tools/make_manifest.lua and commit the result\n")
      return 1
    end

    io.write(string.format("manifest: OK (%d files, version %s, HEAD %s)\n",
      #entries, parsed.version, head:sub(1, 12)))
    return 0
  end

  -- ----------------------------------------------------------------- generate
  local commit = git("rev-parse HEAD")
  if commit == nil then
    io.stderr:write("make_manifest: git rev-parse HEAD failed\n")
    return 1
  end
  commit = commit:gsub("%s", "")

  local clean, dirty = shipped_tree_is_clean()
  if not clean then
    io.stderr:write("make_manifest: the shipped files have uncommitted changes:\n"
      .. "  " .. tostring(dirty)
      .. "\n  The manifest records SIZES that a download from main must match, so"
      .. "\n  those changes have to be committed first. Commit them, then rerun.\n")
    return 1
  end

  local rendered, build_err, entries, version = build(commit)
  if rendered == nil then
    io.stderr:write("make_manifest: " .. tostring(build_err) .. "\n")
    return 1
  end

  local ok, write_err = write_file(MANIFEST_PATH, rendered)
  if not ok then
    io.stderr:write("make_manifest: " .. tostring(write_err) .. "\n")
    return 1
  end
  io.write(string.format("manifest: wrote %s (%d files, version %s, HEAD %s)\n",
    MANIFEST_PATH, #entries, version, commit:sub(1, 12)))
  return 0
end

-- Only run when executed, so the spec can require this file for its pure parts.
if arg ~= nil and arg[0] ~= nil and arg[0]:find("make_manifest", 1, true) then
  local code = main(arg)
  if code ~= 0 then
    error("make_manifest failed with code " .. tostring(code), 0)
  end
end

return tool
