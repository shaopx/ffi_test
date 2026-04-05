// 文件路径: lib/src/utils/native_buffer.dart

import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'exceptions.dart';
import 'logger.dart';

/// 管理一块长驻 Native 堆的内存，避免高频垃圾回收和内存碎片
class NativeBuffer {
  final int capacity;
  
  // 指向 C 语言内存块的首地址指针
  ffi.Pointer<ffi.Uint8> _pointer = ffi.nullptr;
  
  // Dart 层的高速视图 (Zero-Copy)
  late final Uint8List _dartView;

  bool _isDisposed = false;

  /// [capacity] 默认 65535 字节，足以容纳目前网络层最大的 IP 数据包
  NativeBuffer({this.capacity = 65535}) {
    // 1. 在初始化时，只做一次极其昂贵的 Native 内存分配
    _pointer = malloc.allocate<ffi.Uint8>(capacity);
    
    // 2. 建立零拷贝视图：_dartView 读写的数据，物理上就直接写在 _pointer 指向的内存里
    _dartView = _pointer.asTypedList(capacity);
    
    Logger.d('NativeBuffer 已分配一块 $capacity Bytes 的长驻内存块。');
  }

  /// 获取 C 语言裸指针，用于传递给 ffi 底层函数
  ffi.Pointer<ffi.Uint8> get pointer {
    _checkDisposed();
    return _pointer;
  }

  /// 将 Dart 收到的网络字节流，以光速覆盖写入 Native 内存中
  /// 返回实际写入的字节长度
  int write(Uint8List incomingData) {
    _checkDisposed();
    final length = incomingData.length;
    
    if (length > capacity) {
      throw NativeBufferException(
        '传入的数据包体积 ($length) 超出了 NativeBuffer 的最大容量 ($capacity)！'
      );
    }

    // setAll 是极其底层的内存块复制 (类似 C 语言的 memcpy)
    // 它把 incomingData 直接搬运到了 _pointer 的内存地址中，瞬间完成！
    _dartView.setAll(0, incomingData);
    
    return length;
  }

  /// 释放极其宝贵的 C 语言内存。
  /// 警告：只要程序不退出或连接不彻底断开，就不要调用它。
  void dispose() {
    if (!_isDisposed && _pointer != ffi.nullptr) {
      malloc.free(_pointer);
      _pointer = ffi.nullptr;
      _isDisposed = true;
      Logger.d('NativeBuffer 内存已被安全回收。');
    }
  }

  void _checkDisposed() {
    if (_isDisposed) {
      throw NativeBufferException('不能操作已经被回收的 Native 内存！这会引发段错误(Segfault)。');
    }
  }
}