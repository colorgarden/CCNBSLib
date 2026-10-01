-- player/runtime.lua
--
-- 终止保护接缝。
--
-- 为什么存在
-- ---------------
-- 在 CC:Tweaked 里，用户按下 Ctrl+T 时 `os.pullEvent` 会**自动终止**正在运行的程序：
-- 它在 pull 的位置抛出一个 "Terminated" 错误，此后的每一步清理都被跳过。对一个音乐
-- 播放器来说这是一个**真的 bug**，不是锦上添花：扬声器会保留任何已排队的音频，传输
-- 状态被留在未定义的状态。`os.pullEventRaw` 是逃生舱——它把 `terminate` 事件**返回**
-- 给调用方而不是中止，于是程序得以在展开之前停掉它的扬声器。本模块把这套纪律收在
-- **一处**，播放核心永远不必自己记着它。
--
-- 冻结的公共接口（ccnbslib.lua 建立在这些**确切**的名字上）：
--
--   local runtime = require("player.runtime")
--
--   runtime.run(body, opts) -> { terminated = <boolean>,
--                                result     = <body 的返回值>,
--                                error      = <string|nil> }
--
--   runtime.cleanup(speakers, session) -> <integer>  -- 已停止的扬声器数
--   runtime.stop_speakers(speakers)    -> <integer>  -- 已停止的扬声器数
--
-- BODY 契约
-- -----------------
-- `runtime.run` 调用 `body(pull)`，其中 `pull` 是解析出的事件源。需要等待事件的 body
-- 调用交给它的 pull；从不等候的 body 直接忽略这个参数即可。解析是**惰性**的，发生在
-- 调用时，从不在模块加载时：
--
--   * 提供 `opts.pull` 时，它被原样使用（单元测试接缝）；此时全局函数**绝不**被查询
--     ——见注入测试。
--   * 否则在 `run` 内部读取全局 `os.pullEventRaw`。
--
-- 如果经由该接缝的一次调用把 `"terminate"` 作为它的第一个值产出，接缝包装器就记录
-- 这次终止，并抛出一个 terminate 形状的错误，好让 body 展开；`run` 随后执行与 body
-- 内部终止**相同的**清理。
--
-- TERMINATE 形状的识别规则
-- ----------------------------------
-- body 执行期间发生的真实 Ctrl+T 由 `os.pullEvent` 以抛出的错误报告。CC:T 抛出字符串
-- `"Terminated"`（并且可能加前缀/后缀），所以我们把任何消息**包含** `"terminate"`
-- （大小写不敏感）的抛出错误判定为终止。其他任何抛出错误都是真正的崩溃：
--
--   * terminate -> terminated = true,  error = nil,      cleanup 运行；
--   * 其他      -> terminated = false, error = <message>, cleanup **仍然**运行
--                 （崩溃时绝不泄漏扬声器），但**不**被报告为终止。
--
-- 正常返回意味着 terminated = false、result = body 的返回值，且**不**做清理
-- （没有任何东西需要打断）。
--
-- 绝不重新抛出的保证
-- ----------------------------
-- `runtime.run` **绝不**重新抛出。调用方不可能让程序死在清理中途：每一处失败——body、
-- 某个扬声器的 stop()、会话的 cancel()、甚至 `on_terminate`——都被收容，并通过返回值
-- 报告。因此清理也不可能被第二次终止打断。
--
-- `opts.speakers`：扬声器记录数组（player/speaker.lua），可以是 nil 或空。
-- `opts.session`：可选对象，带 `:cancel()` 方法。
-- `opts.on_terminate`：可选 function()，在清理**之后**运行，仅在终止时。
-- `opts.stop_all`：可选 function(speakers)，覆盖逐个扬声器的 stop。
--
-- 兼容性：Lua 5.2 / CC:Tweaked 的 Cobalt。不用整除、不用位运算、不用 utf8、不用
-- string.dump、不用 os.exit。这里**绝不**使用 `os.pullEvent`——`os.pullEventRaw`
-- （或注入的接缝）是唯一的事件源。

local runtime = {}

-- 解包辅助：`table.unpack` 是 Lua 5.2 的名字；对更老的 Cobalt 构建回退到全局函数。
-- 在加载时读取，这是安全的（它不是宿主 API）。
local unpack_values = table.unpack or unpack

-- ---------------------------------------------------------------------------
-- terminate 形状识别
-- ---------------------------------------------------------------------------

-- 当抛出的错误消息指名了一次终止时为 true。CC:Tweaked 抛出字符串 "Terminated"，并可能
-- 加一个前缀或后缀（"Terminated: press Ctrl+T"），所以大小写不敏感的子串测试是合适的
-- 粒度。
local function is_terminate(value)
  if type(value) ~= "string" then
    return false
  end
  return value:lower():find("terminate", 1, true) ~= nil
end

-- ---------------------------------------------------------------------------
-- runtime.stop_speakers(speakers) -> integer
-- ---------------------------------------------------------------------------

-- **防御性地**停止每一条扬声器记录：某个扬声器的 stop() 抛错，不能阻止**其他**扬声器
-- 被停止，并且任何东西都不得向外传播。返回成功停止的扬声器数。缺失/nil/不可调用的
-- 记录只是不被计数（它们的 pcall 失败），绝不致命。
function runtime.stop_speakers(speakers)
  if type(speakers) ~= "table" then
    return 0
  end

  local stopped = 0
  for _, record in ipairs(speakers) do
    local ok = pcall(function()
      record:stop()
    end)
    if ok then
      stopped = stopped + 1
    end
  end
  return stopped
end

-- ---------------------------------------------------------------------------
-- runtime.cleanup(speakers, session) -> integer
-- ---------------------------------------------------------------------------

-- 先停扬声器，再取消会话，每一步都独立受保护。当 `session == nil` 时这里不得抛错。
-- `stop_fn` 是停止步骤的可选覆盖（runtime.run 把 `opts.stop_all` 从这里穿过去）。
-- 幂等：即使某个扬声器的 stop() 被再次调用，再调用一次也是无害的。返回成功停止的
-- 扬声器数。
function runtime.cleanup(speakers, session, stop_fn)
  local stopper = runtime.stop_speakers
  if type(stop_fn) == "function" then
    stopper = stop_fn
  end

  local stopped = 0
  local ok, count = pcall(stopper, speakers)
  if ok and type(count) == "number" then
    stopped = count
  end

  if session ~= nil then
    local cancel = session.cancel
    if type(cancel) == "function" then
      pcall(cancel, session)
    end
  end

  return stopped
end

-- ---------------------------------------------------------------------------
-- runtime.run(body, opts) -> { terminated, result, error }
-- ---------------------------------------------------------------------------

function runtime.run(body, opts)
  if type(opts) ~= "table" then
    opts = {}
  end

  local speakers = opts.speakers
  local session = opts.session
  local on_terminate = opts.on_terminate

  -- **惰性**解析事件源，只在调用时。在模块加载时读取全局会让本文件在纯 Lua 5.2 里
  -- 无法被 require。
  local source = opts.pull
  if source == nil then
    local os_lib = rawget(_G, "os")
    if os_lib ~= nil then
      source = os_lib.pullEventRaw
    end
  end

  -- 当接缝观察到一次终止时置位；在 body 展开之后读取，好让一个吞掉了内部错误的 body
  -- 仍然被当作已终止处理。
  local seam_terminated = false

  -- 交给 body 的 pull。一个架在已解析事件源之上的、感知 terminate 的薄包装：通常它
  -- 原样转发每一个事件值，但第一个值为 "terminate" 时会变成一次展开，好让清理无法被
  -- 跳过。
  local function pull(...)
    if type(source) ~= "function" then
      error("runtime.run: no event source available "
        .. "(os.pullEventRaw is missing; pass opts.pull)", 2)
    end

    local values = { source(...) }
    if values[1] == "terminate" then
      seam_terminated = true
      error("Terminated", 0)
    end
    return unpack_values(values, 1, #values)
  end

  local ok, result = pcall(body, pull)

  local terminated = seam_terminated
  local err = nil
  if not ok then
    if is_terminate(result) then
      terminated = true
    elseif not terminated then
      err = tostring(result)
    end
  end

  -- 清理在**任何**非正常退出时运行：终止**或**崩溃。正常返回不需要清理。
  if terminated or err ~= nil then
    runtime.cleanup(speakers, session, opts.stop_all)
  end

  -- on_terminate 在清理**之后**运行，仅在终止时，且不能重新抛出。
  if terminated and type(on_terminate) == "function" then
    pcall(on_terminate)
  end

  local output = { terminated = terminated, result = nil, error = err }
  if not terminated and err == nil then
    output.result = result
  end
  return output
end

return runtime
