// 文件名: main.dart
import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'dart:io' show Platform, Directory;
import 'package:ffi/ffi.dart'; // 提供 malloc 和 calloc
import 'package:path/path.dart' as path;

// 1. 定义 C 函数签名 (参数为: 指针, 32位整数)
typedef CProcessFunc = ffi.Void Function(ffi.Pointer<ffi.Uint8> data, ffi.Int32 length);
// 2. 定义 Dart 函数签名
typedef DartProcessFunc = void Function(ffi.Pointer<ffi.Uint8> data, int length);

void main() {
  // 组装动态库路径
  final libraryPath = path.join(Directory.current.path, 'libprocessor.dylib');
  print('加载动态库: $libraryPath');

  // 打开动态库并绑定函数
  final dylib = ffi.DynamicLibrary.open(libraryPath);
  final processPacket = dylib
      .lookup<ffi.NativeFunction<CProcessFunc>>('process_packet')
      .asFunction<DartProcessFunc>();

  // --- 核心魔法开始 ---

  // 1. 准备一段 Dart 原生的字节数据 (模拟一个网络包: [10, 20, 30])
  final dartData = Uint8List.fromList([10, 20, 30]);
  print('处理前 Dart 数据: $dartData');

  // 2. 在 C 语言的内存空间分配相同大小的内存 (使用 malloc)
  final ffi.Pointer<ffi.Uint8> nativeMemory = malloc.allocate<ffi.Uint8>(dartData.length);

  // 3. 将 Dart 数据拷贝到 C 内存中
  final nativeBytes = nativeMemory.asTypedList(dartData.length);
  nativeBytes.setAll(0, dartData);

  // 4. 调用 C 语言函数，把指针传过去！
  processPacket(nativeMemory, dartData.length);

  // 5. C 语言处理完后，把数据读回 Dart
  // (因为 asTypedList 是引用的同一块内存，nativeBytes 的值已经被 C 改变了)
  final resultData = Uint8List.fromList(nativeBytes);
  print('处理后 Dart 数据: $resultData');

  // 6. 极其重要：手动释放 C 内存，防止内存泄漏！
  malloc.free(nativeMemory);
}