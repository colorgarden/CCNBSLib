# CCNBSLib

在 [CC:Tweaked](https://tweaked.cc/) 电脑上**解析 Note Block Studio `.nbs` 乐谱，
并可把它调度到 `speaker` 外设上播放**的 Lua 库。

**这是一个库，不是程序。** 仓库里没有界面——只有「字节 → 乐谱 → 分析 → 事件流 →
扬声器调用」这条流水线，一个最小的命令行播放器用来示范怎么用它，以及一个命令行
安装器用来把它装到电脑上。

> 版本：`1.0.0`　模块入口：`require("ccnbslib")`

---

## 快速开始

```lua
local ccnbs = require("ccnbslib")

-- 1. 读取字节（从哪来由你决定）
local handle = io.open("song.nbs", "rb")
local bytes = handle:read("*a")
handle:close()

-- 2. 解码。它从不抛错，失败以 {ok=false, error={code=...}} 返回。
local decoded = ccnbs.decode(bytes)
if not decoded.ok then
  print("解码失败：" .. decoded.error.code)
  return
end

-- 3. 分析 → 编排 → 播放
local song = decoded.song
local analysis = ccnbs.analyze(song)
local events = ccnbs.plan(song, analysis)

local session = ccnbs.play(song, {
  on_warning = function(code, args)
    print("WARN[" .. code .. "]")     -- 只给裸码，怎么显示由你决定
  end,
  on_progress = function(info)
    print(string.format("%d/%d", info.index, info.total))
  end,
})

-- play 立即返回，不阻塞；自己决定什么时候等
while session.is_playing() do
  os.sleep(0.1)
end
```

---

## 环境要求

| 用途 | 需要什么 |
|---|---|
| 解析（`decode` / `analyze` / `plan`） | **什么都不需要**。纯算术，不碰外设、不碰网络 |
| 播放（`play`） | 至少一个 `speaker` 外设，贴在电脑任意一侧 |
| 命令行播放器 `nbsplay` | 一个 speaker + **HTTP**（它要从 URL 取歌） |

两个平台的 HTTP 默认都是开启的：

- **CraftOS-PC 模拟器**：`<用户数据目录>/config/global.json` 里的 `http_enable`；
- **真实 CC:Tweaked 服务器**：`computercraft-server.toml` 里的 `http.enabled`。

改完配置需要重启游戏或电脑才生效。

---

## 安装

一条命令：

```
wget run https://raw.githubusercontent.com/colorgarden/CCNBSLib/main/install.lua
```

`wget` 是 CraftOS 自带的，它会取回安装器并直接执行，把库装到 `/lib/`。

之后可以 `wget run <地址> upgrade` 更新、`wget run <地址> remove` 卸载。
完整说明见 [`docs/CLI.md`](docs/CLI.md)。

> 连不上 GitHub 时，在地址前面加一个代理前缀，例如
> `https://gh.llkk.cc/`、`https://ghproxy.net/` 或 `https://ghfast.top/`：
>
> ```
> wget run https://gh.llkk.cc/https://raw.githubusercontent.com/colorgarden/CCNBSLib/main/install.lua
> ```
>
> 安装器本身也会在某个镜像不通时自动换下一个；`install mirror` 可以增删。

### 手动安装

不用安装器也行，把这 20 个文件按原目录结构复制到电脑的 `/lib/`：

```text
/lib/ccnbslib.lua         （库入口）
/lib/nbsplay.lua          （命令行播放器，可选）
/lib/nbs/*.lua            （10 个解码/分析模块）
/lib/player/*.lua         （8 个调度/播放模块）
```

共 20 个文件，约 237 KB（源码未压缩）。

### `require` 是怎么解析的（重要）

CC:Tweaked 的 `require` **没有**固定的 `/lib` 搜索根。`package.path` 是
`?;?.lua;?/init.lua;/rom/modules/main/?;...`，其中 `?` 会**相对于「正在运行的程序
所在目录」**解析。

所以 `/lib/` 之所以可用，是因为**整棵库都在 `/lib` 下，且你运行的程序也在
`/lib` 下**。若你在别处写脚本，需要显式加路径：

```lua
package.path = "/lib/?.lua;/lib/?/init.lua;" .. package.path
local ccnbs = require("ccnbslib")
```

---

## 命令行播放器

`nbsplay.lua` 是最小示范：**一个直链 → 一首歌 → 一条进度条**。没有播放列表、
不扫描本地文件、不搜索。

```text
nbsplay https://example.com/song.nbs
```

它分两个阶段显示进度，且**永久行与实时行在屏幕上分开**：

- **永久行**：每条都以 `nbsplay:` 开头，写完就换行、留在屏幕上；
- **实时行**：最下面**三行**，原地刷新，不会一帧一行地往下滚。

```text
nbsplay: fetching https://example.com/song.nbs
nbsplay: decoding
nbsplay: "Creeper Chase"  842 notes  1:23  2 speakers
nbsplay: done
```

上面四条是永久行。播放期间屏幕最后三行是这样的：

```text
playing  50%  0:41/1:23  note 421/842
[#########################------------------------]
[Pause]
```

倒数第三行是**信息行**（百分比、时间、音符计数）；倒数第二行是**进度条**，它**独占一整行**，
上面没有别的东西；最下面一行开头是**暂停按钮**——播放时显示 `[Pause]`，暂停后变成
`[Resume]`。下载与解码阶段最后一行是空的，那时没有东西可暂停。

### 点击或拖动进度条跳转

**在进度条那一行点一下、或者按住拖动，就跳到那个位置。** 因为进度条铺满整行，所以点的
列号直接对应进度：点最左边是回到开头，点最右边是跳到结尾。

```
[#########################------------------------]
                    ↑
                拖到这里 -> 关于 44% 处
```

拖动是**实时**的：每移动一格都会立刻跳过去，不是松手之后才跳。

### 暂停与恢复

**点一下进度条底下那行开头的 `[Pause]`，歌就停在当前位置**；按钮变成 `[Resume]`，再点一下
从那里继续。

- 暂停**不重建播放会话**：整首歌的扬声器分配只算一次，所以大歌上按下暂停也是立刻生效的。
- 暂停期间进度条**照样能点**：位置会跟着动，但**不出声**，直到按下 `[Resume]` 才从新位置
  接着播。
- 按钮只认它自己占的那几列；同一行右边的空白处点了没反应。

需要**高级电脑**（`mouse_click` 与 `mouse_drag` 事件只在高级电脑、命令电脑、高级海龟与
高级掌上电脑上投递；普通电脑永远收不到鼠标事件——那台机器上进度条与按钮照常显示，只是
点不动）。

失败一律是同样的前缀加一个**裸错误码**，进程非零退出：

```text
nbsplay: E_DECODE: E_TRUNCATED
```

下载阶段按 8 KiB 分块读取，所以百分比是**真实的字节进度**而不是干等；
播放阶段从库给出的 `t_ms` 计算，因此节拍不均匀的歌也不会让进度条乱跳。

---

## 公共 API

| 调用 | 返回 |
|---|---|
| `ccnbslib.decode(bytes)` | `{ok=true, song=...}` 或 `{ok=false, error={code=, msg=}}`。**从不抛错** |
| `ccnbslib.analyze(song)` | 总音符数、峰值并发、所需扬声器数、是否超出原生音域等 |
| `ccnbslib.plan(song, analysis)` | 事件数组，按冻结全序 `(tick, layer, note)` 排列 |
| `ccnbslib.play(song\|plan, opts)` | 会话对象；立即返回，不阻塞 |
| `ccnbslib.discover_speakers()` | 已挂载扬声器记录数组（按 side 升序） |
| `ccnbslib.cp1252` | CP1252 → UTF-8 显示转换，把曲名/图层名显示给人看 |
| `ccnbslib.runtime` | 安全停掉扬声器，以及一个现成的程序框架（库不拥有事件循环，由你决定） |
| `ccnbslib.version` | `"1.0.0"` |

`decode` / `analyze` / `plan` 是**原样转发**，返回值与直接调用底层模块逐字段一致。

### 会话对象

| 成员 | 说明 |
|---|---|
| `session.cancel()` | 停止播放；幂等。会补发被推迟的 `custom-instrument` 警告 |
| `session.is_playing()` | 还有事件未播完且未被取消时为 `true` |
| `session.stats()` | 调度统计，原样透传 |
| `session.analysis` / `.plan` / `.assignment` | 本次播放用的分析、事件与分配结果 |

### `play` 的接缝（全部可选）

生产环境什么都不传，用真实外设与真实时钟；测试注入即可完全确定：

| 选项 | 默认 | 说明 |
|---|---|---|
| `opts.analysis` | — | **传计划（事件数组）时必填**，否则抛 `E_PLAN_REQUIRES_ANALYSIS` |
| `opts.speakers` | `discover_speakers()` | 扬声器记录数组 |
| `opts.clock` | `player.clock.new_os()` | 时钟（测试可注入虚拟时钟，瞬间播完） |
| `opts.on_warning` | — | `function(code, args)`，**每个不同的码至多一次** |
| `opts.on_event` | — | `function(event)`，每个到期事件在派发**之前**调用 |
| `opts.on_progress` | — | `function(info)`，`info = { t_ms, index, total }` |

---

## 警告码

库**只交裸码**，不管显示——怎么呈现由调用方决定。每个码在一首歌里至多出现一次。

| 码 | 触发时机 | `args` |
|---|---|---|
| `extended-range` | 播放开始时（加载期属性） | `{min_key, max_key}` |
| `speakers` | 播放开始时（由扇出分配决定） | `{peak, required, found, dropped}` |
| `custom-instrument` | 播放结束或取消时汇总 | `{count}` |
| `play-sound-pitch` | 播放到对应音符时 | `{}` |
| `tempo-clamp` | 歌曲自身节拍细于 50 ms 计时粒度时 | `{}` |

---

## 关于 CP1252

NBS **v0–v5 把每个字符串存成一字节一个字符的 CP1252**，不是 UTF-8。读取器把这些
字节**原样保留**——自定义乐器的音效文件路径依赖这份保真度。

所以「把曲名显示给人看」是**一个单独的、显式的步骤**：

```lua
local shown = ccnbs.cp1252.to_display(song.header.name)
```

`ccnbslib.cp1252` 是**唯一**允许做这个转换的地方。它**从不修改输入**，只返回一个
新的显示字符串；五个 CP1252 未定义字节映射到 `U+FFFD`。

---

## 明确不做的事

- **不打包、不做音频采样解码。** 没有 DFPWM / PCM。声音由 Minecraft 自己合成，
  这个库只负责在正确的时刻敲下正确的音符。
- **不播放自定义乐器。** `.nbs` 内自带的自定义乐器会被拒绝并跳过（有警告码）。
- **支持点击进度条跳转与暂停按钮，但不支持循环播放。** 播放期间点进度条那一行就跳到该
  点位置，点进度条底下那行的 `[Pause]` 就地暂停、`[Resume]` 继续；循环播放尚未实现。
- **不访问网络。** `require("ccnbslib")` 不碰网络；只有命令行播放器 `nbsplay`
  会去下载你给的那个直链。
- **没有界面。** 这是库。

---

## 平台差异

[`docs/COMPAT.md`](docs/COMPAT.md) 列出与真实游戏不同的平台行为，影响最大的一条是
扬声器音高：

> **CraftOS-PC 模拟器对 `playNote` 的音高只接受 0..24，越界直接报错；真实
> CC:Tweaked 不校验音高。** 这是「模拟器比游戏更严」的单侧差异。

因此本库**刻意不夹取音高**：超出原生范围的音符**原样**送进扬声器，最终音色取决于
客户端安装的扩展音域材质包。模拟器上跑越界音高的歌会报错——那是模拟器的限制，
不是库的缺陷。

---

## 文档

| 文件 | 用途 |
|---|---|
| [`docs/CLI.md`](docs/CLI.md) | 安装器用法：命令、镜像、出错码、更新与卸载 |
| [`docs/API.md`](docs/API.md) | 公共 API 参考：接缝注入、返回值形状、错误码 |
| [`docs/COMPAT.md`](docs/COMPAT.md) | 平台差异：音高、每 tick 音符数、定时粒度 |

---

## 许可证

以 **MIT 许可证**发布，完整条款见 [`LICENSE`](LICENSE)。
第三方组件及其归属见 [`NOTICE`](NOTICE)。

本库的全部实现均为从零编写，**不含任何第三方代码**。

> 早期版本曾以 GPL-2.0 发布。改为 MIT 只会更宽松、不会更严格，
> 因此那些副本已经获得的权利不受影响。
