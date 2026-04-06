// 文件路径: bin/gnirehtet.dart

import 'dart:io';

// 生产级规范：在 bin 目录下引入 lib 目录的代码，推荐使用 package 语法
// 注意：这里的 'ffi_test' 需要替换成你 pubspec.yaml 里定义的 name 字段的值
import 'package:ffi_test/src/core/router_engine.dart';
import 'package:ffi_test/src/utils/logger.dart';
import 'package:ffi_test/src/utils/file_logger.dart';

void main(List<String> args) async {
  // 1. 初始化生产级日志系统
  // 在开发阶段，我们可以设置为 debug 看底层内存和字节流
  // 在发布生产时，可以改为 info 或 warning
  Logger.currentLevel = LogLevel.info;
  FileLogger.init();

  Logger.i('=======================================');
  Logger.i('   🚀 跨平台虚拟路由器 (Dart FFI 版)   ');
  Logger.i('=======================================');

  // 2. 检测 macOS 系统代理设置，提示用户是否需要开启增强模式
  await _checkAndPrintProxyStatus();

  // 3. 解析命令行参数 (生产级工具必备，这里做个极其简单的示例)
  int devicePort = 31416;
  int localPort = 31416;
  
  if (args.isNotEmpty) {
    if (args.contains('--help') || args.contains('-h')) {
      print('用法: dart run bin/gnirehtet.dart [devicePort] [localPort]');
      exit(0);
    }
    // 未来你可以在这里接入 args 库，进行更复杂的参数解析
  }

  // 4. 实例化中枢大脑
  final engine = RouterEngine(
    devicePort: devicePort,
    localPort: localPort,
  );

  // 5. 【核心防御】拦截系统的终止信号 (Ctrl+C / SIGINT)
  // 如果没有这个拦截，用户按下 Ctrl+C 时程序会瞬间死亡，导致底层的 C 语言内存泄漏，
  // 以及本机的 31416 端口被死锁，下次启动就会报 "Address already in use"。
  ProcessSignal.sigint.watch().listen((ProcessSignal signal) async {
    Logger.w('\n接收到系统的终止信号 (SIGINT)，准备优雅退出...');
    
    // 调用引擎的安全清理流水线
    await engine.stop();
    FileLogger.close();

    Logger.i('再见！👋');
    exit(0);
  });

  // 6. 点火启动！
  try {
    await engine.start();
  } catch (e) {
    Logger.e('致命错误导致引擎启动失败，程序将退出。', e);
    exit(1);
  }
}

// ============================================================================
// 代理状态检测：提醒用户 libslirp 无法自动使用浏览器代理
// ============================================================================
Future<void> _checkAndPrintProxyStatus() async {
  if (!Platform.isMacOS) return;

  try {
    // scutil --proxy 读取 macOS 系统代理配置
    final result = await Process.run('scutil', ['--proxy']);
    final output = result.stdout.toString();

    // 解析 SOCKS 代理
    final socksEnabled = RegExp(r'SOCKSEnable\s*:\s*1').hasMatch(output);
    final socksHostMatch = RegExp(r'SOCKSProxy\s*:\s*(\S+)').firstMatch(output);
    final socksPortMatch = RegExp(r'SOCKSPort\s*:\s*(\d+)').firstMatch(output);

    // 解析 HTTP 代理
    final httpEnabled = RegExp(r'HTTPEnable\s*:\s*1').hasMatch(output);
    final httpHostMatch = RegExp(r'HTTPProxy\s*:\s*(\S+)').firstMatch(output);
    final httpPortMatch = RegExp(r'HTTPPort\s*:\s*(\d+)').firstMatch(output);

    final hasProxy = socksEnabled || httpEnabled;

    if (!hasProxy) {
      Logger.i('🌐 [代理] 未检测到系统代理，直连模式。');
      return;
    }

    Logger.w('');
    Logger.w('╔══════════════════════════════════════════════════════════════╗');
    Logger.w('║  ⚠️  检测到 macOS 系统代理，但 libslirp 无法自动使用！       ║');
    Logger.w('║  手机通过本工具上网将无法访问需要代理的网站 (如 Google)。     ║');
    Logger.w('╠══════════════════════════════════════════════════════════════╣');

    if (socksEnabled && socksHostMatch != null && socksPortMatch != null) {
      Logger.w('║  · SOCKS5 代理: ${socksHostMatch.group(1)}:${socksPortMatch.group(1)}');
    }
    if (httpEnabled && httpHostMatch != null && httpPortMatch != null) {
      Logger.w('║  · HTTP  代理: ${httpHostMatch.group(1)}:${httpPortMatch.group(1)}');
    }

    Logger.w('╠══════════════════════════════════════════════════════════════╣');
    Logger.w('║  ✅ 推荐方案：开启代理工具的「增强模式 / TUN 模式」           ║');
    Logger.w('║     · ClashX / ClashX Pro: 菜单栏 → 增强模式               ║');
    Logger.w('║     · Surge for Mac:       菜单栏 → 增强模式               ║');
    Logger.w('║     · Clash Verge / CFW:   设置   → TUN 模式               ║');
    Logger.w('║                                                              ║');

    if (socksEnabled && socksPortMatch != null) {
      final port = socksPortMatch.group(1);
      Logger.w('║  🔧 备选方案：proxychains4 包裹启动                         ║');
      Logger.w('║     brew install proxychains-ng                            ║');
      Logger.w('║     # 在 proxychains.conf 中添加: socks5 127.0.0.1 $port   ║');
      Logger.w('║     proxychains4 dart run bin/gnirehtet.dart               ║');
    }

    Logger.w('╚══════════════════════════════════════════════════════════════╝');
    Logger.w('');
  } catch (_) {
    // scutil 不可用时静默跳过（非 macOS 环境）
  }
}