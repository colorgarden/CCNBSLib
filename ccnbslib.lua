-- SPDX-License-Identifier: MIT
-- Copyright (C) 2026 colorgarden
-- CCNBSLib 的一部分。以 MIT 授权；见 LICENSE。
--
-- ccnbslib.lua
--
-- 公共库模块 —— 别人的脚本 `require` 的**唯一入口**。下面的一切都是对已有各层的
-- 薄封装、非阻塞组合；decode/analyze/plan/dispatch/fan-out/tempo 这些逻辑在这里
-- **一行都没有**重新实现。
--
-- 为什么这个文件在项目根目录（而不是 nbs/init.lua）
-- ---------------------------------------------------------------------------
-- 目标机上的 `package.path` **不保证**包含 `?/init.lua`，所以包风格的
-- `nbs/init.lua` 可能根本找不到。根目录的 `ccnbslib.lua` 走的是普通的
-- `./?.lua` 模式，而那是**保证**会被解析到的。
--
-- 冻结的公共接口
--   local ccnbs = require("ccnbslib")
--
--   ccnbs.decode(bytes)        -> nbs.decode.decode(bytes)
--   ccnbs.analyze(song)        -> nbs.analyze.analyze(song)
--   ccnbs.plan(song, analysis) -> player.plan.plan(song, analysis)
--   ccnbs.discover_speakers()  -> player.speaker.discover()
--   ccnbs.version              -> "1.0.0"
--   ccnbs.play(song|plan, opts) -> session
--
-- `play` 既可以收解码后的 song，也可以收已算好的 plan。判别依据是**形状**，而不是
-- 某个可能碰巧撞上的字段：
--   * SONG 是带 `header` 子表的表（解码后的 song 其 header 有数字 `version`；分析
--     还需要它的 `tempo_ticks_per_second`）；play 会像以前一样对它做分析和编排；
--   * PLAN 就是 ccnbs.plan 返回的那个数组：每个元素都是事件表，带数字 `t_ms` 和
--     字符串 `kind`（真正的空表就是「没有音符的歌」的 plan）。plan 被**原样**使用
--     ——**绝不**重新分析（事件数组没有可分析的 song header），也**绝不**重新编排。
--   * 其他任何输入都会抛 E_BAD_PLAY_INPUT。
--
-- plan 不带 song header，所以它自己无法确定扬声器数量或 tick 间隔：要把与之匹配的
-- `opts.analysis`（也就是你当初拿来编排的 ccnbs.analyze(song)）传进来。省略它会抛
-- 带类型的错误 E_PLAN_REQUIRES_ANALYSIS，并在消息里点名 opts.analysis——**绝不**是
-- nil 参与算术的崩溃。因此「播一首歌」和「播它的 plan」行为**完全一致**（同样的
-- 警告、同样的分配、同样的调用顺序）。
--
-- `opts`（全部可选；接缝可注入）：
--   opts.analysis    与 PLAN 匹配的分析（传 song 时忽略）
--   opts.speakers    扬声器记录数组；默认 player.speaker.discover()
--   opts.clock       时钟；默认 player.clock.new_os()
--   opts.on_warning  function(code, args)，每个**不同的**裸码至多一次
--   opts.on_progress function(info)，info = { t_ms, index, total }
--   opts.on_event    function(event)，每个到期事件在派发**之前**调用
--
-- 警告聚合 —— 关键的集成要求
-- ---------------------------------------------------------------------------
-- 每一类警告都通过**唯一的** opts.on_warning(code, args) 回调浮出，且每个**裸码**
-- 每次会话**至多一次**：
--   "extended-range"    analysis.has_extended_range；args { min_key, max_key }。
--                       在 play **开始时**发出——它是加载期属性，**不是**播放中途
--                       的事件。
--   "speakers"          fan-out 丢掉了东西 / found < required；args 直接来自
--                       assignment.warning_args
--                       （{ peak, required, found, dropped }）。
--   "custom-instrument" 有任何 custom 事件被拒；args { count = <n> }。
--   "play-sound-pitch"  某个 trumpet 音高被夹取（来自 dispatch）。
--   "tempo-clamp"       某个延迟低于计时粒度（来自 tempo）。
-- 每个码的来源都是**不同**的模块。本文件把它们收集起来，并**按码**去重。它**不**
-- 格式化 `WARN[...]` 字符串——那是 player/warnings.lua 的职责——而且它什么都不打印。
--
-- 调用约定的分裂（刻意为之——不要「统一」它）
-- ---------------------------------------------------------------------------
--   * 扬声器记录和调度器是冒号风格：
--         rec:play_note(name, vol, pitch)   d:event(event, speaker)
--   * 时钟对象和时钟模块是点风格：
--         vc.after(delay, fn)   vc.now_ms()   clock.advance_to(vc, target)
--     用冒号调用时钟方法会把时钟本身当作 delay 传进去，于是失败。tempo **自己**的
--     方法是冒号风格（t:play、t:cancel、t:stats），尽管它消费的时钟是点风格。
--
-- 非阻塞
-- ---------------------------------------------------------------------------
-- play() 只在注入的时钟上排程，然后立刻返回。测试用 clock.advance_to 驱动虚拟
-- 时钟；生产环境用 os 时钟及其真实定时器。本文件从不忙等、从不 sleep，也从不直接
-- 触碰真实时钟——节奏由 player/tempo.lua 掌管。
--
-- 兼容性：Lua 5.2 / CC:Tweaked Cobalt。不用整除、不用位运算、不用 utf8.*、不用
-- collectgarbage、不用 string.dump、不用 os.exit。require 在任何地方都不碰网络。

local decode_module = require("nbs.decode")
local analyze_module = require("nbs.analyze")
local plan_module = require("player.plan")
local speaker_module = require("player.speaker")
local clock_module = require("player.clock")
local dispatch_module = require("player.dispatch")
local fanout_module = require("player.fanout")
local tempo_module = require("player.tempo")
local cp1252_module = require("nbs.cp1252")
local runtime_module = require("player.runtime")
local speakers_module = require("nbs.speakers")

local ccnbs = {}

-- 对外的版本字符串。
ccnbs.version = "1.0.0"

-- 薄透传。每一个都**原样**返回下层模块的返回值；不包装、不归一化，于是形状保持
-- 完全一致。
ccnbs.decode = decode_module.decode
ccnbs.analyze = analyze_module.analyze
ccnbs.plan = plan_module.plan

-- ccnbs.cp1252 —— NBS v0-v5 把每个字符串都存成 CP1252，一个字符一个字节，而读取器
-- 把这些字节**逐字节精确保留**，因为自定义乐器的音效文件路径依赖这份保真度。所以
-- 「让人类能读曲名或图层名」的那次转换是一个**单独的、显式的**步骤，而这里是**唯一**
-- 允许做这次转换的地方。解析，不是呈现。
ccnbs.cp1252 = cp1252_module

-- ccnbs.runtime —— 安全地停掉扬声器，以及一个现成的程序框架，给不想自己写事件循环
-- 的调用方用。**库不拥有事件循环**——调用方才有——所以这是「提供」而不是「强制」。
ccnbs.runtime = runtime_module

-- ccnbs.discover_speakers() -> 按 side 升序排列的扬声器记录数组。让调用方在调用
-- play() 之前就能预先确认有多少个扬声器存在。
function ccnbs.discover_speakers()
  return speaker_module.discover()
end

-- ccnbs.speaker_requirement(analysis) -> integer
--
-- **被分析的这首歌需要几个扬声器**，好让调用方把它和实际挂上的数量对比。
-- `discover_speakers` 回答的是「有几个」；没有这个函数就没有「需要几个」的对应物，
-- 调用方也就无法判断两个扬声器到底**够不够**。
--
-- 对 nbs.speakers.required_count 的薄透传，公式由它掌管——这一层的流水线刻意保持薄，
-- 所以这里不重算、不归一化。数值跟随传给它的 analysis，因此当扩展音域策略生效时，
-- 它反映的就是那个策略的开销。
function ccnbs.speaker_requirement(analysis)
  return speakers_module.required_count(analysis)
end

-- is_song(value)：**可靠**的 song 判别器——**不是**拿一个 plan 可能碰巧也有的字段去
-- 猜。song 是带 `header` 子表的表；解码后的 song 一定有数字 `header.version`，而分析
-- 还需要 header 的数字 `tempo_ticks_per_second`。一个**最小**的合成 song 可以省略
-- `version`，但必须仍然带 tempo——两者接受其一，既让手搭的测试歌曲继续可用，又绝不
-- 会把 plan 误当成 song（plan 数组**根本没有** `header` 键）。
local function is_song(value)
  if type(value) ~= "table" then
    return false
  end
  local header = value.header
  if type(header) ~= "table" then
    return false
  end
  return type(header.version) == "number"
    or type(header.tempo_ticks_per_second) == "number"
end

-- is_plan(value)：**可靠**的 plan 判别器。plan 是事件表组成的**数组**，每个事件带
-- 数字 `t_ms` 和字符串 `kind`（player.plan 冻结的事件形状）。一个真正的**空表**就是
-- 「没有音符的歌」的 plan；而只带非数组键的表不是 plan——它会被当作无意义输入拒掉，
-- 而不是被静默当成空歌。
local function is_plan(value)
  if type(value) ~= "table" then
    return false
  end
  local count = #value
  if count == 0 then
    return next(value) == nil
  end
  for index = 1, count do
    local event = value[index]
    if type(event) ~= "table" then
      return false
    end
    if type(event.t_ms) ~= "number" then
      return false
    end
    if type(event.kind) ~= "string" then
      return false
    end
  end
  return true
end

-- ccnbs.play(song|plan, opts) -> session
--
-- 把整个播放器组合到一次调用之后，并立刻返回。第一个参数可以是解码后的 SONG，也可以
-- 是已算好的 PLAN；判别规则、opts.analysis 与警告契约见模块头。
function ccnbs.play(song_or_plan, opts)
  if opts == nil then
    opts = {}
  end
  if type(opts) ~= "table" then
    error({
      code = "E_BAD_PLAY_OPTS",
      msg = "ccnbs.play: opts must be a table or nil; got " .. type(opts),
    }, 2)
  end

  -- 解出 (events, analysis)。song 在这里被分析和编排；plan 则**原样**取用（**绝不**
  -- 重新分析——它是事件数组——也**绝不**重新编排），并且需要调用方提供匹配的 analysis。
  local events
  local analysis
  -- 越界**策略**必须同时到达分析器和编排器，否则扬声器估算就会按一个与实际事件开销
  -- 不同的成本去定尺寸。
  local plan_opts = { out_of_range = opts.out_of_range }

  if is_song(song_or_plan) then
    analysis = analyze_module.analyze(song_or_plan, plan_opts)
    events = plan_module.plan(song_or_plan, analysis, plan_opts)
  elseif is_plan(song_or_plan) then
    events = song_or_plan
    analysis = opts.analysis
    if type(analysis) ~= "table" then
      error({
        code = "E_PLAN_REQUIRES_ANALYSIS",
        msg = "ccnbs.play: a plan is an array of events and carries no song "
          .. "header, so it cannot size the speakers or the tick interval by "
          .. "itself; pass opts.analysis = ccnbs.analyze(song), or call "
          .. "ccnbs.play(song, opts) with the song instead.",
      }, 2)
    end
  else
    error({
      code = "E_BAD_PLAY_INPUT",
      msg = "ccnbs.play: expected a song (a table carrying a header table) or a "
        .. "plan (an array of events each carrying t_ms and kind); "
        .. "got " .. type(song_or_plan),
    }, 2)
  end

  local total = #events

  local speakers = opts.speakers
  if speakers == nil then
    speakers = speaker_module.discover()
  end

  local clock_obj = opts.clock
  if clock_obj == nil then
    clock_obj = clock_module.new_os()
  end

  local on_warning = opts.on_warning
  local on_event = opts.on_event
  local on_progress = opts.on_progress

  -- 每个码只记一次的警告台账。一个码**第一次**被抛出时转发；同一码此后再抛都在这里
  -- 被吞掉（dispatch 和 fan-out 内部本来就已去重，这一步让保证变成无条件的）。
  local warned = {}

  local function emit(code, args)
    if code == nil or warned[code] then
      return
    end
    warned[code] = true
    if on_warning ~= nil then
      on_warning(code, args)
    end
  end

  -- 在冻结的事件序上做确定性扇出。`assignment` 是调用方可见的记录；`by_speaker`
  -- 让我们按身份把每个事件路由出去。
  local assignment = fanout_module.assign(events, analysis, speakers)

  -- 加载期属性优先：扩展音域在任何一个事件触发之前就已知，所以它不能等到播放中途。
  if analysis.has_extended_range then
    emit("extended-range", {
      min_key = analysis.min_key,
      max_key = analysis.max_key,
    })
  end

  -- 扇出的缺口 / 丢弃同样在开播前就从 assignment 得知。
  if assignment.warning_code ~= nil then
    emit(assignment.warning_code, assignment.warning_args)
  end

  -- 事件表 -> 分配到的扬声器记录。plan 事件都是不同的表，所以按身份作键没有歧义。
  -- 不在映射里的事件就是被丢掉的那个。
  local route = {}
  local speaker_count = #speakers
  for index = 1, speaker_count do
    local record = speakers[index]
    local side = record.side
    local bucket = assignment.by_speaker[side]
    if bucket ~= nil then
      for position = 1, #bucket do
        route[bucket[position]] = record
      end
    end
  end

  local dispatcher = dispatch_module.new({})
  local fired = 0
  local custom_count = 0
  local dropped_count = 0

  -- 推迟到播放跑完才知道最终计数的警告："custom-instrument" 报告实际被拒的 custom
  -- 事件数，"notes-dropped" 报告扬声器拒绝的音符数。两者推迟的原因相同：计数才是有用
  -- 的部分，而它在歌曲结束之前根本不存在。
  local function finish_warnings()
    if custom_count > 0 then
      emit("custom-instrument", { count = custom_count })
    end
    if dropped_count > 0 then
      emit(dispatch_module.WARN_NOTES_DROPPED, { count = dropped_count })
    end
  end

  local tempo_session = tempo_module.new({
    clock = clock_obj,
    -- **权威**的标称 tick 间隔（缺陷 C）。没有它，调度器会从事件时间之间的最小间隔
    -- 去推断间隔，于是**高估**稀疏歌曲的间隔，并**跳过**真正的亚粒度夹取警告。
    tick_ms = analysis.tick_ms,
    -- tempo 的 warn 回调交回的是不带 args 的**裸码**。
    warn = function(code)
      emit(code, {})
    end,
    on_event = function(event)
      fired = fired + 1

      -- on_event 对每个到期事件都在 dispatch **之前**运行。
      if on_event ~= nil then
        on_event(event)
      end

      local target = route[event]
      if target ~= nil then
        -- 冒号调用：调度器接受显式的 self。
        local result = dispatcher:event(event, target)
        if result ~= nil
          and result.warning_code == dispatch_module.WARN_PLAY_SOUND_PITCH then
          emit(dispatch_module.WARN_PLAY_SOUND_PITCH, {})
        end
        -- **拒绝**是扬声器在说「不」——它撞上了每 tick 的音符上限，返回 false 而不是
        -- 抛错。那个音符没有出声，所以会被计数，并在歌曲结束时带上总数报告一次。没有
        -- 这一步，丢失就是完全静默的：一切看起来都正确，而密集段落干脆永远不出声。
        if result ~= nil and result.called and result.refused then
          dropped_count = dropped_count + 1
        end
        if event.kind == "custom" then
          custom_count = custom_count + 1
        end
      end

      if on_progress ~= nil then
        on_progress({ t_ms = event.t_ms, index = fired, total = total })
      end

      if fired >= total then
        finish_warnings()
      end
    end,
  })

  -- 在注入的时钟上排程；立刻返回（绝不阻塞）。
  tempo_session:play(events)

  -- 交还给调用方的会话对象。
  local session = {}

  -- session.cancel()：停止播放；幂等。还会补发被推迟的 "custom-instrument" 警告，
  -- 好让被取消的会话仍能报告它看到过什么。
  function session.cancel()
    if session._cancelled then
      return
    end
    session._cancelled = true
    tempo_session:cancel()
    finish_warnings()
  end

  -- session.is_playing()：还有事件未播完且未被取消时为 true。
  function session.is_playing()
    if session._cancelled then
      return false
    end
    return fired < total
  end

  -- session.stats()：从 tempo 会话原样透传。
  function session.stats()
    return tempo_session:stats()
  end

  session._cancelled = false

  -- 冻结的公共会话字段。
  session.analysis = analysis
  session.plan = events
  session.assignment = assignment

  return session
end

return ccnbs
