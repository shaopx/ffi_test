// 文件路径: lib/src/network/adb_manager.dart

import 'dart:io';

class AdbManager {
  final String adbPath;

  /// 允许外部传入自定义的 adb 路径，如果不传，默认使用系统环境变量中的 'adb'
  AdbManager({this.adbPath = 'adb'});

  /// 检查 ADB 环境和设备连接状态
  Future<bool> checkEnvironment() async {
    try {
      final result = await Process.run(adbPath, ['devices']);
      if (result.exitCode != 0) {
        print('[AdbManager] ADB 运行失败: ${result.stderr}');
        return false;
      }

      final output = result.stdout.toString();
      // 简单的逻辑：如果输出只有 "List of devices attached" 加上空行，说明没设备
      final lines = output.trim().split('\n');
      if (lines.length <= 1) {
        print('[AdbManager] 错误：未检测到已连接的 Android 设备。');
        return false;
      }

      print('[AdbManager] ADB 环境正常，已检测到设备。');
      return true;
    } catch (e) {
      print('[AdbManager] 致命错误：无法找到 adb 命令，请确保已安装 ADB 并加入环境变量。异常: $e');
      return false;
    }
  }

  /// 建立反向网络隧道 (Reverse Forwarding)
  /// [devicePort] 手机端 App 请求的端口 (例如 31416)
  /// [localPort] 电脑端 Dart Server 监听的端口 (例如 31416)
  Future<void> enableReverseTethering(int devicePort, int localPort) async {
    print('[AdbManager] 正在建立反向隧道 (Device:$devicePort -> PC:$localPort)...');
    
    // 执行: adb reverse tcp:31416 tcp:31416
    final result = await Process.run(adbPath, [
      'reverse',
      'tcp:$devicePort',
      'tcp:$localPort'
    ]);

    if (result.exitCode != 0) {
      throw Exception('建立 ADB Reverse 隧道失败: ${result.stderr}');
    }
    
    print('[AdbManager] 反向隧道建立成功！手机端的请求将被引流至电脑。');
  }

  /// 拆除隧道，清理资源
  Future<void> disableReverseTethering(int devicePort) async {
    print('[AdbManager] 正在拆除反向隧道...');
    final result = await Process.run(adbPath, [
      'reverse',
      '--remove',
      'tcp:$devicePort'
    ]);

    if (result.exitCode != 0) {
      print('[AdbManager] 警告：拆除隧道失败，可能是设备已断开: ${result.stderr}');
    } else {
      print('[AdbManager] 反向隧道已彻底清除。');
    }
  }
}