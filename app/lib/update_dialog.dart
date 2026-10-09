import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'hub.dart';
import 'platform.dart';
import 'update_service.dart';

class UpdateDialog extends StatefulWidget {
  final AppRelease release;
  final String currentVersion;

  const UpdateDialog({super.key, required this.release, required this.currentVersion});

  static Future<void> show(BuildContext context, AppRelease release, String currentVersion) => showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => UpdateDialog(release: release, currentVersion: currentVersion),
      );

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _downloading = false;
  int _received = 0;
  int _total = 0;
  double _speed = 0;
  String? _error;
  File? _apk;

  Future<void> _download() async {
    setState(() {
      _downloading = true;
      _error = null;
    });
    try {
      final file = await UpdateService.download(widget.release, onProgress: (received, total, speed) {
        if (!mounted) return;
        setState(() {
          _received = received;
          _total = total;
          _speed = speed;
        });
      });
      if (!mounted) return;
      setState(() {
        _apk = file;
        _downloading = false;
      });
      await _install();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _install() async {
    final apk = _apk;
    if (apk == null) return;
    final result = await UpdateService.install(apk);
    if (!mounted || result.message.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.message)));
  }

  /// 桌面端：不自动安装，用浏览器下载 zip / 打开发布页
  Future<void> _openInBrowser(String url) async {
    var ok = false;
    try {
      ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() => _error = '无法打开浏览器：$url');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!AppPlatform.isAndroid) return _desktop(context, scheme);
    final progress = _total > 0 ? (_received / _total).clamp(0.0, 1.0) : null;
    return AlertDialog(
      icon: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: scheme.primaryContainer, shape: BoxShape.circle),
        child: Icon(Icons.system_update_rounded, color: scheme.primary),
      ),
      title: Text('发现新版本 ${widget.release.tag}', textAlign: TextAlign.center),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('当前 ${widget.currentVersion} · 安装包 ${widget.release.formattedSize}',
              style: Theme.of(context).textTheme.bodySmall),
          if (widget.release.notes.isNotEmpty) ...[
            const SizedBox(height: 14),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(child: MarkdownBody(data: widget.release.notes)),
            ),
          ],
          if (_downloading) ...[
            const SizedBox(height: 18),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 8),
            Text(
              '${formatBytes(_received)} / ${_total > 0 ? formatBytes(_total) : '未知'}'
              '${_speed > 0 ? ' · ${formatBytes(_speed.round())}/s' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text('下载失败：$_error', style: TextStyle(color: scheme.error)),
          ],
        ]),
      ),
      actions: [
        if (!_downloading) TextButton(onPressed: () => Navigator.pop(context), child: const Text('稍后')),
        if (!_downloading)
          FilledButton.icon(
            onPressed: _apk == null ? _download : _install,
            icon: Icon(_apk == null ? Icons.download_rounded : Icons.install_mobile_rounded),
            label: Text(_apk == null ? '下载并安装' : '继续安装'),
          ),
      ],
    );
  }

  Widget _desktop(BuildContext context, ColorScheme scheme) {
    final release = widget.release;
    return AlertDialog(
      icon: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: scheme.primaryContainer, shape: BoxShape.circle),
        child: Icon(Icons.system_update_rounded, color: scheme.primary),
      ),
      title: Text('发现新版本 ${release.tag}', textAlign: TextAlign.center),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('当前 ${widget.currentVersion} · 安装包 ${release.formattedSizeFor(windows: true)}',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          Text('下载后解压，关闭 NelsonBox 再用新文件夹替换旧的即可。', style: Theme.of(context).textTheme.bodySmall),
          if (release.notes.isNotEmpty) ...[
            const SizedBox(height: 14),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(child: MarkdownBody(data: release.notes)),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: scheme.error)),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('稍后')),
        TextButton(onPressed: () => _openInBrowser(release.pageUrl), child: const Text('查看发布页')),
        FilledButton.icon(
          onPressed: () => _openInBrowser(release.windowsUrl.isNotEmpty ? release.windowsUrl : release.pageUrl),
          icon: const Icon(Icons.download_rounded),
          label: const Text('用浏览器下载'),
        ),
      ],
    );
  }
}
