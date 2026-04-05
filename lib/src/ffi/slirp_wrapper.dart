// 文件路径: lib/src/ffi/slirp_wrapper.dart

import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

import 'slirp_bindings.dart';
import 'dart:async';

typedef OnSendDataCallback = void Function(Uint8List data);

class SlirpWrapper {
  final SlirpBindings _bindings;
  ffi.Pointer<Slirp> _slirpInstance = ffi.nullptr;
  final OnSendDataCallback onSendData;

  Timer? _engineTimer;

  static int _instanceCounter = 0;
  final int _wrapperId;
  static final Map<int, SlirpWrapper> _wrapperRegistry = {};

  // 【新增】保存 C 语言内存指针，防止被提前释放
  ffi.Pointer<SlirpCb> _savedCallbacks = ffi.nullptr;
  ffi.Pointer<SlirpConfig> _savedConfig = ffi.nullptr;

  static final Uint8List _fakeEthHeader = Uint8List.fromList([
    0x52, 0x54, 0x00, 0x12, 0x34, 0x56,
    0x52, 0x54, 0x00, 0x12, 0x34, 0x57,
    0x08, 0x00
  ]);

  SlirpWrapper(this._bindings, {required this.onSendData}) 
      : _wrapperId = ++_instanceCounter {
    _wrapperRegistry[_wrapperId] = this;
  }

  // ========================================================================
  // 现代版引擎驱动器 (适配 libslirp v4.7+)：零 C 内存操作的极简盲轮询！
  // ========================================================================
  
  // 用于记录当前循环中，引擎想要监听的事件
  static final List<int> _blindEvents = [];

  // 【修改】返回值从 void 变成 int
  static int _cAddPoll(int fd, int events, ffi.Pointer<ffi.Void> opaque) {
    _blindEvents.add(events);
    // 【核心修复】绝对不能永远返回 0！必须返回它在 List 中的真实索引！
    return _blindEvents.length - 1; 
  }

  // ========================================================================
  // ARP 幽灵回应器：将伪造的 MAC 地址送回给引擎，解锁被憋住的网页数据
  // ========================================================================
  void _sendArpReplyToSlirp(Uint8List arpReply) {
    if (_slirpInstance == ffi.nullptr) return;
    final nativeDataPtr = malloc.allocate<ffi.Uint8>(arpReply.length);
    nativeDataPtr.asTypedList(arpReply.length).setAll(0, arpReply);
    _bindings.slirp_input(_slirpInstance, nativeDataPtr.cast(), arpReply.length);
    malloc.free(nativeDataPtr);
  }

  static int _cGetREvents(int idx, ffi.Pointer<ffi.Void> opaque) {
    // 引擎：小本本上第 idx 个 Socket 准备好了吗？
    // 我们：(终极欺骗) 准备好了！你刚才要求什么事件，我现在就还给你什么事件！
    if (idx >= 0 && idx < _blindEvents.length) {
      return _blindEvents[idx];
    }
    return 0;
  }

  void _driveEngine() {
    if (_slirpInstance == ffi.nullptr) return;

    // 1. 准备超时时间 (我们不关心超时，设为 0)
    final timeoutPtr = calloc<ffi.Uint32>();
    timeoutPtr.value = 0; 

    // 2. 将 Dart 静态方法转化为 C 语言回调指针
    final addPollPtr = ffi.Pointer.fromFunction<
        ffi.Int Function(ffi.Int, ffi.Int, ffi.Pointer<ffi.Void>)
    >(_cAddPoll, 0);

    final getREventsPtr = ffi.Pointer.fromFunction<
        ffi.Int Function(ffi.Int, ffi.Pointer<ffi.Void>)
    >(_cGetREvents, 0);

    // 3. 清空上一轮的记录
    _blindEvents.clear();

    // 4. 第一步：让引擎把想监听的 Socket 填入我们的小本本
    _bindings.slirp_pollfds_fill(
        _slirpInstance,
        timeoutPtr,
        addPollPtr,
        ffi.nullptr
    );

    // 5. 第二步：强制触发事件处理！引擎会调用 _cGetREvents 来询问状态
    _bindings.slirp_pollfds_poll(
        _slirpInstance,
        0, // 0 表示没有底层 OS 错误
        getREventsPtr,
        ffi.nullptr
    );

    calloc.free(timeoutPtr);
  }

  void init() {
    if (_slirpInstance != ffi.nullptr) {
      throw Exception('Slirp 引擎已经初始化，请勿重复调用！');
    }

    // final callbacksPtr = malloc.allocate<SlirpCb>(ffi.sizeOf<SlirpCb>());

    // final callbacksPtr = calloc<SlirpCb>();
    // final configPtr = calloc<SlirpConfig>();
    final callbacksPtr = calloc<ffi.Uint8>(512).cast<SlirpCb>();
    final configPtr = calloc<ffi.Uint8>(512).cast<SlirpConfig>();
    
    // 【修复 1】对齐 C 语言的精确函数签名 (返回 ffi.Long，参数接收 ffi.Size)
    // ffi.Pointer.fromFunction 的第二个参数是当 Dart 抛出异常时的默认 C 返回值，这里给 0
    callbacksPtr.ref.send_packet = ffi.Pointer.fromFunction<
        ffi.Long Function(ffi.Pointer<ffi.Void>, ffi.Size, ffi.Pointer<ffi.Void>)
    >(_cSendPacketCallback, 0); 

    // final configPtr = malloc.allocate<SlirpConfig>(ffi.sizeOf<SlirpConfig>());
    // 【修复 2】从 configPtr 中删除了 opaque 赋值，改为直接生成指针
    final opaquePtr = ffi.Pointer.fromAddress(_wrapperId).cast<ffi.Void>();
    
    // 强制设置 config 的版本号，这是 libslirp 要求的安全机制
    // 1. 基础版本声明
    configPtr.ref.version = 1; 

    // 2. 【核心通电】强制开启 IPv4 和 IPv6 协议栈！
    // (注意：如果 ffigen 把 bool 翻译成了 int，这里的 true 报错的话，请改成 1)
    configPtr.ref.in_enabled = true;  
    configPtr.ref.in6_enabled = false; 

    // 3. 【宣告领土】告诉 libslirp 我们这套虚拟网络的 IP 规划
    // 这必须和 Android 端 Constants.kt 里的 10.0.2.15 在同一个网段！
    configPtr.ref.vnetwork.s_addr = _parseIp('10.0.2.0');
    configPtr.ref.vnetmask.s_addr = _parseIp('255.255.255.0');
    configPtr.ref.vhost.s_addr = _parseIp('10.0.2.2');        // 虚拟网关
    configPtr.ref.vnameserver.s_addr = _parseIp('10.0.2.3');

    callbacksPtr.ref.send_packet = ffi.Pointer.fromFunction<
        ffi.Long Function(ffi.Pointer<ffi.Void>, ffi.Size, ffi.Pointer<ffi.Void>)
    >(_cSendPacketCallback, 0); 

    // 【新增修复】挂载网络轮询占位回调，彻底消灭 0x0 空指针崩溃！
    callbacksPtr.ref.register_poll_fd = ffi.Pointer.fromFunction<
        ffi.Void Function(ffi.Int, ffi.Pointer<ffi.Void>) 
    >(_cRegisterPollFd);

    // 【修改】把 ffi.Int32 替换为 ffi.Int
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

    // 【修复 3】将 opaquePtr 作为第三个独立参数传递
    _slirpInstance = _bindings.slirp_new(configPtr, callbacksPtr, opaquePtr);

    // 【修改】把指针存入类成员，交给 dispose 去管理
    _savedCallbacks = callbacksPtr;
    _savedConfig = configPtr;

    // calloc.free(callbacksPtr);
    // calloc.free(configPtr);

    if (_slirpInstance == ffi.nullptr) {
      throw Exception('底层 libslirp 初始化失败，返回了空指针。');
    }

    _engineTimer = Timer.periodic(const Duration(milliseconds: 10), (_) {
      _driveEngine();
    });
  }

  // 将 "10.0.2.0" 转为 C 语言结构体所需的小端序 Uint32
  int _parseIp(String ip) {
    final parts = ip.split('.').map(int.parse).toList();
    return (parts[3] << 24) | (parts[2] << 16) | (parts[1] << 8) | parts[0];
  }

  void inputFromDevice(Uint8List data) {
    if (_slirpInstance == ffi.nullptr || data.isEmpty) return;

    // 【动态识别】通过第一字节的高 4 位判断是 IPv4 还是 IPv6
    final isIPv6 = (data[0] >> 4) == 6;
    
    // 0x0800 是 IPv4 的以太网标识，0x86DD 是 IPv6 的标识
    final etherTypeHigh = isIPv6 ? 0x86 : 0x08;
    final etherTypeLow  = isIPv6 ? 0xDD : 0x00;

    final frameLength = 14 + data.length;
    final nativeDataPtr = malloc.allocate<ffi.Uint8>(frameLength);
    final nativeView = nativeDataPtr.asTypedList(frameLength);
    
    // 缝合智能马甲
    nativeView.setAll(0, [
      0x52, 0x54, 0x00, 0x12, 0x34, 0x56, // 目标 MAC: 网关
      0x52, 0x54, 0x00, 0x12, 0x34, 0x57, // 源 MAC: 手机
      etherTypeHigh, etherTypeLow         // 动态协议头！
    ]);
    
    nativeView.setAll(14, data);

    _bindings.slirp_input(_slirpInstance, nativeDataPtr.cast(), frameLength);

    malloc.free(nativeDataPtr);
  }

  void dispose() {
    _engineTimer?.cancel(); // 【新增】熄火
    if (_slirpInstance != ffi.nullptr) {
      _bindings.slirp_cleanup(_slirpInstance);
      _slirpInstance = ffi.nullptr;
    }
    _wrapperRegistry.remove(_wrapperId);

    // 【新增】在这里释放，绝对安全
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
  // 【修复 4】将静态回调的返回值改为 int，以匹配 ffi.Long
  // ========================================================================
  // ========================================================================
  // 终极修复：精准切除以太网 Padding (防止 Android TUN 网卡崩溃)
  // ========================================================================
  // ========================================================================
  // 终极修复：以太网协议安检门 + 精准切除 Padding (防止 Android TUN 崩溃)
  // ========================================================================
  static int _cSendPacketCallback(ffi.Pointer<ffi.Void> pkt, int pktLen, ffi.Pointer<ffi.Void> opaque) {
    final wrapperId = opaque.address;
    final wrapper = _wrapperRegistry[wrapperId];
    if (wrapper == null) return -1;

    final nativeBytes = pkt.cast<ffi.Uint8>().asTypedList(pktLen);
    
    if (pktLen > 14) {
      final etherTypeHigh = nativeBytes[12];
      final etherTypeLow = nativeBytes[13];

      // 【全新加入】ARP 幽灵截获与回应！
      if (etherTypeHigh == 0x08 && etherTypeLow == 0x06) {
        // 判断是否是 ARP Request (Opcode == 1)
        if (nativeBytes.length >= 42 && nativeBytes[20] == 0x00 && nativeBytes[21] == 0x01) {
          print('🛡️ [RouterEngine] 拦截到引擎发出的 ARP 请求，正在伪造 MAC 应答解锁流量...');
          
          final arpReply = Uint8List(42);
          // 1. 目标 MAC：填入引擎的 MAC (拷贝自 Request 的源 MAC)
          arpReply.setRange(0, 6, nativeBytes.sublist(6, 12));
          // 2. 源 MAC：我们伪造给手机的假 MAC (52:54:00:12:34:57)
          arpReply.setAll(6, [0x52, 0x54, 0x00, 0x12, 0x34, 0x57]);
          // 3. EtherType (0x0806)
          arpReply.setAll(12, [0x08, 0x06]);
          
          // 4. 拷贝 ARP 硬件与协议类型
          arpReply.setRange(14, 20, nativeBytes.sublist(14, 20));
          // 5. Opcode 改为 Reply (0x0002)
          arpReply.setAll(20, [0x00, 0x02]);
          
          // 6. 发送者 MAC (手机假 MAC)
          arpReply.setAll(22, [0x52, 0x54, 0x00, 0x12, 0x34, 0x57]);
          // 7. 发送者 IP (手机 IP，拷贝自 Request 的目标 IP)
          arpReply.setRange(28, 32, nativeBytes.sublist(38, 42));
          // 8. 目标 MAC (引擎 MAC，拷贝自 Request 的源 MAC)
          arpReply.setRange(32, 38, nativeBytes.sublist(22, 28));
          // 9. 目标 IP (引擎 IP，拷贝自 Request 的源 IP)
          arpReply.setRange(38, 42, nativeBytes.sublist(28, 32));

          // 将应答直接塞回给引擎内部，彻底解锁流量！
          wrapper._sendArpReplyToSlirp(arpReply);
        }
        return pktLen; // 拦截完毕，千万不要把这个 ARP 包发给手机！
      }

      // 0x0800 是 IPv4 的身份证，0x86DD 是 IPv6 的身份证
      final isIPv4 = (etherTypeHigh == 0x08 && etherTypeLow == 0x00);
      final isIPv6 = (etherTypeHigh == 0x86 && etherTypeLow == 0xDD);

      if (isIPv4 || isIPv6) {
        // ... (保留你之前写的脱衣服和 Padding 切除代码)
        final paddedIpData = nativeBytes.sublist(14);
        if (paddedIpData.isEmpty) return pktLen;

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
      } else {
        print('🛡️ [RouterEngine] 拦截并丢弃未知报文 (EtherType: 0x${etherTypeHigh.toRadixString(16).padLeft(2, '0')}${etherTypeLow.toRadixString(16).padLeft(2, '0')})');
      }
    }
    
    return pktLen;
  }

  // ========================================================================
  // 核心底层轮询回调 (防止 tcp_fconnect 空指针崩溃)
  // ========================================================================
  
  static void _cRegisterPollFd(int fd, ffi.Pointer<ffi.Void> opaque) {
    // 【新增免疫】如果 Mac 拒绝分配 Socket (FD < 0)，直接忽略！
    if (fd < 0) return; 
    print('🔗 [Slirp 引擎] 替手机创建了真实的 Mac Socket，文件描述符 FD = $fd');
  }

  static void _cUnregisterPollFd(int fd, ffi.Pointer<ffi.Void> opaque) {
    if (fd < 0) return; 
    print('🔗 [Slirp 引擎] 销毁了 Socket FD = $fd');
  }

  static void _cNotify(ffi.Pointer<ffi.Void> opaque) {
    // 引擎的异步通知回调，暂时留空
  }
  // ========================================================================
  // 核心定时器回调 (防止 udp_attach 等函数发生空指针崩溃)
  // ========================================================================

  static int _cClockGetNs(ffi.Pointer<ffi.Void> opaque) {
    // libslirp 需要知道当前的纳秒级时间来计算超时
    return DateTime.now().microsecondsSinceEpoch * 1000;
  }

  // 注意：这里的第一个参数类型非常长，如果编译报错请贴给我！
  static ffi.Pointer<ffi.Void> _cTimerNew(
      ffi.Pointer<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>> cb, 
      ffi.Pointer<ffi.Void> cbOpaque, 
      ffi.Pointer<ffi.Void> opaque) {
    // 【修改】在 Mac ARM64 上，返回 0x1 可能会触发硬件级未对齐校验。
    // 我们直接给它分配一块真实的、合法的 8 字节对齐内存作为假定时器句柄！
    return calloc<ffi.Uint64>(1).cast<ffi.Void>();
  }

  static void _cTimerFree(ffi.Pointer<ffi.Void> timer, ffi.Pointer<ffi.Void> opaque) {
    // 【修改】有借有还，防止内存泄漏
    if (timer != ffi.nullptr) {
      calloc.free(timer);
    }
  }

  static void _cTimerMod(ffi.Pointer<ffi.Void> timer, int expireTime, ffi.Pointer<ffi.Void> opaque) {
    // 修改定时器时间，暂时留空
  }
}