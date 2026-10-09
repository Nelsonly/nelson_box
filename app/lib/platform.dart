// 平台差异集中在这里：Android 走原生 MethodChannel，Windows（及其他桌面）用 Dart 实现。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

class AppPlatform {
  AppPlatform._();

  static bool get isAndroid => !kIsWeb && Platform.isAndroid;
  static bool get isWindows => !kIsWeb && Platform.isWindows;
  static bool get isDesktop => !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// 只有桌面端允许 AI“可修改”模式；Android 固定只读问答
  static bool get allowsAiEdit => isDesktop;

  /// WebSocket 上报的 device_type
  static String get deviceType => deviceTypeFor(isAndroid ? 'android' : Platform.operatingSystem);

  static String deviceTypeFor(String os) => switch (os) {
        'android' => 'android',
        'windows' => 'windows',
        'macos' => 'mac',
        _ => os,
      };

  /// 默认设备名
  static String get defaultDeviceName {
    if (isAndroid) return 'Android 手机';
    try {
      final host = Platform.localHostname.trim();
      if (host.isNotEmpty) return host;
    } catch (_) {}
    return isWindows ? 'Windows 电脑' : '电脑';
  }

  /// 剪贴板相关文字里的“手机 / 电脑”
  static String get deviceNoun => isAndroid ? '手机' : '电脑';
}

/// 同名文件加 " (1)"、" (2)"…；[exists] 判断某个文件名是否已被占用
String uniqueFileName(String name, bool Function(String candidate) exists) {
  if (!exists(name)) return name;
  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  for (var i = 1;; i++) {
    final candidate = '$base ($i)$ext';
    if (!exists(candidate)) return candidate;
  }
}

/// 保存好的文件：uri 在 Android 上是 content://，桌面上是本地路径
typedef SavedInfo = ({String uri, String name});

/// 原生能力：缓存目录、存储权限、保存到“下载/NelsonBox”、打开文件、系统分享
abstract class NativeBridge {
  static NativeBridge? _instance;
  static NativeBridge get instance =>
      _instance ??= AppPlatform.isAndroid ? AndroidBridge() : DesktopBridge();

  Future<String> cacheDir();
  Future<bool> ensureStoragePermission();
  Future<SavedInfo> saveToDownloads(String path, String name);

  /// 打开文件；返回 null 表示成功，否则返回错误信息
  Future<String?> openFile(String uri, String name);

  /// 能否“在文件夹中显示”
  bool get canReveal => false;
  Future<String?> revealFile(String uri) async => '不支持';

  /// 从系统“分享”进来的文字 / 文件（只有 Android 有）
  void listenShares({required void Function(String? text) onText, required void Function(List<String>? paths) onFiles}) {}
  Future<String?> takeSharedText() async => null;
  Future<List<String>?> takeSharedFiles() async => null;
}

/// Android：全部交给 MainActivity.kt 里的 "nelsonbox/share" 通道
class AndroidBridge extends NativeBridge {
  static const _ch = MethodChannel('nelsonbox/share');

  @override
  Future<String> cacheDir() async => await _ch.invokeMethod<String>('cacheDir') ?? Directory.systemTemp.path;

  @override
  Future<bool> ensureStoragePermission() async => await _ch.invokeMethod<bool>('ensureStoragePermission') ?? true;

  @override
  Future<SavedInfo> saveToDownloads(String path, String name) async {
    final r = await _ch.invokeMapMethod<String, dynamic>('saveToDownloads', {'path': path, 'name': name});
    return (uri: r?['uri'] as String? ?? '', name: r?['name'] as String? ?? name);
  }

  @override
  Future<String?> openFile(String uri, String name) async {
    try {
      await _ch.invokeMethod('openFile', {'uri': uri, 'name': name});
      return null;
    } on PlatformException catch (e) {
      return e.message ?? '无法打开';
    }
  }

  @override
  void listenShares({required void Function(String? text) onText, required void Function(List<String>? paths) onFiles}) {
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'sharedText':
          onText(call.arguments as String?);
        case 'sharedFiles':
          onFiles((call.arguments as List?)?.cast<String>());
      }
    });
  }

  @override
  Future<String?> takeSharedText() => _ch.invokeMethod<String>('takeSharedText');

  @override
  Future<List<String>?> takeSharedFiles() => _ch.invokeListMethod<String>('takeSharedFiles');
}

/// Windows / 桌面：临时目录 + 下载目录/NelsonBox，用系统默认程序打开
class DesktopBridge extends NativeBridge {
  @override
  Future<String> cacheDir() async {
    try {
      return (await getTemporaryDirectory()).path;
    } catch (_) {
      return Directory.systemTemp.path;
    }
  }

  @override
  Future<bool> ensureStoragePermission() async => true;

  Future<Directory> _downloadsDir() async {
    Directory? base;
    try {
      base = await getDownloadsDirectory();
    } catch (_) {}
    base ??= Directory('${Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.'}'
        '${Platform.pathSeparator}Downloads');
    return Directory('${base.path}${Platform.pathSeparator}NelsonBox').create(recursive: true);
  }

  @override
  Future<SavedInfo> saveToDownloads(String path, String name) async {
    final dir = await _downloadsDir();
    String full(String n) => '${dir.path}${Platform.pathSeparator}$n';
    final finalName = uniqueFileName(name, (n) => FileSystemEntity.typeSync(full(n)) != FileSystemEntityType.notFound);
    final dest = full(finalName);
    final src = File(path);
    try {
      await src.rename(dest); // 同一个盘时直接移动
    } on FileSystemException {
      await src.copy(dest); // 跨盘：复制（临时文件由调用方删除）
    }
    return (uri: dest, name: finalName);
  }

  @override
  Future<String?> openFile(String uri, String name) async {
    if (!await File(uri).exists()) return '文件不存在（可能已被移动或删除）';
    try {
      if (await launchUrl(Uri.file(uri))) return null;
    } catch (_) {}
    if (AppPlatform.isWindows) {
      try {
        await Process.run('explorer', [uri]);
        return null;
      } catch (_) {}
    }
    return '没有可以打开此文件的应用';
  }

  @override
  bool get canReveal => AppPlatform.isWindows;

  @override
  Future<String?> revealFile(String uri) async {
    try {
      // explorer 的返回码不可靠，不检查
      await Process.run('explorer', ['/select,', uri]);
      return null;
    } catch (e) {
      return '无法打开文件夹：$e';
    }
  }
}
