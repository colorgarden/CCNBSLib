# ccnbs 公共库 API

`ccnbslib` 是 CCNBSLib 对外的唯一入口模块。其它脚本只需要 `require("ccnbslib")`
即可完成「解码 → 分析 → 编排 → 播放」全流程，无需了解内部各层的存在。

模块文件位于**项目根目录** `ccnbslib.lua`，而不是 `nbs/init.lua`：目标环境的
`package.path` 不保证包含 `?/init.lua`，但根目录的 `ccnbslib.lua` 一定能被
`./?.lua` 这一条默认规则解析到。

## 快速开始

```text
local ccnbs = require("ccnbslib")
```

`require` 不会访问网络。安装完成后可从全新 shell 直接加载。

## 公共接口

| 调用 | 返回 |
| --- | --- |
| `ccnbs.decode(bytes)` | 与 `nbs.decode.decode` 完全相同的结构：成功 `{ok=true, song=...}`，失败 `{ok=false, error={code=...}}` |
| `ccnbs.analyze(song, opts)` | 与 `nbs.analyze.analyze` 完全相同的结构 |
| `ccnbs.plan(song, analysis, opts)` | 事件数组（冻结全序 `(tick_index, layer_index, note_index)`） |
| `ccnbs.play(song\|plan, opts)` | 一个**会话** `session`，立即返回、不阻塞（第一个参数可以是歌曲表，也可以是已编排好的事件数组） |
| `ccnbs.discover_speakers()` | 已挂载扬声器记录数组（side 升序），调用 `player.speaker.discover` |
| `ccnbs.speaker_requirement(analysis)` | 这首歌**需要几个**扬声器（整数）。与 `discover_speakers` 配对：一个回答「有几个」，一个回答「要几个」 |
| `ccnbs.cp1252` | CP1252 → UTF-8 显示转换。**唯一**允许做该转换的地方，且只用于显示 |
| `ccnbs.runtime` | `stop_speakers` / `cleanup`：安全停掉扬声器；另含一个现成的程序框架 |
| `ccnbs.version` | 版本字符串，例如 `"1.0.0"` |

`decode` / `analyze` / `plan` 是**原样转发**，返回值与直接调用底层模块逐字段一致。

## 超出音域的音符

Minecraft 客户端播放音效时会把音高夹到 `0.5..2.0`，所以**一份录音只能覆盖一个
八度上下**——更远的音符会被听成边界音。想再远，只能**换一份录在别的八度的音效
文件**（OpenNBS 官方 extranotes 材质包注册了 `<乐器>_1` / `<乐器>_-1`，各再覆盖
两个八度）。

因此越界音符怎么处理有四种选择，由 `opts.out_of_range` 指定：

| 取值 | 行为 | 音高 | 需要材质包 | 代价 |
| --- | --- | --- | --- | --- |
| `"shift"`（**默认**） | 换偏移录音 | **正确** | **是** | 每个越界音符占满一个扬声器 tick |
| `"passthrough"` | 原样交给客户端夹 | 被夹到边界 | 否 | 无 |
| `"clamp"` | 我们自己夹到原生范围 | 被夹到边界 | 否 | 无 |
| `"drop"` | 不播放这个音符 | — | 否 | 完全静音，但不占扬声器槽 |

覆盖范围：`shift` 下 key **9..81**（六个八度）；其余三种不扩展，超出原生
`33..57` 即被夹或不发声。

> `shift` 是默认值，因为不这样的话材质包装了也不起作用。**没装材质包就用
> `"passthrough"`**——否则越界音符会因为音效名解析不到而完全静音。

`opts.out_of_range` 在 `play` / `analyze` / `plan` 上含义一致，且**必须同时传**：
它决定越界音符的事件种类，而扬声器需求正是按事件种类算的；只传给其中一个会让
需求数与实际事件不符。

## 接缝注入（seams）

`ccnbs.play(song, opts)` 的 `opts` 全部可选。生产环境什么都不传，即使用真实
外设与真实时钟；测试环境注入两个接缝即可获得完全确定性：

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `opts.speakers` | `ccnbs.discover_speakers()` | 扬声器记录数组 |
| `opts.clock` | 新建的 `player.clock.new_os()` | 计时来源；可注入虚拟时钟 |
| `opts.on_warning` | 无 | `function(code, args)`，每个不同的**裸**代码至多回调一次 |
| `opts.on_progress` | 无 | `function(info)`，`info = {t_ms, index, total}` |
| `opts.on_event` | 无 | `function(event)`，每个到期事件在**派发之前**回调 |
| `opts.out_of_range` | `"shift"` | 越界音符怎么处理，见上文〈超出音域的音符〉 |

`play` 只在注入的时钟上排期后立即返回。测试用虚拟时钟通过
`clock.advance_to(vc, target_ms)` 推进；生产用 os 时钟与真实定时器。
`play` 自身不忙等、不睡眠，节奏由 `player.tempo` 负责。

## `play` 的第一个参数：歌曲或计划

`play` 接受**两种**形状，靠**形状**可靠区分（不靠某个可能碰巧存在的字段）：

- **歌曲**：带 `header` 表的表。`ccnbs.decode` 产出的歌曲其 `header.version`
  是数字，分析还需要 `header.tempo_ticks_per_second`。给出歌曲时，`play` 照旧先
  `analyze` 再 `plan`，行为与从前完全一致。
- **计划**：`ccnbs.plan` 返回的**事件数组**——每个元素都带数字 `t_ms` 与字符串
  `kind`。给出计划时，`play` **原样使用**它，既不重新分析（事件数组没有歌曲头可
  分析），也不重新编排。空表被视为「零事件歌曲的计划」。
- 其它任何值（`nil`、字符串、数字……）都会抛出类型化错误 `E_BAD_PLAY_INPUT`。

计划本身**不含歌曲头**，无法自行推算扬声器需求与节拍间隔，因此必须把与之匹配的
分析经 `opts.analysis` 传入：

| 选项 | 何时需要 | 说明 |
| --- | --- | --- |
| `opts.analysis` | 仅当第一个参数是**计划**时 | 与计划匹配的分析结果（即 `ccnbs.analyze(song)`）；参数是歌曲时忽略 |

```text
local analysis = ccnbs.analyze(song)
local events = ccnbs.plan(song, analysis)
ccnbs.play(events, { analysis = analysis })   -- 播放已编排好的计划
```

省略 `opts.analysis` 时会抛出类型化错误 `E_PLAN_REQUIRES_ANALYSIS`（错误信息点名
`opts.analysis`），而**不是**一个 nil 算术崩溃。播放歌曲与播放其计划的行为
**完全一致**：相同的警告、相同的分配、相同的调用序列。

## 会话对象 `session`

| 成员 | 说明 |
| --- | --- |
| `session.cancel()` | 停止播放；幂等 |
| `session.is_playing()` | 是否仍在播放（取消后为 `false`） |
| `session.analysis` | 本次分析结果 |
| `session.plan` | 本次事件数组 |
| `session.assignment` | 扇出分配结果（含 `warning_args`） |
| `session.stats()` | 透传自 tempo 会话的统计 |

## 警告代码

所有警告都汇到**同一个** `opts.on_warning(code, args)` 回调上，每个会话**每个不同的码至多一次**。
`ccnbs` 只上报**裸码**，不做任何渲染，也不给句子 —— 怎么显示完全由调用方决定。

| 代码 | 触发条件 | `args` |
| --- | --- | --- |
| `"extended-range"` | 音符超出 33..57 之间的键**在播放开始时**上报（加载期属性，而非播放中途）。用 `opts.out_of_range` 决定怎么处理它们 | `{min_key, max_key}` |
| `"speakers"` | 扇出发生丢弃或所需扬声器数不足 | `{peak, required, found, dropped}` |
| `"custom-instrument"` | 有自定义乐器事件被拒绝播放 | `{count=<n>}` |
| `"play-sound-pitch"` | 小号音高被夹取进 0.5..2.0 | 无 |
| `"tempo-clamp"` | 某个延时低于定时器粒度（50 ms） | 无 |
| `"notes-dropped"` | 扬声器拒绝了音符（每 tick 上限 8 个），这些音符没有发声 | `{count=<n>}` |

## 调用约定：冒号与点号**故意不统一**

注入的两类接缝使用不同的方法调用约定，这是刻意设计的，请勿「统一」：

- **扬声器记录**与**分发器**用冒号（方法带显式 `self`）：
  `rec:play_note(name, vol, pitch)`、`d:event(event, speaker)`。
- **时钟对象**与**时钟模块**用点号（方法不带 `self`）：
  `vc.after(delay, fn)`、`vc.now_ms()`、`clock.advance_to(vc, target)`。
  对时钟调用 `vc:after(...)` 会把时钟自身当作延时传入并报错。

注意 tempo 自己暴露的接口又是冒号风格（`t:play`、`t:cancel`、`t:stats`），
即使它消费的时钟是点号风格。

## 完整可运行示例

下面的示例演示完整的「解码 → 注入接缝 → 播放 → 推进时钟」流程。请把示例里的
`my_song.nbs`（位于当前目录）**替换成你自己的歌曲文件**；该文件不存在时，示例会打印
一句提示后直接跳过，不会报错。

```lua
local ccnbs = require("ccnbslib")
local clock = require("player.clock")
local speaker = require("player.speaker")

-- 1) 读取并解码一个 .nbs 文件（把 "my_song.nbs" 替换成你自己的歌曲文件）
local file = io.open("my_song.nbs", "rb")
if file == nil then
  print("未找到 my_song.nbs，请替换成你自己的歌曲文件后再运行本示例。")
  return
end
local bytes = file:read("*a")
file:close()

local decoded = ccnbs.decode(bytes)
assert(decoded.ok, "decode failed: " .. tostring(decoded.error and decoded.error.code))

-- 2) 注入两个 mock 扬声器与一个虚拟时钟（生产环境省略这两个接缝即可）
local left = speaker.mock("left")
local right = speaker.mock("right")
local vclock = clock.new_virtual(0)

local warning_counts = {}
local session = ccnbs.play(decoded.song, {
  speakers = { left, right },
  clock = vclock,
  on_warning = function(code)
    warning_counts[code] = (warning_counts[code] or 0) + 1
  end,
})

-- 3) 推进虚拟时钟直到歌曲结束（play 不阻塞调用方）
clock.advance_to(vclock, 60000)

assert(session.analysis.total_notes > 0)
assert(#session.plan == #decoded.song.notes)
assert(session.is_playing() == false)
for code, count in pairs(warning_counts) do
  assert(count == 1, "each warning code fires at most once: " .. code)
end
```

### 等价示例：播放已编排好的计划

`ccnbs.plan` 与 `ccnbs.play` 分离的意义，是让调用方**编排一次、播放一个计划**。
播放计划时把与之匹配的分析经 `opts.analysis` 传入即可；行为与播放歌曲完全一致。
下面的示例同样演示「编排一次、播放一个计划」的流程（同样请把 `my_song.nbs` 换成你自己
的歌曲文件）：

```lua
local ccnbs = require("ccnbslib")
local clock = require("player.clock")
local speaker = require("player.speaker")

-- 把 "my_song.nbs" 替换成你自己的歌曲文件
local file = io.open("my_song.nbs", "rb")
if file == nil then
  print("未找到 my_song.nbs，请替换成你自己的歌曲文件后再运行本示例。")
  return
end
local bytes = file:read("*a")
file:close()

local decoded = ccnbs.decode(bytes)
assert(decoded.ok, "decode failed")

local analysis = ccnbs.analyze(decoded.song)
local events = ccnbs.plan(decoded.song, analysis)

local left = speaker.mock("left")
local right = speaker.mock("right")
local vclock = clock.new_virtual(0)

-- 播放 PLAN（不是歌曲）：必须传 opts.analysis。
local session = ccnbs.play(events, {
  analysis = analysis,
  speakers = { left, right },
  clock = vclock,
})
clock.advance_to(vclock, 60000)

assert(session.is_playing() == false)
assert(#session.plan == #events)                 -- 计划被原样使用，未重新编排
assert(#left.calls + #right.calls > 0)
```

## 注意事项

- `ccnbs` 不打印任何内容；警告一律交给 `opts.on_warning`。
- 自定义乐器**从不**被播放：`play` 会跳过并上报一次 `"custom-instrument"`。
- 多扬声器同步在 CC:Tweaked 中是尽力而为；`ccnbs` 只保证分配确定性。
- v1 不支持跳转进度与循环播放。
