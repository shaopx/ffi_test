// 文件路径: lib/src/ffi/lib_loader.dart

import 'dart:ffi' as ffi;
import 'dart:io'; // 【修复】去掉了 show 限制，引入所有 io 类
import 'package:path/path.dart' as path;

class LibLoader {
  static ffi.DynamicLibrary loadSlirpLibrary() {
    String libraryFileName;

    if (Platform.isWindows) {
      libraryFileName = 'libslirp.dll';
    } else if (Platform.isMacOS) {
      libraryFileName = 'libslirp.dylib';
    } else if (Platform.isLinux) {
      libraryFileName = 'libslirp.so';
    } else {
      throw UnsupportedError('不支持的操作系统: ${Platform.operatingSystem}');
    }

    final currentDir = Directory.current.path;
    final searchPaths = [
      path.join(currentDir, libraryFileName),
      path.join(currentDir, 'libs', libraryFileName),
      path.join(currentDir, 'build', libraryFileName),
    ];

    for (final libPath in searchPaths) {
      // 【修复】直接使用 Directory 检查文件状态，删除了错误的 ffi.File
      final fileStat = Directory(libPath).statSync();
      if (fileStat.type != FileSystemEntityType.notFound) {
        print('[LibLoader] 找到动态库: $libPath');
        return ffi.DynamicLibrary.open(libPath);
      }
    }

    print('[LibLoader] 警告：未在预期目录找到动态库，尝试依赖系统路径加载...');
    try {
      return ffi.DynamicLibrary.open(libraryFileName);
    } catch (e) {
      throw Exception('''
无法加载 libslirp 动态库！
尝试搜索的路径: \n${searchPaths.join('\n')}
系统错误信息: $e
      ''');
    }
  }
}