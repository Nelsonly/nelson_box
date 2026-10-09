// AI 聊天的状态（纯逻辑，不依赖网络，便于单元测试）。协议见 docs/ai-chat-protocol.md。
import 'dart:math';

class AiModel {
  final String id;
  final String name;
  final List<String> efforts; // 空表示不支持选推理强度
  const AiModel(this.id, this.name, this.efforts);

  factory AiModel.fromJson(Map j) => AiModel(
        _str(j['id']),
        _str(j['name'], _str(j['id'])),
        [for (final e in _list(j['efforts'])) if (e is String && e.isNotEmpty) e],
      );
}

class AiEngine {
  final String id;
  final String name;
  final bool available;
  final String defaultModel; // 空表示未知
  final String defaultEffort;
  final List<AiModel> models;
  const AiEngine(this.id, this.name, this.available,
      {this.defaultModel = '', this.defaultEffort = '', this.models = const []});

  factory AiEngine.fromJson(Map j) => AiEngine(
        _str(j['id']),
        _str(j['name'], _str(j['id'])),
        j['available'] == true,
        defaultModel: _str(j['default_model']),
        defaultEffort: _str(j['default_effort']),
        models: [for (final m in _list(j['models'])) if (m is Map && _str(m['id']).isNotEmpty) AiModel.fromJson(m)],
      );

  AiModel? model(String id) {
    for (final m in models) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// 模型显示名（找不到时用原始 ID）
  String modelName(String id) => model(id)?.name ?? id;
}

/// 每条消息的模型 / 推理强度选择；空字符串表示“默认”（由 Mac 决定）
class ModelChoice {
  final String model;
  final String effort;
  const ModelChoice([this.model = '', this.effort = '']);

  /// 按主机当前的模型列表校正：记住的模型 / 强度不存在了就回到默认
  static ModelChoice resolve(AiEngine? engine, String model, String effort) {
    if (engine == null) return const ModelChoice();
    final m = model.isEmpty ? null : engine.model(model);
    final chosen = m == null ? '' : model;
    final efforts = effortsFor(engine, chosen);
    return ModelChoice(chosen, efforts.contains(effort) ? effort : '');
  }

  /// 某个模型可选的推理强度；默认模型用 default_model 对应的条目
  static List<String> effortsFor(AiEngine engine, String model) =>
      engine.model(model.isEmpty ? engine.defaultModel : model)?.efforts ?? const [];

  /// 顶栏上显示的简短标签，例如 “GPT-6-Sol · high” / “默认（GPT-5.6-Sol）”
  String label(AiEngine? engine) {
    if (engine == null) return '默认';
    final String m;
    if (model.isNotEmpty) {
      m = engine.modelName(model);
    } else {
      m = engine.defaultModel.isEmpty ? '默认' : '默认（${engine.modelName(engine.defaultModel)}）';
    }
    final e = effort.isNotEmpty ? effort : (model.isEmpty ? engine.defaultEffort : '');
    return e.isEmpty ? m : '$m · $e';
  }
}

class AiHost {
  final String id;
  final String name;
  final List<AiEngine> engines;
  final List<String> projects;
  const AiHost(this.id, this.name, this.engines, this.projects);

  factory AiHost.fromJson(Map j) => AiHost(
        _str(j['id']),
        _str(j['name'], 'Mac'),
        [
          for (final e in _list(j['engines']))
            if (e is Map) AiEngine.fromJson(e),
        ],
        [
          for (final p in _list(j['projects']))
            if (p is Map && _str(p['name']).isNotEmpty) _str(p['name']),
        ],
      );
}

class AiConvSummary {
  final String id;
  final String title;
  final String engine;
  final String project;
  final double updatedAt;
  final bool busy;
  const AiConvSummary(this.id, this.title, this.engine, this.project, this.updatedAt, this.busy);

  factory AiConvSummary.fromJson(Map j) => AiConvSummary(
        _str(j['id']),
        _str(j['title'], '新对话'),
        _str(j['engine']),
        _str(j['project']),
        _num(j['updated_at']),
        j['busy'] == true,
      );
}

class AiMessage {
  final String id;
  final String role; // user / assistant
  String text;
  String status; // pending / running / done / error / cancelled
  String? error;
  final String sender;
  final double createdAt;
  final String model; // 这条回复实际使用的模型（可能为空）
  final String effort;

  AiMessage(this.id, this.role, this.text, this.status, this.error, this.sender, this.createdAt,
      {this.model = '', this.effort = ''});

  factory AiMessage.fromJson(Map j) => AiMessage(
        _str(j['id']),
        _str(j['role'], 'assistant'),
        _str(j['text']),
        _str(j['status'], 'done'),
        j['error'] is String && (j['error'] as String).isNotEmpty ? j['error'] as String : null,
        _str(j['sender']),
        _num(j['created_at']),
        model: _str(j['model']),
        effort: _str(j['effort']),
      );

  bool get isUser => role == 'user';
  bool get active => status == 'pending' || status == 'running';
}

class AiConv {
  final String id;
  final String title;
  final String engine;
  final String project;
  final List<AiMessage> messages;
  AiConv(this.id, this.title, this.engine, this.project, this.messages);

  factory AiConv.fromJson(Map j) => AiConv(
        _str(j['id']),
        _str(j['title'], '新对话'),
        _str(j['engine']),
        _str(j['project']),
        [for (final m in _list(j['messages'])) if (m is Map) AiMessage.fromJson(m)],
      );

  /// 最后一条回复还在等待 / 生成中
  bool get busy => messages.isNotEmpty && messages.last.active;
}

/// AI 聊天状态。[apply] 处理服务器发来的 ai:* 消息。
class AiChat {
  List<AiHost> hosts = [];
  List<AiConvSummary> convs = [];
  AiConv? current;

  /// 已发出 ai:send、还没收到对应 ai:conv 的请求 ID（新建对话时用来认领）
  String? pendingReq;

  /// 已发出 ai:open、还没收到的对话 ID
  String? openingId;

  /// Mac 是否在线
  bool get hostOnline => hosts.isNotEmpty;

  /// 可用的引擎（去重，按主机顺序）
  List<AiEngine> get engines {
    final seen = <String>{};
    return [
      for (final h in hosts)
        for (final e in h.engines)
          if (e.available && seen.add(e.id)) e,
    ];
  }

  List<String> get projects => {for (final h in hosts) ...h.projects}.toList();

  /// 按 ID 找引擎（包括不可用的）
  AiEngine? engine(String id) {
    for (final h in hosts) {
      for (final e in h.engines) {
        if (e.id == id) return e;
      }
    }
    return null;
  }

  /// 回复下方显示的“模型 · 强度”，例如 “GPT-6-Sol · high”；都为空时返回空字符串
  String usedLabel(String engineId, AiMessage m) {
    var name = m.model;
    if (name.isNotEmpty) {
      name = engine(engineId)?.model(name)?.name ?? _anyModelName(name) ?? name;
    }
    return [name, m.effort].where((s) => s.isNotEmpty).join(' · ');
  }

  String? _anyModelName(String id) {
    for (final h in hosts) {
      for (final e in h.engines) {
        final m = e.model(id);
        if (m != null) return m.name;
      }
    }
    return null;
  }

  /// 组装 ai:send 消息。手机端固定只读问答；model / effort 为“默认”时不发送
  static Map<String, dynamic> sendPayload({
    String? convId,
    required String engine,
    required String project,
    required String text,
    required String req,
    ModelChoice choice = const ModelChoice(),
  }) =>
      {
        'type': 'ai:send',
        'conv_id': ?convId,
        'engine': engine,
        'project': project,
        'text': text,
        'mode': 'ask',
        if (choice.model.isNotEmpty) 'model': choice.model,
        if (choice.effort.isNotEmpty) 'effort': choice.effort,
        'client_req': req,
      };

  String engineName(String id) {
    for (final h in hosts) {
      for (final e in h.engines) {
        if (e.id == id) return e.name;
      }
    }
    return switch (id) {
      'claude' => 'Claude Code',
      'codex' => 'Codex',
      'gemini' => 'Gemini',
      _ => id,
    };
  }

  /// 正在等待服务器确认，或最后一条回复还没结束：此时不能再发
  bool get busy => pendingReq != null || (current?.busy ?? false);

  /// 处理一条服务器消息。返回需要提示给用户的错误（ai:error），否则返回 null。
  String? apply(Map<String, dynamic> msg) {
    switch (msg['type']) {
      case 'ai:hosts':
        hosts = [for (final h in _list(msg['hosts'])) if (h is Map) AiHost.fromJson(h)];
      case 'ai:convs':
        convs = [for (final c in _list(msg['convs'])) if (c is Map) AiConvSummary.fromJson(c)];
        // 当前对话被删除（别的设备删的也算）
        final cur = current;
        if (cur != null && !convs.any((c) => c.id == cur.id)) current = null;
      case 'ai:conv':
        final raw = msg['conv'];
        if (raw is! Map) return null;
        final conv = AiConv.fromJson(raw);
        final req = msg['client_req'];
        if (pendingReq != null && req == pendingReq) {
          pendingReq = null;
          current = conv;
        } else if (conv.id == openingId || conv.id == current?.id) {
          current = conv;
        }
        if (conv.id == openingId) openingId = null;
      case 'ai:delta':
        final m = _findMessage(msg['conv_id'], msg['msg_id']);
        if (m == null) return null;
        m.text += _str(msg['text']);
        if (m.status == 'pending') m.status = 'running';
      case 'ai:msg':
        final raw = msg['message'];
        final cur = current;
        if (raw is! Map || cur == null || msg['conv_id'] != cur.id) return null;
        final updated = AiMessage.fromJson(raw);
        final i = cur.messages.indexWhere((m) => m.id == updated.id);
        if (i >= 0) {
          cur.messages[i] = updated;
        } else {
          cur.messages.add(updated);
        }
      case 'ai:error':
        pendingReq = null;
        return _str(msg['error'], '请求失败');
    }
    return null;
  }

  AiMessage? _findMessage(Object? convId, Object? msgId) {
    final cur = current;
    if (cur == null || convId != cur.id) return null;
    for (final m in cur.messages.reversed) {
      if (m.id == msgId) return m;
    }
    return null;
  }

  /// 生成 client_req
  static String newReq() {
    final r = Random();
    return List.generate(10, (_) => r.nextInt(36).toRadixString(36)).join();
  }
}

String _str(Object? v, [String fallback = '']) => v is String && v.isNotEmpty ? v : fallback;
double _num(Object? v) => v is num ? v.toDouble() : 0;
List _list(Object? v) => v is List ? v : const [];
