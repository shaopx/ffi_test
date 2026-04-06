// 文件路径: lib/src/utils/file_logger.dart

import 'dart:io';

/// PC 端文件日志器
/// 日志文件固定位于项��根目录: gnirehtet_pc_log.txt
///
/// 使用方法:
///   FileLogger.init();     // 程序启动时
///   FileLogger.log('消息'); // 替代 print
///   FileLogger.close();    // 程序退出时
class FileLogger {
  static IOSink? _sink;
  static File? _logFile;

  static void init() {
    try {
      // 写到项目根目录
      _logFile = File('gnirehtet_pc_log.txt');
      _sink = _logFile!.openWrite(mode: FileMode.write); // 每次启动覆盖

      final header = '=== Gnirehtet PC 日志 ${DateTime.now()} ===';
      _sink!.writeln(header);
      print(header);
    } catch (e) {
      print('[FileLogger] 初始化失败: $e');
    }
  }

  /// 同时打印到控制台和写入文件
  static void log(String message) {
    final timestamp = _formatTime(DateTime.now());
    final line = '$timestamp $message';
    print(line);
    _sink?.writeln(line);
  }

  /// 只写文件不打印（用于高频日志避免刷屏）
  static void logQuiet(String message) {
    final timestamp = _formatTime(DateTime.now());
    _sink?.writeln('$timestamp $message');
  }

  static void close() {
    _sink?.writeln('=== 日志结束 ${DateTime.now()} ===');
    _sink?.flush();
    _sink?.close();
    _sink = null;
    print('[FileLogger] 日志已保存到 ${_logFile?.path}');
  }

  static String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}.'
        '${dt.millisecond.toString().padLeft(3, '0')}';
  }
}
