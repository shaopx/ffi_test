# Gnirehtet PC 端 — Dart FFI libslirp 虚拟路由器

一个用 Dart FFI 封装 [libslirp](https://gitlab.freedesktop.org/slirp/libslirp)（用户态 TCP/IP 协议栈）实现的**反向网络共享工具**，类似 [gnirehtet](https://github.com/Genymobile/gnirehtet) 但完全用 Dart 实现。

**功能**：通过 USB 线让 Android 手机使用电脑的网络上网，无需 Wi-Fi、无需 root。

## 工作原理

```
┌─────────────────────────────────────────────────────┐
│  Android 手机                                        │
│  ┌──────────────┐    ┌──────────────────────────┐   │
│  │  App 网络请求  │───▶│  VPN Service (TUN 虚拟网卡) │   │
│  └──────────────┘    └────────────┬─────────────┘   │
│                                   │ 原始 IP 包       │
│                      ┌────────────▼─────────────┐   │
│                      │  TrafficForwarder         │   │
│                      │  TCP Socket → localhost:31416│ │
│                      └────────────┬─────────────┘   │
└───────────────────────────────────┼─────────────────┘
                        USB (adb reverse tcp:31416)
┌───────────────────────────────────┼─────────────────┐
│  PC 电脑                          │                  │
│                      ┌────────────▼─────────────┐   │
│                      │  TunnelServer (:31416)    │   │
│                      └────────────┬─────────────┘   │
│                                   │ 原始 IP 包       │
│                      ┌────────────▼─────────────┐   │
│                      │  RouterEngine (调度中心)    │   │
│                      └────────────┬─────────────┘   │
│                                   │ +Ethernet 头     │
│                      ┌────────────▼─────────────┐   │
│                      │  SlirpWrapper (Dart FFI)  │   │
│                      │  ┌──────────────────────┐ │   │
│                      │  │  libslirp.dylib       │ │   │
│                      │  │  用户态 NAT/TCP/IP 栈  │ │   │
│                      │  └──────────┬───────────┘ │   │
│                      └─────────────┼─────────────┘   │
│                                    │                  │
│                              真实网络出口              │
└───────────────────────────────────────────────────────┘
```

## 项目结构

```
bin/
  gnirehtet.dart          # 程序入口

lib/src/
  core/
    router_engine.dart     # 中央调度器：管理 ADB↔Tunnel↔Slirp 的数据流
  ffi/
    slirp_wrapper.dart     # 核心：Dart FFI 封装 libslirp，含 poll 事件转换
    slirp_bindings.dart    # ffigen 自动生成的 C 绑定（勿手动编辑）
    lib_loader.dart        # 跨平台动态库加载器
  network/
    tunnel_server.dart     # TCP 服务器，接收手机通过 ADB 隧道发来的 IP 包
    adb_manager.dart       # ADB 环境检测与反向隧道管理
  utils/
    file_logger.dart       # 双通道日志（全量 + 关键事件）
    connection_tracker.dart # TCP/UDP 连接生命周期追踪与诊断
```

## 前置条件

1. **Dart SDK** >= 3.0（推荐通过 [FVM](https://fvm.app/) 管理）
2. **ADB**：已安装并加入 PATH（`adb version` 能正常输出）
3. **libslirp**：项目根目录下需要 `libslirp.dylib`（macOS）或 `libslirp.so`（Linux）
4. **Android 端 App**：配套的 [MyGnirehtet](https://github.com/shaopx/MyGnirehtet) 需要安装到手机

### 安装 libslirp（macOS）

```bash
brew install libslirp

# 将动态库复制到项目根目录
cp /opt/homebrew/lib/libslirp.dylib .
cp /opt/homebrew/lib/libslirp.0.dylib .
```

## 使用方法

### 第一步：USB 连接手机

用 USB 线连接 Android 手机到电脑，确认 ADB 能识别：

```bash
adb devices
# 应该看到类似：
# List of devices attached
# XXXXXXXX    device
```

### 第二步：启动 PC 端

```bash
dart run bin/gnirehtet.dart
```

启动后会自动：
1. 检测 ADB 环境和设备连接
2. 建立反向隧道 `adb reverse tcp:31416 tcp:31416`
3. 启动本地 TCP 服务器监听 31416 端口
4. 初始化 libslirp 虚拟路由器
5. 等待手机端连接

### 第三步：启动 Android 端

打开手机上的 MyGnirehtet App，点击"启动 VPN"按钮。

### 第四步：验证

手机上打开浏览器或任意 App，流量将通过 USB → PC 网络出口上网。

PC 终端会显示实时心跳日志：
```
💓 [引擎心跳] 轮询#500, 5秒内100次, socket=42, 定时器=0/0
  | poll统计: calls=500, fdsWithEvents=1200, IN=800, OUT=400, ERR=0
```

### 停止

- PC 端：`Ctrl + C`
- 手机端：点击"停止 VPN"按钮

## 自定义端口

```bash
dart run bin/gnirehtet.dart 31416 31416
#                           ^       ^
#                      devicePort  localPort
```

> 修改端口后需同步修改 Android 端 `Constants.kt` 中的 `PC_PORT`。

## 日志文件

运行时会在项目根目录生成日志文件：

| 文件 | 内容 | 用途 |
|------|------|------|
| `gnirehtet_pc_log.txt` | 全量日志 | 深度排查 |
| `gnirehtet_pc_key.txt` | 关键事件（连接建立/断开、异常、心跳） | 快速诊断 |

## 重新生成 FFI 绑定

当 libslirp 头文件更新时：

```bash
dart run ffigen
# 输出到 lib/src/ffi/slirp_bindings.dart
```

## 配套项目

- **Android 端**：[MyGnirehtet](https://github.com/shaopx/MyGnirehtet)

## 技术细节

关键的 FFI 实现要点：

- **poll 事件映射**：libslirp 的 `SLIRP_POLL_OUT=2` 与 POSIX `POLLOUT=4` 值不同，必须双向转换
- **Ethernet 帧封装**：libslirp 工作在 L2，但隧道传输 L3 IP 包，需要添加/剥离 14 字节以太网头
- **ARP 自动应答**：拦截 libslirp 的 ARP 请求并伪造回应，满足其 L2 协议要求
- **10ms 轮询引擎**：`Timer.periodic` 驱动 `slirp_pollfds_fill → poll() → slirp_pollfds_poll` 循环
- **粘包处理**：TCP 流可能将多个 IP 包合并成一次读取，需循环解析 IP Total Length 逐包喂入

## License

MIT
