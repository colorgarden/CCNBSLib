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
| Gitea `license` API field said `None` | The repo's LICENSE file was GPL-2.0, 17,337 bytes |
| `tostring(a_table):find("write")` | Can never match; reported a false failure |
| A grep count of `setImage` = 0 | The name is generated at runtime, not absent |
| raw CDN right after a push | Served the OLD file for ~5 min (`max-age=300`) |
| A size difference vs upstream | Was CRLF, not a stale artifact — I blamed upstream first |
| `total * 0.69` as a shrink estimate | Real ratio was 0.54; the estimate was pessimistic, not safer |
| A DELETED file's calling convention | The live API's: it took no `self` |

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

---

## 4. PROJECT CONSTRAINTS (hard)

* **Language subset** — CC:Tweaked Cobalt, Lua 5.2 base. FORBIDDEN in our code:
  `//`, bitwise operators, `math.maxinteger`, `collectgarbage`, `string.dump`,
  `os.exit`, `goto`. `lua tests/lint.lua` must exit 0.
  NOTE: lint does **not** check `utf8.*` — that is a convention enforced by review,
  and it exists because the desktop interpreter (stock Lua 5.2.4) lacks `utf8`.
* **Licence: GPL-2.0, and the library contains ZERO third-party code.** There is
  no `vendor/` any more. If you ever need a third-party library, that is a
  decision for the user, not a vendoring detail.
* **`tests/` is NOT published** (`.gitignore`). The suite protects the local
  developer only. If a guarantee must hold on GitHub, it cannot live only in
  `tests/`.
* **Do not add a module without adding it to the file list in `README.md`.** The
  installer that used to enforce a shipped list is gone, so nothing mechanical
  checks this now — a module that is not listed simply will not be copied, and the
  library will be broken for everyone but you.

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
