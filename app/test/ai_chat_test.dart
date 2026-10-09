import 'package:flutter_test/flutter_test.dart';
import 'package:nelson_box_app/ai_chat.dart';

Map<String, dynamic> conv(String id, List<Map<String, dynamic>> messages, {String engine = 'codex'}) => {
      'id': id,
      'title': 't-$id',
      'engine': engine,
      'project': 'nelson_box',
      'messages': messages,
    };

Map<String, dynamic> msg(String id, String role, String text, String status, {String? error}) => {
      'id': id,
      'role': role,
      'text': text,
      'status': status,
      'error': ?error,
      'created_at': 1.0,
    };

void main() {
  test('ai:hosts lists available engines and projects', () {
    final ai = AiChat();
    expect(ai.hostOnline, isFalse);
    ai.apply({
      'type': 'ai:hosts',
      'hosts': [
        {
          'id': 'mac_1',
          'name': 'MacBook',
          'engines': [
            {'id': 'claude', 'name': 'Claude Code', 'available': true},
            {'id': 'codex', 'name': 'Codex', 'available': true},
            {'id': 'gemini', 'name': 'Gemini', 'available': false},
          ],
          'projects': [
            {'name': 'nelson_box'},
            {'name': 'game'},
          ],
          'edit_enabled': true,
        }
      ],
    });
    expect(ai.hostOnline, isTrue);
    expect(ai.engines.map((e) => e.id), ['claude', 'codex']);
    expect(ai.projects, ['nelson_box', 'game']);
    expect(ai.engineName('gemini'), 'Gemini');
    ai.apply({'type': 'ai:hosts', 'hosts': []});
    expect(ai.hostOnline, isFalse);
    expect(ai.engines, isEmpty);
  });

  test('send claims the new conversation via client_req; others are ignored', () {
    final ai = AiChat();
    ai.pendingReq = 'r1';
    expect(ai.busy, isTrue);
    // 别的设备新建的对话不会被打开
    ai.apply({'type': 'ai:conv', 'conv': conv('other', [])});
    expect(ai.current, isNull);
    ai.apply({
      'type': 'ai:conv',
      'client_req': 'r1',
      'conv': conv('c1', [msg('u1', 'user', '你好', 'done'), msg('a1', 'assistant', '', 'pending')]),
    });
    expect(ai.pendingReq, isNull);
    expect(ai.current!.id, 'c1');
    expect(ai.current!.messages.length, 2);
    expect(ai.busy, isTrue, reason: 'reply still pending');
  });

  test('ai:delta appends to the right message and marks it running', () {
    final ai = AiChat();
    ai.openingId = 'c1';
    ai.apply({'type': 'ai:conv', 'conv': conv('c1', [msg('u1', 'user', 'q', 'done'), msg('a1', 'assistant', '', 'pending')])});
    expect(ai.openingId, isNull);
    ai.apply({'type': 'ai:delta', 'conv_id': 'c1', 'msg_id': 'a1', 'text': 'Hel'});
    ai.apply({'type': 'ai:delta', 'conv_id': 'c1', 'msg_id': 'a1', 'text': 'lo **世界**'});
    final a = ai.current!.messages.last;
    expect(a.text, 'Hello **世界**');
    expect(a.status, 'running');
    // 其他对话 / 未知消息的增量被忽略
    ai.apply({'type': 'ai:delta', 'conv_id': 'c2', 'msg_id': 'a1', 'text': 'X'});
    ai.apply({'type': 'ai:delta', 'conv_id': 'c1', 'msg_id': 'zz', 'text': 'X'});
    expect(a.text, 'Hello **世界**');
  });

  test('ai:msg replaces the local message (or appends a new one)', () {
    final ai = AiChat();
    ai.current = AiConv.fromJson(conv('c1', [msg('u1', 'user', 'q', 'done'), msg('a1', 'assistant', 'partial', 'running')]));
    ai.apply({'type': 'ai:msg', 'conv_id': 'c1', 'message': msg('a1', 'assistant', 'full answer', 'done')});
    expect(ai.current!.messages.last.text, 'full answer');
    expect(ai.current!.messages.last.status, 'done');
    expect(ai.busy, isFalse);
    ai.apply({'type': 'ai:msg', 'conv_id': 'c1', 'message': msg('a2', 'assistant', '', 'error', error: 'Mac 断开连接')});
    expect(ai.current!.messages.length, 3);
    expect(ai.current!.messages.last.error, 'Mac 断开连接');
    // 别的对话的消息不影响当前对话
    ai.apply({'type': 'ai:msg', 'conv_id': 'c9', 'message': msg('a1', 'assistant', 'nope', 'done')});
    expect(ai.current!.messages[1].text, 'full answer');
  });

  test('reopen after reconnect replaces stale content with the full conversation', () {
    final ai = AiChat();
    ai.current = AiConv.fromJson(conv('c1', [msg('u1', 'user', 'q', 'done'), msg('a1', 'assistant', 'par', 'running')]));
    ai.openingId = 'c1';
    ai.apply({'type': 'ai:conv', 'conv': conv('c1', [msg('u1', 'user', 'q', 'done'), msg('a1', 'assistant', 'partial and more', 'done')])});
    expect(ai.current!.messages.last.text, 'partial and more');
    expect(ai.current!.busy, isFalse);
  });

  test('ai:convs updates the list and drops a deleted current conversation', () {
    final ai = AiChat();
    ai.current = AiConv.fromJson(conv('c1', []));
    ai.apply({
      'type': 'ai:convs',
      'convs': [
        {'id': 'c2', 'title': '新的', 'engine': 'claude', 'project': '', 'updated_at': 2.0, 'busy': true},
        {'id': 'c1', 'title': '旧的', 'engine': 'codex', 'project': 'p', 'updated_at': 1.0, 'busy': false},
      ],
    });
    expect(ai.convs.map((c) => c.id), ['c2', 'c1']);
    expect(ai.convs.first.busy, isTrue);
    expect(ai.current, isNotNull);
    ai.apply({'type': 'ai:convs', 'convs': [{'id': 'c2', 'title': '新的', 'engine': 'claude', 'project': '', 'updated_at': 2.0, 'busy': false}]});
    expect(ai.current, isNull);
  });

  test('ai:error is returned and clears the pending send', () {
    final ai = AiChat();
    ai.pendingReq = 'r';
    expect(ai.apply({'type': 'ai:error', 'error': '上一条回复还没结束'}), '上一条回复还没结束');
    expect(ai.pendingReq, isNull);
    expect(ai.apply({'type': 'ai:conv', 'conv': 'garbage'}), isNull);
  });

  group('models and effort', () {
    final codexJson = {
      'id': 'codex',
      'name': 'Codex',
      'available': true,
      'default_model': 'gpt-5.6-sol',
      'default_effort': 'medium',
      'models': [
        {'id': 'gpt-5.6-sol', 'name': 'GPT-5.6-Sol', 'efforts': ['low', 'medium', 'high']},
        {'id': 'gpt-6-sol', 'name': 'GPT-6-Sol', 'efforts': ['medium', 'high']},
        {'id': 'mini', 'name': 'Mini', 'efforts': []},
        {'name': 'no id is skipped'},
      ],
    };
    AiChat chatWith(Map<String, dynamic> engine) => AiChat()
      ..apply({
        'type': 'ai:hosts',
        'hosts': [
          {'id': 'mac', 'name': 'Mac', 'engines': [engine], 'projects': []}
        ],
      });

    test('parses models, efforts and defaults from ai:hosts', () {
      final e = chatWith(codexJson).engine('codex')!;
      expect(e.defaultModel, 'gpt-5.6-sol');
      expect(e.defaultEffort, 'medium');
      expect(e.models.map((m) => m.id), ['gpt-5.6-sol', 'gpt-6-sol', 'mini']);
      expect(e.model('gpt-6-sol')!.efforts, ['medium', 'high']);
      expect(e.model('mini')!.efforts, isEmpty);
      expect(e.modelName('unknown-x'), 'unknown-x');
      // 旧版主机没有 models 字段
      final old = chatWith({'id': 'claude', 'name': 'Claude Code', 'available': true}).engine('claude')!;
      expect(old.models, isEmpty);
      expect(old.defaultModel, '');
    });

    test('remembered choice falls back to default when no longer offered', () {
      final e = chatWith(codexJson).engine('codex')!;
      expect(ModelChoice.resolve(e, 'gpt-6-sol', 'high'), isA<ModelChoice>()
          .having((c) => c.model, 'model', 'gpt-6-sol')
          .having((c) => c.effort, 'effort', 'high'));
      final gone = ModelChoice.resolve(e, 'gpt-4-old', 'high');
      expect((gone.model, gone.effort), ('', 'high'), reason: 'default model supports high');
      final badEffort = ModelChoice.resolve(e, 'gpt-6-sol', 'low');
      expect((badEffort.model, badEffort.effort), ('gpt-6-sol', ''));
      final noEfforts = ModelChoice.resolve(e, 'mini', 'high');
      expect((noEfforts.model, noEfforts.effort), ('mini', ''));
      expect(ModelChoice.effortsFor(e, ''), ['low', 'medium', 'high']);
      final none = ModelChoice.resolve(null, 'gpt-6-sol', 'high');
      expect((none.model, none.effort), ('', ''));
    });

    test('chip label', () {
      final e = chatWith(codexJson).engine('codex')!;
      expect(const ModelChoice('gpt-6-sol', 'high').label(e), 'GPT-6-Sol · high');
      expect(const ModelChoice('mini').label(e), 'Mini');
      expect(const ModelChoice().label(e), '默认（GPT-5.6-Sol） · medium');
      expect(const ModelChoice('', 'low').label(e), '默认（GPT-5.6-Sol） · low');
      final bare = chatWith({'id': 'x', 'name': 'X', 'available': true}).engine('x');
      expect(const ModelChoice().label(bare), '默认');
    });

    test('ai:send payload has model/effort only when chosen, and always mode ask', () {
      final plain = AiChat.sendPayload(engine: 'codex', project: '', text: 'hi', req: 'r');
      expect(plain, {
        'type': 'ai:send',
        'engine': 'codex',
        'project': '',
        'text': 'hi',
        'mode': 'ask',
        'client_req': 'r',
      });
      final chosen = AiChat.sendPayload(
          convId: 'c1', engine: 'codex', project: 'p', text: 'hi', req: 'r', choice: const ModelChoice('gpt-6-sol', 'high'));
      expect(chosen['conv_id'], 'c1');
      expect(chosen['model'], 'gpt-6-sol');
      expect(chosen['effort'], 'high');
      expect(chosen['mode'], 'ask');
      final effortOnly = AiChat.sendPayload(
          engine: 'codex', project: '', text: 'hi', req: 'r', choice: const ModelChoice('', 'low'));
      expect(effortOnly.containsKey('model'), isFalse);
      expect(effortOnly['effort'], 'low');
    });

    test('assistant messages carry the model/effort actually used', () {
      final ai = chatWith(codexJson);
      ai.current = AiConv.fromJson(conv('c1', [
        {...msg('a1', 'assistant', 'x', 'done'), 'model': 'gpt-6-sol', 'effort': 'high'},
        {...msg('a2', 'assistant', 'y', 'done'), 'model': 'some-new-model'},
        msg('a3', 'assistant', 'z', 'done'),
      ]));
      final ms = ai.current!.messages;
      expect(ai.usedLabel('codex', ms[0]), 'GPT-6-Sol · high');
      expect(ai.usedLabel('codex', ms[1]), 'some-new-model');
      expect(ai.usedLabel('codex', ms[2]), '');
      ai.apply({'type': 'ai:msg', 'conv_id': 'c1', 'message': {...msg('a3', 'assistant', 'z', 'done'), 'model': 'mini'}});
      expect(ai.usedLabel('codex', ai.current!.messages[2]), 'Mini');
    });
  });
}
