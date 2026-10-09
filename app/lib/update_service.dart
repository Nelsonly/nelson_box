import 'dart:convert';
import 'dart:io';

import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class AppRelease {
  final String tag;
  final String name;
  final String notes;
  final String pageUrl;
  final String apkUrl;
  final int apkSize;

  const AppRelease({
    required this.tag,
    required this.name,
    required this.notes,
    required this.pageUrl,
    required this.apkUrl,
    required this.apkSize,
  });

  factory AppRelease.fromJson(Map<String, dynamic> json) {
    String apkUrl = '';
    var apkSize = 0;
    for (final raw in json['assets'] as List? ?? const []) {
      if (raw is! Map) continue;
      final asset = Map<String, dynamic>.from(raw);
      final fileName = (asset['name'] as String? ?? '').toLowerCase();
      if (fileName.endsWith('.apk')) {
        apkUrl = asset['browser_download_url'] as String? ?? '';
        apkSize = asset['size'] as int? ?? 0;
        break;
      }
    }
    final tag = (json['tag_name'] as String? ?? '').trim();
    return AppRelease(
      tag: tag,
      name: (json['name'] as String? ?? '').trim().isEmpty ? tag : (json['name'] as String).trim(),
      notes: (json['body'] as String? ?? '').trim(),
      pageUrl: json['html_url'] as String? ?? UpdateService.releasesUrl,
      apkUrl: apkUrl,
      apkSize: apkSize,
    );
  }

  String get formattedSize => apkSize <= 0 ? '未知大小' : '${(apkSize / 1024 / 1024).toStringAsFixed(1)} MB';
}

class UpdateService {
  UpdateService._();

  static const releasesUrl = 'https://github.com/Nelsonly/nelson_box/releases';
  static const _apiUrl = 'https://api.github.com/repos/Nelsonly/nelson_box/releases';

  static Future<PackageInfo> packageInfo() => PackageInfo.fromPlatform();

  static bool isNewer(String currentVersion, int currentBuild, String tag) {
    List<int> parse(String value) {
      final clean = value.replaceFirst(RegExp(r'^[vV]'), '').trim();
      final pieces = clean.split('+');
      final semver = pieces.first.split('.').map((e) => int.tryParse(e) ?? 0).toList();
      while (semver.length < 3) {
        semver.add(0);
      }
      semver.add(pieces.length > 1 ? int.tryParse(pieces[1]) ?? 0 : 0);
      return semver.take(4).toList();
    }

    final current = parse('$currentVersion+$currentBuild');
    final target = parse(tag);
    for (var i = 0; i < 4; i++) {
      if (target[i] != current[i]) return target[i] > current[i];
    }
    return false;
  }

  /// 优先取 latest；如果它的 APK 还在上传，则选最新的可下载 Release。
  static Future<AppRelease?> latest() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.getUrl(Uri.parse(_apiUrl));
      request.headers
        ..set(HttpHeaders.userAgentHeader, 'NelsonBox-App')
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('检查更新失败（HTTP ${response.statusCode}）');
      }
      final decoded = jsonDecode(await response.transform(utf8.decoder).join());
      if (decoded is! List) throw const FormatException('Release 数据格式错误');
      for (final raw in decoded) {
        if (raw is! Map) continue;
        final release = AppRelease.fromJson(Map<String, dynamic>.from(raw));
        if (release.apkUrl.isNotEmpty) return release;
      }
      return null;
    } finally {
      client.close();
    }
  }

  static Future<File> download(
    AppRelease release, {
    required void Function(int received, int total, double bytesPerSecond) onProgress,
  }) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
    await dir.create(recursive: true);
    final finalFile = File('${dir.path}/NelsonBox_${release.tag}.apk');
    final partial = File('${finalFile.path}.part');
    var existing = await partial.exists() ? await partial.length() : 0;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      var uri = Uri.parse(release.apkUrl);
      HttpClientResponse? response;
      for (var redirects = 0; redirects < 6; redirects++) {
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.userAgentHeader, 'NelsonBox-App');
        if (existing > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existing-');
        response = await request.close();
        if (response.statusCode >= 300 && response.statusCode < 400) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null) throw HttpException('下载重定向缺少地址');
          uri = uri.resolve(location);
          continue;
        }
        break;
      }
      if (response == null || (response.statusCode != HttpStatus.ok && response.statusCode != HttpStatus.partialContent)) {
        throw HttpException('下载失败（HTTP ${response?.statusCode ?? 0}）');
      }
      if (response.statusCode == HttpStatus.ok && existing > 0) {
        await partial.delete();
        existing = 0;
      }
      final total = existing + response.contentLength.clamp(0, 1 << 62);
      final sink = partial.openWrite(mode: existing > 0 ? FileMode.append : FileMode.write);
      var received = existing;
      var sampleBytes = received;
      var sampleTime = DateTime.now();
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          final now = DateTime.now();
          final elapsed = now.difference(sampleTime).inMilliseconds;
          if (elapsed >= 250) {
            onProgress(received, total, (received - sampleBytes) * 1000 / elapsed);
            sampleBytes = received;
            sampleTime = now;
          }
        }
      } finally {
        await sink.close();
      }
      onProgress(received, total, 0);
      if (total > 0 && received != total) throw const HttpException('下载未完成');
      if (await finalFile.exists()) await finalFile.delete();
      return await partial.rename(finalFile.path);
    } finally {
      client.close();
    }
  }

  static Future<OpenResult> install(File apk) => OpenFilex.open(apk.path, type: 'application/vnd.android.package-archive');
}
