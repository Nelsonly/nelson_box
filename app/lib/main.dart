import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'hub.dart';

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
    const seed = Color(0xFF3B82F6);
    return MaterialApp(
      title: 'NelsonBox',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
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
  static const _share = MethodChannel('nelsonbox/share');
  final _input = TextEditingController();

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

    // 从“分享”菜单或文字选择菜单进入
    _share.setMethodCallHandler((call) async {
      if (call.method == 'sharedText') _sendShared(call.arguments as String?);
    });
    _share.invokeMethod<String>('takeSharedText').then(_sendShared);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!hub.configured) _openSettings();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _input.dispose();
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

  Future<void> _sendPhoneClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isEmpty) {
      _toast('手机剪贴板是空的');
      return;
    }
    _toast(hub.send(text) ?? '已发送手机剪贴板');
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

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsPage(hub: hub)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('NelsonBox'),
          actions: [
            _StatusChip(hub: hub),
            IconButton(icon: const Icon(Icons.settings_outlined), onPressed: _openSettings),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: () async => hub.connect(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              if (hub.status == HubStatus.unauthorized || hub.status == HubStatus.notConfigured)
                _Banner(
                  text: hub.status == HubStatus.unauthorized ? '令牌错误，请在设置里修改' : '请先在设置里填写服务器和令牌',
                  onTap: _openSettings,
                ),
              FilledButton.icon(
                onPressed: _sendPhoneClipboard,
                icon: const Icon(Icons.upload),
                label: const Text('发送手机剪贴板'),
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
        ),
      ),
    );
  }
}

String _formatTime(double ts) {
  final d = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final hm = '${two(d.hour)}:${two(d.minute)}';
  if (d.year == now.year && d.month == now.month && d.day == now.day) return hm;
  return '${d.month}/${d.day} $hm';
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
              leading: Icon(switch (d.type) {
                'mac' || 'windows' || 'linux' => Icons.computer,
                'android' => Icons.phone_android,
                _ => Icons.language,
              }),
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
            title: const Text('收到内容自动复制到手机剪贴板'),
            value: _autoCopy,
            onChanged: (v) => setState(() => _autoCopy = v),
          ),
        ],
      ),
    );
  }
}
