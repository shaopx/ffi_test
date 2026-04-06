# 问题排查记录

> 📅 2026-04-05
> 现象：PC 端启动正常，手机端 VPN 图标出现，但浏览器打开任何网页均失败（网络不通）

---

## 一、现象分析

从日志可以看到整个链路已经部分通畅：

```
[TunnelServer] ⚡ 收到新的设备连接请求！远程端口: 63996
📦 收到来自手机的字节流，大小: 200 Bytes   ← 首字节 0x60 (IPv6)
📦 收到来自手机的字节流，大小: 61 Bytes    ← 首字节 0x45 (IPv4)
🔗 替手机创建了真实的 Mac Socket，FD = 12
🛡️ 拦截到 ARP 请求，伪造 MAC 应答
✅ libslirp 吐出了外网回包，大小: 93 Bytes  ← 有回包！
📦 收到来自手机的字节流，大小: 122 Bytes   ← 首字节 0x45 (IPv4)
🔗 替手机创建了真实的 Mac Socket，FD = 13
✅ libslirp 吐出了外网回包，大小: 94 Bytes  ← 有回包！
```

**关键观察：**
- libslirp 确实创建了真实 socket 并产生了回包 → C 引擎在工作
- 但只有最初的 2-3 个包有响应，之后就静默了 → TCP 握手可能失败

---

## 二、已识别问题（按严重程度排序）

### 🔴 致命问题 1：TCP 流缺少分包协议（最大嫌疑）

**文件**：`lib/src/network/tunnel_server.dart`

TCP 是**流式协议**，没有消息边界。但 TunnelServer 把每次 `listen` 回调收到的 `Uint8List` 直接当作一个完整的 IP 包：

```dart
client.listen((Uint8List data) {
    onPacketReceived(data);  // ← 直接当一个包处理
});
```

这会导致两种致命错误：

| 情况 | 后果 |
|------|------|
| **粘包**：两个 IP 包合并成一次回调 | libslirp 只处理第一个包的头部，后面的数据全部损坏 |
| **拆包**：一个大 IP 包分成两次回调 | libslirp 收到不完整的 IP 头，直接丢弃或崩溃 |

**验证**：原版 gnirehtet 使用了长度前缀协议——每个 IP 包前面加 4 字节大端序长度头：

```
[4 字节: 包长度 (big-endian)] [N 字节: IP 数据包]
[4 字节: 包长度 (big-endian)] [N 字节: IP 数据包]
...
```

**为什么前几个包"碰巧"能工作**：
- 连接刚建立时流量很少，操作系统恰好把每个 IP 包单独交付
- 一旦流量增大（比如加载网页），多个包被合并交付，立刻全部损坏

**修复方向**：
需要实现 TCP 分包器（packet framer），在 TunnelServer 中：
1. 维护一个 `BytesBuilder` 缓冲区
2. 每次收到数据追加到缓冲区
3. 循环检查：如果缓冲区 >= 4 字节，读取长度头；如果数据足够，取出完整包
4. 发送方向同理：`sendToDevice` 时需要加上 4 字节长度前缀

---

### 🔴 致命问题 2：回传数据也缺少长度前缀

**文件**：`lib/src/network/tunnel_server.dart`

```dart
void sendToDevice(Uint8List data) {
    _activeClient!.add(data);  // ← 直接发裸 IP 包
}
```

Android 端的 gnirehtet 客户端期望收到 `[4字节长度][IP包]` 格式，但我们只发了裸 IP 包。
Android 端可能把前 4 字节当长度头解析，导致后续所有数据错位。

---

### 🟡 严重问题 3：定时器回调是空操作

**文件**：`lib/src/ffi/slirp_wrapper.dart`，第 384 行

```dart
static void _cTimerMod(ffi.Pointer<ffi.Void> timer, int expireTime, ffi.Pointer<ffi.Void> opaque) {
    // 修改定时器时间，暂时留空
}
```

libslirp 依赖定时器实现：
- TCP 重传（SYN-ACK 丢了需要重发）
- DNS 查询超时和重试
- TCP keepalive
- 连接超时回收

**当前的 10ms 盲轮询部分弥补了这个问题**（强制驱动引擎处理），但无法替代精确的定时器回调。
某些需要延迟触发的逻辑（如 TCP 重传退避）可能永远不会执行。

**修复方向**：
实现一个简单的定时器调度器：
```dart
static final Map<int, Timer> _timers = {};

static void _cTimerMod(Pointer<Void> timer, int expireTimeMs, Pointer<Void> opaque) {
    final key = timer.address;
    _timers[key]?.cancel();
    final delay = Duration(milliseconds: max(0, expireTimeMs - DateTime.now().millisecondsSinceEpoch));
    _timers[key] = Timer(delay, () {
        // 调用 libslirp 保存的回调函数
    });
}
```

---

### 🟡 严重问题 4：IPv6 被禁用但设备在发 IPv6 包

**文件**：`lib/src/ffi/slirp_wrapper.dart`，第 139 行

```dart
configPtr.ref.in6_enabled = false;  // ← IPv6 关闭
```

日志中第一个包就是 IPv6（首字节 `0x60`，200 字节）——很可能是 **IPv6 Router Solicitation** 或 **DNS over IPv6**。

这些包被 libslirp 静默丢弃。如果 Android 的 DNS 解析优先走 IPv6，那么：
- DNS 查询（IPv6）→ 丢弃 → 超时
- 浏览器等不到 DNS 响应 → "网络不通"

**修复方向**：
- 方案 A：开启 IPv6 支持 `in6_enabled = true`，并配置 IPv6 网络参数
- 方案 B：在 Android 端 VPN 配置中只路由 IPv4 流量

---

### 🟠 中等问题 5：盲轮询的可靠性

**文件**：`lib/src/ffi/slirp_wrapper.dart`，`_cGetREvents` 方法

```dart
static int _cGetREvents(int idx, ffi.Pointer<ffi.Void> opaque) {
    if (idx >= 0 && idx < _blindEvents.length) {
        return _blindEvents[idx];  // ← 总是说"事件就绪了"
    }
    return 0;
}
```

告诉 libslirp **所有 socket 都已就绪**。这意味着：
- 当 libslirp 尝试 `write()` 到一个实际上 buffer 已满的 socket → 返回 EAGAIN → libslirp 可能标记连接错误
- 当 libslirp 尝试 `read()` 一个没有数据的 socket → 返回 EAGAIN → 浪费 CPU 但通常不致命

**在初期调试阶段这个方案可以接受**，但大流量下可能导致丢包或连接中断。

---

### 🟢 低优先级问题 6：send_packet 回调注册了两次

**文件**：`lib/src/ffi/slirp_wrapper.dart`，第 124 行和第 148 行

```dart
// 第一次（第 124 行）
callbacksPtr.ref.send_packet = ffi.Pointer.fromFunction<...>(_cSendPacketCallback, 0);

// ... 中间配置 config ...

// 第二次（第 148 行）— 完全相同
callbacksPtr.ref.send_packet = ffi.Pointer.fromFunction<...>(_cSendPacketCallback, 0);
```

功能上无害（第二次覆盖第一次），但表明代码是增量调试堆叠出来的，容易隐藏 bug。

---

## 三、排查优先级路线图

```
第一步（最高优先级）：
  └→ 确认 Android 端使用的 TCP 分包协议
     └→ 在 TunnelServer 中抓取原始字节流的前 20 字节进行分析
     └→ 如果使用了长度前缀，实现分包/组包逻辑

第二步：
  └→ 给 sendToDevice 加上对应的长度前缀

第三步：
  └→ 开启 IPv6 或确认 DNS 走 IPv4

第四步：
  └→ 实现定时器回调

第五步：
  └→ 改进 socket 轮询机制（用真实的 select/poll 替代盲轮询）
```

---

## 四、快速验证方法

### 验证"分包协议"猜测

在 `tunnel_server.dart` 的 `_handleNewClient` 中，临时加入原始字节 dump：

```dart
client.listen((Uint8List data) {
    // 调试：打印前 20 字节的 hex
    final preview = data.take(20).map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(' ');
    print('🔬 [RAW] 长度=${data.length}, 前20字节: $preview');
    onPacketReceived(data);
});
```

**预期结果**：
- 如果前 4 字节是 `0x00 0x00 0x00 0xXX`（XX = 后续 IP 包长度），则确认使用了长度前缀协议
- 如果前 4 字节是 `0x60 ...`（IPv6）或 `0x45 ...`（IPv4），则没有长度前缀，Android 端可能使用了不同的协议

### 验证"回包是否到达手机"

在手机端通过 `adb logcat` 过滤 gnirehtet 日志：
```bash
adb logcat -s gnirehtet:V
```
看手机端是否报告收到了数据、是否有解析错误。

---

## 五、参考：原版 gnirehtet 的 TCP 协议格式

原版 gnirehtet (Java/Rust) 的 relay 协议：

```
连接建立后，双向通信的每个消息格式：

┌──────────────────────────────────────────────┐
│  2 字节: 消息类型 (big-endian uint16)        │
│  2 字节: 有效载荷长度 (big-endian uint16)    │
│  N 字节: 有效载荷 (IP 数据包)                │
└──────────────────────────────────────────────┘

消息类型：
  0x0000 = 无操作 (keepalive)
  0x0001 = IP 数据包 (payload 是完整的 IP packet)
```

如果 Android 端用的是原版 gnirehtet APK，那么 PC 端必须按此协议解析，
否则把消息头的 4 字节当 IP 包头喂给 libslirp，必然全部失败。

---

---

## 六、2026-04-05 第二轮分析：阅读 Android 端源码

### Android 项目位置

`/Users/shaopx/data/code/MyGnirehtet/`

### 重大发现：Android 端也没有分包协议

阅读 `TrafficForwarder.kt` 后确认：

```
上行: tunInputStream.read(buffer) → socketOutputStream.write(buffer, 0, length) + flush()
下行: socketInputStream.read(buffer) → tunOutputStream.write(buffer, 0, length)
```

**两个方向都是裸 TCP 传输，没有任何长度前缀或分包机制。**

### 修正后的分析

之前猜测 Android 端使用了原版 gnirehtet 的 4 字节长度前缀协议——**这个猜测是错误的**。
这是一个全新的自写 Android 客户端，直接裸发 IP 包。

### 核心矛盾依然存在

虽然 Android 的 TUN 设备每次 `read()` 返回一个完整 IP 包，但 TCP 是流式协议：

**上行方向（手机→PC）**：
- Android 侧每次 `write()` + `flush()` 发一个完整 IP 包
- 但 Dart 的 `Socket.listen()` 收到的数据**可能被合并或拆分**
- PC 端目前把每次回调的数据当作一个 IP 包 → **粘包时会损坏**

**下行方向（PC→手机）**：
- PC 用 `Socket.add(ipPacket)` 发裸 IP 包
- Android 的 `socketInputStream.read(buffer)` 也可能收到粘包/拆包
- 粘包数据直接 `write()` 到 TUN → **内核只处理第一个包，后续包丢失**

### 新发现的配置问题

| 配置项 | Constants.kt | 实际使用 (GnirehtetVpnService.kt) | PC 端 (slirp_wrapper.dart) |
|--------|-------------|----------------------------------|---------------------------|
| 手机 VPN IP | `10.0.0.2` | `10.0.2.15` | 网段 `10.0.2.0/24` |
| DNS | — | `10.0.2.3` | `10.0.2.3` |

`10.0.2.15` 在 `10.0.2.0/24` 网段内 ✅，配置一致。

### 已添加的调试代码

**PC 端 (`tunnel_server.dart`)**:
- `_debugAnalyzePacket()`: 解析 IP 头，对比声明长度 vs 实际收到长度
- 如果发生粘包，打印 `🔴 !!粘包/拆包!!` 并分析偏移处的下一个包头
- 下行也加了序号和 IP 头分析

**Android 端 (`TrafficForwarder.kt`)**:
- 上行: 解析并打印 IP 版本、协议类型、目标 IP、长度匹配状态
- 下行: 检测粘包/拆包，如果粘包则只写第一个完整包到 TUN（临时修复）
- 用 `Log.e` 确保 logcat 可见

### 下一步操作

1. 编译并部署 Android APK: `cd /Users/shaopx/data/code/MyGnirehtet && ./gradlew assembleDebug`
2. PC 端重新运行: `cd /Volumes/data/code/ffi_test && dart run bin/gnirehtet.dart`
3. 手机打开浏览器访问任意网页
4. 观察两端日志：
   - PC: 看是否有 `🔴 !!粘包/拆包!!` 输出
   - Android: `adb logcat -s GnirehtetApp-UP:* GnirehtetApp-DOWN:*`
5. 根据日志确认问题类型，再决定修复方案

---

## 七、2026-04-05 第三轮分析：真实日志解读

### 日志对照

| Android 上行 | PC 收到 | 说明 |
|-------------|---------|------|
| IPv6 多个包 | DEBUG#1: 200字节粘包 | 多个IPv6包合并成一次TCP交付 |
| #4 ICMP → 103.107.217.26 | DEBUG#2: 84字节 ✅ | ICMP ping，libslirp正常处理 |
| #5 UDP → 10.0.2.3 | DEBUG#3: 61字节 ✅ | DNS查询，libslirp正确回复93字节 |
| #6 TCP → 103.102.202.191 | DEBUG#4: 60字节 ✅ | TCP SYN，libslirp创建socket |
| #7 ~ #56+ | **PC 端完全无日志** | ❌ 数据消失！ |

### 核心发现

**Android 发了 56+ 包，PC 只收到 4 个数据事件后就彻底沉默。**

这不是粘包问题（后面3个包都是完美匹配的）。问题出在更底层：

### 猜测方向

#### 猜测 A：FFI 调用阻塞了 Dart 事件循环（最高嫌疑）

Dart 是单线程事件循环模型。`slirp_pollfds_poll` 是同步 FFI 调用。
如果 libslirp 内部在处理 TCP SYN 时做了阻塞操作（比如 DNS 解析、connect 超时），
整个 Dart 事件循环将冻结，导致：
- Socket 数据堆积在 OS 缓冲区
- Timer 回调排队无法执行
- 看起来就像"PC 停止接收数据"

**验证方法**：已添加引擎心跳日志（每5秒打印一次轮询次数）+ 单次耗时超过50ms告警。

#### 猜测 B：ARP 回复中的递归 slirp_input 导致 UB

在 `_cSendPacketCallback` 内部（这是 C 回调 Dart 的静态方法），
代码立刻又调用了 `_sendArpReplyToSlirp → slirp_input`。
这等于在 C 函数执行中间，从 Dart 反向调用 C → **递归进入 libslirp**。

libslirp 很可能**不是可重入的**（non-reentrant）。在 send_packet 回调里再调 slirp_input，
可能导致 libslirp 内部状态被破坏，后续所有操作静默失败。

**验证方法**：已添加 `_isInsideCallback` 标志，检测到递归时改用 `Timer.run()` 延迟执行。

#### 猜测 C：盲轮询导致 libslirp 错误关闭 socket

TCP SYN 发出后 socket 处于 CONNECTING 状态。
盲轮询谎报"socket 可读"，libslirp 可能：
- `read()` 返回 EAGAIN → libslirp 认为连接异常 → 关闭 socket
- 但 libslirp 没有通过 send_packet 发 RST → 手机不知道连接断了

### 本轮添加的调试代码

**slirp_wrapper.dart**：
1. `_driveEngine()` 心跳：每5秒打印轮询次数 + 单次超50ms告警
2. `inputFromDevice()` 粘包修复：检测IP头长度，只喂第一个完整包
3. `_cSendPacketCallback` 加序号和详细日志
4. `_sendArpReplyToSlirp` 递归检测：在回调内部改用 Timer.run 延迟

### 下次运行后应观察

1. **引擎心跳是否持续打印** → 如果停了，说明 FFI 阻塞
2. **心跳中的轮询次数** → 应该约 100次/秒（10ms间隔），如果远低于此说明有阻塞
3. **是否出现 `⚠️ 检测到递归`** → 确认 ARP 递归是否发生
4. **是否出现 `🐌 轮询耗时异常`** → 定位阻塞在 fill 还是 poll
5. **`INPUT#N` 和 `CALLBACK#N` 的序号** → 看最后卡在哪一步

---

## 八、2026-04-05 第四轮：确定性 Bug 修复 + 文件日志

### 确认的 Bug：`_isInsideCallback` 永远不被重置

**根因链**：

```
slirp_input(DNS包)
  → libslirp 需要发 ARP 请求
  → 回调 _cSendPacketCallback()
    → _isInsideCallback = true   ← 设置
    → 检测到 ARP → _sendArpReplyToSlirp()
      → 检测到 _isInsideCallback==true → Timer.run() 延迟
    → return pktLen              ← 提前返回，没经过 _isInsideCallback=false ！！！
```

后果：
1. `_isInsideCallback` **永久为 true**
2. Timer.run() 触发 → 仍然检测到"递归" → 再次 Timer.run() → **无限延迟循环**
3. ARP 回复**永远不会注入** libslirp
4. libslirp **不知道手机的 MAC 地址** → 无法发送任何回包给手机
5. 每次 `_driveEngine` 轮询，libslirp 又发 ARP 请求 → 又被延迟 → 事件队列被淹没
6. Dart 事件循环被海量 Timer.run() 阻塞 → Socket 数据接收停滞 → **表现为"PC 不再收数据"**
7. Ctrl+C 的信号处理器也排不上队 → **表现为"Ctrl+C 无效"**

### 修复

在 `_cSendPacketCallback` 的 ARP 分支 `return` 前加入 `_isInsideCallback = false;`

### 新增 Android 文件日志

创建 `FileLogger.kt`，日志文件路径：
```
/sdcard/Android/data/com.xxx.gnirehtet/files/gnirehtet_log.txt
```

取日志：
```bash
adb pull /sdcard/Android/data/com.xxx.gnirehtet/files/gnirehtet_log.txt
```

每次 VPN 启动时自动清空旧日志，停止时自动关闭文件句柄。

---

## 九、2026-04-05 第五轮：确定根因 + 实施真正修复

### 根因确认

日志铁证：
```
🔄 [POLL#4798] slirp_pollfds_poll 返回, 耗时=20027383μs   ← 阻塞 20 秒！！
📦 [DEBUG#9] 收到 170663 字节   ← 20秒堆积的数据一次涌入
```

**盲轮询 (blind polling) 是根本原因。**

原理：盲轮询对所有 socket 谎报"事件已就绪"。当 libslirp 对一个正在 connect() 的 TCP socket
调用 `getsockopt(SO_ERROR)` 检查连接状态时，发现连接尚未完成（EINPROGRESS），
但因为我们说"可写"，libslirp 可能进入了内部重试/等待逻辑，最终触发了 TCP 连接超时（~20秒）。

这个 20 秒阻塞冻结了整个 Dart 事件循环：
- Socket 数据堆积在 OS 缓冲区
- Timer 回调无法执行
- Ctrl+C 信号无法处理

### 修复方案：用 libc `poll()` 替代盲轮询

通过 `DynamicLibrary.process()` 加载 libc 的 `poll()` 系统调用，在每次 `_driveEngine` 中：

1. `slirp_pollfds_fill` → libslirp 注册 (fd, events) 对
2. **调用真正的 `poll(fds, nfds, 0)`**，timeout=0 表示不阻塞
3. 读取 `revents`（真实的 socket 就绪状态）
4. `slirp_pollfds_poll` → 向 libslirp 报告真实事件

关键 FFI 定义：
```dart
final class PollFd extends ffi.Struct {
  @ffi.Int32() external int fd;
  @ffi.Int16() external int events;
  @ffi.Int16() external int revents;
}
```

### 同时修复的粘包问题

`inputFromDevice()` 改为循环处理：解析每个 IP 包的声明长度，按包边界切割，逐个喂入 libslirp。
不再丢弃粘包中的后续包。

### 文件日志

- PC 端：`gnirehtet_pc_log.txt`（项目根目录），`FileLogger.log()` 同时写文件+控制台
- Android 端：`/sdcard/Android/data/com.xxx.gnirehtet/files/gnirehtet_log.txt`

取日志命令：
```bash
# PC 日志直接在项目根目录
cat gnirehtet_pc_log.txt

# Android 日志
adb pull /sdcard/Android/data/com.xxx.gnirehtet/files/gnirehtet_log.txt
```

*本文件将随排查进展持续更新。*
