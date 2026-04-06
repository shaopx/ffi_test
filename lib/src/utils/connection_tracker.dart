// 文件路径: lib/src/utils/connection_tracker.dart
//
// 连接级别追踪器：记录每条 TCP/UDP 流的完整生命周期
// 定期输出统计摘要到关键日志，帮助定位"哪些连接失败了、为什么失败"

import 'dart:typed_data';
import 'file_logger.dart';

/// TCP 标志位常量
class TcpFlags {
  static const int FIN = 0x01;
  static const int SYN = 0x02;
  static const int RST = 0x04;
  static const int PSH = 0x08;
  static const int ACK = 0x10;

  static String describe(int flags) {
    final parts = <String>[];
    if (flags & SYN != 0) parts.add('SYN');
    if (flags & ACK != 0) parts.add('ACK');
    if (flags & FIN != 0) parts.add('FIN');
    if (flags & RST != 0) parts.add('RST');
    if (flags & PSH != 0) parts.add('PSH');
    return parts.isEmpty ? 'NONE' : parts.join('+');
  }
}

/// 单条连接的状态
class ConnState {
  final String key;         // "TCP 10.0.2.15:43210→93.184.216.34:443"
  final String protocol;    // TCP / UDP
  final String srcIp;
  final int srcPort;
  final String dstIp;
  final int dstPort;
  final DateTime createdAt;

  int upPackets = 0;        // 上行包数
  int downPackets = 0;      // 下行包数
  int upBytes = 0;          // 上行字节
  int downBytes = 0;        // 下行字节
  int rstCount = 0;         // RST 次数
  int finCount = 0;         // FIN 次数
  bool synSeen = false;     // 是否见过 SYN
  bool synAckSeen = false;  // 是否见过 SYN+ACK
  bool established = false; // 是否建立成功
  String? dnsQuery;         // 如果是 DNS 查询，记录域名
  DateTime lastActivity = DateTime.now();

  ConnState({
    required this.key,
    required this.protocol,
    required this.srcIp,
    required this.srcPort,
    required this.dstIp,
    required this.dstPort,
  }) : createdAt = DateTime.now();

  /// 连接是否"失败"：有 SYN 但无数据交换，或被 RST
  bool get isFailed =>
      (synSeen && !established && downPackets == 0) || rstCount > 0;

  /// 连接寿命
  Duration get lifetime => lastActivity.difference(createdAt);

  @override
  String toString() {
    final status = established
        ? 'OK'
        : (rstCount > 0 ? 'RST!' : (synSeen ? 'SYN未完成' : '?'));
    return '$key [$status] up=$upPackets($upBytes B) down=$downPackets($downBytes B) '
        'rst=$rstCount fin=$finCount life=${lifetime.inSeconds}s'
        '${dnsQuery != null ? " dns=$dnsQuery" : ""}';
  }
}

class ConnectionTracker {
  /// 所有追踪的连接 (key → state)
  static final Map<String, ConnState> _connections = {};

  /// DNS 查询记录 (域名 → 解析结果IP / 超时)
  static final Map<String, String> _dnsResults = {};

  /// 统计计数器
  static int _totalUpPackets = 0;
  static int _totalDownPackets = 0;
  static int _totalUpBytes = 0;
  static int _totalDownBytes = 0;
  static int _droppedPackets = 0;
  static int _stickyPackets = 0;  // 粘包次数
  static DateTime _lastSummaryTime = DateTime.now();

  /// 分析上行 IP 包（手机 → PC → 互联网）
  static void trackUpstream(Uint8List data, int offset, int pktLen) {
    _totalUpPackets++;
    _totalUpBytes += pktLen;

    if (pktLen < 20) return;
    final ver = data[offset] >> 4;
    if (ver != 4) return; // 暂只追踪 IPv4

    final protocol = data[offset + 9];
    final srcIp = _readIp(data, offset + 12);
    final dstIp = _readIp(data, offset + 16);

    if (protocol == 6 && pktLen >= 40) {
      // TCP
      final ihl = (data[offset] & 0x0F) * 4;
      final srcPort = (data[offset + ihl] << 8) | data[offset + ihl + 1];
      final dstPort = (data[offset + ihl + 2] << 8) | data[offset + ihl + 3];
      final flags = data[offset + ihl + 13];

      final key = 'TCP $srcIp:$srcPort→$dstIp:$dstPort';
      final conn = _getOrCreate(key, 'TCP', srcIp, srcPort, dstIp, dstPort);
      conn.upPackets++;
      conn.upBytes += pktLen;
      conn.lastActivity = DateTime.now();

      if (flags & TcpFlags.SYN != 0 && flags & TcpFlags.ACK == 0) {
        conn.synSeen = true;
        FileLogger.key('🔵 [CONN] 新连接 $key (${TcpFlags.describe(flags)})');
      }
      if (flags & TcpFlags.RST != 0) {
        conn.rstCount++;
        FileLogger.key('🔴 [CONN] RST上行 $key');
      }
      if (flags & TcpFlags.FIN != 0) {
        conn.finCount++;
        FileLogger.logQuiet('🟡 [CONN] FIN上行 $key');
      }
    } else if (protocol == 17) {
      // UDP
      final ihl = (data[offset] & 0x0F) * 4;
      if (pktLen < ihl + 8) return;
      final srcPort = (data[offset + ihl] << 8) | data[offset + ihl + 1];
      final dstPort = (data[offset + ihl + 2] << 8) | data[offset + ihl + 3];

      final key = 'UDP $srcIp:$srcPort→$dstIp:$dstPort';
      final conn = _getOrCreate(key, 'UDP', srcIp, srcPort, dstIp, dstPort);
      conn.upPackets++;
      conn.upBytes += pktLen;
      conn.lastActivity = DateTime.now();

      // DNS 查询追踪 (目标端口 53)
      if (dstPort == 53 && pktLen > ihl + 12) {
        final dnsName = _parseDnsQuery(data, offset + ihl + 8 + 12, pktLen - ihl - 8 - 12);
        if (dnsName != null) {
          conn.dnsQuery = dnsName;
          FileLogger.key('🔍 [DNS] 查询 $dnsName (→$dstIp)');
        }
      }

      // QUIC 检测 (UDP 端口 443)
      if (dstPort == 443) {
        FileLogger.key('⚡ [QUIC?] UDP:443 $srcIp:$srcPort→$dstIp:$dstPort (可能是QUIC/HTTP3)');
      }
    }
  }

  // 下行诊断计数器
  static int _downTcpMatched = 0;
  static int _downTcpUnmatched = 0;
  static int _downTcpSynAck = 0;
  static int _unmatchedLogCount = 0;

  /// 分析下行 IP 包（互联网 → PC → 手机）
  static void trackDownstream(Uint8List data) {
    _totalDownPackets++;
    _totalDownBytes += data.length;

    if (data.length < 20) return;
    final ver = data[0] >> 4;
    if (ver != 4) return;

    final protocol = data[9];
    final srcIp = _readIp(data, 12);
    final dstIp = _readIp(data, 16);

    if (protocol == 6 && data.length >= 40) {
      // TCP
      final ihl = (data[0] & 0x0F) * 4;
      if (ihl + 14 > data.length) return; // 防越界
      final srcPort = (data[ihl] << 8) | data[ihl + 1];
      final dstPort = (data[ihl + 2] << 8) | data[ihl + 3];
      final flags = data[ihl + 13];

      // 注意：下行包的 src/dst 与上行是反的
      final key = 'TCP $dstIp:$dstPort→$srcIp:$srcPort';
      final conn = _connections[key];

      if (conn != null) {
        _downTcpMatched++;
        conn.downPackets++;
        conn.downBytes += data.length;
        conn.lastActivity = DateTime.now();

        if ((flags & TcpFlags.SYN) != 0 && (flags & TcpFlags.ACK) != 0) {
          conn.synAckSeen = true;
          conn.established = true;
          _downTcpSynAck++;
          FileLogger.key('🟢 [CONN] 连接建立 $key (SYN+ACK flags=0x${flags.toRadixString(16)})');
        }

        // 记录首次收到数据的连接（不含 SYN+ACK，说明连接已通过其他方式建立）
        if (conn.downPackets == 1 && data.length > 60) {
          FileLogger.key('📨 [CONN] 首次下行数据 $key ${data.length}B flags=${TcpFlags.describe(flags)}(0x${flags.toRadixString(16)})');
          // 如果有数据流但没检测到 SYN+ACK，也标记为建立
          if ((flags & TcpFlags.ACK) != 0 && !conn.established) {
            conn.established = true;
            FileLogger.key('🟢 [CONN] 数据流建立 $key (ACK+数据, 无SYN+ACK检测)');
          }
        }

        if ((flags & TcpFlags.RST) != 0) {
          conn.rstCount++;
          FileLogger.key('🔴 [CONN] RST下行 $key (来自$srcIp:$srcPort)');
        }
        if ((flags & TcpFlags.FIN) != 0) {
          conn.finCount++;
        }
      } else {
        _downTcpUnmatched++;
        // 前 20 条未匹配记录详细日志
        if (_unmatchedLogCount < 20) {
          _unmatchedLogCount++;
          FileLogger.key('❓ [CONN] 下行未匹配! key=$key flags=${TcpFlags.describe(flags)} ${data.length}B '
              'src=$srcIp:$srcPort dst=$dstIp:$dstPort 已知连接=${_connections.length}');
        }
      }
    } else if (protocol == 17) {
      // UDP
      final ihl = (data[0] & 0x0F) * 4;
      if (data.length < ihl + 8) return;
      final srcPort = (data[ihl] << 8) | data[ihl + 1];
      final dstPort = (data[ihl + 2] << 8) | data[ihl + 3];

      // DNS 响应
      if (srcPort == 53) {
        final key = 'UDP $dstIp:$dstPort→$srcIp:$srcPort';
        final conn = _connections[key];
        if (conn != null) {
          conn.downPackets++;
          conn.downBytes += data.length;
          conn.lastActivity = DateTime.now();
          if (conn.dnsQuery != null) {
            // 尝试解析 DNS 响应中的 IP
            final resultIp = _parseDnsResponseIp(data, ihl + 8, data.length - ihl - 8);
            final result = resultIp ?? 'OK';
            _dnsResults[conn.dnsQuery!] = result;
            FileLogger.key('🔍 [DNS] 应答 ${conn.dnsQuery} → $result');
          }
        }
      }
    }
  }

  /// 记录粘包事件
  static void recordStickyPacket(int totalBytes, int packetCount) {
    _stickyPackets++;
    FileLogger.key('📦 [粘包] 一次TCP交付${totalBytes}字节 含${packetCount}个IP包 (累计粘包$_stickyPackets次)');
  }

  /// 记录丢包事件
  static void recordDroppedPacket(String reason) {
    _droppedPackets++;
    FileLogger.key('💀 [丢包] $reason (累计$_droppedPackets次)');
  }

  /// 输出统计摘要（由引擎心跳定期调用）
  static void printSummary() {
    final now = DateTime.now();
    final elapsed = now.difference(_lastSummaryTime).inSeconds;
    if (elapsed < 10) return; // 每 10 秒最多一次
    _lastSummaryTime = now;

    final totalConns = _connections.length;
    final activeConns = _connections.values
        .where((c) => now.difference(c.lastActivity).inSeconds < 30)
        .length;
    final failedConns = _connections.values.where((c) => c.isFailed).toList();
    final rstConns = _connections.values.where((c) => c.rstCount > 0).toList();
    final pendingSyn = _connections.values
        .where((c) => c.synSeen && !c.established && c.rstCount == 0 &&
                       now.difference(c.createdAt).inSeconds > 5)
        .toList();

    // DNS 统计
    final dnsQueries = _connections.values.where((c) => c.dnsQuery != null).toList();
    final dnsNoReply = dnsQueries.where((c) => c.downPackets == 0).toList();

    // QUIC 统计
    final quicConns = _connections.values
        .where((c) => c.protocol == 'UDP' && c.dstPort == 443)
        .toList();

    final establishedConns = _connections.values.where((c) => c.established).length;
    final dataFlowConns = _connections.values
        .where((c) => c.downBytes > 100 && !c.established)
        .length;

    FileLogger.key('');
    FileLogger.key('═══════════════════════════════════════════════════════');
    FileLogger.key('📊 [统计] 总连接=$totalConns 活跃=$activeConns 已建立=$establishedConns '
        '上行=${_totalUpPackets}包/${_formatBytes(_totalUpBytes)} '
        '下行=${_totalDownPackets}包/${_formatBytes(_totalDownBytes)}');
    FileLogger.key('📊 [统计] 粘包=$_stickyPackets次 丢包=$_droppedPackets次');
    FileLogger.key('📊 [下行匹配] TCP匹配=$_downTcpMatched 未匹配=$_downTcpUnmatched SYN+ACK=$_downTcpSynAck '
        '有数据流但未标记建立=$dataFlowConns');

    if (failedConns.isNotEmpty) {
      FileLogger.key('🔴 [统计] 失败连接=${failedConns.length}条:');
      for (final c in failedConns.take(10)) {
        FileLogger.key('   → $c');
      }
    }

    if (rstConns.isNotEmpty) {
      FileLogger.key('🔴 [统计] RST连接=${rstConns.length}条:');
      for (final c in rstConns.take(10)) {
        FileLogger.key('   → $c');
      }
    }

    if (pendingSyn.isNotEmpty) {
      FileLogger.key('🟡 [统计] SYN未完成(>5s)=${pendingSyn.length}条:');
      for (final c in pendingSyn.take(10)) {
        FileLogger.key('   → $c');
      }
    }

    if (dnsNoReply.isNotEmpty) {
      FileLogger.key('🔴 [统计] DNS无应答=${dnsNoReply.length}条:');
      for (final c in dnsNoReply.take(10)) {
        FileLogger.key('   → ${c.dnsQuery}');
      }
    }

    if (quicConns.isNotEmpty) {
      FileLogger.key('⚡ [统计] QUIC/UDP:443=${quicConns.length}条 '
          '(有应答=${quicConns.where((c) => c.downPackets > 0).length}条)');
    }

    // DNS 解析结果一览
    if (_dnsResults.isNotEmpty) {
      FileLogger.key('🔍 [DNS结果] 共${_dnsResults.length}条:');
      _dnsResults.forEach((domain, result) {
        FileLogger.key('   $domain → $result');
      });
    }

    FileLogger.key('═══════════════════════════════════════════════════════');
    FileLogger.key('');

    // 清理超过 60 秒无活动的已完成连接，防止内存膨胀
    _connections.removeWhere((key, conn) =>
        now.difference(conn.lastActivity).inSeconds > 60 &&
        (conn.finCount > 0 || conn.rstCount > 0));
  }

  // ========================================================================
  // 内部工具方法
  // ========================================================================

  static ConnState _getOrCreate(
      String key, String protocol, String srcIp, int srcPort, String dstIp, int dstPort) {
    return _connections.putIfAbsent(
        key,
        () => ConnState(
            key: key,
            protocol: protocol,
            srcIp: srcIp,
            srcPort: srcPort,
            dstIp: dstIp,
            dstPort: dstPort));
  }

  static String _readIp(Uint8List data, int offset) {
    return '${data[offset]}.${data[offset + 1]}.${data[offset + 2]}.${data[offset + 3]}';
  }

  /// 简易 DNS 域名解析（从查询段提取域名）
  static String? _parseDnsQuery(Uint8List data, int offset, int remaining) {
    if (remaining < 2) return null;
    final parts = <String>[];
    int pos = offset;
    while (pos < data.length) {
      final labelLen = data[pos];
      if (labelLen == 0) break;
      if (labelLen > 63 || pos + labelLen + 1 > data.length) break;
      pos++;
      try {
        parts.add(String.fromCharCodes(data.sublist(pos, pos + labelLen)));
      } catch (_) {
        break;
      }
      pos += labelLen;
    }
    return parts.isEmpty ? null : parts.join('.');
  }

  /// 尝试从 DNS 响应中提取第一个 A 记录的 IP
  static String? _parseDnsResponseIp(Uint8List data, int dnsOffset, int dnsLen) {
    if (dnsLen < 12) return null;
    try {
      // DNS header: ID(2) + Flags(2) + QDCount(2) + ANCount(2) + ...
      final anCount = (data[dnsOffset + 6] << 8) | data[dnsOffset + 7];
      if (anCount == 0) return 'NXDOMAIN/空';

      // 跳过 Question section
      int pos = dnsOffset + 12;
      // 跳过 QNAME
      while (pos < data.length && data[pos] != 0) {
        if (data[pos] >= 0xC0) {
          pos += 2; // 压缩指针
          break;
        }
        pos += data[pos] + 1;
      }
      if (pos < data.length && data[pos] == 0) pos++; // 终止零
      pos += 4; // QTYPE + QCLASS

      // 解析第一个 Answer
      for (int i = 0; i < anCount && pos + 12 <= data.length; i++) {
        // Name (可能是压缩指针)
        if (data[pos] >= 0xC0) {
          pos += 2;
        } else {
          while (pos < data.length && data[pos] != 0) {
            pos += data[pos] + 1;
          }
          pos++; // 终止零
        }
        if (pos + 10 > data.length) break;
        final rtype = (data[pos] << 8) | data[pos + 1];
        final rdlen = (data[pos + 8] << 8) | data[pos + 9];
        pos += 10;
        if (rtype == 1 && rdlen == 4 && pos + 4 <= data.length) {
          // A 记录
          return '${data[pos]}.${data[pos + 1]}.${data[pos + 2]}.${data[pos + 3]}';
        }
        pos += rdlen;
      }
      return '${anCount}条记录';
    } catch (_) {
      return '解析失败';
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }
}
