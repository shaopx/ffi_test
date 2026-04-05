// 文件路径: lib/src/utils/logger.dart

import 'dart:developer' as developer;

enum LogLevel {
  debug,   // 用于极其详细的网络包追踪 (字节级)
  info,    // 用于核心生命周期的节点记录 (连接、断开)
  warning, // 用于非致命错误 (丢包、延迟)
  error,   // 用于致命崩溃 (内存泄漏、引擎罢工)
}

class Logger {
  // 生产环境可以调高等级，比如 LogLevel.warning，屏蔽掉海量的正常日志
  static LogLevel currentLevel = LogLevel.info;

  static void d(String message) {
    if (currentLevel.index <= LogLevel.debug.index) {
      _printLog('🐛 [DEBUG]', message, 90); // 灰色
    }
  }

  static void i(String message) {
    if (currentLevel.index <= LogLevel.info.index) {
      _printLog('💡 [INFO]', message, 36); // 青色
    }
  }

  static void w(String message) {
    if (currentLevel.index <= LogLevel.warning.index) {
      _printLog('⚠️ [WARN]', message, 33); // 黄色
    }
  }

  static void e(String message, [Object? error, StackTrace? stackTrace]) {
    if (currentLevel.index <= LogLevel.error.index) {
      _printLog('❌ [ERROR]', '$message ${error != null ? '\nError: $error' : ''}', 31); // 红色
      if (stackTrace != null) {
        developer.log('StackTrace:', error: error, stackTrace: stackTrace);
      }
    }
  }

  /// 使用 ANSI 转义序列在终端输出带颜色的日志
  static void _printLog(String prefix, String message, int colorCode) {
    // \x1B[XXm 是控制终端颜色的指令，\x1B[0m 是重置颜色
    print('\x1B[${colorCode}m$prefix $message\x1B[0m');
  }
}