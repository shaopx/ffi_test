// 文件路径: lib/src/ffi/slirp_wrapper.dart

import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

import 'slirp_bindings.dart';
import '../utils/file_logger.dart';
import 'dart:async';

typedef OnSendDataCallback = void Function(Uint8List data);

// ========================================================================
// libc poll() 相关的 FFI 定义 (macOS/Linux)
// struct pollfd { int fd; short events; short revents; }
// int poll(struct pollfd *fds, nfds_t nfds, int timeout);
// ========================================================================
final class PollFd extends ffi.Struct {
  @ffi.Int32()
  external int fd;

  @ffi.Int16()
  external int events;

  @ffi.Int16()
  external int revents;
}

typedef PollNative = ffi.Int32 Function(
    ffi.Pointer<PollFd>, ffi.UnsignedLong, ffi.Int32);
typedef PollDart = int Function(ffi.Pointer<PollFd>, int, int);

class SlirpWrapper {
  final SlirpBindings _bindings;
  ffi.Pointer<Slirp> _slirpInstance = ffi.nullptr;
  final OnSendDataCallback onSendData;

  Timer? _engineTimer;

  static int _instanceCounter = 0;
  final int _wrapperId;
  static final Map<int, SlirpWrapper> _wrapperRegistry = {};

  ffi.Pointer<SlirpCb> _savedCallbacks = ffi.nullptr;
  ffi.Pointer<SlirpConfig> _savedConfig = ffi.nullptr;

  // libc poll() 函数指针
  static late final PollDart _nativePoll;
  static bool _pollLoaded = false;

  SlirpWrapper(this._bindings, {required this.onSendData})
      : _wrapperId = ++_instanceCounter {
    _wrapperRegistry[_wrapperId] = this;

    // 加载 libc 的 poll() 函数（只加载一次）
    if (!_pollLoaded) {
      final libc = ffi.DynamicLibrary.process(); // macOS: 当前进程就能找到 libc
      _nativePoll = libc.lookupFunction<PollNative, PollDart>('poll');
      _pollLoaded = true;
      print('[SlirpWrapper] libc poll() 加载成功');
    }
  }

  // ========================================================================
  // 真实 poll() 驱动器：用 libc poll() 替代盲轮询
  // ========================================================================

  // 存储 libslirp 注册的 (fd, events) 对
  static final List<int> _pollFds = [];
  static final List<int> _pollRequestedEvents = [];
  // poll() 返回的真实 revents
  static final List<int> _pollRevents = [];

  static int _cAddPoll(int fd, int events, ffi.Pointer<ffi.Void> opaque) {
    final idx = _pollFds.length;
    _pollFds.add(fd);
    _pollRequestedEvents.add(events);
    _pollRevents.add(0); // 先填 0，后面 poll() 会更新
    return idx;
  }

  static int _cGetREvents(int idx, ffi.Pointer<ffi.Void> opaque) {
    if (idx >= 0 && idx < _pollRevents.length) {
      return _pollRevents[idx];
    }
    return 0;
  }

  // ========================================================================
  // ARP 幽灵回应器
  // ========================================================================
  static bool _isInsideCallback = false;

  void _sendArpReplyToSlirp(Uint8List arpReply) {
    if (_slirpInstance == ffi.nullptr) return;
    if (_isInsideCallback) {
      // 延迟到下一个事件循环，避免在 C 回调内递归调用 C 函数
      final reply = Uint8List.fromList(arpReply);
      Timer.run(() => _sendArpReplyToSlirp(reply));
      return;
    }
    final nativeDataPtr = malloc.allocate<ffi.Uint8>(arpReply.length);
    nativeDataPtr.asTypedList(arpReply.length).setAll(0, arpReply);
    _bindings.slirp_input(_slirpInstance, nativeDataPtr.cast(), arpReply.length);
    malloc.free(nativeDataPtr);
  }

  // 调试计数器
  int _driveCount = 0;
  int _lastLoggedDriveCount = 0;
  DateTime _lastDriveLogTime = DateTime.now();

  void _driveEngine() {
    if (_slirpInstance == ffi.nullptr) return;

    _driveCount++;

    // 每 5 秒打印一次引擎心跳
    final now = DateTime.now();
    if (now.difference(_lastDriveLogTime).inSeconds >= 5) {
      final rate = _driveCount - _lastLoggedDriveCount;
      FileLogger.log('💓 [引擎心跳] 轮询#$_driveCount, 5秒内$rate次, socket=${_pollFds.length}');
      _lastLoggedDriveCount = _driveCount;
      _lastDriveLogTime = now;
    }

    final timeoutPtr = calloc<ffi.Uint32>();
    timeoutPtr.value = 0;

    final addPollPtr = ffi.Pointer.fromFunction<
        ffi.Int Function(ffi.Int, ffi.Int, ffi.Pointer<ffi.Void>)
    >(_cAddPoll, 0);

    final getREventsPtr = ffi.Pointer.fromFunction<
        ffi.Int Function(ffi.Int, ffi.Pointer<ffi.Void>)
    >(_cGetREvents, 0);

    // 1. 清空上一轮的记录
    _pollFds.clear();
    _pollRequestedEvents.clear();
    _pollRevents.clear();

    // 2. 让 libslirp 注册它关心的 fd 和 events
    _bindings.slirp_pollfds_fill(
        _slirpInstance,
        timeoutPtr,
        addPollPtr,
        ffi.nullptr
    );

    // 3. 【核心改进】用真正的 poll() 系统调用检测 socket 就绪状态
    final nfds = _pollFds.length;
    if (nfds > 0) {
      // 分配 C 结构体数组
      final pollFdsPtr = calloc<PollFd>(nfds);
      for (int i = 0; i < nfds; i++) {
        pollFdsPtr[i].fd = _pollFds[i];
        pollFdsPtr[i].events = _pollRequestedEvents[i];
        pollFdsPtr[i].revents = 0;
      }

      // 调用 libc poll()，timeout=0 表示不阻塞，立即返回
      _nativePoll(pollFdsPtr, nfds, 0);

      // 读取真实的 revents
      for (int i = 0; i < nfds; i++) {
        _pollRevents[i] = pollFdsPtr[i].revents;
      }

      calloc.free(pollFdsPtr);
    }

    // 4. 通知 libslirp 真实的事件结果
    _bindings.slirp_pollfds_poll(
        _slirpInstance,
        0,
        getREventsPtr,
        ffi.nullptr
    );

    calloc.free(timeoutPtr);
  }

  void init() {
    if (_slirpInstance != ffi.nullptr) {
      throw Exception('Slirp 引擎已经初始化，请勿重复调用！');
    }

    final callbacksPtr = calloc<ffi.Uint8>(512).cast<SlirpCb>();
    final configPtr = calloc<ffi.Uint8>(512).cast<SlirpConfig>();

    callbacksPtr.ref.send_packet = ffi.Pointer.fromFunction<
        ffi.Long Function(ffi.Pointer<ffi.Void>, ffi.Size, ffi.Pointer<ffi.Void>)
    >(_cSendPacketCallback, 0);

    final opaquePtr = ffi.Pointer.fromAddress(_wrapperId).cast<ffi.Void>();

    configPtr.ref.version = 1;
    configPtr.ref.in_enabled = true;
    configPtr.ref.in6_enabled = false;

    configPtr.ref.vnetwork.s_addr = _parseIp('10.0.2.0');
    configPtr.ref.vnetmask.s_addr = _parseIp('255.255.255.0');
    configPtr.ref.vhost.s_addr = _parseIp('10.0.2.2');
    configPtr.ref.vnameserver.s_addr = _parseIp('10.0.2.3');

    callbacksPtr.ref.send_packet = ffi.Pointer.fromFunction<
        ffi.Long Function(ffi.Pointer<ffi.Void>, ffi.Size, ffi.Pointer<ffi.Void>)
    >(_cSendPacketCallback, 0);

    callbacksPtr.ref.register_poll_fd = ffi.Pointer.fromFunction<
        ffi.Void Function(ffi.Int, ffi.Pointer<ffi.Void>)
    >(_cRegisterPollFd);

    callbacksPtr.ref.unregister_poll_fd = ffi.Pointer.fromFunction<
        ffi.Void Function(ffi.Int, ffi.Pointer<ffi.Void>)
    >(_cUnregisterPollFd);

    callbacksPtr.ref.notify = ffi.Pointer.fromFunction<
        ffi.Void Function(ffi.Pointer<ffi.Void>)
    >(_cNotify);

    callbacksPtr.ref.clock_get_ns = ffi.Pointer.fromFunction<
        ffi.Int64 Function(ffi.Pointer<ffi.Void>)
    >(_cClockGetNs, 0);

    callbacksPtr.ref.timer_new = ffi.Pointer.fromFunction<
        ffi.Pointer<ffi.Void> Function(
            ffi.Pointer<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>
        )
    >(_cTimerNew);

    callbacksPtr.ref.timer_free = ffi.Pointer.fromFunction<
        ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)
    >(_cTimerFree);

    callbacksPtr.ref.timer_mod = ffi.Pointer.fromFunction<
        ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int64, ffi.Pointer<ffi.Void>)
    >(_cTimerMod);

    _slirpInstance = _bindings.slirp_new(configPtr, callbacksPtr, opaquePtr);

    _savedCallbacks = callbacksPtr;
    _savedConfig = configPtr;

    if (_slirpInstance == ffi.nullptr) {
      throw Exception('底层 libslirp 初始化失败，返回了空指针。');
    }

    _engineTimer = Timer.periodic(const Duration(milliseconds: 10), (_) {
      _driveEngine();
    });
  }

  int _parseIp(String ip) {
    final parts = ip.split('.').map(int.parse).toList();
    return (parts[3] << 24) | (parts[2] << 16) | (parts[1] << 8) | parts[0];
  }

  void inputFromDevice(Uint8List data) {
    if (_slirpInstance == ffi.nullptr || data.isEmpty) return;

    // 粘包处理：循环喂入所有完整 IP 包
    int offset = 0;
    while (offset < data.length) {
      final remaining = data.length - offset;
      final ver = data[offset] >> 4;
      int pktLen = remaining;

      if (ver == 4 && remaining >= 20) {
        pktLen = (data[offset + 2] << 8) | data[offset + 3];
      } else if (ver == 6 && remaining >= 40) {
        pktLen = ((data[offset + 4] << 8) | data[offset + 5]) + 40;
      }

      if (pktLen <= 0 || pktLen > remaining) {
        // 数据不完整或者长度异常，丢弃剩余
        break;
      }

      final pktIsIPv6 = ver == 6;
      final ethHigh = pktIsIPv6 ? 0x86 : 0x08;
      final ethLow  = pktIsIPv6 ? 0xDD : 0x00;

      final frameLength = 14 + pktLen;
      final nativeDataPtr = malloc.allocate<ffi.Uint8>(frameLength);
      final nativeView = nativeDataPtr.asTypedList(frameLength);

      nativeView.setAll(0, [
        0x52, 0x54, 0x00, 0x12, 0x34, 0x56,
        0x52, 0x54, 0x00, 0x12, 0x34, 0x57,
        ethHigh, ethLow
      ]);
      nativeView.setRange(14, frameLength, data, offset);

      _bindings.slirp_input(_slirpInstance, nativeDataPtr.cast(), frameLength);
      malloc.free(nativeDataPtr);

      offset += pktLen;
    }
  }

  void dispose() {
    _engineTimer?.cancel();
    if (_slirpInstance != ffi.nullptr) {
      _bindings.slirp_cleanup(_slirpInstance);
      _slirpInstance = ffi.nullptr;
    }
    _wrapperRegistry.remove(_wrapperId);

    if (_savedCallbacks != ffi.nullptr) {
      calloc.free(_savedCallbacks);
      _savedCallbacks = ffi.nullptr;
    }
    if (_savedConfig != ffi.nullptr) {
      calloc.free(_savedConfig);
      _savedConfig = ffi.nullptr;
    }
  }

  // ========================================================================
  // send_packet 回调
  // ========================================================================
  static int _cSendPacketCallback(ffi.Pointer<ffi.Void> pkt, int pktLen, ffi.Pointer<ffi.Void> opaque) {

    final wrapperId = opaque.address;
    final wrapper = _wrapperRegistry[wrapperId];
    if (wrapper == null) return -1;

    _isInsideCallback = true;
    final nativeBytes = pkt.cast<ffi.Uint8>().asTypedList(pktLen);

    if (pktLen > 14) {
      final etherTypeHigh = nativeBytes[12];
      final etherTypeLow = nativeBytes[13];

      // ARP 截获与回应
      if (etherTypeHigh == 0x08 && etherTypeLow == 0x06) {
        if (nativeBytes.length >= 42 && nativeBytes[20] == 0x00 && nativeBytes[21] == 0x01) {
          final arpReply = Uint8List(42);
          arpReply.setRange(0, 6, nativeBytes.sublist(6, 12));
          arpReply.setAll(6, [0x52, 0x54, 0x00, 0x12, 0x34, 0x57]);
          arpReply.setAll(12, [0x08, 0x06]);
          arpReply.setRange(14, 20, nativeBytes.sublist(14, 20));
          arpReply.setAll(20, [0x00, 0x02]);
          arpReply.setAll(22, [0x52, 0x54, 0x00, 0x12, 0x34, 0x57]);
          arpReply.setRange(28, 32, nativeBytes.sublist(38, 42));
          arpReply.setRange(32, 38, nativeBytes.sublist(22, 28));
          arpReply.setRange(38, 42, nativeBytes.sublist(28, 32));
          wrapper._sendArpReplyToSlirp(arpReply);
        }
        _isInsideCallback = false;
        return pktLen;
      }

      final isIPv4 = (etherTypeHigh == 0x08 && etherTypeLow == 0x00);
      final isIPv6 = (etherTypeHigh == 0x86 && etherTypeLow == 0xDD);

      if (isIPv4 || isIPv6) {
        final paddedIpData = nativeBytes.sublist(14);
        if (paddedIpData.isEmpty) {
          _isInsideCallback = false;
          return pktLen;
        }

        int actualIpLength = paddedIpData.length;
        if (isIPv4 && paddedIpData.length >= 20) {
          actualIpLength = (paddedIpData[2] << 8) | paddedIpData[3];
        } else if (isIPv6 && paddedIpData.length >= 40) {
          actualIpLength = ((paddedIpData[4] << 8) | paddedIpData[5]) + 40;
        }

        if (actualIpLength > 0 && actualIpLength <= paddedIpData.length) {
          final pureIpData = Uint8List.fromList(paddedIpData.sublist(0, actualIpLength));
          wrapper.onSendData(pureIpData);
        }
      }
    }

    _isInsideCallback = false;
    return pktLen;
  }

  // ========================================================================
  // 底层回调
  // ========================================================================

  static void _cRegisterPollFd(int fd, ffi.Pointer<ffi.Void> opaque) {
    if (fd < 0) return;
    print('🔗 [Slirp] 注册 Socket FD=$fd');
  }

  static void _cUnregisterPollFd(int fd, ffi.Pointer<ffi.Void> opaque) {
    if (fd < 0) return;
    print('🔗 [Slirp] 注销 Socket FD=$fd');
  }

  static void _cNotify(ffi.Pointer<ffi.Void> opaque) {}

  static int _cClockGetNs(ffi.Pointer<ffi.Void> opaque) {
    return DateTime.now().microsecondsSinceEpoch * 1000;
  }

  static ffi.Pointer<ffi.Void> _cTimerNew(
      ffi.Pointer<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>> cb,
      ffi.Pointer<ffi.Void> cbOpaque,
      ffi.Pointer<ffi.Void> opaque) {
    return calloc<ffi.Uint64>(1).cast<ffi.Void>();
  }

  static void _cTimerFree(ffi.Pointer<ffi.Void> timer, ffi.Pointer<ffi.Void> opaque) {
    if (timer != ffi.nullptr) {
      calloc.free(timer);
    }
  }

  static void _cTimerMod(ffi.Pointer<ffi.Void> timer, int expireTime, ffi.Pointer<ffi.Void> opaque) {
    // TODO: 实现定时器调度
  }
}
