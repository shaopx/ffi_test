// 文件路径: lib/src/core/router_engine.dart

import 'dart:io';
import 'dart:typed_data';

// 导入我们刚才写好的积木
import '../ffi/slirp_bindings.dart';
import '../ffi/slirp_wrapper.dart';
import '../ffi/lib_loader.dart';
import '../network/adb_manager.dart';
import '../network/tunnel_server.dart';

class RouterEngine {
  late final AdbManager _adbManager;
  late final TunnelServer _tunnelServer;
  SlirpWrapper? _slirpWrapper;

  bool _isRunning = false;

  // 端口配置信息
  final int devicePort;
  final int localPort;

  RouterEngine({
    this.devicePort = 31416, // 安卓端 App 默认发数据的端口
    this.localPort = 31416,  // 电脑端 Dart 监听的端口
  }) {
    _adbManager = AdbManager();
    
    // 初始化网络服务器，并绑定好数据回调
    _tunnelServer = TunnelServer(
      onPacketReceived: _handleDataFromDevice,
      onClientDisconnected: _handleDeviceDisconnected,
    );
  }

  /// 启动整个路由引擎的生命周期
  Future<void> start() async {
    if (_isRunning) {
      print('[RouterEngine] 引擎已经在运行中。');
      return;
    }

    print('\n🚀 [RouterEngine] 正在启动虚拟路由器引擎...');

    try {
      // 第一步：检查并建立物理通道 (ADB)
      final hasDevice = await _adbManager.checkEnvironment();
      if (!hasDevice) {
        throw Exception('未检测到 Android 设备，请检查 USB 连接和 ADB 环境。');
      }
      await _adbManager.enableReverseTethering(devicePort, localPort);

      // 第二步：启动本地监听插座 (TunnelServer)
      await _tunnelServer.start(localPort);

      // 第三步：加载底层 C 语言动态库 (跨平台魔法)
      print('[RouterEngine] 正在加载底层 libslirp 引擎...');
      final dylib = LibLoader.loadSlirpLibrary();
      final bindings = SlirpBindings(dylib);

      // 第四步：初始化 FFI 适配器 (SlirpWrapper)
      // 注意：这里我们把 _tunnelServer 发送数据的能力，作为闭包传给了底层
      _slirpWrapper = SlirpWrapper(
        bindings,
        onSendData: _handleDataFromNetwork,
      );
      
      // 真正点火启动 C 语言引擎
      _slirpWrapper!.init();

      _isRunning = true;
      print('✅ [RouterEngine] 引擎启动成功！现在只要手机端发起连接，数据就会自动转发。');
      print('   [RouterEngine] (按 Ctrl+C 停止服务)\n');

    } catch (e) {
      print('\n❌ [RouterEngine] 启动失败: $e');
      // 启动失败时，必须执行安全回滚，防止端口被死锁占用
      await stop();
    }
  }

  // ========================================================================
  // 核心数据流转逻辑 (极其简洁，因为复杂度都被各层消化了)
  // ========================================================================

  /// 手机端 -> 电脑端 -> 互联网
  /// TunnelServer 收到手机发来的原始 IP 包，转交给底层的 C 语言引擎
  void _handleDataFromDevice(Uint8List data) {
    if (_slirpWrapper != null) {
      // 这里的 data 可以是 TCP SYN, HTTP GET 等纯净的 IP 报文
      _slirpWrapper!.inputFromDevice(data);
    }
  }

  /// 互联网 -> 电脑端 -> 手机端
  /// 底层 libslirp 收到百度的回包，触发 Dart 回调，通过 TunnelServer 塞回给手机
  void _handleDataFromNetwork(Uint8List data) {
    print('✅ [RouterEngine] libslirp 吐出了外网回包，准备发回手机！大小: ${data.length} Bytes');
    _tunnelServer.sendToDevice(data);
  }

  // ========================================================================
  // 异常恢复与生命周期管理
  // ========================================================================

  /// 当手机断开连接时 (比如线拔了，或者 App 崩溃了)
  void _handleDeviceDisconnected() {
    print('[RouterEngine] 警告：手机端已断开连接。清理当前底层路由状态...');
    // 在生产环境中，为了防止 C 语言内部的 NAT 表被塞满僵尸连接，
    // 当物理设备断开时，我们通常会直接销毁并重建 Slirp 引擎，或者调用其 cleanup 接口
    if (_slirpWrapper != null) {
      _slirpWrapper!.dispose();
      _slirpWrapper = null;
    }
    
    // 重新加载底层引擎，准备迎接设备的下一次插入
    // (这里是一个极简的恢复策略，你可以根据业务需求做得更平滑)
    print('[RouterEngine] 正在重置底层引擎状态...');
    try {
      final dylib = LibLoader.loadSlirpLibrary();
      final bindings = SlirpBindings(dylib);
      _slirpWrapper = SlirpWrapper(bindings, onSendData: _handleDataFromNetwork);
      _slirpWrapper!.init();
      print('[RouterEngine] 引擎重置完毕，等待设备重新连接。');
    } catch (e) {
      print('[RouterEngine] 引擎重置失败，建议重启应用: $e');
    }
  }

  /// 彻底关闭整个路由器 (退出应用时调用)
  Future<void> stop() async {
    print('\n🛑 [RouterEngine] 收到停止指令，正在执行安全清理流水线...');
    _isRunning = false;

    // 1. 拆除底层 C 语言引擎 (释放 Native 内存)
    if (_slirpWrapper != null) {
      _slirpWrapper!.dispose();
      _slirpWrapper = null;
      print('   -> [SlirpWrapper] 已销毁');
    }

    // 2. 拔掉本地网络插头 (释放 31416 端口)
    await _tunnelServer.stop();
    print('   -> [TunnelServer] 已停止');

    // 3. 拆除 ADB 隧道 (释放手机端的端口映射)
    await _adbManager.disableReverseTethering(devicePort);
    print('   -> [AdbManager] 隧道已拆除');

    print('✅ [RouterEngine] 清理完毕，程序已安全退出。');
  }
}