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

  // 2. 解析命令行参数 (生产级工具必备，这里做个极其简单的示例)
  int devicePort = 31416;
  int localPort = 31416;
  
  if (args.isNotEmpty) {
    if (args.contains('--help') || args.contains('-h')) {
      print('用法: dart run bin/gnirehtet.dart [devicePort] [localPort]');
      exit(0);
    }
    // 未来你可以在这里接入 args 库，进行更复杂的参数解析
  }

  // 3. 实例化中枢大脑
  final engine = RouterEngine(
    devicePort: devicePort,
    localPort: localPort,
  );

  // 4. 【核心防御】拦截系统的终止信号 (Ctrl+C / SIGINT)
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

  // 5. 点火启动！
  try {
    await engine.start();
  } catch (e) {
    Logger.e('致命错误导致引擎启动失败，程序将退出。', e);
    exit(1);
  }
}