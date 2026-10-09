import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ai_page.dart';
import 'hub.dart';
import 'p2p.dart';
import 'platform.dart';
import 'update_dialog.dart';
import 'update_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final hub = Hub();
  await hub.init();
  runApp(NelsonBoxApp(hub: hub));
}

class NelsonBoxApp extends StatelessWidget {
  final Hub hub;
  const NelsonBoxApp({super.key, required this.hub});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF1769E0);
    ThemeData makeTheme(Brightness brightness) {
      final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
      return ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        brightness: brightness,
        scaffoldBackgroundColor: scheme.surfaceContainerLowest,
        cardTheme: CardThemeData(
          elevation: 0,
          color: scheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: scheme.surfaceContainerLow,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        ),
      );
    }
    return MaterialApp(
      title: 'NelsonBox',
      debugShowCheckedModeBanner: false,
      theme: makeTheme(Brightness.light),
      darkTheme: makeTheme(Brightness.dark),
      home: HomePage(hub: hub),
    );
  }
}

class HomePage extends StatefulWidget {
  final Hub hub;
  const HomePage({super.key, required this.hub});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final _native = NativeBridge.instance;
  final _input = TextEditingController();
  late final P2P p2p = P2P(widget.hub, _native);
  bool _dragging = false; // 桌面端：文件正拖到窗口上
  int _page = 0;
  bool _checkedUpdate = false;
  String? _targetId; // 文件发送目标设备

  Hub get hub => widget.hub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    hub.onReceived = (item) {
      if (item.senderId == hub.deviceId) return;
      _toast(hub.autoCopy ? '已复制来自【${item.sender}】的内容' : '收到来自【${item.sender}】的内容');
    };
    hub.onError = _toast;
    hub.onAiError = _toast;
    p2p.onIncoming = (t) => _toast('正在接收来自【${t.peerName}】的文件…');
    p2p.onSaved = (t, f) => _toast(
          '已保存到 $_saveDirLabel：${f.name}',
          action: SnackBarAction(label: '打开', onPressed: () => _open(f)),
        );
    p2p.onFailed = (t) {
      if (t.error != '已取消') _toast('${t.dir == TransferDir.send ? '发送' : '接收'}失败：${t.error}');
    };

    // 从“分享”菜单或文字选择菜单进入（只有 Android 有）
    if (AppPlatform.isAndroid) {
      _native.listenShares(onText: _sendShared, onFiles: _sendSharedFiles);
      _native.takeSharedText().then(_sendShared);
      _native.takeSharedFiles().then(_sendSharedFiles);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!hub.configured) _openSettings();
      if (hub.autoCheckUpdates) _checkUpdate(silent: true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _input.dispose();
    p2p.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) hub.ensureConnected();
  }

  void _sendShared(String? text) {
    if (text == null || text.isEmpty) return;
    final err = hub.send(text);
    _toast(err ?? '已发送到所有设备');
  }

  /// 当前选中的发送目标：手动选过的优先；只有一台其他设备时默认选它
  Device? get _target {
    final others = hub.otherDevices;
    for (final d in others) {
      if (d.id == _targetId) return d;
    }
    return others.length == 1 ? others.first : null;
  }

  /// 刚启动时等 WebSocket 连上、拿到设备列表（最多等 8 秒）
  Future<void> _waitOnline() async {
    for (var i = 0; i < 40 && (hub.status != HubStatus.online || hub.devices.isEmpty); i++) {
      if (hub.status == HubStatus.notConfigured || hub.status == HubStatus.unauthorized) return;
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }

  /// 分享进来的文件（原生层已复制到缓存目录）：选目标设备后直传，结束后删除缓存副本
  Future<void> _sendSharedFiles(List<String>? paths) async {
    if (paths == null || paths.isEmpty) return;
    Future<void> discard() async {
      for (final p in paths) {
        try {
          final f = File(p);
          await f.delete();
          await f.parent.delete();
        } catch (_) {}
      }
    }

    if (mounted) setState(() => _page = 1);
    await _waitOnline();
    final others = hub.otherDevices;
    if (others.isEmpty) {
      _toast(hub.status == HubStatus.online ? '没有其他在线设备，无法发送文件' : '未连接服务器，无法发送文件');
      await discard();
      return;
    }
    final target = others.length == 1 ? others.first : await _chooseDevice(others);
    if (target == null) {
      await discard();
      return;
    }
    final files = [for (final p in paths) LocalFile(p, File(p).uri.pathSegments.last)];
    final err = await p2p.sendFiles(target, files, deleteAfter: true);
    if (err != null) _toast(err);
  }

  /// 收到的文件保存位置（显示用）
  String get _saveDirLabel => AppPlatform.isAndroid ? '下载/NelsonBox' : r'下载\NelsonBox';

  /// 桌面端：把文件拖到“文件传输”页上发送（不删除原文件）
  Future<void> _sendDropped(List<String> paths) async {
    final files = <LocalFile>[];
    for (final p in paths) {
      if (await FileSystemEntity.type(p) != FileSystemEntityType.file) {
        _toast('只能发送文件，不能发送文件夹');
        continue;
      }
      files.add(LocalFile(p, File(p).uri.pathSegments.last));
    }
    if (files.isEmpty) return;
    final others = hub.otherDevices;
    if (others.isEmpty) {
      _toast(hub.status == HubStatus.online ? '没有其他在线设备，无法发送文件' : '未连接服务器，无法发送文件');
      return;
    }
    final target = _target ?? await _chooseDevice(others);
    if (target == null) return;
    final err = await p2p.sendFiles(target, files);
    if (err != null) _toast(err);
  }

  Future<Device?> _chooseDevice(List<Device> devices) async {
    if (!mounted) return null;
    return showModalBottomSheet<Device>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('发送到哪台设备？')),
          for (final d in devices)
            ListTile(
              leading: Icon(_deviceIcon(d.type)),
              title: Text(d.name),
              onTap: () => Navigator.pop(ctx, d),
            ),
        ]),
      ),
    );
  }

  Future<void> _pickAndSend() async {
    final target = _target;
    if (target == null) {
      _toast('请先选择接收设备');
      return;
    }
    final List<PlatformFile> picked;
    try {
      picked = await FilePicker.pickFiles();
    } catch (_) {
      _toast('无法打开文件选择器');
      return;
    }
    if (picked.isEmpty) return;
    final files = <LocalFile>[];
    for (final f in picked) {
      final path = f.path;
      if (path == null) {
        _toast('${f.name} 无法读取');
        continue;
      }
      files.add(LocalFile(path, f.name));
    }
    if (files.isEmpty) return;
    // Android 上 file_picker 会把文件复制到缓存目录，传完删掉副本；
    // 桌面端拿到的是原文件路径，绝不能删除
    final err = await p2p.sendFiles(target, files, deleteAfter: AppPlatform.isAndroid);
    if (err != null) _toast(err);
  }

  Future<void> _open(SavedFile f) async {
    final err = await p2p.open(f);
    if (err != null) _toast(err);
  }

  Future<void> _reveal(SavedFile f) async {
    final err = await p2p.reveal(f);
    if (err != null) _toast(err);
  }

  Future<void> _openSaved(Transfer t) async {
    if (t.saved.length == 1) return _open(t.saved.first);
    final f = await showModalBottomSheet<SavedFile>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          for (final f in t.saved)
            ListTile(
              leading: Icon(_fileIcon(f.name)),
              title: Text(f.name),
              onTap: () => Navigator.pop(ctx, f),
            ),
        ]),
      ),
    );
    if (f != null) await _open(f);
  }

  Future<void> _sendPhoneClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    final noun = AppPlatform.deviceNoun;
    if (text.isEmpty) {
      _toast('$noun剪贴板是空的');
      return;
    }
    _toast(hub.send(text) ?? '已发送$noun剪贴板');
  }

  void _sendInput() {
    final err = hub.send(_input.text);
    if (err == null) {
      _input.clear();
      FocusScope.of(context).unfocus();
    }
    _toast(err ?? '已发送');
  }

  void _copy(ClipItem item) {
    Clipboard.setData(ClipboardData(text: item.text));
    _toast('已复制');
  }

  void _toast(String msg, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        action: action,
        duration: Duration(seconds: action == null ? 2 : 5),
      ));
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsPage(hub: hub)));
  }

  void _selectPage(int index) {
    if (_page != index) setState(() => _page = index);
    if (index == 2) hub.aiList();
    Navigator.of(context).maybePop();
  }

  Future<void> _checkUpdate({bool silent = false}) async {
    if (_checkedUpdate && silent) return;
    _checkedUpdate = true;
    try {
      final info = await UpdateService.packageInfo();
      final release = await UpdateService.latest(windows: !AppPlatform.isAndroid);
      if (!mounted || release == null) return;
      final build = int.tryParse(info.buildNumber) ?? 0;
      if (UpdateService.isNewer(info.version, build, release.tag)) {
        await UpdateDialog.show(context, release, 'v${info.version}+$build');
      } else if (!silent) {
        _toast('当前已是最新版本 v${info.version}');
      }
    } catch (e) {
      if (!silent) _toast('检查更新失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    const titles = ['剪贴板', '文件传输', 'AI 助手'];
    return ListenableBuilder(
      listenable: Listenable.merge([hub, p2p]),
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(titles[_page]),
          actions: [
            _StatusChip(hub: hub),
            const SizedBox(width: 8),
          ],
        ),
        drawer: NavigationDrawer(
          selectedIndex: _page,
          onDestinationSelected: _selectPage,
          header: _DrawerHeader(hub: hub),
          children: [
            const NavigationDrawerDestination(
              icon: Icon(Icons.content_paste_outlined),
              selectedIcon: Icon(Icons.content_paste_rounded),
              label: Text('剪贴板'),
            ),
            NavigationDrawerDestination(
              icon: Badge(
                isLabelVisible: p2p.transfers.any((t) => t.active),
                label: Text('${p2p.transfers.where((t) => t.active).length}'),
                child: const Icon(Icons.swap_horiz_rounded),
              ),
              selectedIcon: const Icon(Icons.folder_copy_rounded),
              label: const Text('文件传输'),
            ),
            const NavigationDrawerDestination(
              icon: Icon(Icons.auto_awesome_outlined),
              selectedIcon: Icon(Icons.auto_awesome_rounded),
              label: Text('AI 助手'),
            ),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Divider()),
            ListTile(leading: const Icon(Icons.settings_outlined), title: const Text('设置'), onTap: _openSettings),
            ListTile(
              leading: const Icon(Icons.system_update_outlined),
              title: const Text('检查更新'),
              onTap: () {
                Navigator.pop(context);
                _checkUpdate();
              },
            ),
          ],
        ),
        body: IndexedStack(index: _page, children: [
          _clipboardTab(),
          _filesTab(),
          AiTab(hub: hub, toast: _toast),
        ]),
      ),
    );
  }

  Widget _clipboardTab() {
    return RefreshIndicator(
      onRefresh: () async => hub.connect(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          ?_configBanner(),
          FilledButton.icon(
            onPressed: _sendPhoneClipboard,
            icon: const Icon(Icons.upload),
            label: Text('发送${AppPlatform.deviceNoun}剪贴板'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _input,
            minLines: 1,
            maxLines: 5,
            decoration: InputDecoration(
              hintText: '或在这里输入内容',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(icon: const Icon(Icons.send), onPressed: _sendInput),
            ),
          ),
          const SizedBox(height: 20),
          Text('剪贴板记录 · 点击复制', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          if (hub.history.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text('暂无记录')),
            ),
          for (final item in hub.history)
            Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                title: Text(item.text, maxLines: 4, overflow: TextOverflow.ellipsis),
                subtitle: Text('${item.sender} · ${_formatTime(item.updatedAt)}'),
                trailing: const Icon(Icons.copy, size: 18),
                onTap: () => _copy(item),
              ),
            ),
        ],
      ),
    );
  }

  Widget? _configBanner() {
    if (hub.status != HubStatus.unauthorized && hub.status != HubStatus.notConfigured) return null;
    return _Banner(
      text: hub.status == HubStatus.unauthorized ? '令牌错误，请在设置里修改' : '请先在设置里填写服务器和令牌',
      onTap: _openSettings,
    );
  }

  Widget _filesTab() {
    final list = _filesList();
    if (!AppPlatform.isDesktop) return list;
    final scheme = Theme.of(context).colorScheme;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (detail) {
        setState(() => _dragging = false);
        _sendDropped([for (final f in detail.files) f.path]);
      },
      child: Stack(children: [
        list,
        if (_dragging)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: scheme.primary, width: 2),
                ),
                alignment: Alignment.center,
                child: Text(
                  _target == null ? '松开发送（之后选择设备）' : '松开发送到 ${_target!.name}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _filesList() {
    final others = hub.otherDevices;
    final target = _target;
    final finished = p2p.transfers.any((t) => !t.active);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        ?_configBanner(),
        Text('发送到', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        if (others.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              hub.status == HubStatus.online ? '没有其他在线设备' : '未连接服务器',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          )
        else
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final d in others)
              ChoiceChip(
                avatar: Icon(_deviceIcon(d.type), size: 18),
                label: Text(d.name),
                selected: target?.id == d.id,
                onSelected: (_) => setState(() => _targetId = d.id),
              ),
          ]),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: target == null ? null : _pickAndSend,
          icon: const Icon(Icons.upload_file),
          label: Text(target == null ? '选择文件发送' : '选择文件发送到 ${target.name}'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        ),
        const SizedBox(height: 6),
        Text(
          AppPlatform.isAndroid
              ? '设备之间直连传输，不经过服务器；传输时请保持 App 在前台。收到的文件保存在 下载/NelsonBox'
              : '设备之间直连传输，不经过服务器；也可以把文件拖到这里发送。收到的文件保存在 $_saveDirLabel',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: Text('传输记录', style: Theme.of(context).textTheme.labelLarge)),
          if (finished) TextButton(onPressed: p2p.clearFinished, child: const Text('清除已结束')),
        ]),
        if (p2p.transfers.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: Text('暂无传输')),
          ),
        for (final t in p2p.transfers) _transferCard(t),
      ],
    );
  }

  Widget _transferCard(Transfer t) {
    final theme = Theme.of(context);
    final send = t.dir == TransferDir.send;
    final names = t.files.length == 1 ? t.files.first.name : '${t.files.first.name} 等 ${t.files.length} 个文件';
    final details = [
      '${send ? '发送给' : '来自'} ${t.peerName}',
      formatBytes(t.total),
      ?t.connType,
    ].join(' · ');
    final progress = t.status == TransferStatus.transferring
        ? '${formatBytes(t.bytes)} / ${formatBytes(t.total)} · ${formatBytes(t.speed.bytesPerSecond.round())}/s'
        : null;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(children: [
          Icon(send ? Icons.arrow_upward : Icons.arrow_downward,
              color: t.status == TransferStatus.failed ? theme.colorScheme.error : theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${send ? '发送' : '接收'} · $names', maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(details, style: theme.textTheme.bodySmall),
              Text(
                [t.statusText, ?progress].join(' · '),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: t.status == TransferStatus.failed ? theme.colorScheme.error : null,
                ),
              ),
              if (t.active) ...[
                const SizedBox(height: 6),
                LinearProgressIndicator(value: t.status == TransferStatus.transferring ? t.fraction : null),
              ],
            ]),
          ),
          if (t.active)
            IconButton(tooltip: '取消', icon: const Icon(Icons.close), onPressed: () => p2p.cancel(t))
          else if (!send && t.saved.isNotEmpty) ...[
            if (p2p.canReveal && t.saved.length == 1)
              IconButton(
                tooltip: '在文件夹中显示',
                icon: const Icon(Icons.folder_open_outlined),
                onPressed: () => _reveal(t.saved.first),
              ),
            TextButton(onPressed: () => _openSaved(t), child: const Text('打开')),
          ],
        ]),
      ),
    );
  }
}

IconData _deviceIcon(String type) => switch (type) {
      'mac' || 'windows' || 'linux' => Icons.computer,
      'android' => Icons.phone_android,
      _ => Icons.language,
    };

IconData _fileIcon(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return switch (ext) {
    'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' || 'heic' || 'bmp' => Icons.image_outlined,
    'mp4' || 'mov' || 'mkv' || 'avi' || 'webm' => Icons.movie_outlined,
    'mp3' || 'wav' || 'm4a' || 'flac' || 'aac' || 'ogg' => Icons.audiotrack_outlined,
    'pdf' => Icons.picture_as_pdf_outlined,
    'zip' || 'rar' || '7z' || 'tar' || 'gz' => Icons.folder_zip_outlined,
    'apk' => Icons.android,
    _ => Icons.insert_drive_file_outlined,
  };
}

String _formatTime(double ts) {
  final d = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final hm = '${two(d.hour)}:${two(d.minute)}';
  if (d.year == now.year && d.month == now.month && d.day == now.day) return hm;
  return '${d.month}/${d.day} $hm';
}

class _DrawerHeader extends StatelessWidget {
  final Hub hub;
  const _DrawerHeader({required this.hub});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [scheme.primaryContainer, scheme.tertiaryContainer]),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(14)),
          child: Icon(Icons.inventory_2_rounded, color: scheme.onPrimary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('NelsonBox', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            Text(hub.deviceName, maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
      ]),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final Hub hub;
  const _StatusChip({required this.hub});

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (hub.status) {
      HubStatus.online => ('${hub.devices.length} 台在线', Colors.green),
      HubStatus.connecting => ('连接中', Colors.amber),
      HubStatus.offline => ('已断开', Colors.red),
      HubStatus.unauthorized => ('令牌错误', Colors.red),
      HubStatus.notConfigured => ('未设置', Colors.grey),
    };
    return GestureDetector(
      onTap: hub.status == HubStatus.online ? () => _showDevices(context) : hub.connect,
      child: Row(children: [
        Icon(Icons.circle, size: 10, color: color),
        const SizedBox(width: 6),
        Text(text, style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }

  void _showDevices(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('在线设备')),
          for (final d in hub.devices)
            ListTile(
              leading: Icon(_deviceIcon(d.type)),
              title: Text(d.name),
              subtitle: Text(d.id == hub.deviceId ? '本机' : d.type),
            ),
        ]),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final String text;
  final VoidCallback onTap;
  const _Banner({required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: const Icon(Icons.warning_amber),
        title: Text(text),
        onTap: onTap,
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  final Hub hub;
  const SettingsPage({super.key, required this.hub});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final _server = TextEditingController(text: widget.hub.server);
  late final _token = TextEditingController(text: widget.hub.token);
  late final _name = TextEditingController(text: widget.hub.deviceName);
  late bool _autoCopy = widget.hub.autoCopy;
  late bool _autoCheckUpdates = widget.hub.autoCheckUpdates;
  bool _showToken = false;

  @override
  void dispose() {
    _server.dispose();
    _token.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await widget.hub.saveSettings(
      server: _server.text,
      token: _token.text,
      deviceName: _name.text,
      autoCopy: _autoCopy,
      autoCheckUpdates: _autoCheckUpdates,
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: [TextButton(onPressed: _save, child: const Text('保存'))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _server,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '服务器地址',
              hintText: 'http://1.2.3.4:18888',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _token,
            obscureText: !_showToken,
            decoration: InputDecoration(
              labelText: '访问令牌',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_showToken ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _showToken = !_showToken),
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: '设备名称', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('收到内容自动复制到${AppPlatform.deviceNoun}剪贴板'),
            value: _autoCopy,
            onChanged: (v) => setState(() => _autoCopy = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.system_update_outlined),
            title: const Text('启动时自动检查更新'),
            subtitle: const Text('只有发现新版本时才提示'),
            value: _autoCheckUpdates,
            onChanged: (v) => setState(() => _autoCheckUpdates = v),
          ),
        ],
      ),
    );
  }
}
