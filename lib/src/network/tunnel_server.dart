// 文件路径: lib/src/network/tunnel_server.dart

import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import '../utils/file_logger.dart';
import '../utils/connection_tracker.dart';

/// 负责监听本地端口，接收来自 ADB Tunnel 的真实字节流
class TunnelServer {
  // Dart 原生的 Socket 服务器端
  ServerSocket? _serverSocket;
  
  // 当前正在活跃的手机端连接
  Socket? _activeClient;

  // 业务层回调：当收到手机发来的数据时触发
  final void Function(Uint8List data) onPacketReceived;
  
  // 业务层回调：当手机断开连接时触发 (用于通知外层重置路由或 UI)
  final void Function() onClientDisconnected;

  bool _isRunning = false;

  TunnelServer({
    required this.onPacketReceived,
    required this.onClientDisconnected,
  });

  /// 启动本地服务器，开始监听
  /// [port] 必须与 adb reverse 中配置的 localPort 保持一致
  Future<void> start(int port) async {
    if (_isRunning) {
      print('[TunnelServer] 警告：服务器已在运行中，请勿重复启动。');
      return;
    }

    try {
      // 绑定到本地回环地址 (127.0.0.1)，这样最安全，防止局域网内其他电脑蹭网
      _serverSocket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      _isRunning = true;
      print('[TunnelServer] 启动成功！正在监听本地端口: $port');

      // 持续监听来自手机端 (通过 adb reverse 转发过来) 的连接请求
      _serverSocket!.listen(
        _handleNewClient,
        onError: (error) {
          print('[TunnelServer] ServerSocket 发生严重异常: $error');
          stop();
        },
        cancelOnError: true,
      );
    } catch (e) {
      _isRunning = false;
      throw Exception('TunnelServer 启动失败，端口 $port 可能已被占用！错误: $e');
    }
  }

  /// 处理新的客户端连接
  void _handleNewClient(Socket client) {
    FileLogger.log('[TunnelServer] ⚡ 收到新的设备连接请求！远程端口: ${client.remotePort}');

    // 【生产级防御】踢掉旧连接，确保通道唯一性
    if (_activeClient != null) {
      print('[TunnelServer] 警告：检测到旧的存活连接，正在强制断开并替换为新连接...');
      _activeClient!.destroy();
      _activeClient = null;
    }

    _activeClient = client;

    // 禁用 Nagle 算法，降低网络延迟。这对于游戏、视频流等实时网络包极其重要！
    client.setOption(SocketOption.tcpNoDelay, true);

    // 监听数据流
    client.listen(
      (Uint8List data) {
        _debugAnalyzePacket(data);
        // 收到来自手机的字节流，直接甩给外层的 SlirpWrapper
        onPacketReceived(data);
      },
      onError: (error) {
        print('[TunnelServer] ❌ 客户端 Socket 发生读写错误: $error');
        _cleanupActiveClient();
      },
      onDone: () {
        print('[TunnelServer] 🔌 客户端主动断开了连接 (正常结束)。');
        _cleanupActiveClient();
      },
      cancelOnError: true,
    );
  }

  /// 发送数据给手机端 (通常是由 libslirp 处理完外网数据后，调用的回传动作)
  int _downstreamPacketCount = 0;

  void sendToDevice(Uint8List data) {
    if (_activeClient == null) {
      print('❌ [TunnelServer] 致命拦截：没有活跃的手机连接(_activeClient 为空)，数据被抛弃！');
      return;
    }

    _downstreamPacketCount++;
    final seq = _downstreamPacketCount;

    try {
      // 下行连���追踪
      if (data.isNotEmpty) {
        ConnectionTracker.trackDownstream(data);
        // 前 50 个下行包：dump IP 头部，用于诊断 IP 匹配问题
        if (seq <= 50 && data.length >= 20) {
          final ver = data[0] >> 4;
          if (ver == 4) {
            final proto = data[9];
            final srcIp = '${data[12]}.${data[13]}.${data[14]}.${data[15]}';
            final dstIp = '${data[16]}.${data[17]}.${data[18]}.${data[19]}';
            final ihl = (data[0] & 0x0F) * 4;
            String portInfo = '';
            if (data.length >= ihl + 4) {
              final srcPort = (data[ihl] << 8) | data[ihl + 1];
              final dstPort = (data[ihl + 2] << 8) | data[ihl + 3];
              portInfo = ' ports=$srcPort→$dstPort';
            }
            String flagInfo = '';
            if (proto == 6 && data.length >= ihl + 14) {
              final flags = data[ihl + 13];
              flagInfo = ' flags=0x${flags.toRadixString(16)}(${_describeFlags(flags)})';
            }
            FileLogger.key('🔬 [DOWN#$seq] ${data.length}B IPv$ver proto=$proto $srcIp���$dstIp$portInfo$flagInfo');
          }
        }
      }
      FileLogger.logQuiet('🚀 [DOWN#$seq] ${data.length}字节');

      _activeClient!.add(data);
    } catch (e) {
      print('❌ [TunnelServer] 向 Socket 写入时发生物理异常: $e');
    }
  }

  /// 清理当前活跃的客户端并触发回调
  void _cleanupActiveClient() {
    if (_activeClient != null) {
      try {
        _activeClient!.destroy();
      } catch (e) {
        // 忽略销毁时的异常
      }
      _activeClient = null;
      print('[TunnelServer] 🧹 已清理失效的设备连接。');
      
      // 通知外层大脑 (RouterEngine)，让它去清理底层的 C 语言内存
      onClientDisconnected();
    }
  }

  // ========================================================================
  // 调试分析：深度检查每个 TCP 接收到的数据
  // ========================================================================
  int _upstreamPacketCount = 0;

  void _debugAnalyzePacket(Uint8List data) {
    _upstreamPacketCount++;
    final seq = _upstreamPacketCount;

    if (data.isEmpty) {
      FileLogger.key('⚠️ [UP#$seq] 收到空数据！');
      return;
    }

    // 检查粘包：计算实际包含几个 IP 包
    int offset = 0;
    int packetCount = 0;
    while (offset < data.length) {
      final ver = data[offset] >> 4;
      int pktLen = data.length - offset;
      if (ver == 4 && data.length - offset >= 20) {
        pktLen = (data[offset + 2] << 8) | data[offset + 3];
      } else if (ver == 6 && data.length - offset >= 40) {
        pktLen = ((data[offset + 4] << 8) | data[offset + 5]) + 40;
      }
      if (pktLen <= 0 || pktLen > data.length - offset) break;

      // 将每个独立 IP 包送入连接追踪器
      ConnectionTracker.trackUpstream(data, offset, pktLen);
      packetCount++;
      offset += pktLen;
    }

    if (packetCount > 1) {
      ConnectionTracker.recordStickyPacket(data.length, packetCount);
    }

    // 静默记录到全量日志
    FileLogger.logQuiet('📦 [UP#$seq] ${data.length}字节 含${packetCount}个IP包');
  }

  static String _describeFlags(int flags) {
    final parts = <String>[];
    if (flags & 0x02 != 0) parts.add('SYN');
    if (flags & 0x10 != 0) parts.add('ACK');
    if (flags & 0x01 != 0) parts.add('FIN');
    if (flags & 0x04 != 0) parts.add('RST');
    if (flags & 0x08 != 0) parts.add('PSH');
    return parts.isEmpty ? 'NONE' : parts.join('+');
  }

  /// 彻底关闭服务器 (用于退出 App 时)
  Future<void> stop() async {
    print('[TunnelServer] 准备彻底关闭服务器...');
    _cleanupActiveClient();
    
    if (_serverSocket != null) {
      await _serverSocket!.close();
      _serverSocket = null;
    }
    _isRunning = false;
    print('[TunnelServer] 服务器已安全停止。');
  }
}