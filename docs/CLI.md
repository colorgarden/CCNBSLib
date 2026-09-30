# 安装器

`install.lua` 是一个命令行安装器，用来把 CCNBSLib 装到电脑上、更新它、卸载它。

它需要 **HTTP** 才能下载文件（见 [环境要求](../README.md#环境要求)），界面只有命令行。

---

## 安装：一条命令

在电脑上敲：

```
wget run https://gh.llkk.cc/https://raw.githubusercontent.com/colorgarden/CCNBSLib/main/install.lua
```

`wget` 是 CraftOS 自带的，它会取回安装器并直接执行，把库装到 `/lib/`，全程显示进度。

装完就能用了：

```lua
local ccnbs = require("ccnbslib")
```

> 连不上 GitHub 时，地址里的 `https://gh.llkk.cc/` 是代理前缀。换成
> `https://ghproxy.net/` 或 `https://ghfast.top/`，或者（能直连的话）整个去掉。

### 如果 wget 不可用

先存成文件，再运行：

```lua
local r = http.get("https://gh.llkk.cc/https://raw.githubusercontent.com/colorgarden/CCNBSLib/main/install.lua")
local f = fs.open("install.lua", "w")
f.write(r.readAll())
f.close()
```

```
install.lua install
```

---

## 命令

```
install install              下载并安装全部文件
install update               只刷新文件清单，不装
install upgrade              只重新下载有变化的文件
install verify               检查已装文件是否与清单一致
install remove               删除已装文件
install remove --purge       删除已装文件，并清除镜像设置
install list                 显示已装了什么
install mirror list          显示镜像列表
install mirror add <名> <前缀>   添加镜像
install mirror remove <名>      删除镜像
install mirror default <名>     把某个镜像设为优先
install mirror test [名]        测试镜像是否可用
install help                 显示用法
```

选项：

| 选项 | 作用 |
|---|---|
| `--mirror <名>` | 优先用某个镜像（失败时仍会换下一个） |
| `--debug` | 打印每一步用了哪个镜像 |

用 `wget run` 时，命令写在地址后面：

```
wget run <地址> upgrade
```

不写命令就是 `install`。

---

## 镜像

文件从 GitHub 取。如果你的网络连不上 GitHub，就走**代理**。默认镜像按顺序尝试，
前一个失败自动换下一个：

```
*  gh.llkk.cc     https://gh.llkk.cc/
   ghproxy.net    https://ghproxy.net/
   ghfast.top     https://ghfast.top/
   direct         （直连 GitHub，不带代理）
```

带 `*` 的是当前优先项。用 `install mirror default <名>` 改。

加自己的镜像：

```
install mirror add mine https://mine.example/
```

前缀必须是 `http://` 或 `https://` 开头；它会被拼在完整下载地址前面。

> 镜像设置存在 `/lib/ccnbs-install/sources.txt`，`install remove` **不会**删它——
> 它是你的设置，不是包的一部分。要连它一起清掉用 `remove --purge`。

---

## 文件装在哪

```
/lib/ccnbslib.lua          库入口
/lib/nbsplay.lua           命令行播放器
/lib/nbs/*.lua             解析模块
/lib/player/*.lua          调度与播放模块
/lib/ccnbs-install/        安装器自己的状态（镜像列表、已装记录）
```

`install remove` 只删前两类里的库文件，保留 `/lib/ccnbs-install/` 里的镜像设置。

---

## 出错了怎么办

失败一律以 `install: E_<码>: <说明>` 的形式打印，退出码非零。

| 码 | 什么意思 | 怎么办 |
|---|---|---|
| `E_USAGE` | 命令或选项写错了 | 看 `install help` |
| `E_NO_HTTP` | 这台电脑没有 HTTP | 开启 HTTP 后重启（见 [环境要求](../README.md#环境要求)） |
| `E_MIRROR` | 所有镜像都连不上 | `install mirror test` 看哪个能用；或 `install mirror add` 加一个 |
| `E_MANIFEST` | 文件清单取不到或格式不对 | 换个镜像试试；`install mirror test` |
| `E_DOWNLOAD` | 某个文件多次尝试都没下下来 | 换镜像重试；网络不稳时多试几次 |
| `E_SIZE` | 下载到的字节数与清单不符（通常是被截断） | 重试；换个镜像 |
| `E_WRITE` | 写盘失败 | 磁盘满或只读。腾出空间后重试 |
| `E_VERIFY` | 有已装文件与清单不一致 | `install install` 重装一次 |
| `E_MISSING` | 要卸载或校验的东西没装 | 先 `install install` |

想看某一步到底走了哪个镜像，加 `--debug`。

---

## 更新

```
install update      # 只刷新清单，看看有什么变化
install upgrade     # 把有变化的文件换掉
```

`upgrade` 只重新下载**大小有变化**的文件，已经是当前版本的文件不会重复下载。

---

## 手动安装

不想用安装器也可以，把这 20 个文件按原目录结构复制到 `/lib/`：

```text
/lib/ccnbslib.lua
/lib/nbsplay.lua
/lib/nbs/*.lua
/lib/player/*.lua
```

共 20 个文件，约 237 KB（源码未压缩）。
