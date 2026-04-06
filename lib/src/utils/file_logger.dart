// 文件路径: lib/src/utils/file_logger.dart

import 'dart:io';

/// PC 端双通道日志器
///
/// 两个日志文件：
///   gnirehtet_pc_log.txt  — 全量日志（所有事件，供深度分析）
///   gnirehtet_pc_key.txt  — 关键事件日志（异常、连接生命周期、统计摘要）
///
/// 使用方法:
///   FileLogger.init();              // 程序启动时
///   FileLogger.log('普通消息');       // 全量日志 + 控制台
///   FileLogger.logQuiet('高频消息');  // 仅全量日志
///   FileLogger.key('关键事件');       // 关键日志 + 全量日志 + 控制台
///   FileLogger.close();             // 程序退出时
class FileLogger {
  static IOSink? _sink;
  static IOSink? _keySink;
  static File? _logFile;
  static File? _keyFile;

  static void init() {
    try {
      _logFile = File('gnirehtet_pc_log.txt');
      _sink = _logFile!.openWrite(mode: FileMode.write);

      _keyFile = File('gnirehtet_pc_key.txt');
      _keySink = _keyFile!.openWrite(mode: FileMode.write);

      final header = '=== Gnirehtet PC 日志 ${DateTime.now()} ===';
      _sink!.writeln(header);
      _keySink!.writeln(header);
      _keySink!.writeln('此文件仅记录关键事件：异常、连接生命周期、DNS、RST/FIN、统计摘要');
      _keySink!.writeln('');
      print(header);
    } catch (e) {
      print('[FileLogger] 初始化失败: $e');
    }
  }

  /// 全量日志：同时打印到控制台和全量日志文件
  static void log(String message) {
    final timestamp = _formatTime(DateTime.now());
    final line = '$timestamp $message';
    print(line);
    _sink?.writeln(line);
  }

  /// 静默日志：仅写入全量日志文件（高频事件避免刷屏）
  static void logQuiet(String message) {
    final timestamp = _formatTime(DateTime.now());
    _sink?.writeln('$timestamp $message');
  }

  /// 关键事件日志：同时写入关键日志文件 + 全量日志文件 + 控制台
  /// 用于：异常、连接生命周期、DNS、TCP RST/FIN、统计摘要
  static void key(String message) {
    final timestamp = _formatTime(DateTime.now());
    final line = '$timestamp $message';
    print(line);
    _sink?.writeln(line);
    _keySink?.writeln(line);
  }

  static void close() {
    final footer = '=== 日志结束 ${DateTime.now()} ===';
    _sink?.writeln(footer);
    _keySink?.writeln(footer);
    _sink?.flush();
    _keySink?.flush();
    _sink?.close();
    _keySink?.close();
    _sink = null;
    _keySink = null;
    print('[FileLogger] 全量日志: ${_logFile?.path}');
    print('[FileLogger] 关键日志: ${_keyFile?.path}');
  }

  static String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}.'
        '${dt.millisecond.toString().padLeft(3, '0')}';
  }
}
