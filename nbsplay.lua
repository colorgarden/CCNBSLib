-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 colorgarden
-- Part of CCNBSLib. Licensed under GPL-2.0; see LICENSE.
--
-- nbsplay.lua
--
-- THE MINIMAL PLAYER: one URL, one song, a progress bar.
--
--     nbsplay <url>
--
-- where `<url>` is a DIRECT LINK to an `.nbs` file.  There is no playlist, no
-- local-file scan and no search -- the library does the parsing and the
-- scheduling, and this file exists only to fetch a song, hand it over, and show
-- how far along it is.
--
-- ===========================================================================
-- WHY IT STREAMS THE DOWNLOAD INSTEAD OF USING ONE BLOCKING CALL
-- ===========================================================================
-- `http.get` hands back a handle that can be read in pieces, and the response
-- usually advertises a Content-Length.  Reading it in chunks instead of one
-- `read("*a")` costs two lines and buys a real download percentage rather than a
-- dead terminal while a few hundred kilobytes arrive.
--
-- ===========================================================================
-- WHY IT IS BUILT ON `ccnbs`, NOT ON ITS OWN PARSER
-- ===========================================================================
-- Every byte of parsing, analysis, scheduling and speaker routing belongs to the
-- library.  This file owns exactly three things: fetching, drawing a bar, and
-- shutting the speakers down safely on the way out.  If it re-implemented any
-- part of the pipeline, the CLI and the library would drift.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No integer division, no bitwise
-- operators, no utf8.*, no collectgarbage, no string.dump, no os.exit.  Every CC
-- global is read LAZILY, so this file is `require`-able in plain desktop Lua and
-- its pure parts are unit-testable.

local cli = {}

cli.VERSION = "1.0.0"

-- Read a CC global without making it a load-time dependency.
local function raw_global(name)
  local ok, value = pcall(rawget, _G, name)
  if ok then
    return value
  end
  return nil
end

-- `try(ok, value)` unpacks a protected call.  Written as `pcall(require, "x")`
-- with a literal name so a dependency scan can see it.
local function try(ok, value)
  if ok and type(value) == "table" then
    return value
  end
  return nil
end

-- The DEFAULTS.  Written as `pcall(require, "literal")` so a dependency
-- scan can see them, and held in locals the seam accessors below can
-- override -- a pipeline that cannot be driven from a test has only
-- compile-level assurance, and that is the gap this closes.
local default_ccnbs = try(pcall(require, "ccnbslib"))
local default_runtime = try(pcall(require, "player.runtime"))

-- ---------------------------------------------------------------------------
-- Pure parts -- these are what the spec drives, because they are the parts where
-- a mistake is silent (a bar that never fills, a clock that reads 0:00)
-- ---------------------------------------------------------------------------

-- cli.usage() -> the two lines a user sees when they run it wrong.
function cli.usage()
  return "usage: nbsplay <url>", "  <url> is a direct link to a .nbs file"
end

-- cli.parse_url(argv) -> url | nil, error
--
-- The FIRST argument that looks like a URL wins, so a stray flag cannot be
-- mistaken for one.  Anything that is not http/https is rejected here rather
-- than fetched, because a typo should cost a message, not a network round trip.
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

-- cli.format_time(ms) -> "M:SS", clamped at zero and tolerant of nonsense.
function cli.format_time(ms)
  local value = tonumber(ms) or 0
  if value < 0 then
    value = 0
  end
  local seconds = math.floor(value / 1000)
  local minutes = math.floor(seconds / 60)
  return string.format("%d:%02d", minutes, seconds - minutes * 60)
end

-- cli.render_bar(frac, width) -> a string of exactly `width` characters.
--
-- The caller draws it between its own brackets; this only produces the cells, so
-- the arithmetic can be asserted without a terminal.  A non-numeric or
-- out-of-range fraction is clamped -- a bar that overflows its own width is a
-- rendering bug that looks like a progress bug.
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

-- cli.percent(frac) -> an integer 0..100, for the label beside the bar.
function cli.percent(frac)
  local value = tonumber(frac) or 0
  if value < 0 then
    value = 0
  elseif value > 1 then
    value = 1
  end
  return math.floor(value * 100 + 0.5)
end

-- cli.duration_ms(events) -> the song's length in ms, from its last event.
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
-- Default seams -- injected by the spec, read lazily here
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

local function terminal()
  return seams.term or raw_global("term")
end

local function clock_sleep(seconds)
  local sleeper = seams.sleep
  if type(sleeper) == "function" then
    sleeper(seconds)
    return
  end
  local oslib = raw_global("os")
  if type(oslib) == "table" and type(oslib.sleep) == "function" then
    oslib.sleep(seconds)
  end
end

-- library() -> the ccnbslib table, injected or the real one.  EVERY use in
-- run() goes through here, so a test can supply a fake library: no speakers,
-- no clock, no waiting, and the whole path becomes assertable.
local function library()
  if type(seams.ccnbs) == "table" then
    return seams.ccnbs
  end
  return default_ccnbs
end

-- runtime_module() -> player.runtime, injected or the real one.
local function runtime_module()
  if type(seams.runtime) == "table" then
    return seams.runtime
  end
  return default_runtime
end

-- ---------------------------------------------------------------------------
-- Output
-- ---------------------------------------------------------------------------
-- One line is rewritten in place rather than scrolling, because a progress bar
-- that scrolls is just a log.  Everything goes through `emit` so a test can
-- capture the exact strings.

local function make_writer()
  local term = terminal()
  if type(term) ~= "table" or type(term.write) ~= "function" then
    local printer = raw_global("print")
    return function(line)
      if type(printer) == "function" then
        printer(line)
      end
    end
  end
  return function(line, keep)
    term.clearLine()
    term.write(line)
    term.setCursorPos(1, select(2, term.getCursorPos()))
  end
end

-- ---------------------------------------------------------------------------
-- Fetching
-- ---------------------------------------------------------------------------

-- cli.fetch(url, on_progress) -> body | nil, error
--
-- Reads in chunks so the caller can show a percentage.  A response with no
-- Content-Length simply reports progress without a total, which is why
-- `on_progress` receives `(received, total)` and total may be nil.
function cli.fetch(url, on_progress)
  local api = http_api()
  if type(api) ~= "table" or type(api.get) ~= "function" then
    return nil, "HTTP is disabled on this computer"
  end

  local ok, response = pcall(api.get, url)
  if not ok or response == nil then
    return nil, "could not reach the server"
  end

  -- The response handle's methods are COLON-STYLE: `self` is passed
  -- explicitly. Calling them dot-style puts the first argument into
  -- `self` and breaks -- see the header comment.
  local total = nil
  if type(response.getResponseHeaders) == "function" then
    local headers_ok, headers =
      pcall(response.getResponseHeaders, response)
    if headers_ok and type(headers) == "table" then
      total = tonumber(headers["Content-Length"] or headers["content-length"])
    end
  end

  local chunks = {}
  local received = 0
  while true do
    local read_ok, chunk = pcall(response.read, response, 8192)
    if not read_ok then
      pcall(response.close, response)
      return nil, "the download was interrupted"
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
  pcall(response.close, response)

  local body = table.concat(chunks)
  if #body == 0 then
    return nil, "the server returned nothing"
  end
  return body
end

-- ---------------------------------------------------------------------------
-- run(argv, opts) -> exit code
-- ---------------------------------------------------------------------------

function cli.run(argv, opts)
  opts = type(opts) == "table" and opts or {}
  local write_line = opts.write or make_writer()
  local lib = library()
  local rt = runtime_module()
  local line = function(text)
    write_line(tostring(text or ""))
  end

  local url, err = cli.parse_url(argv)
  if url == nil then
    local first, second = cli.usage()
    line(first)
    if second then line(second) end
    return 1
  end

  if lib == nil then
    line("ccnbslib.lua is missing; the library is not installed.")
    return 1
  end

  line("fetching " .. url)
  local body, fetch_error = cli.fetch(url, function(received, total)
    local text = string.format("  %d KiB", math.floor(received / 1024))
    if total ~= nil and total > 0 then
      text = string.format("  [%s] %3d%%  %d/%d KiB",
        cli.render_bar(received / total, 24), cli.percent(received / total),
        math.floor(received / 1024), math.floor(total / 1024))
    end
    line(text)
  end)
  if body == nil then
    line("download failed: " .. tostring(fetch_error))
    return 1
  end

  line("decoding...")
  local decoded = lib.decode(body)
  if type(decoded) ~= "table" or decoded.ok ~= true then
    local code = type(decoded) == "table" and decoded.error
      and decoded.error.code or "unknown"
    line("this is not a readable .nbs file (" .. tostring(code) .. ")")
    return 1
  end

  local song = decoded.song
  local analysis = lib.analyze(song)
  local events = lib.plan(song, analysis)
  local duration = cli.duration_ms(events)

  -- A title if the file has one, so a user can tell whether they got the song
  -- they meant to.  CP1252 bytes are converted for DISPLAY only, which is what
  -- the library's converter is for; the song itself keeps its bytes.
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

  line(string.format("%s  %d notes  %s  %d speaker(s)",
    title, analysis.total_notes or 0, cli.format_time(duration), found))
  if found == 0 then
    line("no speaker attached; attach one to a side of the computer and retry.")
    return 1
  end

  local session = lib.play(events, {
    analysis = analysis,
    speakers = speakers,
    on_progress = function(info)
      local elapsed = tonumber(info.t_ms) or 0
      local frac = duration > 0 and (elapsed / duration) or 0
      local width = 30
      local term = terminal()
      if type(term) == "table" and type(term.getSize) == "function" then
        local size_ok, columns = pcall(term.getSize)
        if size_ok and type(columns) == "number" and columns > 40 then
          width = columns - 42
        end
      end
      line(string.format("[%s] %3d%%  %s / %s  note %d/%d",
        cli.render_bar(frac, width), cli.percent(frac),
        cli.format_time(elapsed), cli.format_time(duration),
        tonumber(info.index) or 0, tonumber(info.total) or 0))
    end,
  })

  if type(session) ~= "table" then
    line("playback could not start.")
    return 1
  end

  -- Poll until the song ends.  Playing is scheduled on a clock inside the
  -- library, so this loop only waits and redraws.
  while type(session.is_playing) == "function" and session.is_playing() do
    clock_sleep(0.1)
  end

  -- Speakers are stopped on EVERY path, including this one, because a speaker
  -- left playing keeps sounding after the program ends.
  if rt ~= nil and type(rt.cleanup) == "function" then
    pcall(rt.cleanup, speakers, session)
  end
  line("done.")
  return 0
end

-- ---------------------------------------------------------------------------
-- Autorun -- only when executed as a program, never when required by a test
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
