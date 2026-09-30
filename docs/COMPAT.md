# 兼容性分析：speaker 音高（pitch）越界行为

> 任务：task-31。本文档只做**记录与分析**，不含任何生产代码改动。
> 结论以「CraftOS-PC 实测输出」与「上游源码原文引用（含 commit SHA / URL / 行号）」为准；
> 无法核实的项一律标注 **UNVERIFIED**，不把承接自早期桌面调研的说法当既成事实。
>
> 日期：2026-09-25
> 被测环境：`D:\tools\CraftOS-PC\CraftOS-PC_console.exe`（`version.txt` 写作 `v2.8`；安装目录内含
> `debug.bundled-v2.8.3` / `rom.bundled-v2.8.3-portablezip`，故运行时 bundle 为 **2.8.3**，
> ROM 自报 `CraftOS 1.9`）。
> 探针：一个本地新增的音高扫描脚本（未改动任何既有文件）。

---

## 0. 摘要（先看结论）

| 问题 | 判定 | 依据 |
|---|---|---|
| A. 真实 CC:Tweaked `speaker.playNote` 越界音高 | **原样透传（pass-through）**，仅做「有限性」检查；不夹取、不拒绝。文档范围 0..24，**代码不强制**；非整数接受 | `SpeakerPeripheral.java` @ `mc-1.20.x` `7c60ed10…` |
| A. `speaker.playSound` 第 3 参数（速度比） | **原样透传**（仅有限性检查）；第 2 参数 volume 被夹取到 `[0,3]` | 同上 |
| B. 同一游戏 tick 内 `playNote` + `playSound` 能否都生效 | **现代 CC:T：能共存**（≤8 音符 + 1 声音，同一 `update()` 排空）。**CraftOS-PC：不能**（互斥）。legacy CC:T（1.12.2）：能共存，但仅「先声音后音符」 | `SpeakerPeripheral.java` 的 `update()`；`craftos2/src/peripheral/speaker.cpp` |
| C. CCPC 的 `invalid pitch` 是 ROM 策略还是忠实模拟 | **两者都不是**。它是 **CraftOS-PC 原生 C++ 的更严格策略**（比真实 CC:T 更严）：CC:T 上游根本没有该检查 | `craftos2/src/peripheral/speaker.cpp` L505-512；两仓库 ROM 全树无 `pitch` 校验 |
| D. CCPC 实测 `playNote` 音高范围 | **0..24（含）接受；`<0` 或 `>24` 抛错**（`invalid pitch N`），**不是**返回 false；非整数按截断取整 | 本文 §5 探针原始输出 |
| D. CCPC 实测 `playSound` 速度比范围 | **[0.0, 2.0]（含）**；越界抛 `invalid speed %f`（注意：**不是**项目假设的 0.5 下界） | 本文 §5 探针原始输出 |
| E. `simple.nbs` 爆炸半径 | 49 音里 5 个越界（key 27/29/32，pitch -6/-4/-1，全在低端，首个在 t=3200ms/tick 32）。CCPC：首越界处抛错；`ccnbs.play` **静默丢弃**；模拟器侧的录制校验 **判 fail**。真实 CC:T：原样透传，音符照常发声（音色取决于材质包） | §7 |

**最重要的一条**：项目「越界音高原样透传、提示安装扩展音域材质包」的**产品承诺在真实 CC:Tweaked 上成立**（源码证明 pass-through）；**只有 CraftOS-PC 模拟器会拒绝**——因此这是「模拟器比游戏更严」的**模拟器侧分歧**，不是项目理解错误。

> 订正：早期桌面调研声称「CC:T 不夹取」是对的，本次已用**源码原文 + SHA**独立复核确认；但它同时声称
> 「CraftOS-PC 也接受越界音高」——**该半句被实测证伪**（CCPC 抛错）。两半句必须拆开看。

---

## 1. 平台与版本

| 平台 | 标识 | 角色 |
|---|---|---|
| 真实 CC:Tweaked（Minecraft 模组） | 分支 `mc-1.20.x` @ `7c60ed109fdc27cca04b7b59a84c08e257c1b0bf`；另核 `mc-1.21.x` @ `e458382f…`、`mc-1.21.y` @ `f31d0b20…`、`mc-26.1` @ `06abd03e…`、`master`（=legacy 1.12.2）@ `1da86d6f…` | 生产目标 |
| CraftOS-PC（模拟器） | console 2.8.3（`version.txt`=`v2.8`，bundle 2.8.3，ROM `CraftOS 1.9`）；原生实现 `craftos2` @ `2844cba6184e7e2590910d6c2c33697b9b5ff9fd` | Tier-2 测试环境 |
| CraftOS-PC ROM | `craftos2-rom` @ `e6f63a1b168a4e37c5b06b090003219085f638cf` | 模拟器的 Lua ROM |

---

## 2. 问题 A：真实 CC:Tweaked `playNote` 的越界音高行为

### 2.1 判定：**原样透传（PASS-THROUGH），仅做有限性检查**

- **是否校验？** 校验，但**只校验是否为有限数**（拒绝 `NaN` / `±Inf`），**不校验范围**。
- **接受范围？** **任意有限 double**。文档（javadoc）写 0..24，但**代码不强制**。
- **非整数？** **接受**（值作为 `double` 流入 `Math.pow`）。
- **校验位置？** `SpeakerPeripheral.playNote` 自身调用 `LuaValues.checkFinite`（**不在** `ArgumentHelpers`；
  `ArgumentHelpers` 在 `mc-1.20.x` 里只剩 `getRegistryEntry`）。

**决定性源码**：`projects/common/src/main/java/dan200/computercraft/shared/peripheral/speaker/SpeakerPeripheral.java`
@ `7c60ed109fdc27cca04b7b59a84c08e257c1b0bf`，
[blob L211-232](https://github.com/cc-tweaked/CC-Tweaked/blob/7c60ed109fdc27cca04b7b59a84c08e257c1b0bf/projects/common/src/main/java/dan200/computercraft/shared/peripheral/speaker/SpeakerPeripheral.java#L211-L232) ·
[raw](https://raw.githubusercontent.com/cc-tweaked/CC-Tweaked/7c60ed109fdc27cca04b7b59a84c08e257c1b0bf/projects/common/src/main/java/dan200/computercraft/shared/peripheral/speaker/SpeakerPeripheral.java)：

```java
211:    @LuaFunction
212:    public final boolean playNote(ILuaContext context, String instrumentA, Optional<Double> volumeA, Optional<Double> pitchA) throws LuaException {
213:        var volume = (float) clampVolume(checkFinite(1, volumeA.orElse(1.0)));
214:        var pitch = (float) checkFinite(2, pitchA.orElse(1.0));
...
224:        // Check if the note exists
225:        if (instrument == null) throw new LuaException("Invalid instrument, \"" + instrument + "\"!");
226:
227:        synchronized (pendingNotes) {
228:            if (pendingNotes.size() >= Config.maxNotesPerTick) return false;
229:            pendingNotes.add(new PendingSound<>(instrument.getSoundEvent(), volume, (float) Math.pow(2.0, (pitch - 12.0) / 12.0)));
230:        }
231:        return true;
232:    }
```

关键点：
- 第 214 行**只有 `checkFinite`**；第 229 行 `pitch` 被**原样**代入 `Math.pow(2.0, (pitch - 12.0) / 12.0)`。
  **没有 `Mth.clamp`、没有 `<`/`>` 范围判断、没有拒绝。** `pitch = 25`、`-13`、`100.5` 只要有限就接受。
- 唯一会抛的两处：非有限数（`checkFinite`）、乐器名不存在（第 225 行）。
- 接受范围 = **任意有限 double**；文档范围见 javadoc 第 208 行（“from 0 to 24”），但**不是代码约束**。

**有限性检查本体**：`projects/core-api/src/main/java/dan200/computercraft/api/lua/LuaValues.java` @ 同 SHA，
[blob L136-139](https://github.com/cc-tweaked/CC-Tweaked/blob/7c60ed109fdc27cca04b7b59a84c08e257c1b0bf/projects/core-api/src/main/java/dan200/computercraft/api/lua/LuaValues.java#L136-L139)：

```java
136:    public static double checkFinite(int index, double value) throws LuaException {
137:        if (!Double.isFinite(value)) throw badArgument(index, "number", getNumericType(value));
138:        return value;
139:    }
```

### 2.2 `playSound`：第 3 参数（速度）同样透传；volume 被夹取

同文件 [blob L256-276](https://github.com/cc-tweaked/CC-Tweaked/blob/7c60ed109fdc27cca04b7b59a84c08e257c1b0bf/projects/common/src/main/java/dan200/computercraft/shared/peripheral/speaker/SpeakerPeripheral.java#L256-L276)：

```java
257:    public final boolean playSound(ILuaContext context, String name, Optional<Double> volumeA, Optional<Double> pitchA) throws LuaException {
258:        var volume = (float) clampVolume(checkFinite(1, volumeA.orElse(1.0)));
259:        var pitch = (float) checkFinite(2, pitchA.orElse(1.0));
...
271:            if (pendingSound != null || (dfpwmState != null && dfpwmState.isPlaying())) return false;
272:            dfpwmState = null;
273:            pendingSound = new PendingSound<>(identifier, volume, pitch);
274:            return true;
275:    }
```

```java
370:    static double clampVolume(double volume) {
371:        return Mth.clamp(volume, 0, 3);
372:    }
```

- `playSound` 第 3 参数（速度比）：**透传**（文档 0.5..2.0，**不强制**）。
- `playSound` / `playNote` 的 **volume 被夹取到 [0,3]**（`Math.pow` 同级的 `clampVolume`）。

### 2.3 跨分支

- `mc-1.20.x` / `mc-1.21.x` / `mc-1.21.y` / `mc-26.1`：**语义一致**，均为 `pitch = (float) checkFinite(2, …)`，无范围检查。
- `master`（实为 **legacy 1.12.2**，`gradle.properties`：`mod_version=1.89.2`、`mc_version=1.12.2`）同样仅 `optFiniteDouble`；
  差异：legacy 的 volume **只夹上界**（`Math.min(volume, 3.0f)`），modern 夹两侧。

**结论 A：没有任何 CC:T 分支对 `playNote` / `playSound` 的音高做范围校验、夹取或拒绝。项目「不夹取」的产品决定在真实 CC:T 上成立。**

---

## 3. 问题 B：同一游戏 tick 内 `playNote` 与 `playSound` 能否共存

| 平台 | 结论 | 依据 |
|---|---|---|
| 现代 CC:T（mc-1.20.x / 1.21.x） | **能共存**：同一 tick 内最多 8 个 `playNote` + 1 个 `playSound`，在同一 `update()` 内一起排空 | 见下 |
| legacy CC:T（1.12.2，即上游 `master`） | **能共存，但有次序**：仅「先 sound 后 note」可以；同一 tick 内「先 note 后 sound」被拒 | `SpeakerPeripheral.java` 1.12.2 L122-130（`isNote` 逃逸条件） |
| **CraftOS-PC 2.8.3（原生）** | **不能共存（互斥）**：一个 tick 内做过音符号后，`playSound` 拒绝；做过 `playSound` 后，后续 `playNote` 全拒绝 | `speaker.cpp` L505-521 / L672-691；本文 §5 实测 |

现代 CC:T 证据（同 SHA）：

- `pendingNotes` 队列（上限 `Config.maxNotesPerTick = 8`）在 `update()` 中排空，[L95-104](https://github.com/cc-tweaked/CC-Tweaked/blob/7c60ed109fdc27cca04b7b59a84c08e257c1b0bf/projects/common/src/main/java/dan200/computercraft/shared/peripheral/speaker/SpeakerPeripheral.java#L95-L104)；
- `pendingSound` **单槽**，在**同一个** `update()` 中紧随其后排空，[L112-140](https://github.com/cc-tweaked/CC-Tweaked/blob/7c60ed109fdc27cca04b7b59a84c08e257c1b0bf/projects/common/src/main/java/dan200/computercraft/shared/peripheral/speaker/SpeakerPeripheral.java#L112-L140)；
- 二者用**不同的锁**（`pendingNotes` 对 `lock`），因此一个 tick 内可同时各放各的。

**对本项目的影响（次要分歧）**：`nbs/speakers.lua` 的加法公式
`required = ceil(vanilla_at_peak / 8) + play_sound_at_peak`（其注释断言「一个 speaker 同一游戏 tick 内不能既发
playSound 又发别的声音」）**对 CraftOS-PC 正确，对现代 CC:T 偏保守**（现代 CC:T 里 note+sound 可共存，
所以 `(vanilla=1, play_sound=1)` 在真实游戏里其实只需 1 个 speaker，公式却报 2）。偏保守是**安全方向**
（多估不丢音），只会在真实 CC:T 上产生「要求数量偏高」的提示。**本任务不改生产代码**，仅记录此分歧。

---

## 4. 问题 C：CraftOS-PC 的拒绝是「ROM 策略」还是「忠实模拟」

### 4.1 判定：**两者都不是** —— 它是 CraftOS-PC **原生 C++** 的、比真实 CC:T 更严的自有策略

- **不是 ROM 策略**：`peripheral.lua`（无论 CC:T 还是 craftos2-rom）**全树都没有任何 `pitch` 校验**。
- **不是忠实模拟**：真实 CC:T 上游**根本没有这个检查**（见 §2），所以谈不上「模拟」。

### 4.2 证据一：两仓库 ROM 都没有 pitch 校验

- CC:T `mc-1.20.x` 的 `projects/core/src/main/resources/data/computercraft/lua/rom/apis/peripheral.lua`（346 行）：
  **零次出现 `pitch`**。
  [raw](https://raw.githubusercontent.com/cc-tweaked/CC-Tweaked/7c60ed109fdc27cca04b7b59a84c08e257c1b0bf/projects/core/src/main/resources/data/computercraft/lua/rom/apis/peripheral.lua)
- craftos2-rom `rom/apis/peripheral.lua` @ `e6f63a1b…`：**零次出现 `pitch`**。
  [raw](https://raw.githubusercontent.com/MCJack123/craftos2-rom/e6f63a1b168a4e37c5b06b090003219085f638cf/rom/apis/peripheral.lua)
- 全树里唯一的 Lua 侧 pitch 检查在 `rom/programs/fun/speaker.lua`（命令行 `speaker` 小程序，且是给
  `playSound` 用的，不是 `playNote`）：

```lua
153:    if pitch then
154:        pitch = tonumber(pitch)
155:        if not pitch then
156:            error("Pitch must be a number", 0)
157:        end
158:        if pitch < 0 or pitch > 2 then
159:            error("Pitch must be between 0 and 2", 0)
```

### 4.3 证据二：`invalid pitch` 字符串在 CCPC 原生 C++ 里

`craftos2/src/peripheral/speaker.cpp` @ `2844cba6184e7e2590910d6c2c33697b9b5ff9fd`，
[blob L505-521](https://github.com/MCJack123/craftos2/blob/2844cba6184e7e2590910d6c2c33697b9b5ff9fd/src/peripheral/speaker.cpp#L505-L521)：

```cpp
505:int speaker::playNote(lua_State *L) {
506:    lastCFunction = __func__;
507:    const std::string inst = luaL_checkstring(L, 1);
508:    const float volume = (float)luaL_optnumber(L, 2, 1.0);
509:    const int pitch = (int)luaL_optnumber(L, 3, 1.0);
510:    if (volume < 0.0f || volume > 3.0f) luaL_error(L, "invalid volume %f", volume);
511:    if (pitch < 0 || pitch > 24) luaL_error(L, "invalid pitch %d", pitch);
512:    if (speaker_sounds.find(inst) == speaker_sounds.end()) luaL_error(L, "invalid instrument %s", inst.c_str());
```

同文件 `playSound`，[blob L672-691](https://github.com/MCJack123/craftos2/blob/2844cba6184e7e2590910d6c2c33697b9b5ff9fd/src/peripheral/speaker.cpp#L672-L691)：

```cpp
672:int speaker::playSound(lua_State *L) {
...
679:    const float volume = (float)luaL_optnumber(L, 2, 1.0);
680:    const float speed = (float)luaL_optnumber(L, 3, 1.0);
681:    if (volume < 0.0f || volume > 3.0f) luaL_error(L, "invalid volume %f", volume);
682:    if (speed < 0.0f || speed > 2.0f) luaL_error(L, "invalid speed %f", speed);
...
687:    if (noteCount != 0) {
688:        lua_pushboolean(L, false);
689:        return 1;
690:    }
691:    noteCount = UINT_MAX;
```

**这也解释了三处实测现象**：
1. `playNote` 音高越界**抛错**（第 511 行 `luaL_error`），而不是返回 false；
2. 非整数被 `(int)` **截断**（第 509 行 cast）；
3. `playSound` 越界抛的是 **`invalid speed`**（不是 `invalid pitch`），且范围是 **[0,2]**（第 682 行）。

### 4.4 证据三：`/rom/apis/peripheral.lua:257` 是**调用点**，不是校验位置

实测报错文本形如 `/rom/apis/peripheral.lua:257: invalid pitch -1`。本机 ROM 的该行是：

```lua
253: function call(name, method, ...)
254:     expect(1, name, "string")
255:     expect(2, method, "string")
256:     if native.isPresent(name) then
257:         return native.call(name, method, ...)
258:     end
```

`native.call` 是 C++ 边界；C++ 用 `luaL_error` 抛错时，Lua 会附上**调用方**的源码位置，于是错误前缀显示
`peripheral.lua:257`。旁证：探针里用**冒号**调用 `obj:playNote(...)` 得到
`/rom/apis/peripheral.lua:257: bad argument #1 (expected string, got peripheral)` —— 同一个第 257 行调用点。
因此报错里的 `peripheral.lua:257` **不是**校验逻辑所在。

> 该字符串也确实**编译进了 exe**：对本机 `CraftOS-PC_console.exe` 做二进制检索可读到
> `invalid volume %f` / `invalid pitch %d` / `invalid instrument %s` / `invalid speed %f`。
> 两仓库 ROM 全树检索 `invalid pitch` 则**零命中**。

---

## 5. 问题 D：CraftOS-PC 2.8.3 实测（探针原始输出）

命令（宿主机，仓库根）：本地运行的音高扫描脚本，见本文 §10。
该脚本输出到 `<temp>\computer\0\result.txt`，退出码 0，末尾 `STATUS ok`。
以下为**逐字复制**的原始输出：

> 说明：下方 `PROBE methods=...` 一行列出了仿真扬声器**对外暴露的全部方法**（平台能力清单），
> 其中包含 `playAudio` 等音频缓冲接口。**本项目不使用这些接口**——CCNBSLib 属于
> 音符调度方案，只调用 `playNote` / `playSound`。此处保留原文仅为记录平台 API 表面。

```
== ENVIRONMENT ==
PROBE version=1 side=back
PROBE craftos_version=CraftOS 1.9
PROBE methods=listSounds,playAudio,playLocalMusic,playNote,playSound,setPosition,setSoundFont,stop,stopSounds
== A. CALL CONVENTION ==
CALL dot playNote => ok=true ret=true
CALL colon playNote => ok=false ret=/rom/apis/peripheral.lua:257: bad argument #1 (expected string, got peripheral)
== B. PER-TICK BUDGET ==
BUDGET unslept burst12 => true_count=8 pattern=ttttttttffff
BUDGET slept burst12 => true_count=12 pattern=tttttttttttt
BUDGET same_tick note_then_sound => note=true sound=false
BUDGET same_tick sound_then_note => sound=false note=false
== C. playNote PITCH SCAN (one probe per game tick) ==
SCAN pitch=-3 => RAISED /rom/apis/peripheral.lua:257: invalid pitch -3
SCAN pitch=-2 => RAISED /rom/apis/peripheral.lua:257: invalid pitch -2
SCAN pitch=-1 => RAISED /rom/apis/peripheral.lua:257: invalid pitch -1
SCAN pitch=0 => ok=true
SCAN pitch=1 => ok=true
SCAN pitch=2 => ok=true
SCAN pitch=3 => ok=true
SCAN pitch=4 => ok=true
SCAN pitch=5 => ok=true
SCAN pitch=6 => ok=true
SCAN pitch=7 => ok=true
SCAN pitch=8 => ok=true
SCAN pitch=9 => ok=true
SCAN pitch=10 => ok=true
SCAN pitch=11 => ok=true
SCAN pitch=12 => ok=true
SCAN pitch=13 => ok=true
SCAN pitch=14 => ok=true
SCAN pitch=15 => ok=true
SCAN pitch=16 => ok=true
SCAN pitch=17 => ok=true
SCAN pitch=18 => ok=true
SCAN pitch=19 => ok=true
SCAN pitch=20 => ok=true
SCAN pitch=21 => ok=true
SCAN pitch=22 => ok=true
SCAN pitch=23 => ok=true
SCAN pitch=24 => ok=true
SCAN pitch=25 => RAISED /rom/apis/peripheral.lua:257: invalid pitch 25
SCAN pitch=26 => RAISED /rom/apis/peripheral.lua:257: invalid pitch 26
SCAN pitch=27 => RAISED /rom/apis/peripheral.lua:257: invalid pitch 27
SCAN summary accepted={0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24}
SCAN summary rejected_false={(none)}
SCAN summary raised={-3,-2,-1,25,26,27}
== D. playNote NON-INTEGER PITCH ==
NOTE pitch=12.500000 => ok=true ret=true
NOTE pitch=0.500000 => ok=true ret=true
NOTE pitch=-0.500000 => ok=true ret=true
NOTE pitch=-0.400000 => ok=true ret=true
NOTE pitch=-0.900000 => ok=true ret=true
NOTE pitch=24.500000 => ok=true ret=true
NOTE pitch=24.600000 => ok=true ret=true
NOTE pitch=24.900000 => ok=true ret=true
NOTE pitch=25 => ok=false raised=/rom/apis/peripheral.lua:257: invalid pitch 25
== E. playNote VOLUME (pitch 12) ==
NOTE volume=-0.100000 => ok=false raised=/rom/apis/peripheral.lua:257: invalid volume -0.10000000149012
NOTE volume=0 => ok=true ret=true
NOTE volume=1.500000 => ok=true ret=true
NOTE volume=3 => ok=true ret=true
NOTE volume=3.100000 => ok=false raised=/rom/apis/peripheral.lua:257: invalid volume 3.0999999046326
== F. playNote INSTRUMENT NAME ==
NOTE name=notreal => ok=false raised=/rom/apis/peripheral.lua:257: invalid instrument notreal
NOTE name=bass => ok=true ret=true
== G. playSound NAME + RATIO ==
SOUND listSounds => ok=true count=0
SOUND chosen_name=minecraft:block.note_block.harp source=candidate
SOUND ratio=0.400000 => ok=true ret=false
SOUND ratio=0.500000 => ok=true ret=false
SOUND ratio=1 => ok=true ret=false
SOUND ratio=1.999000 => ok=true ret=false
SOUND ratio=2 => ok=true ret=false
SOUND ratio=2.001000 => ok=false raised=/rom/apis/peripheral.lua:257: invalid speed 2.0009999275208
SOUND ratio=2.100000 => ok=false raised=/rom/apis/peripheral.lua:257: invalid speed 2.0999999046326
SOUND ratio=0.010000 => ok=true ret=false
SOUND ratio=0 => ok=true ret=false
SOUND ratio=-0.010000 => ok=false raised=/rom/apis/peripheral.lua:257: invalid speed -0.0099999997764826
SOUND ratio=-0.500000 => ok=false raised=/rom/apis/peripheral.lua:257: invalid speed -0.5
SOUND ratio=-1 => ok=false raised=/rom/apis/peripheral.lua:257: invalid speed -1
== H. SAME-TICK NOTE vs SOUND (3 trials each) ==
COEXIST trial=1 order=note_then_sound note=true sound=false
COEXIST trial=1 order=sound_then_note sound=false note=false
COEXIST trial=2 order=note_then_sound note=true sound=false
COEXIST trial=2 order=sound_then_note sound=false note=false
COEXIST trial=3 order=note_then_sound note=true sound=false
COEXIST trial=3 order=sound_then_note sound=false note=false
STATUS ok
```

### 5.1 实测结论

| 项 | CraftOS-PC 2.8.3 实测 |
|---|---|
| `playNote` 音高接受范围 | **0..24（含）**；`-3,-2,-1,25,26,27` 全部**抛错**，错误串 `invalid pitch N`；**没有任何一例返回 false** |
| 边界是否干净 | **是**：0 首个接受、24 末个接受、-1 与 25 首个拒绝 |
| 非整数音高 | **接受**；`-0.9` 与 `24.9` 都接受 ⇒ 转换是**向零截断**（若四舍五入，`-0.9→-1`、`24.9→25` 应被拒） |
| volume | **[0,3]**；`-0.1`、`3.1` 抛 `invalid volume %f` |
| 乐器名 | 只认内置集合；`notreal` 抛 `invalid instrument notreal`，`bass` 通过 |
| 每 tick 音符上限 | **8**：连发 12 个得 `ttttttttffff`；隔一个 game tick 再发 12 个得全 `t` ⇒ 预算按 50ms 重置 |
| `playSound` 速度比 | **[0,2]（含）**；`0,0.01,…,2.0` 接受，`2.001/2.1/-0.01/-0.5/-1` 抛 `invalid speed %f`。**注意下界是 0，不是项目假设的 0.5** |
| note 与 sound 同 tick | **互斥**：`sound_then_note` 三次全部 `note=false`（与 `speaker.cpp` 的 `noteCount = UINT_MAX` 一致） |
| `playSound` 是否真的发声 | 本环境 `listSounds` **count=0**（无音源库），故范围内 `playSound` 一律 `ret=false`（不抛错）。**因此「同 tick 两者是否都能出声」在本环境无法直接观测**，只能由源码（§3）判定 |

> `note_then_sound` 的 `sound=false` 是因为**无音源库**；`sound_then_note` 的 `note=false` 则是
> **互斥策略**（一个 `playSound` 尝试占满该 tick）。二者原因不同，勿混为一谈。

---

## 6. DIVERGENCE（分歧）章节

### 6.1 分歧总表

| 维度 | 真实 CC:Tweaked（mc-1.20.x…mc-26.1） | CraftOS-PC 2.8.3 | 谁更严 |
|---|---|---|---|
| `playNote` 音高越界 | **透传**（任意有限数） | **抛错** `invalid pitch`，范围 0..24 | **CCPC** |
| `playNote` 非整数音高 | 透传（float→pow 的 double 精度） | **(int) 截断** | CCPC（改变了值） |
| `playNote` volume 越界 | **夹取**到 [0,3] | **抛错** `invalid volume` | CCPC |
| `playSound` 速度越界 | **透传** | **抛错** `invalid speed`，范围 [0,2] | **CCPC** |
| `playSound` volume 越界 | **夹取**到 [0,3] | **抛错** | CCPC |
| note + sound 同 tick | **可共存** | **互斥** | CCPC |
| 拒绝方式 | 越界 volume 静默夹取；超 8 音符返回 false | 越界**抛错**；超预算返回 false | 语义不同 |

### 6.2 分歧的本质

- **音高越界**：CC:T「透传」，CCPC「拒绝」。这是**模拟器比游戏更严**。项目「不夹取」的决定**在真实游戏上正确**；
  受影响的是**只在 CCPC 上跑的人**（以及 Tier-2 测试）。
- **注**：项目 `player/mapping.lua` 注释「Minecraft 的音符盒音高接受越界值」经本次源码复核**成立**。
- **必须修正的既有说法**：早期本地 harness 文档与录制脚本头部把现象描述为「拒绝**负**音高」。
  实测是「**拒绝 0..24 之外的一切**」（负值 **和** >24 都拒）。当时这些文件不在可改范围，
  故仅在此记录为**待订正项**。

---

## 7. 问题 E：对本项目的爆炸半径（`simple.nbs` 为例）

### 7.1 相关代码事实（已阅读，未改动）

- `player/mapping.lua`
  - `pitch_semitones(key) = key - 33`，**刻意不夹取**（第 117-119 行）；`NATIVE_MIN_KEY=33`、`NATIVE_MAX_KEY=57`。
  - `play_sound_pitch(key) = clamp(2 ^ ((key-45)/12), 0.5, 2.0)`（第 134-137 行）。
    → 其 **0.5 下界比 CCPC 实际的 0 下界更保守**；即使不夹到 0.5 也不会被 CCPC 拒。
- `player/dispatch.lua`
  - `route_play_note` 把 `pitch` **原样**传给 `invoke`（第 206-213 行）。
  - `invoke` 用 `pcall(fn, record, args[1], args[2], args[3])` 包住调用（第 192 行）；
    **抛错被包含**，返回 `unusable(...)`：
    `{ called=false, method=nil, refused=false, error_message="dispatch: play_note raised: <msg>" }`。
    ⇒ `d:event` **永不向外抛**，但该结果**带 `error_message`、且既不算 called 也不算 refused**。
- `nbs/analyze.lua`
  - `has_extended_range` = 任一 `key < 33 or key > 57`（第 133-135 行）；同时给出 `min_key/max_key`。
- `player/fanout.lua`：`fanout.play` **不检查** `result.error_message`（第 330-339 行）；
  该事件既不计 `calls_made`、也不计 `refused`、也不计 `dropped` ⇒ **静默丢失**。
- `ccnbslib.lua`：`on_event` 里拿到 `dispatcher:event(...)` 后**只看 `warning_code`**，**不看 `error_message`**
  （第 197-205 行）⇒ 经 `ccnbs.play` 时越界音符**静默丢音、无任何运行期提示**；
  但 `has_extended_range` 会在播放**开始时**发一次 `"extended-range"` 警告（第 141-146 行）。
- 录制脚本（本地 harness）：`on_event` 里 `if result.error_message ~= nil then error(...)`（第 311-313 行）
  ⇒ harness **把抛错当致命**，整场 `STATUS fail`。

### 7.2 `simple.nbs` 具体数据（用项目自身模块算出）

```
decode.ok=true version=6 vanilla_count=20
notes=49 min_key=27 max_key=46 has_extended_range=true peak=3 tps=10 tick_ms=100
events=49 out_of_native_events=5 (play_note=5, play_sound=0) min_pitch=-6
OOR t_ms=3200 tick=32 layer=0 key=32 pitch=-1 kind=play_note name=harp ratio=0.5
OOR t_ms=3200 tick=32 layer=1 key=32 pitch=-1 kind=play_note name=bass ratio=0.5
OOR t_ms=4400 tick=44 layer=0 key=27 pitch=-6 kind=play_note name=harp ratio=0.5
OOR t_ms=4600 tick=46 layer=1 key=29 pitch=-4 kind=play_note name=bass ratio=0.5
OOR t_ms=4800 tick=48 layer=0 key=29 pitch=-4 kind=play_note name=harp ratio=0.5
distinct_out_pitches=-6x1,-4x2,-1x2
key_histogram=27x1,29x2,32x2,34x1,36x3,38x2,39x36,43x1,46x1
```

要点：49 个音符中 **5 个越界**（key 27/29/32 → pitch -6/-4/-1，**全部低于原生下界**，没有高端越界）；
首个越界在 **t=3200ms（tick 32）**；0..3100ms 的音符全在原生范围内。

### 7.3 逐平台后果

| 路径 | 今天在 CraftOS-PC 上会发生什么 |
|---|---|
| 裸 `speaker:playNote(...,-1)` | **抛错** `/rom/apis/peripheral.lua:257: invalid pitch -1` |
| 经 `player/dispatch` | 抛错被 `pcall` **包含**；返回 `error_message=...`、`called=false`、`refused=false`（不向外抛） |
| 经 `player/fanout.play` | 含 `error_message` 的结果被忽略 ⇒ 该音符**静默丢失**（不计 calls/refused/dropped） |
| 经 `ccnbs.play` | 同上**静默丢失**；只有开场的 `"extended-range"` 警告，无运行期报错 |
| 经模拟器侧的录制校验 | `on_event` 见 `error_message` 即 `error(...)` ⇒ 播放中止，`STATUS fail:... invalid pitch -1` |

| 路径 | 在**真实 CC:Tweaked** 上会发生什么（依 §2 判定） |
|---|---|
| 裸 `speaker.playNote("harp", v, -6)` | **接受**（有限数即可），以 `2^((-6-12)/12)` 的频率播放该音符音色 |
| 经 `ccnbs.play` | 音符**照常发声**；是否能听出「正确音高」取决于客户端材质包（见 §9 UNVERIFIED） |
| 「扩展音域材质包」承诺 | **成立**：服务器端不拒绝，客户端按材质包/音源表现 |

一句话：**`simple.nbs` 在模拟器上会丢掉（或让 harness 中止于）那 5 个低音；在真实游戏里则会照常发出**。

---

## 8. RECOMMENDATION（只给选项，不实现；由项目所有者决定）

> 前提：分歧是**模拟器单侧**的（真实 CC:T 透传）。因此「正确性」与「可测试性」是两件事，需分开权衡。

### 选项 1：保持不夹取，仅记录模拟器分歧（Tier-2 无法测扩展音域歌）
- **用户听到**：真实 CC:T 上完全符合承诺；CCPC 上经 `ccnbs.play` 时那些音符**静默消失**（无提示，除开场 `extended-range` 外）。
- **既有警告是否足够**：**是**（`extended-range` 已在开场提示），但对「在模拟器上静音丢失」**没有任何说明**。
- **要改的代码面**：`docs/`（本文档）+ 可选订正早期 harness 文档的措辞。**零生产代码**。
- **风险**：Tier-2 **永远无法回归测试扩展音域歌曲**；若有人把 CCPC 当预览器，会以为「歌坏了」。

### 选项 2：dispatch 兜底——越界抛错时改用可表示的音高重试（如八度折叠到 0..24），并告警
- **用户听到**：音符**能听见但音高被移调**（折叠到原生八度）；真实 CC:T 上**不会触发**（不抛错），故不影响游戏内表现。
- **既有警告是否足够**：不够，需**新增**一个警告码（如 `pitch-folded`/`emulator-pitch`），且只在真的折叠时发一次。
- **要改的代码面**：`player/dispatch.lua`（捕获 `error_message` 后重试）+ 新警告码 + `ccnbslib.lua` 的警告聚合 + 文档。
- **风险**：**改变了 Tier-2 录制**——同一事件的 `playNote` 参数会与 `plan` 不一致，破坏「plan vs 录制逐行比对」；
  且「模拟器上移调、真机不移调」本身就是新的分歧面。实现复杂度最高。

### 选项 3：跳过该音符并告警（安全降级）
- **用户听到**：音符**不发声**（与今天 `ccnbs.play` 的静默丢失**听觉上相同**），但会**明确告警**「某些音符超出扬声器可表示范围，已跳过」。
- **既有警告是否足够**：`extended-range` 说了「装材质包」，但**没说是模拟器限制**；建议把它细化为两个码或带 reason。
- **要改的代码面**：`player/dispatch.lua`（或 `ccnbslib.lua`）把 `error_message` 转成一个警告码；文档。
- **风险**：最低且**不改变真实 CC:T 行为**（真机不抛，永不触发）；但仍无法在 Tier-2 断言「这些音符被播放」。

### 选项 4：在 mapping 层夹取到 0..24（**推翻既有产品决定**）
- **用户听到**：真实 CC:T 上扩展音域音符**被压进原生八度**（音高错误），**扩展音域特性彻底失效**。
- **既有警告是否足够**：需再造一个新警告说明「已夹取」，且与「提示装材质包」自相矛盾。
- **要改的代码面**：`player/mapping.lua`（`pitch_semitones`）+ 大量已锁定的单测（`mapping_spec` 明确断言 key 20→-13、不夹取）。
- **风险**：**与本次源码证据直接冲突**，会让真实 CC:T 上本可正常播放的歌曲变差。**证据不支持此选项。**

### 推荐（仍由所有者拍板）

**证据最支持「选项 1 为主，叠加选项 3 的告警」。** 理由：

1. 真实 CC:T 的 `playNote` **确证为 pass-through**（§2），所以「不夹取」是**正确的产品行为**，不应推翻（排除选项 4）。
2. 分歧只存在于模拟器；**生产路径 `ccnbs.play` 本来就不会崩**（`dispatch` 已 `pcall` 包住），只是**静默**。
   「静默」才是真正待修的用户体验问题——选项 3 用最小改动把「静默」变「告警」，且**不改变真机行为**。
3. 选项 2 会引入「模拟器移调 vs 真机不移调」的新分歧，并破坏 Tier-2 的逐行比对，收益/风险比最差；
   若确实要让 Tier-2 覆盖扩展音域歌，更干净的做法是**在 harness 侧**把「音高越界被拒」当作**预期结果**记录，
   而不是去改生产 `dispatch` 的语义。

> **注意**：以上仅为建议。凡涉及 `player/mapping.lua` / `player/dispatch.lua` / `nbs/analyze.lua` 以及
> 本地测试 harness 的改动，均**不在本任务范围**，需由所有者另开任务实施。

---

## 9. UNVERIFIED（未能核实，不得当作事实）

1. **客户端可听性**：本任务只证明了「CC:T 服务器端外设接受越界音高并把它代入
   `Math.pow(2.0, (pitch-12)/12)`」。该 pitch 比值传送到客户端后**是否**会被 Minecraft 客户端/音源
   自行夹取或无法发声，以及「扩展音域材质包」具体如何影响它，**未核实**（需真实客户端 + 材质包实测）。
2. **CCPC `maxNotesPerTick` 默认值**：源码读取点在 `configuration.cpp`，但默认初始化值未定位；实测用
   `-o maxNotesPerTick=8` 显式设定，故 §5 的「8」是该配置下的结果；**默认值本身 UNVERIFIED**（CC:T 默认是 8）。
3. **`mc-26.2` / `mc-26.3`** 分支未逐一抓取（已核到 `mc-26.1`）；鉴于 `1.20.x→26.1` 语义一致，漂移可能性低但未证。
4. **CCPC 的 `sound_then_note ⇒ note=false`** 已与 `speaker.cpp` 的 `noteCount=UINT_MAX` 对齐；但「一个
   playSound **尝试**（在本环境因无音源库而返回 false）是否仍占满 tick」——源码第 687-691 行的
   `noteCount = UINT_MAX` 是在**通过校验之后**执行的；本环境返回 false 的原因在 691 行之前（无音源），
   故严格说「false 的 playSound 是否也占 tick」的因果链**部分 UNVERIFIED**（现象稳定复现三次）。
5. 早期桌面调研称「CC:T 不夹取」——本次已用源码复核为**真**；但其「CraftOS-PC 也接受」的推论为**假**（实测证伪）。

---

## 10. 复现命令

```powershell
# 1) 探针（宿主机 → CraftOS-PC 无头 → result.txt）
$tmp = "$env:TEMP\ccnbs-pitch-probe"
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path "$tmp\computer\0" -Force | Out-Null
$env:SDL_AUDIODRIVER = "dummy"
& "D:\tools\CraftOS-PC\CraftOS-PC_console.exe" --headless `
    --directory "$tmp" --id 0 `
    --script "<本地音高扫描脚本路径>" `
    -o standardsMode=true -o maxNotesPerTick=8 -o http_enable=true
Get-Content "$tmp\computer\0\result.txt"
Get-Process | Where-Object { $_.ProcessName -like "*CraftOS*" }   # 期望 0 个

# 2) 静态检查 + 全量单测（本地运行，必须仍绿）
```

复现「本机 ROM 第 257 行是调用点」：

```powershell
$c = Get-Content "D:\tools\CraftOS-PC\rom\apis\peripheral.lua"
$c[252..257]     # 第 256-257 行: if native.isPresent(name) then / return native.call(...)
```

（`os.shutdown` 前固定 `os.sleep(1.5)`：CraftOS-PC 2.8.3 在有排队音频时关机会以 `0xC0000005` 崩溃，
探针所有路径都复用该收尾模式。）
