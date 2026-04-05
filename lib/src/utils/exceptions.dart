// 文件路径: lib/src/utils/exceptions.dart

/// 整个路由器项目的异常基类
abstract class RouterException implements Exception {
  final String message;
  final dynamic cause;

  RouterException(this.message, [this.cause]);

  @override
  String toString() {
    if (cause != null) {
      return '$runtimeType: $message (底层原因: $cause)';
    }
    return '$runtimeType: $message';
  }
}

/// ADB 环境或连接相关的异常
class AdbEnvironmentException extends RouterException {
  AdbEnvironmentException(super.message, [super.cause]);
}

/// 底层 libslirp (C语言引擎) 相关的异常
class SlirpEngineException extends RouterException {
  SlirpEngineException(super.message, [super.cause]);
}

/// 端口监听或网络隧道相关的异常
class TunnelNetworkException extends RouterException {
  TunnelNetworkException(super.message, [super.cause]);
}

/// 内存越界或 Native 缓冲池异常
class NativeBufferException extends RouterException {
  NativeBufferException(super.message, [super.cause]);
}