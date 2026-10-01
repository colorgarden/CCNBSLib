# AGENTS.md — CCNBSLib agent instructions

**This file is binding for every agent session in this repository.** Read it before
planning anything.

The project is a **library**. It parses `.nbs` scores and schedules them to
`speaker` peripherals. It has no interface, no installer, no network client, and
no third-party code. It used to be an application called CCNBSPlayer with all of
those; they were deleted on request, and that history is deliberate context — much
of what follows is what that deletion cost.

---

## 1. THE SHAPE OF THE THING

```
bytes ──decode──> song ──analyze──> analysis ──plan──> events ──play──> speakers
                     │                                        │
                     └── v0-v5 strings are CP1252 bytes ──────┘
                         (cp1252.to_display is a SEPARATE,
                          explicit step for showing them)
```

* `ccnbslib.lua` (project root) is the ONLY public entry point.
  `require("ccnbslib")` gives the whole pipeline.
* `nbs/` is parsing: reader → header → layers/notes → instruments → decode → analyze.
* `player/` is scheduling: plan → fanout → tempo → dispatch → speaker, plus `clock`
  (the injectable timer seam) and `runtime` (safe shutdown).
* `nbsplay.lua` is a minimal CLI: one URL, one song, one progress bar. It is a
  demonstration, not a product surface.

**A LIBRARY DOES NOT OWN THE EVENT LOOP.** `ccnbslib.play` returns a session
immediately and never blocks. The caller decides when to wait. Do not add a
`run()` that takes the loop.

---

## 2. READ THE REFERENCE BEFORE YOU DESIGN

When the user says **"照抄 MPlayer"** (copy MPlayer), they mean *read its source
and reproduce it*. The reference is readable Lua, not a compressed blob:

```
https://git.liulikeji.cn/xingluo/MPlayer    branch: master
  src/startup.lua      9,545 lines, ~34 bytes/line — READABLE. Read it.
  src/Settings.lua     settings persistence
  src/Api/ImeApi.lua   the pinyin client
  src/Lib/Player.lua   playback
  src/install.lua      the GUI installer
  release/install_list.lua   the install manifest + third-party URLs
```

Costs of not doing so, all real, all in this repository's history:

* Claimed the installer "followed MPlayer" without ever reading it. It did not:
  MPlayer's is a Basalt GUI with a progress bar and a button state machine.
* Missed that MPlayer opens with a `package`/`shell` shim. Without it the vendored
  Basalt could not load at all, so the GUI never appeared and the failure was
  swallowed by a `pcall` that returned a bare nil.
* Vendored the OFFICIAL Basalt instead of the fork MPlayer uses. The official
  build cannot render Chinese in text elements, so the entire Chinese interface
  was built on a framework that could not do the job.

**Rule: before writing a line that reproduces reference behaviour, `curl` the
relevant file and read it.** One call.

---

## 3. CONFIRM FACTS FROM THE SOURCE OR A PROBE

Never from an API field, a cache, or memory. Measured examples:

| Trusted | Reality |
|---|---|
| Gitea `license` API field said `None` | The repo's LICENSE file was GPL-2.0, 17,337 bytes — and is MIT now, so the field would be a stale answer in EITHER direction |
| `tostring(a_table):find("write")` | Can never match; reported a false failure |
| A grep count of `setImage` = 0 | The name is generated at runtime, not absent |
| raw CDN right after a push | Served the OLD file for ~5 min (`max-age=300`) |
| A size difference vs upstream | Was CRLF, not a stale artifact — I blamed upstream first |
| `total * 0.69` as a shrink estimate | Real ratio was 0.54; the estimate was pessimistic, not safer |
| A DELETED file's calling convention | The live API's: it took no `self` |
| `os.epoch("ingame")` as a millisecond clock | It is the IN-GAME day clock: frozen with `doDaylightCycle` off, and 72000 ms/real-second with it on |
| A "clock health check" that compares `os.epoch("utc")` with `now_ms()` | `now_ms()` IS `os.epoch("utc")` — it compared the clock with itself and could only report 1.0. `os.sleep` is the independent reference |
| `term.write("\n")` "makes a newline" | Measured: the row does not change; `"\n"` is an ordinary character that moves the cursor one COLUMN |
| The docs calling the layer byte "Layer lock" | It is a MUTE/SOLO switch: 1 = muted, 2 = solo (OpenNBS#307, which the published spec omits) |
| A fixture suite that passes | It cannot see a bug the fixtures do not contain — the mute bug needed a real 65-layer song to appear |
| "The speaker pitch is passed through, so out-of-range notes sound" | The SERVER passes it through; the CLIENT clamps it. `SoundEngine.calculatePitch` is `Mth.clamp(pitch, PITCH_MIN, PITCH_MAX)` = 0.5..2.0, so one recording reaches one octave either side and everything beyond is heard as the edge note. Two extra octaves need a different RECORDING (`block.note_block.<instrument>_1` / `_-1`, registered by OpenNBS's own extranotes pack), which only `playSound` can name |
| "A line as wide as the terminal wraps, so the bar scrolls" | `term.write` never wraps — the cursor just passes the edge. The real risk is CLIPPING, and the real defect was the missing newline |
| A hand-built fake terminal that models `"\n"` or wrapping | It is then wrong in the direction that HIDES the defect; encode only measured facts |
| Counting live rows left on screen to prove overwriting | The last frame is legitimately replaced by the next permanent line — count WHERE ticks LAND, not what survives |

**Rule: read the file, run the probe, or compare a hash. Then state the method.**

### The calling convention, specifically — it cost a broken release

CC:Tweaked registers a handle's methods with `@LuaFunction` on Java methods that
have **no `self` parameter**:

```java
@LuaFunction
public final Object[] getResponseCode() { ... }
@LuaFunction
public final Map<String, String> getResponseHeaders() { ... }
```

So they are called **dot-style**: `response.read(8192)`, `response.readAll()`,
`response.close()`. Passing the handle back in — `response.read(response, 8192)` —
sends a table where a count belongs, which on a real computer raises and surfaces
as a failed download.

I got this wrong by trusting this project's own **deleted** `net/http.lua`, which
passed `self` explicitly. Whether that ever worked is beside the point: it was not
the authority, and it was not on the machine any more.

Measured on CraftOS-PC against a FILE handle, which the response handle's javadoc
says shares its methods and which uses the same machinery:

```text
h.read(5)      -> "01234"   five characters            correct
h.read(h, 5)   -> "0"       the table became the count  wrong
```

`tests/nbsplay_spec.lua` now ENFORCES this: its fake response refuses an extra
leading argument, so passing `self` fails the suite. Verified by mutation.

### PERIPHERAL methods take no `self` either — same trap, and it cost the SOUND

The http response handle is not special. `SpeakerPeripheral.playNote` is registered
the same way — `@LuaFunction` on a Java method whose only Lua-visible parameters are
the real ones (`ILuaContext` is INJECTED):

```java
@LuaFunction
public final boolean playNote(ILuaContext context, String instrumentA,
                              Optional<Double> volumeA, Optional<Double> pitchA)
```

So `speaker.playNote(name, volume, pitch)` — dot-style, no `self`. `player/speaker.lua`
passed the peripheral object as the first argument, which made `instrumentA` a TABLE.
The speaker throws `Invalid instrument` for that, `player/dispatch.lua` contains the
raise in a pcall, and the result is the worst possible failure shape: **a normal
progress bar and no sound at all**, for the entire song.

The suite could not see it because every fake was declared
`function object.playNote(self, name, ...)` — the fake and the implementation agreed
with each other while BOTH disagreed with the platform. **A stub that accepts the
wrong shape cannot catch a disagreement with the platform.** The fakes now assert the
shape (first argument must be a string) and reject `self`, and test 5b pins it.

### A clock check must use an INDEPENDENT reference

The first "is the clock healthy?" check compared `os.epoch("utc")` before and after an
`os.sleep` against `now_ms()` — but `now_ms()` IS `os.epoch("utc")`, so it compared the
clock with itself and could only ever report a ratio of 1.0. A check that cannot fail
is worse than no check, because it looks like one. `os.sleep` is the independent
reference: it blocks for a known stretch of real time on the game's own timer.

Measured on CraftOS-PC 2.8.3 with `doDaylightCycle` ON, over an `os.sleep(1)`:

```text
os.epoch("utc")     1001 ms     real milliseconds        -- correct
os.epoch("ingame")  72000 ms    72x -- unusable when the cycle is ON
os.clock() * 1000   1000 ms     real, but quantised to 50 ms
```

`os.epoch("ingame")` is wrong in BOTH directions, and silently: frozen (delay becomes
an absolute time and the song never ends) or 72x (every event instantly overdue and
the song dumps at once). `now_ms` therefore uses `os.epoch("utc")`.

Note that the achievable TIMING is unchanged by any of this: `os.startTimer` rounds to
0.05 s and the speaker itself batches notes per game tick (`SpeakerPeripheral.update`
broadcasts `pendingNotes` once per tick, capped at `Config.maxNotesPerTick` = 8). 50 ms
is the floor for note scheduling regardless of clock resolution. Sub-tick precision
would require `playAudio` + DFPWM, which is a different architecture.

---

### KNOWN AND DEFERRED: the speaker formula over-asks, because two buffers are not one

`nbs/speakers.lua` computes `required = ceil(vanilla / 8) + play_sound` and its comment
states the reason: "one vanilla note plus one trumpet note needs TWO speakers, not one."
**The source says otherwise.** `SpeakerPeripheral.update()` flushes two INDEPENDENT
buffers in the same tick:

```java
public void update() {
    clock++;
    ...
    synchronized (pendingNotes) {              // all 8 pending playNotes, broadcast
        for (var sound : pendingNotes) { ...broadcast... }
        pendingNotes.clear();
    }
    ...
    synchronized (lock) { sound = pendingSound; pendingSound = null; ... }
    if (shouldStop && lastPosition != null) { ...; return; }   // the ONLY return, after both
    if (sound != null) { ...send the sound... }
```

and the two entry points guard only their own buffer: `playNote` refuses when
`pendingNotes.size() >= maxNotesPerTick`, `playSound` when `pendingSound != null`.
Neither consults the other. So **one speaker can play 8 notes AND 1 sound in the same
tick**, and the correct formula is `max(ceil(vanilla / 8), play_sound)`.

This is the same class of error this file keeps recording -- a hand-built model of the
platform that was never checked against the platform. The comment says "verified by the
test suite", but the suite verifies the FORMULA's arithmetic, not the platform's
behaviour.

WHY IT IS STILL LIKE THIS. The formula is CONSERVATIVE: it asks for more speakers than
necessary, never fewer, so nothing is silently dropped as long as the advice is
followed. Fixing it properly is not a one-line change -- `player/fanout.lua` models a
speaker as a single pool of eight slots where a sound displaces notes, and its ENTIRE
evacuation machinery exists to resolve a conflict that does not occur. The correct
allocator is smaller: notes and sounds never compete. That rewrite is deferred, on
purpose, and this note is the reason it must not be forgotten.

What it costs today: `simple.nbs` is told it needs 3 speakers when 2 suffice, and any
song with shifted notes is over-provisioned. Measured, before and after the extended
range default: `required` for `simple.nbs` went 1 -> 3.

### The layer byte is a MUTE/SOLO switch, and the fixtures could not have found it
The published NBS specification calls the per-layer byte "Layer lock" and documents
only "1 = locked", which reads like an editor permission. It is not. The OpenNBS
project's own issue tracker says so (OpenNBS/NoteBlockStudio#307):

> The 'Layer lock' field, originally intended to be a boolean, may actually assume
> values 0-2 (0= unlocked, 1=locked, 2=solo). This is currently undocumented in the
> NBS specification...

and a developer in that thread states the field is what people use to "mute
incomplete sections of the song or single out certain layers". The decisive argument
is that **solo is a playback concept, and solo cannot exist without a mute.**

Measured on a real song the user supplied (`THE KING.nbs`, 65 layers): three layers
carried lock=1 and **903 notes**, every one of which was being played. The fixtures
in `tests/fixtures/` are all lock=0, so **the suite passed while the player was wrong
— a fixture set cannot contain the bug it does not contain.** Only the real file
showed it.

Two more things this cost, both worth repeating:

* The rule is owned in **one** place, `nbs/layers.lua`, and consumed by both
  `player/plan.lua` (which notes become events) and `nbs/analyze.lua` (how many
  speakers those events need). When they disagree, the analysis sizes the fan-out for
  notes that will never sound.
* The first version of the `analyze.lua` filter kept the window scan iterating the
  FILE's note count while `items` had become a packed array of AUDIBLE notes, so it
  indexed past the end. **492 tests passed and the real song raised**, because on a
  song with no muted layers the two counts are equal. `total_notes` (the file) and
  `audible_notes` (`#items`) are different quantities and the code now names both.

---

### `term.write` does not make a newline — and that cost a whole release

The CLI wrote every permanent message as `term.write(text)` then
`term.write("\n")`. That second call does **not** move down a row. The documentation
says so plainly — `term.write` "does not handle more advanced features such as line
breaks or word wrapping" — and `TermAPI.java` agrees:

```java
m_terminal.write( text );
m_terminal.setCursorPos( m_terminal.getCursorX() + text.length(), m_terminal.getCursorY() );
```

Measured on CraftOS-PC 2.8.3, because documentation can describe another build:

```text
after write("AAAA")    x=5  y=1
after write("\n")      x=6  y=1     the ROW did not change
after write("BBBB")    x=10 y=1     so both landed on row 1
after write(width+5)   x=57 y=3     no wrapping either; the cursor passes the edge
clearLine()                         clears the WHOLE row, whatever column the cursor is on
```

So every message overwrote the one before and the screen ended up holding a single
line — the last one. The real way down is `bios.lua`'s own `write`: `setCursorPos(1,
y + 1)`, or `setCursorPos(1, height)` then `scroll(1)` at the bottom.

**The worse mistake was how it was diagnosed.** A fake terminal was built for the
suite that treated `"\n"` as a line break and wrapped at the right edge — both
wrong — so a writer doing `write(text); write("\n")` PASSED while putting every line
on one row for real. And an early "the line wraps at exactly the terminal width"
theory was invented from that same fake and written into the docs, where it was
simply false: `term.write` never wraps. **A hand-built model of the platform cannot
find a disagreement with the platform.** The fake now encodes only measured facts,
and its `write` deliberately does NOT special-case `"\n"` — removing that special
case is what makes the defect reproducible in the suite at all. Mutation-verified:
restoring `term.write("\n")` fails with `expected 4 separate rows, found 1: nbsplay:
done`.

---

## 4. PROJECT CONSTRAINTS (hard)

* **Language subset** — CC:Tweaked Cobalt, Lua 5.2 base. FORBIDDEN in our code:
  `//`, bitwise operators, `math.maxinteger`, `collectgarbage`, `string.dump`,
  `os.exit`, `goto`. `lua tests/lint.lua` must exit 0.
  NOTE: lint does **not** check `utf8.*` — that is a convention enforced by review,
  and it exists because the desktop interpreter (stock Lua 5.2.4) lacks `utf8`.
* **Licence: MIT, and the library contains ZERO third-party code.** There is
  no `vendor/` any more. If you ever need a third-party library, that is a
  decision for the user, not a vendoring detail. (Older releases were GPL-2.0.
  The move to MIT was the owner's own call, made while the repository still had
  a single author, so it is NOT a precedent for pulling in third-party code.)
* **`tests/` is NOT published** (`.gitignore`). The suite protects the local
  developer only. If a guarantee must hold on GitHub, it cannot live only in
  `tests/`.
* **A SHIPPED MODULE MUST APPEAR IN THE MANIFEST, AND THE MANIFEST IS GENERATED.**
  `manifest.txt` is the list `install.lua` installs; a module missing from it is
  simply not installed, and the library is then broken for everyone but you. That is
  not a thing to remember: `lua tools/make_manifest.lua` derives the manifest from
  git, and `tests/installer_spec.lua` case 22 fails when the committed manifest is
  missing a file or disagrees with a size. So:
  * after adding, renaming or deleting a module — `lua tools/make_manifest.lua`,
    then commit `manifest.txt` along with the change;
  * `lua tools/make_manifest.lua --check` exits non-zero when the committed manifest
    is stale, which is what a CI would run;
  * the generator REFUSES a commit that is not on `origin/main`. A manifest naming an
    unpushed commit points every user at a 404, so push first, then regenerate.
  `README.md`'s file list is still written by hand and still matters for a human
  reader; the manifest is what the machine uses.

---

## 5. WORKING PROTOCOL

0. **DO NOT COMMIT OR PUSH without an explicit request.** The user revoked this
   twice ("不许提交到远程仓库", then "本地也不行") before later asking for specific
   pushes. So: **leave changes in the working tree** and never commit
   speculatively. Commit only what the user names, only when they ask.
1. **Plan agent for anything 2+ steps.** It returns a task graph with waves.
2. **TDD, always.** Write the failing test FIRST, run it, capture the assertion
   message proving it fails for the RIGHT reason. Then the smallest change that
   turns it GREEN. Production code before its failing test = revert and redo.
3. **Delegate.** Parallelise independent work; one module per lane; never let two
   lanes touch the same file.
4. **Evidence, not assertion.** "Tests pass" is the floor. Capture literal command
   output, and for anything user-visible capture the real surface.
5. **Mutation-test your own tests.** Break the implementation deliberately and
   confirm the test FAILS. This caught a spec whose driver silently recorded
   nothing after the first assertion.
6. **Prove equivalence by RUNNING it, not by inspecting it.** When 46 files were
   minified, my first correctness check compared string literals and was
   worthless — it counted quotes inside comments, which is exactly what a
   comment-stripper removes, so every file looked corrupted. The proof that
   mattered was minifying the whole tree and passing the whole suite on it.
7. **Correct yourself in the record.** When a claim in `NOTICE`, a doc or a
   ledger entry turns out false, fix the text — do not leave it standing.
8. **PUBLISHED DOCS ARE FOR USERS.** Everything committed under `docs/` (and every
   section of `README.md`) is read by someone who wants to install and play music,
   so it is written for them: what the thing does, how to run it, what can go
   wrong, and nothing else. No design rationale, no "measured evidence", no
   references to this file, no account of the mistakes made along the way.
   The ONE exception is a document that is explicitly for an agent — this file is
   the example. Planning artifacts (design specs, work plans, evidence) are agent
   material and belong in `.omo/`, which `.gitignore` already refuses to publish.
   This was broken once: a design spec was committed to `docs/superpowers/specs/`
   and had to be moved out.

---

## 6. DECISIONS ALREADY MADE (do not relitigate)

* **The pipeline is frozen at `decode` / `analyze` / `plan` / `play`.** They are
  thin pass-throughs: whatever the underlying module returns, the library returns
  unchanged. Do not wrap or normalise at that level.
* **Warnings are BARE CODES.** `on_warning(code, args)` — the library never
  formats a sentence. The prose renderer that used to do this was deleted with the
  interface, and its absence is the contract.
* **Pitch is deliberately NOT clamped.** Out-of-range notes go to the speaker as
  they are; real CC:Tweaked does no validation, and the timbre depends on the
  user's resource pack. CraftOS-PC rejects them, which is documented in
  `docs/COMPAT.md` and is an emulator-only divergence — do not "fix" it.
* **CP1252 conversion is a separate, explicit step.** `nbs/cp1252.lua` is the only
  place allowed to do it, and only for display.
* **The clock seam is how time is controlled.** `opts.clock` lets a test run a
  whole song instantly. Anything time-dependent must go through it.
* **A SESSION DOES NOT DRIVE ITSELF — THE CALLER MUST PUMP THE CLOCK.**
  `ccnbslib.play` arms timers and returns; it does not run them.
  `player.clock.new_os().after()` calls `os.startTimer` and records the handle, and
  the callback runs only when `run_due()` drains `timer` events and dispatches that
  handle. So a consumer must:

  ```lua
  local clock = require("player.clock").new_os()
  local session = ccnbslib.play(song, { clock = clock })
  clock.run_due()   -- blocks for the whole song; without it, SILENCE
  ```

  **Polling with `os.sleep` does not work, and fails silently.** `os.sleep` pulls
  and discards every event until its own timer fires, so the song's timers are
  consumed with their callbacks never invoked: no notes are dispatched, the
  program prints `nbsplay: done`, and there is no sound. That was a real bug in
  `nbsplay.lua`, caught only by driving the CLI in a test. Also check
  `clock.errors` afterwards — a raising timer callback is captured there rather
  than propagated, so ignoring it makes a broken dispatch look like a finished
  song.

---

## 7. HOW TO RUN THINGS

```text
lua tests/run.lua                             # full suite
lua tests/lint.lua                            # the Cobalt-subset gate; must print "lint: OK"
lua tests/run.lua tests/nbs/decode_spec.lua   # one spec
```

The emulator, for anything that must be proven on the real target:

```text
D:\tools\CraftOS-PC\CraftOS-PC_console.exe --headless -d <data-dir>
```

Files handed to it MUST be written **without a BOM** — PowerShell's
`Set-Content -Encoding UTF8` adds one and CC's Lua rejects it with
"Unexpected character". Write with Python in binary mode instead.

The emulator's speaker rejects pitch outside 0..24; see `docs/COMPAT.md`. The
user's real test rig additionally needs its `computercraft-server.toml` to allow
`198.18.0.0/15` before `$private`, because their proxy resolves every domain into
that range and CC:Tweaked otherwise refuses it as a private address.
