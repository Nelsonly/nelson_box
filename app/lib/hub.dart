import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'ai_chat.dart';

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

/// 文件大小转成易读格式：512 B / 1.5 KB / 23.4 MB / 1.25 GB / 2 GB
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final digits = v >= 100 ? 0 : (i >= 2 ? 2 : 1);
  final n = v.toStringAsFixed(digits).replaceFirst(RegExp(r'\.0+$'), '');
  return '$n ${units[i]}';
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
  bool autoCheckUpdates = true;

  HubStatus status = HubStatus.connecting;
  List<ClipItem> history = [];
  List<Device> devices = [];

  /// 收到其他设备内容时的回调（用于界面提示）
  void Function(ClipItem item)? onReceived;

  /// AI 聊天状态（对话列表、当前对话、Mac 主机信息）
  final AiChat ai = AiChat();

  /// AI 标签页上次选的引擎和项目（新对话用）
  String aiEngine = '';
  String aiProject = '';

  /// AI 请求被拒时的回调（用于界面提示）
  void Function(String message)? onAiError;

  /// 服务器下发的 ICE 配置（只有 STUN，没有 TURN）
  List<Map<String, dynamic>> iceServers = [];

  /// 收到 P2P 信令 / 信令错误时的回调（由 P2P 模块设置）
  void Function(String from, String fromName, Map<String, dynamic> data)? onSignal;
  void Function(String? transferId, String error)? onSignalError;

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
    autoCheckUpdates = _prefs.getBool('autoCheckUpdates') ?? true;
    aiEngine = _prefs.getString('aiEngine') ?? '';
    aiProject = _prefs.getString('aiProject') ?? '';
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
    required bool autoCheckUpdates,
  }) async {
    this.server = server.trim().replaceAll(RegExp(r'/+$'), '');
    this.token = token.trim();
    this.deviceName = deviceName.trim().isEmpty ? 'Android 手机' : deviceName.trim();
    this.autoCopy = autoCopy;
    this.autoCheckUpdates = autoCheckUpdates;
    await _prefs.setString('server', this.server);
    await _prefs.setString('token', this.token);
    await _prefs.setString('deviceName', this.deviceName);
    await _prefs.setBool('autoCopy', autoCopy);
    await _prefs.setBool('autoCheckUpdates', autoCheckUpdates);
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
      _aiResync();
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
      case 'ai:hosts' || 'ai:convs' || 'ai:conv' || 'ai:delta' || 'ai:msg' || 'ai:error':
        final err = ai.apply(msg);
        notifyListeners();
        if (err != null) onAiError?.call(err);
      case 'rtc:config':
        iceServers = ((msg['ice_servers'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      case 'rtc:signal':
        final data = msg['data'];
        final from = msg['from'];
        if (data is Map && from is String) {
          onSignal?.call(from, msg['from_name'] as String? ?? from, Map<String, dynamic>.from(data));
        }
      case 'rtc:error':
        onSignalError?.call(msg['transfer_id'] as String?, msg['error'] as String? ?? '对方不在线');
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

  // ---------- AI 聊天 ----------
  bool _sendJson(Map<String, dynamic> msg) {
    final ch = _ch;
    if (status != HubStatus.online || ch == null) return false;
    ch.sink.add(jsonEncode(msg));
    return true;
  }

  /// 连上（含断线重连）后：刷新列表，并重新拉取当前对话，补齐掉线期间的回复
  void _aiResync() {
    // 掉线前发出、没收到确认的请求作废（服务器若已收到，会出现在对话列表里）
    ai.pendingReq = null;
    aiList();
    final cur = ai.current;
    if (cur != null) aiOpen(cur.id);
  }

  void setAiPrefs({String? engine, String? project}) {
    if (engine != null) {
      aiEngine = engine;
      _prefs.setString('aiEngine', engine);
    }
    if (project != null) {
      aiProject = project;
      _prefs.setString('aiProject', project);
    }
    notifyListeners();
  }

  /// 某个引擎记住的模型 / 推理强度（已按主机当前的模型列表校正，不存在就回到默认）
  ModelChoice aiChoice(String engine) => ModelChoice.resolve(
        ai.engine(engine),
        _prefs.getString('aiModel_$engine') ?? '',
        _prefs.getString('aiEffort_$engine') ?? '',
      );

  void setAiChoice(String engine, ModelChoice c) {
    _prefs.setString('aiModel_$engine', c.model);
    _prefs.setString('aiEffort_$engine', c.effort);
    notifyListeners();
  }

  void aiList() => _sendJson({'type': 'ai:list'});

  void aiOpen(String convId) {
    ai.openingId = convId;
    if (!_sendJson({'type': 'ai:open', 'conv_id': convId})) ai.openingId = null;
    notifyListeners();
  }

  /// 回到“新对话”状态（下一次发送会新建对话）
  void aiNew() {
    ai.current = null;
    ai.openingId = null;
    notifyListeners();
  }

  /// 发消息（手机端只用只读问答模式）。返回 null 表示已发出，否则返回错误信息
  String? aiSend(String text,
      {required String engine, required String project, ModelChoice choice = const ModelChoice()}) {
    if (text.trim().isEmpty) return '内容为空';
    if (ai.busy) return '上一条回复还没结束';
    final cur = ai.current;
    final req = AiChat.newReq();
    final ok = _sendJson(AiChat.sendPayload(
      convId: cur?.id,
      engine: cur?.engine ?? engine,
      project: cur?.project ?? project,
      text: text,
      req: req,
      choice: choice,
    ));
    if (!ok) return '未连接服务器';
    ai.pendingReq = req;
    notifyListeners();
    return null;
  }

  void aiCancel(String msgId) => _sendJson({'type': 'ai:cancel', 'msg_id': msgId});

  bool aiDelete(String convId) {
    if (!_sendJson({'type': 'ai:delete', 'conv_id': convId})) return false;
    if (ai.current?.id == convId) aiNew();
    return true;
  }

  // ---------- P2P 信令 ----------
  /// 通过服务器转发信令；未连接时返回 false
  bool sendSignal(String to, Map<String, dynamic> data) {
    final ch = _ch;
    if (status != HubStatus.online || ch == null) return false;
    ch.sink.add(jsonEncode({'type': 'rtc:signal', 'to': to, 'data': data}));
    return true;
  }

  /// 其他在线设备（不含本机）
  List<Device> get otherDevices => devices.where((d) => d.id != deviceId).toList();

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
