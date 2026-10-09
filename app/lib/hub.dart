import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const maxClipboardBytes = 64 * 1024; // 与服务端上限一致
const maxHistory = 50;

// 编译时通过 --dart-define-from-file=dart_defines.json 注入，源码里不写死
const _defaultServer = String.fromEnvironment('NB_SERVER');
const _defaultToken = String.fromEnvironment('NB_TOKEN');

class ClipItem {
  final String text;
  final String sender;
  final String senderId;
  final double updatedAt;

  ClipItem(this.text, this.sender, this.senderId, this.updatedAt);

  factory ClipItem.fromJson(Map<String, dynamic> j) => ClipItem(
        j['text'] as String? ?? '',
        j['sender'] as String? ?? '',
        j['sender_id'] as String? ?? '',
        (j['updated_at'] as num?)?.toDouble() ?? 0,
      );
}

class Device {
  final String id;
  final String name;
  final String type;
  Device(this.id, this.name, this.type);
}

enum HubStatus { notConfigured, connecting, online, offline, unauthorized }

class Hub extends ChangeNotifier {
  late SharedPreferences _prefs;
  String server = '';
  String token = '';
  String deviceName = 'Android 手机';
  String deviceId = '';
  bool autoCopy = true;

  HubStatus status = HubStatus.connecting;
  List<ClipItem> history = [];
  List<Device> devices = [];

  /// 收到其他设备内容时的回调（用于界面提示）
  void Function(ClipItem item)? onReceived;

  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  Timer? _reconnect;
  final List<String> _outbox = [];

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    server = _prefs.getString('server') ?? _defaultServer;
    token = _prefs.getString('token') ?? _defaultToken;
    deviceName = _prefs.getString('deviceName') ?? deviceName;
    autoCopy = _prefs.getBool('autoCopy') ?? true;
    deviceId = _prefs.getString('deviceId') ?? '';
    if (deviceId.isEmpty) {
      final r = Random.secure();
      deviceId = 'android_${List.generate(8, (_) => r.nextInt(16).toRadixString(16)).join()}';
      await _prefs.setString('deviceId', deviceId);
    }
    connect();
  }

  bool get configured => server.isNotEmpty && token.isNotEmpty;

  Future<void> saveSettings({
    required String server,
    required String token,
    required String deviceName,
    required bool autoCopy,
  }) async {
    this.server = server.trim().replaceAll(RegExp(r'/+$'), '');
    this.token = token.trim();
    this.deviceName = deviceName.trim().isEmpty ? 'Android 手机' : deviceName.trim();
    this.autoCopy = autoCopy;
    await _prefs.setString('server', this.server);
    await _prefs.setString('token', this.token);
    await _prefs.setString('deviceName', this.deviceName);
    await _prefs.setBool('autoCopy', autoCopy);
    connect();
  }

  // ---------- 连接 ----------
  void connect() {
    _reconnect?.cancel();
    _sub?.cancel();
    _ch?.sink.close();
    _ch = null;

    if (!configured) {
      _setStatus(HubStatus.notConfigured);
      return;
    }
    _setStatus(HubStatus.connecting);

    final base = Uri.parse(server);
    final uri = base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/ws',
      queryParameters: {
        'device_id': deviceId,
        'name': deviceName,
        'device_type': 'android',
        'token': token,
      },
    );

    final ch = IOWebSocketChannel.connect(uri,
        pingInterval: const Duration(seconds: 20),
        connectTimeout: const Duration(seconds: 8));
    _ch = ch;
    ch.ready.then((_) {
      if (_ch != ch) return;
      _setStatus(HubStatus.online);
      _flushOutbox();
    }).catchError((_) {});

    _sub = ch.stream.listen(
      _onMessage,
      onDone: () => _onClosed(ch),
      onError: (_) => _onClosed(ch),
      cancelOnError: true,
    );
  }

  void _onClosed(WebSocketChannel ch) {
    if (_ch != ch) return;
    if (ch.closeCode == 4001) {
      _setStatus(HubStatus.unauthorized);
      return;
    }
    _setStatus(HubStatus.offline);
    _reconnect = Timer(const Duration(seconds: 3), connect);
  }

  /// App 回到前台时调用：断线了就立即重连
  void ensureConnected() {
    if (status == HubStatus.offline) connect();
  }

  void _onMessage(dynamic raw) {
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (msg['type']) {
      case 'clipboard:history':
        history = (msg['history'] as List)
            .map((e) => ClipItem.fromJson(e as Map<String, dynamic>))
            .toList();
        notifyListeners();
      case 'clipboard:sync':
        final item = ClipItem.fromJson(msg['data'] as Map<String, dynamic>);
        _addToHistory(item);
        if (autoCopy && item.senderId != deviceId) {
          Clipboard.setData(ClipboardData(text: item.text));
        }
        onReceived?.call(item);
      case 'devices:update':
        devices = (msg['devices'] as List)
            .map((e) => Device(e['id'] as String, e['name'] as String, e['type'] as String))
            .toList();
        notifyListeners();
      case 'clipboard:error':
        onError?.call(msg['error'] as String? ?? '发送失败');
    }
  }

  void Function(String message)? onError;

  // ---------- 发送 ----------
  /// 返回 null 表示成功（或已排队），否则返回错误信息
  String? send(String text) {
    if (text.trim().isEmpty) return '内容为空';
    if (utf8.encode(text).length > maxClipboardBytes) return '内容超过 64KB 上限';
    _addToHistory(ClipItem(text, deviceName, deviceId, DateTime.now().millisecondsSinceEpoch / 1000));
    final payload = jsonEncode({'type': 'clipboard:send', 'text': text});
    if (status == HubStatus.online) {
      _ch?.sink.add(payload);
    } else {
      _outbox.add(payload);
      if (status == HubStatus.offline) connect();
    }
    return null;
  }

  void _flushOutbox() {
    while (_outbox.isNotEmpty && _ch != null) {
      _ch!.sink.add(_outbox.removeAt(0));
    }
  }

  void _addToHistory(ClipItem item) {
    history = [item, ...history.where((h) => h.text != item.text)].take(maxHistory).toList();
    notifyListeners();
  }

  void _setStatus(HubStatus s) {
    status = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _reconnect?.cancel();
    _sub?.cancel();
    _ch?.sink.close();
    super.dispose();
  }
}
