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

-- FORWARD DECLARED, not defined here. `cli.choose_out_of_range` uses this, and Lua
-- resolves a name LEXICALLY AT COMPILE TIME -- so a `local function read_seam` declared
-- further down would leave that reference looking up a GLOBAL, which is nil, and the
-- interactive menu would raise the moment it was reached. Two earlier bugs in this
-- project's history were exactly this (`terminal` and `log`).
local read_seam

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
local default_clock = try(pcall(require, "player.clock"))

-- ---------------------------------------------------------------------------
-- Pure parts -- these are what the spec drives, because they are the parts where
-- a mistake is silent (a bar that never fills, a clock that reads 0:00)
-- ---------------------------------------------------------------------------

-- The four out-of-range policies, with the one line each that a user needs in order
-- to choose. The library owns the VALUES (player/mapping.lua); this table owns the
-- wording, because presenting a choice is the CLI's job and the library never writes
-- a sentence.
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

-- cli.usage() -> the two lines a user sees when they run it wrong.
function cli.usage()
  return "usage: nbsplay [--debug] [--policy <name>] [-f] <url>",
    "  <url> is a direct link to a .nbs file",
    "  --policy " .. table.concat(cli.policy_names(), "|")
      .. "  how to play notes outside the native range",
    "           (default: ask, unless there are none)",
    "  -f, --force   play even if there are too few speakers (drops notes)",
    "  --debug  writes " .. cli.LOG_PATH
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

-- The native key range, read from the library when it exposes one and falling back to
-- NBS's own documented bounds. Read rather than hardcoded so the CLI cannot drift from
-- the mapping that actually decides what is in range.
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
-- The library hands over a BARE CODE and never a sentence -- that is the contract, and
-- the prose renderer was deleted with the interface on purpose. So the CLI is where a
-- code becomes something a person can act on, and this is the one place that knows how.
--
-- PURE, so every message is pinned by the spec without needing to play a song.
function cli.describe_warning(code, args)
  args = type(args) == "table" and args or {}

  if code == "extended-range" then
    -- Two different causes share this code, and they need different advice. Above the
    -- native range the extranotes pack registers `_1`; below it, `_-1`. The library
    -- reports the song's keys; which end is out decides whether the pack helps.
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

  -- An unrecognised code still gets reported: a warning nobody mentioned is worse
  -- than one with a terse message.
  return "warning: " .. tostring(code)
end

-- cli.choose_out_of_range(opts, probe, say, emit) -> policy string
--
-- THE INTERACTIVE CHOICE, and the reason it exists: a note outside its recording's
-- octave has no single right answer. Playing a shifted recording gets the pitch right
-- but needs a resource pack; passing it through is always audible but the client
-- flattens it; clamping is predictable and wrong; dropping is silence. The user is the
-- only one who knows which they want, so they are asked.
--
-- `probe` is an analysis computed with PASSTHROUGH, so the reported key range is the
-- song's own regardless of any later choice.
--
-- ANY NON-ANSWER FALLS BACK TO SHIFT, which is the library's own default. A blank
-- line, unreadable input, or a typo must not abort a playback the user asked for --
-- the same reasoning the installer's mirror menu uses.
function cli.choose_out_of_range(opts, probe, say, emit)
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

  local answer = read_seam(opts, "choose 1-4 (blank = shift): ")
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
-- Separated from parse_url so the URL rule stays exactly as tested: a flag is
-- REMOVED here rather than being tolerated inside the URL matcher, so any future
-- flag cannot quietly change what counts as a URL.
-- cli.parse_argv(argv) -> url | nil, debug, policy | nil, error
--
-- Flags may appear anywhere. `--policy <name>` SKIPS the interactive out-of-range menu,
-- which an unattended caller -- a startup file, a script -- cannot answer. Interactive
-- remains the default, because the choice genuinely depends on whether the listener has
-- the resource pack and on what they would rather hear.
--
-- An unknown policy name is refused rather than ignored: silently falling back would
-- play the song a different way from the one that was asked for.
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
        -- Play even when the speakers cannot hold the song. Dropping notes is the
        -- user's call once they can see the counts; this is how they make it.
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
        -- "=form": --policy=shift
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

-- cli.policy_names() -> the accepted policy names, in menu order.
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

-- `terminal` is defined further down with the other seams; it is FORWARD
-- DECLARED here because progress_line reads it, and Lua resolves locals
-- lexically at COMPILE time -- a later `local function` would leave this
-- reference a global lookup, which is nil.
local terminal

-- cli.speaker_count(n) -> "<n> speaker" / "<n> speakers".
-- A raw "%d speaker(s)" is the kind of thing that never gets cleaned up, so it is
-- a function, and therefore testable.
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

-- cli.display_width(text) -> the number of COLUMNS text occupies
--
-- Not the character count: on a CC:T terminal a CJK glyph takes TWO cells. Counting
-- characters would let a Chinese line pass a width check and then be clipped -- the
-- exact failure this function exists to prevent -- and song titles and layer names are
-- routinely CJK, so it is not a hypothetical.
--
-- The test is the common wide range (CJK and the fullwidth forms) rather than a whole
-- Unicode East Asian Width table: a Lua module running on a 1 MB computer disk is not
-- the place for one, and everything a .nbs file carries is ASCII, CP1252 or that range.
function cli.display_width(text)
  local value = tostring(text or "")
  local columns = 0
  for index = 1, #value do
    local byte = value:byte(index)
    if byte < 0x80 then
      columns = columns + 1
    elseif byte >= 0xE0 and byte <= 0xEF then
      -- A three-byte UTF-8 sequence: one character, two columns.
      columns = columns + 2
    elseif byte >= 0x80 and byte < 0xC0 then
      -- A CONTINUATION byte, already counted with its lead byte.
      columns = columns + 0
    else
      -- A two- or four-byte sequence: one column, which is right for Latin/Greek/
      -- Cyrillic and good enough outside the BMP.
      columns = columns + 1
    end
  end
  return columns
end

-- cli.wrap_text(text, width) -> array of lines
--
-- `term.write` DOES NOT WRAP. AGENTS.md section 3 records the measurement, and
-- `TextBuffer.write` bounds-checks past the right edge, so the overflow is simply GONE.
-- A 77-character menu on a 51-column terminal therefore read "…-- play a different
-- RECO" and the user had no way to learn what the options were.
--
-- So the CLI wraps for itself:
--   * on SPACES where possible, so a sentence stays readable;
--   * HARD, inside a word longer than the line -- a URL or a sound name has no spaces
--     and overflowing would be clipped, which is the failure being fixed;
--   * an existing "\n" starts a new line;
--   * a non-positive width never loops: it falls back to one column.
function cli.wrap_text(text, width)
  local limit = tonumber(width) or 0
  if limit < 1 then
    limit = 1
  end

  local source = tostring(text or "")
  local out = {}

  -- Split on newlines first: an explicit break is a break.
  for paragraph in (source .. "\n"):gmatch("([^\n]*)\n") do
    -- Also handle CR, so a message built with CRLF does not carry a stray character.
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

          -- The word alone may still be too long: break it by characters.
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
              -- A single character wider than the line. Emit it alone rather than
              -- spinning forever; one clipped character beats a hang.
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

-- cli.progress_line(label, frac, extras, columns) -> a line that FITS.
--
-- PURE, apart from reading the terminal size when `columns` is not given, so the
-- arithmetic can be asserted without a terminal.
--
-- The line is kept strictly SHORTER than the terminal so nothing is CLIPPED.
-- `term.write` does not wrap (measured: width + 5 characters left the row
-- unchanged and the cursor at column 57) -- the text simply runs off the right
-- edge, and TextBuffer.write bounds-checks, so it is lost, not fatal. Fitting is
-- therefore about not losing characters, which matters here because the
-- percentage and the clock are the point of the line.
--
-- The bar and the percentage are never dropped, because they ARE the progress.
-- `extras` are trailing fragments in priority order (most important first) and are
-- dropped from the end until the line fits. If not even a small bar fits, it
-- degrades to a bare percentage, with the label shortened only as a last resort.
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

  -- Longest first, so the most informative version that fits is the one used.
  for count = #fragments, 0, -1 do
    local tail = table.concat(fragments, "", 1, count)
    -- Count the fixed characters ONE TERM AT A TIME rather than as a total. An
    -- off-by-one here was got wrong twice, and the consequence is characters
    -- silently dropped off the right edge -- so it is spelled out rather than
    -- trusted:
    --
    --   " ["      2   before the bar
    --   "] "      2   after the bar
    --   "100%"    4   `%3d%%` is four characters for every value from 0 to 999
    --   tail      #tail
    local fixed = 2 + 2 + 4 + #tail
    local room = width - 1 - #text - fixed
    if room >= 4 then
      return text .. " [" .. cli.render_bar(frac, room) .. "] "
        .. string.format("%3d%%", cli.percent(frac)) .. tail
    end
  end

  -- Nothing fits: a percentage alone still tells the user something is happening,
  -- with the label shortened if even that would overflow.
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

terminal = function()
  return seams.term or raw_global("term")
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

-- current_clock() -> the clock playback is timed by.
--
-- THE CLOCK MUST BE PUMPED, not merely handed over. `after()` arms a timer;
-- the callback runs only when `run_due()` drains `timer` events and dispatches
-- the matching handle. Polling with os.sleep does NOT work: os.sleep pulls and
-- discards every event until its own timer fires, so the song's timers are
-- consumed with their callbacks never invoked -- silence, reported as success.
local function current_clock()
  if type(seams.clock) == "table" then
    return seams.clock
  end
  if default_clock ~= nil and type(default_clock.new_os) == "function" then
    return default_clock.new_os()
  end
  return nil
end

-- read_seam(prompt): how the CLI asks the user a question.
--
-- Injected through opts.read so a test can answer it. An interactive path that was
-- never exercised is how the autorun bug survived -- written, never run, silently
-- wrong. Returns nil when there is no way to read, which callers treat as "said
-- nothing".
read_seam = function(opts, prompt)
  if type(opts) == "table" and type(opts.read) == "function" then
    return opts.read(prompt)
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

-- ---------------------------------------------------------------------------
-- Output
-- ---------------------------------------------------------------------------
-- One line is rewritten in place rather than appended, because a progress bar that
-- is appended is just a log.  Every line goes through the writer `make_writer`
-- returns -- or through `opts.write`, when a caller supplies one -- so a test can
-- capture the exact strings, and so there is a single place that knows how a row is
-- advanced.
--
-- THE OUTPUT HAS ONE SHAPE
--
--   nbsplay: <status>            a permanent line; the cursor moves down a row
--   nbsplay: E_CODE: <detail>    a failure; it exits non-zero
--   <bar>  <pct>  <detail>       a LIVE line, refreshed in place
--   usage: ...                   help, unprefixed
--
-- A permanent line is never overwritten: the cursor is moved down past it, so it
-- stays. A live line is redrawn on the same row, so a progress bar animates instead
-- of filling the screen with every step it ever took.
--
-- "Moved down" is NOT `term.write("\n")`, which does no such thing -- see the long
-- note on `make_writer` for the measurement.
--
-- EVERY FAILURE PATH PRINTS `E_CODE: detail`.  The project's convention is
-- that machine-readable output is a BARE CODE and the caller words it -- the
-- library returns `{code = "E_..."}` and never a sentence.  The CLI follows
-- the same rule so a script can branch on the code, and so the codes are
-- stable enough to assert on.  All ASCII, all greppable:
--
--   E_USAGE          no usable URL on the command line
--   E_NO_LIBRARY     ccnbslib.lua is not installed
--   E_HTTP_DISABLED  this computer has no http API
--   E_HTTP           the request itself failed; CC's own reason follows, e.g.
--                    `E_HTTP: Domain not permitted` or `E_HTTP: Not Found`
--   E_DOWNLOAD       reading the response failed part way
--   E_EMPTY          the server answered with nothing
--   E_DECODE         the library rejected the bytes (its code follows)
--   E_NO_SPEAKER     no speaker peripheral is attached
--   E_NO_CLOCK       player.clock is missing, or cannot be driven
--   E_CLOCK_FROZEN   the clock does not advance with real time
--   E_CLOCK_SCALE    the clock's unit is not real milliseconds
--   E_DISPATCH       the clock stopped early, or a timer callback raised
--   E_PLAY           the library returned no usable session

-- make_writer() -> { line = fn, refresh = fn }
--
-- TWO KINDS OF OUTPUT, and conflating them destroys the screen:
--
--   line(text)     a PERMANENT message: written once, then the cursor moves DOWN a
--                  row. Nothing written later can erase it.
--   refresh(text)  a LIVE line, rewritten in place: the cursor is left at the start
--                  of the same row, so a progress bar animates rather than filling
--                  the screen with every step it ever took.
--
-- A NEWLINE IS NOT `term.write("\n")`.  MEASURED on CraftOS-PC 2.8.3, because the
-- documentation and the behaviour had to agree before this was written at all:
--
--   after write("AAAA")     x=5  y=1
--   after write("\n")       x=6  y=1     <- the ROW did not change
--   after write("BBBB")     x=10 y=1     <- so both landed on row 1
--
-- `term.write` is documented as not handling "line breaks or word wrapping", and
-- TermAPI.java agrees -- it does `setCursorPos(getCursorX() + text.length(),
-- getCursorY())`.  So a "\n" sent through it is stored as an ordinary character and
-- advances the COLUMN by one. The previous version ended every permanent line with
-- exactly that, so each message overwrote the one before: the user saw a single
-- line, the last one. `bios.lua`'s own `write` shows how a row is really advanced --
-- setCursorPos(1, y + 1), or setCursorPos(1, height) then scroll(1) at the bottom.
--
-- `term.write` does NOT wrap either (measured: writing width + 5 characters left
-- the cursor at column 57 with the row unchanged). Text past the right edge is
-- simply CLIPPED -- TextBuffer.write bounds-checks and does not raise -- so the
-- progress line still aims to FIT, but only so nothing is cut off, NOT because a
-- long line would scroll the screen. It would not.
--
-- clearLine() clears the WHOLE row, not just from the cursor onwards (also
-- measured), which is what makes clear-then-write the right pair.
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
    -- No cursor control, so a refresh CANNOT overwrite: it would be a new line
    -- every time. Printing nothing for it keeps the real output readable, and the
    -- permanent lines still carry the outcome.
    return {
      line = plain,
      wrapped = plain,
      refresh = function() end,
    }
  end

  -- Is a live line on screen right now? Its row is simply WHEREVER THE CURSOR IS,
  -- because `refresh` always leaves the cursor there. Nothing has to be remembered,
  -- so this stays correct if the terminal is resized mid-song.
  local live = false

  -- Move down one row, scrolling at the bottom. This is the step `term.write` does
  -- not take; it is copied from the `newLine` helper inside bios.lua's `write`,
  -- which is the authority on it.
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

  -- How many columns the terminal has, measured once. A terminal that cannot report
  -- its size falls back to the CC:T default rather than to zero, which would wrap
  -- every message to one character per line.
  local columns = 51
  if type(term.getSize) == "function" then
    local ok, measured = pcall(term.getSize)
    if ok and type(measured) == "number" and measured > 0 then
      columns = measured
    end
  end

  local function write_line(text)
    if live then
      -- Take over the live line's row rather than leaving a blank one behind.
      -- The cursor is still on that row, so clearLine is all it takes.
      term.clearLine()
      live = false
    end
    term.write(tostring(text))
    advance()
  end

  return {
    line = write_line,
    -- A message WRAPPED to the terminal.
    --
    -- `term.write` clips rather than wraps, so anything longer than the screen loses
    -- its right-hand end silently. The out-of-range menu proved it: its lines are 77
    -- to 80 characters, the default terminal is 51 columns, and the user saw
    -- "…-- play a different RECO" with no way to find out what the options were.
    wrapped = function(text)
      local lines = cli.wrap_text(text, columns)
      for index = 1, #lines do
        write_line(lines[index])
      end
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
-- Fetching
-- ---------------------------------------------------------------------------

-- cli.fetch(url, on_progress) -> body | nil, code, detail
--
-- Reads in chunks so the caller can show a percentage.  A response with no
-- Content-Length simply reports progress without a total, which is why
-- `on_progress` receives `(received, total)` and total may be nil.
--
-- THE HANDLE'S METHODS TAKE NO `self` -- call them DOT-STYLE.
--
-- CC:Tweaked registers them with @LuaFunction on Java methods that have no
-- self parameter (HttpResponseHandle.java), and the ROM's own example is
-- `request.readAll()`.  Measured on CraftOS-PC against a FILE handle, which the
-- response handle's javadoc says shares its methods and which uses the same
-- machinery:
--
--     h.read(5)      -> "01234"   five characters           -- correct
--     h.read(h, 5)   -> "0"       the table became the count -- wrong
--
-- So passing the handle back in makes `read` receive a table where a number
-- belongs.  On real CC:Tweaked that raises, and the caller sees a failed
-- download -- which is precisely what happened when this was written the other
-- way round.
function cli.fetch(url, on_progress)
  local api = http_api()
  if type(api) ~= "table" or type(api.get) ~= "function" then
    return nil, "E_HTTP_DISABLED", "HTTP is disabled on this computer"
  end

  -- http.get DOES NOT RAISE when a request fails -- IT RETURNS THE FAILURE:
  --
  --     handle                            on success
  --     nil, message, failing_response    on failure
  --
  -- and `pcall` carries every one of those through, so the message arrives in the
  -- THIRD slot. Capturing only the second -- `local ok, response = pcall(...)` -- was
  -- a real defect: the reason was thrown away and every failure was reported as
  -- "the request failed", telling the user nothing. It also leaked the failing
  -- response handle, which is a real handle that has to be closed.
  --
  -- MEASURED on CraftOS-PC 2.8.3. `table.pack` is used to read the shape, because a
  -- table CONSTRUCTOR drops trailing nils and `#` is undefined across holes -- the
  -- first attempt to measure this reported "1 value" and was wrong:
  --
  --   success   pcall n=2  true, <response>
  --   404       pcall n=4  true, nil, "Not Found",                      <response>
  --   dead host pcall n=4  true, nil, "SSL connection unexpectedly closed", nil
  --   bad host  pcall n=4  true, nil, "No message received",            nil
  --   bad scheme pcall n=4 true, nil, "Invalid protocol 'gopher'",      nil
  --   malformed pcall n=4  true, nil, "Must specify http or https",     nil
  local ok, response, message, failing = pcall(api.get, url)
  if not ok then
    -- pcall only fails when http.get itself raised -- e.g. the Java side's "Too
    -- many ongoing HTTP requests" -- which is a different thing from a refused
    -- request, so it is reported as such.
    return nil, "E_HTTP", "the request raised: " .. tostring(response)
  end
  if response == nil then
    -- A failing response is still a HANDLE (the 404 case returns one), so it is
    -- closed here rather than leaked -- CC caps open files.
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
-- Debug logging
-- ---------------------------------------------------------------------------
-- OFF unless --debug is given, and silent when it fails: a diagnostic that
-- crashes the program it is diagnosing is worse than no diagnostic. Writes with
-- file:write, where "\n" IS a newline -- unlike term.write, which stores it as an
-- ordinary character (see make_writer).
cli.LOG_PATH = "nbsplay-debug.log"

-- cli.describe_argv(argv) -> a readable one-liner for the log.
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
-- Returns a no-op logger when disabled, so callers never branch on whether
-- logging is on.
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
  -- DOT-STYLE, NO SELF.  CC:Tweaked registers a handle's methods on Java methods
  -- with no `self` parameter (AGENTS.md section 3), so `file.write(file, text)`
  -- hands the handle over AS the text.  That is what made this logger create a log
  -- file and then leave it at 0 bytes: the open succeeded (fs is an API table, so
  -- fs.open(path, mode) is right) while every write quietly failed inside pcall.
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

  -- A logger that cannot write is worth knowing about, so the caller can say so
  -- instead of handing back an empty file.
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

-- instrument_clock(clock, log) -> a clock that logs every call it receives.
--
-- Forwards every call to the REAL clock, so nothing about the run changes -- only
-- the record does. This is the difference between measuring and modelling: a fake
-- clock would tell us what I assumed, and assumptions are what produced the last
-- four wrong diagnoses.
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

  return wrapped
end

-- cli.rate_verdict(real_ms, clock_ms) -> ok, code, detail
--
-- PURE, so the thresholds are pinned by the spec rather than argued about.
--
--   real_ms    the known interval that elapsed -- an os.sleep duration
--   clock_ms   how far the injected clock's now_ms() moved during it
--   ratio      clock_ms / real_ms -- 1.0 is correct
--
-- A clock that does not advance with real time makes every delay wrong, and it
-- does so WITHOUT RAISING -- which is the worst possible failure for a scheduler.
-- Measured on a real machine, with the world's daylight cycle off:
--
--   CLOCK RATE: real=296ms clock_now_ms=0ms  ratio=0.000
--   clock.now_ms() -> 109436400     ... for the entire run
--
-- so `delay = ideal - now` stopped being an interval and became each event's own
-- absolute t_ms, compounding until a 143 s song never finished. The other direction
-- is just as broken: os.epoch("ingame") advances 72000 ms per real second when the
-- cycle IS on (a Minecraft day is 20 real minutes), so every event is instantly
-- overdue and the whole song dispatches at once.
--
--   real_ms    the known interval that elapsed (an os.sleep duration)
--   clock_ms   how far the injected clock's now_ms() moved during that time
--   ratio      clock_ms / real_ms -- 1.0 is correct
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
-- Runs the probe and applies the verdict. Skipped where real time cannot be read
-- (no os.epoch / no os.sleep -- plain desktop Lua, which is what the suite runs
-- under), because a check that cannot measure anything must not block a run.
local function check_clock_health(clock, log)
  local os_api = raw_global("os")
  if type(os_api) ~= "table"
    or type(os_api.epoch) ~= "function"
    or type(os_api.sleep) ~= "function"
    or type(clock.now_ms) ~= "function" then
    log("clock check: skipped (no os.epoch/os.sleep, so real time is unreadable)")
    return true, nil, nil
  end

    -- THE REFERENCE IS os.sleep, NOT A SECOND READING OF THE CLOCK.
    --
    -- The first version of this check read os.epoch("utc") before and after the
    -- sleep and compared it against clock.now_ms() -- but now_ms IS os.epoch("utc"),
    -- so it compared the clock with ITSELF and could only ever report 1.0. A check
    -- that cannot fail is worse than no check, because it looks like one.
    --
    -- os.sleep blocks for a known stretch of real time on the game's own timer,
    -- which is a reference INDEPENDENT of where now_ms comes from. If the clock is
    -- healthy it advances by about that much; if it is frozen it does not move; if
    -- its unit is wrong it moves by the wrong factor.
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

    -- rate_verdict(real_ms, clock_ms): how far the clock moved, against how far it
    -- SHOULD have moved over that known interval.
    local healthy, code, detail = cli.rate_verdict(SLEEP_MS, clock_ms)
    log(string.format("clock check: slept %dms, now_ms advanced %sms -> %s",
      SLEEP_MS, tostring(clock_ms), healthy and "OK" or tostring(code)))
    if not healthy then
      return false, code, detail
    end
    return true, nil, nil
  end

-- ---------------------------------------------------------------------------
-- run(argv, opts) -> exit code
-- ---------------------------------------------------------------------------

function cli.run(argv, opts)
  opts = type(opts) == "table" and opts or {}

  -- FORWARD DECLARED, not declared here: `say` and `fail` are defined below and
  -- reference this, and Lua resolves a name lexically at COMPILE time. A `local`
  -- introduced after them would leave those references looking up a GLOBAL, which
  -- is nil, and every message would raise instead of printing.
  local log, close_log, log_empty

  local out = make_writer()
  if type(opts.write) == "function" then
    -- A single injected sink receives BOTH kinds, so a test sees exactly the
    -- ordered sequence the terminal would: refreshes included.
    out = { line = opts.write, refresh = opts.write, wrapped = opts.write }
  end
  local lib = library()
  local rt = runtime_module()

  -- Every permanent line is `nbsplay: ...`, so the output is greppable and has one
  -- shape; every failure is `nbsplay: E_CODE: detail`, so it is machine-readable
  -- as well as readable.  The same rule the library follows when it hands over
  -- `{code = "E_..."}` rather than a sentence.
  -- Every permanent line goes through `wrapped`, so nothing this program prints can be
  -- clipped by a terminal narrower than the message. The out-of-range menu is the
  -- reason: its lines are 77 to 80 characters and the default terminal is 51 columns,
  -- which is how a user ended up reading "…-- play a different RECO".
  local function say(text)
    out.wrapped("nbsplay: " .. tostring(text or ""))
    log("say: " .. tostring(text or ""))
  end
  local function fail(code, detail)
    out.wrapped("nbsplay: " .. tostring(code) .. ": " .. tostring(detail or ""))
    log(string.format("FAIL %s: %s", tostring(code), tostring(detail or "")))
  end
  local function live(text)
    out.refresh(text)
  end

  local url, debug, policy, force, parse_error = cli.parse_argv(argv)
  log, close_log, log_empty = make_logger(debug, cli.LOG_PATH)
  if debug then
    log("nbsplay debug log -- " .. os.date("%Y-%m-%d %H:%M:%S"))
    log("argv: " .. cli.describe_argv(argv))
  end
  if url == nil then
    fail("E_USAGE", parse_error)
    -- Help text: left unprefixed, because prefixing every line of it is noise.
    local first, second, third, fourth = cli.usage()
    out.line(first)
    if second then out.line(second) end
    if third then out.line(third) end
    if fourth then out.line(fourth) end
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
        -- No Content-Length, so there is no fraction to draw -- report the count
        -- rather than inventing one.
        live(string.format("download  %d KiB", math.floor(received / 1024)))
      end
    end)
  if body == nil then
    fail(fetch_code, fetch_detail)
    return 1
  end

  say("decoding")
  local decoded = lib.decode(body)
  if type(decoded) ~= "table" or decoded.ok ~= true then
    local code = type(decoded) == "table" and decoded.error
      and decoded.error.code or "unknown"
    -- The library's OWN typed code is passed through, not restated: it is
    -- the machine-readable half of the contract, so a script can branch on it.
    fail("E_DECODE", code)
    return 1
  end

  local song = decoded.song

  -- WHICH NOTES ARE OUT OF RANGE, asked with PASSTHROUGH because that policy changes
  -- no event's kind: every audible note stays a play_note, so the count is the number
  -- of notes that would actually sound and the answer is independent of what the user
  -- is about to choose.
  local probe = lib.analyze(song,
    { out_of_range = "passthrough" })
  local has_out_of_range = probe.has_extended_range == true

  local out_of_range = "passthrough"
  if has_out_of_range then
    if policy ~= nil then
      -- An unattended caller named a policy, so the menu is skipped -- but it is still
      -- SAID, so the log and the screen agree about how the song was played.
      out_of_range = policy
      say("out-of-range notes: " .. policy)
    else
      out_of_range = cli.choose_out_of_range(opts, probe, say, out.wrapped)
    end
  end

  -- The POLICY is settled BEFORE planning, because it decides an event's kind and
  -- therefore the speaker requirement -- choosing afterwards would size the fan-out
  -- for the wrong cost.
  local analysis = lib.analyze(song, { out_of_range = out_of_range })
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
    -- Distinct deadlines: the number of timers a per-deadline scheduler needs.
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

  -- BOTH NUMBERS.  Reporting only how many are attached answers half the question:
  -- a user cannot tell whether two speakers are two enough.  The requirement is the
  -- library's figure and follows the policy just chosen, so it has to be read AFTER
  -- that choice -- which it is.
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

  -- REFUSE A SONG THE SPEAKERS CANNOT HOLD, BEFORE ANY EXPENSIVE WORK.
  --
  -- Measured on `RushE.nbs` under the default shift policy: a peak of 109 simultaneous
  -- play_sounds, so 117 speakers are needed where 43 are attached. The allocator spent
  -- ELEVEN SECONDS relocating notes to make room for sounds it could never place --
  -- 43 speakers cannot hold 109 concurrent sounds however the notes are shuffled -- and
  -- on a real computer that is past the watchdog, so it crashed instead of finishing.
  --
  -- The shortfall is already known here, so refusing costs nothing and the futile work
  -- never starts. `--force` plays anyway: losing notes is the user's call once they can
  -- see the numbers.
  --
  -- A MISSING NUMBER IS NOT A SHORTFALL. An older or partial library exposes no
  -- `speaker_requirement`, and treating "unknown" as "needs a great many" would refuse
  -- every song. Only a definite shortfall blocks.
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
    -- Forcing is a deliberate choice, so it is stated: the user should not have to
    -- remember that they asked to lose notes.
    say(string.format(
      "forced: needs %d speakers, %d attached -- notes that do not fit will be dropped",
      needed, found))
  end

  -- A shortfall is NOT reported again here: the library already emits its `speakers`
  -- warning with the numbers (required, found, dropped), and saying it twice in
  -- different words is how a message becomes noise. The summary line above carries the
  -- count, and playback continues -- losing notes is the user's call, not a reason to
  -- refuse a song they asked to hear.

  local clock = current_clock()
  if clock == nil then
    fail("E_NO_CLOCK", "player.clock is missing, so playback cannot be timed")
    return 1
  end
  if type(clock.run_due) ~= "function" then
    -- Refused rather than degraded: polling cannot drive this clock, so
    -- accepting it here would mean accepting a silent song.
    fail("E_NO_CLOCK", "this clock cannot be driven (no run_due)")
    return 1
  end

  -- THE CLOCK IS CHECKED ON EVERY RUN, not just under --debug, and a clock that
  -- does not track real time REFUSES the song. Playing it anyway produces a
  -- silently wrong result -- either a song that never ends or one that finishes in
  -- seconds -- and no amount of watching the progress bar would explain why.
  log("--- clock: measuring rate before playback (0.2 s pause) ---")
  local clock_ok, clock_code, clock_detail = check_clock_health(clock, log)
  if not clock_ok then
    fail(clock_code, clock_detail)
    if close_log ~= nil then close_log() end
    return 1
  end

  if debug then
    log("--- instrumenting the clock; playback follows ---")
    clock = instrument_clock(clock, log)
  end

  local progress_logged = 0
  local session = lib.play(events, {
    analysis = analysis,
    speakers = speakers,
    clock = clock,
    out_of_range = out_of_range,
    -- WARNINGS WERE BEING DISCARDED.  The library emits bare codes and expects the
    -- caller to word them; a CLI that passes no handler silently loses every one, so
    -- "no warning appeared" said nothing about whether there had been a problem.
    on_warning = function(code, args)
      log(string.format("WARN %s", tostring(code)))
      say("warning: " .. cli.describe_warning(code, args))
    end,
    on_progress = function(info)
      local elapsed = tonumber(info.t_ms) or 0
      local frac = duration > 0 and (elapsed / duration) or 0
      -- Most informative first: the clock, then the note counter. The one that
      -- does not fit is the one that goes.
      live(cli.progress_line("playing", frac, {
        "  " .. cli.format_time(elapsed) .. "/" .. cli.format_time(duration),
        string.format("  note %d/%d",
          tonumber(info.index) or 0, tonumber(info.total) or 0),
      }))
      -- Rate-limited: 21247 callbacks would bury the log.
      progress_logged = progress_logged + 1
      if progress_logged <= 10 or progress_logged % 200 == 0 then
        log(string.format("progress %d/%s  t_ms=%s (%s)",
          tonumber(info.index) or 0, tostring(info.total), tostring(info.t_ms),
          cli.format_time(elapsed)))
      end
    end,
  })

  if type(session) ~= "table" then
    fail("E_PLAY", "the library did not return a playback session")
    return 1
  end

  -- DRIVE THE SONG. run_due() blocks on os.pullEvent("timer") and dispatches
  -- each armed handle until none remains -- which is the whole song. The
  -- progress callback fires from inside that dispatch, so the bar still moves.
  clock.run_due()

  -- A timer callback that raised was CAPTURED, not propagated, so without this
  -- a broken dispatch would look exactly like a song that finished.
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

  -- If it still reports itself playing once the clock has drained, something
  -- stopped early. Saying "done." there would be a lie.
  if type(session.is_playing) == "function" and session.is_playing() then
    fail("E_DISPATCH", "playback did not finish; the clock stopped early")
    if rt ~= nil and type(rt.cleanup) == "function" then
      pcall(rt.cleanup, speakers, session)
    end
    if close_log ~= nil then close_log() end
    return 1
  end

  -- Speakers are stopped on EVERY path, including this one, because a speaker
  -- left playing keeps sounding after the program ends.
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
