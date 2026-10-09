import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'ai_chat.dart';
import 'hub.dart';
import 'platform.dart';

/// “AI”标签页：通过服务器和 Mac 上的 AI 命令行对话。
/// Android 只读问答；桌面端（Windows）可切换到“可修改”模式（需要 Mac 上设置的编辑口令）。
class AiTab extends StatefulWidget {
  final Hub hub;
  final void Function(String msg) toast;
  const AiTab({super.key, required this.hub, required this.toast});

  @override
  State<AiTab> createState() => _AiTabState();
}

class _AiTabState extends State<AiTab> with AutomaticKeepAliveClientMixin {
  final _input = TextEditingController();
  final _passcode = TextEditingController();
  late final FocusNode _inputFocus = FocusNode(onKeyEvent: _onInputKey);
  bool _edit = false; // 桌面端：可修改模式
  bool _showPasscode = false;

  // 编辑口令存在系统凭据库（Windows 凭据管理器）里，不放 shared_preferences
  static const _secure = FlutterSecureStorage();
  static const _passcodeKey = 'nelsonbox_ai_edit_passcode';

  bool get _editAllowed => AppPlatform.allowsAiEdit && ai.editEnabled;

  @override
  void initState() {
    super.initState();
    if (AppPlatform.allowsAiEdit) {
      _secure.read(key: _passcodeKey).then((v) {
        if (mounted && v != null && _passcode.text.isEmpty) _passcode.text = v;
      }).catchError((_) {});
    }
  }

  /// 桌面端：Enter 发送，Shift+Enter 换行
  KeyEventResult _onInputKey(FocusNode node, KeyEvent event) {
    if (!AppPlatform.isDesktop || event is! KeyDownEvent) return KeyEventResult.ignored;
    final enter = event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!enter || HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
    // 输入法正在组字时（中文候选框）Enter 交给输入法
    if (_input.value.composing.isValid && !_input.value.composing.isCollapsed) return KeyEventResult.ignored;
    if (_canSend) _send();
    return KeyEventResult.handled;
  }

  bool get _canSend =>
      hub.status == HubStatus.online && !ai.busy && (ai.current != null || _engine != null);

  void _savePasscode() {
    final v = _passcode.text;
    (v.isEmpty ? _secure.delete(key: _passcodeKey) : _secure.write(key: _passcodeKey, value: v)).catchError((_) {});
  }

  Hub get hub => widget.hub;
  AiChat get ai => widget.hub.ai;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _input.dispose();
    _passcode.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  /// 当前选中的引擎：记住的优先，否则第一个可用的
  String? get _engine {
    final engines = ai.engines;
    for (final e in engines) {
      if (e.id == hub.aiEngine) return e.id;
    }
    return engines.isEmpty ? null : engines.first.id;
  }

  String get _project => ai.projects.contains(hub.aiProject) ? hub.aiProject : '';

  void _send() {
    final text = _input.text;
    final engine = ai.current?.engine ?? _engine;
    if (engine == null) {
      widget.toast(ai.hostOnline ? 'Mac 上没有可用的 AI' : 'Mac 不在线');
      return;
    }
    final edit = _editAllowed && _edit;
    final err = hub.aiSend(text,
        engine: engine,
        project: _project,
        choice: hub.aiChoice(engine),
        edit: edit,
        passcode: edit ? _passcode.text.trim() : '');
    if (err != null) {
      widget.toast(err);
      return;
    }
    if (edit) _savePasscode();
    _input.clear();
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    widget.toast('已复制');
  }

  Future<bool> _confirmDelete(AiConvSummary c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除对话'),
        content: Text('确定删除“${c.title}”吗？所有设备上都会删除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return false;
    if (!hub.aiDelete(c.id)) {
      widget.toast('未连接服务器');
      return false;
    }
    return true;
  }

  /// 选模型 / 推理强度（每条消息都可以不同，对已有对话也生效）
  void _showModelPicker(String engineId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => ListenableBuilder(
        listenable: hub,
        builder: (ctx, _) {
          final engine = ai.engine(engineId);
          if (engine == null) return const SafeArea(child: ListTile(title: Text('Mac 不在线')));
          final choice = hub.aiChoice(engineId);
          final efforts = ModelChoice.effortsFor(engine, choice.model);
          final defaultModel = engine.defaultModel.isEmpty ? '' : '（${engine.modelName(engine.defaultModel)}）';
          final showDefaultEffort = choice.model.isEmpty || choice.model == engine.defaultModel;
          final defaultEffort =
              showDefaultEffort && engine.defaultEffort.isNotEmpty ? '（${engine.defaultEffort}）' : '';
          Widget option(String title, bool selected, VoidCallback onTap) => ListTile(
                dense: true,
                title: Text(title),
                trailing: selected ? Icon(Icons.check, color: Theme.of(ctx).colorScheme.primary) : null,
                onTap: onTap,
              );
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
              child: ListView(shrinkWrap: true, children: [
                ListTile(title: Text('${engine.name} 模型'), subtitle: const Text('每条消息都可以换，只影响之后发出的消息')),
                option('默认$defaultModel', choice.model.isEmpty,
                    () => hub.setAiChoice(engineId, ModelChoice.resolve(engine, '', choice.effort))),
                for (final m in engine.models)
                  option(m.name, choice.model == m.id,
                      () => hub.setAiChoice(engineId, ModelChoice.resolve(engine, m.id, choice.effort))),
                if (efforts.isNotEmpty) ...[
                  const Divider(),
                  const ListTile(title: Text('推理强度')),
                  option('默认$defaultEffort', choice.effort.isEmpty,
                      () => hub.setAiChoice(engineId, ModelChoice(choice.model))),
                  for (final e in efforts)
                    option(e, choice.effort == e, () => hub.setAiChoice(engineId, ModelChoice(choice.model, e))),
                ],
              ]),
            ),
          );
        },
      ),
    );
  }

  void _showConvs() {
    hub.aiList();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => ListenableBuilder(
        listenable: hub,
        builder: (ctx, _) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const ListTile(title: Text('对话记录'), subtitle: Text('点击打开 · 左滑或长按删除')),
              if (ai.convs.isEmpty)
                const Padding(padding: EdgeInsets.all(24), child: Text('暂无对话')),
              Flexible(
                child: ListView(shrinkWrap: true, children: [
                  for (final c in ai.convs)
                    Dismissible(
                      key: ValueKey(c.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: Theme.of(ctx).colorScheme.errorContainer,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 24),
                        child: const Icon(Icons.delete_outline),
                      ),
                      confirmDismiss: (_) => _confirmDelete(c),
                      child: ListTile(
                        selected: c.id == ai.current?.id,
                        title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text([
                          ai.engineName(c.engine),
                          c.project.isEmpty ? '不选项目' : c.project,
                          _formatTime(c.updatedAt),
                        ].join(' · ')),
                        trailing: c.busy
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : null,
                        onTap: () {
                          Navigator.pop(ctx);
                          hub.aiOpen(c.id);
                        },
                        onLongPress: () => _confirmDelete(c),
                      ),
                    ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final cur = ai.current;
    final online = hub.status == HubStatus.online;
    final canSend = _canSend;
    final messages = cur?.messages ?? const <AiMessage>[];
    final engineId = cur?.engine ?? _engine;
    final activeEngine = engineId == null ? null : ai.engine(engineId);

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
        child: Row(children: [
          Expanded(child: _selectors(cur)),
          IconButton(tooltip: '对话记录', icon: const Icon(Icons.history), onPressed: _showConvs),
          IconButton(
            tooltip: '新对话',
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: cur == null && ai.openingId == null ? null : hub.aiNew,
          ),
        ]),
      ),
      if (activeEngine != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 2),
          child: Align(
            alignment: Alignment.centerLeft,
            child: ActionChip(
              avatar: const Icon(Icons.tune, size: 16),
              label: Text(hub.aiChoice(activeEngine.id).label(activeEngine),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              visualDensity: VisualDensity.compact,
              onPressed: () => _showModelPicker(activeEngine.id),
            ),
          ),
        ),
      if (AppPlatform.allowsAiEdit) _modeBar(theme),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          Icon(_editAllowed && _edit ? Icons.edit_note : Icons.lock_outline,
              size: 14, color: _editAllowed && _edit ? theme.colorScheme.error : theme.colorScheme.outline),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
                !AppPlatform.allowsAiEdit
                    ? '手机端只能问答，AI 不会修改 Mac 上的文件'
                    : _editAllowed && _edit
                        ? '可修改模式下 AI 可以在 Mac 上修改项目文件、运行命令'
                        : _editAllowed
                            ? '只读：AI 只能读文件、回答问题。可修改模式下 AI 可以在 Mac 上修改项目文件、运行命令'
                            : '只读：AI 只能读文件、回答问题（Mac 上没有开启可修改模式）',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: _editAllowed && _edit ? theme.colorScheme.error : theme.colorScheme.outline)),
          ),
        ]),
      ),
      const Divider(height: 12),
      Expanded(
        child: ai.openingId != null && cur?.id != ai.openingId
            ? const Center(child: CircularProgressIndicator())
            : messages.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        ai.hostOnline ? '向 Mac 上的 AI 提问，例如“这个项目的入口在哪里？”' : 'Mac 不在线\n请在 Mac 上打开 NelsonBox',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
                      ),
                    ),
                  )
                : ListView.builder(
                    reverse: true, // 新消息在底部，流式输出时自动停在最下面
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    itemCount: messages.length,
                    itemBuilder: (_, i) => _bubble(messages[messages.length - 1 - i], cur!.engine),
                  ),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
              child: TextField(
                controller: _input,
                focusNode: _inputFocus,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: !online
                      ? '未连接服务器'
                      : ai.busy
                          ? '等待回复结束…'
                          : (cur == null ? '新对话：输入问题' : '继续提问') +
                              (AppPlatform.isDesktop ? '（Enter 发送，Shift+Enter 换行）' : ''),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            IconButton(
              tooltip: '发送',
              icon: const Icon(Icons.send),
              onPressed: canSend ? _send : null,
            ),
          ]),
        ),
      ),
    ]);
  }

  /// 桌面端：只读问答 / 可修改 切换 + 编辑口令
  Widget _modeBar(ThemeData theme) {
    final edit = _editAllowed && _edit;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
      child: Wrap(spacing: 12, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SegmentedButton<bool>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: [
            const ButtonSegment(value: false, label: Text('只读问答'), icon: Icon(Icons.lock_outline, size: 16)),
            ButtonSegment(
              value: true,
              label: const Text('可修改'),
              icon: const Icon(Icons.edit_outlined, size: 16),
              enabled: _editAllowed,
              tooltip: _editAllowed ? null : 'Mac 上没有设置编辑口令',
            ),
          ],
          selected: {edit},
          onSelectionChanged: (v) => setState(() => _edit = v.first),
        ),
        if (edit)
          SizedBox(
            width: 240,
            child: TextField(
              controller: _passcode,
              obscureText: !_showPasscode,
              decoration: InputDecoration(
                isDense: true,
                labelText: '编辑口令',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_showPasscode ? Icons.visibility_off : Icons.visibility, size: 18),
                  onPressed: () => setState(() => _showPasscode = !_showPasscode),
                ),
              ),
              onChanged: (v) {
                if (v.isEmpty) _savePasscode(); // 清空即忘记口令
              },
            ),
          ),
      ]),
    );
  }

  Widget _selectors(AiConv? cur) {
    final theme = Theme.of(context);
    if (cur != null) {
      // 已有对话：引擎和项目固定
      return Text(
        '${ai.engineName(cur.engine)} · ${cur.project.isEmpty ? '不选项目' : cur.project}',
        style: theme.textTheme.labelLarge,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    if (!ai.hostOnline) {
      return Row(children: [
        Icon(Icons.circle, size: 10, color: theme.colorScheme.error),
        const SizedBox(width: 6),
        const Text('Mac 不在线'),
      ]);
    }
    final engines = ai.engines;
    if (engines.isEmpty) return const Text('Mac 上没有可用的 AI');
    return Row(children: [
      DropdownButton<String>(
        value: _engine,
        underline: const SizedBox(),
        items: [for (final e in engines) DropdownMenuItem(value: e.id, child: Text(e.name))],
        onChanged: (v) => setState(() => hub.setAiPrefs(engine: v)),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: DropdownButton<String>(
          value: _project,
          isExpanded: true,
          underline: const SizedBox(),
          items: [
            const DropdownMenuItem(value: '', child: Text('不选项目')),
            for (final p in ai.projects) DropdownMenuItem(value: p, child: Text(p, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() => hub.setAiPrefs(project: v ?? '')),
        ),
      ),
    ]);
  }

  Widget _bubble(AiMessage m, String engineId) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    var maxWidth = MediaQuery.of(context).size.width * (m.isUser ? 0.8 : 0.92);
    if (AppPlatform.isDesktop && maxWidth > 820) maxWidth = 820;
    if (m.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: GestureDetector(
          onLongPress: () => _copy(m.text),
          child: Container(
            constraints: BoxConstraints(maxWidth: maxWidth),
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(14)),
            child: AppPlatform.allowsAiEdit && m.mode == 'edit'
                ? Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(m.text, style: TextStyle(color: scheme.onPrimaryContainer)),
                    Text('可修改', style: theme.textTheme.labelSmall?.copyWith(color: scheme.error)),
                  ])
                : Text(m.text, style: TextStyle(color: scheme.onPrimaryContainer)),
          ),
        ),
      );
    }

    final status = switch (m.status) {
      'pending' => _statusRow('等待 Mac…', spinner: true),
      'running' => _statusRow('生成中', spinner: true, stop: () => hub.aiCancel(m.id)),
      'error' => _statusRow('失败：${m.error ?? '未知错误'}', color: scheme.error),
      'cancelled' => _statusRow('已取消', color: scheme.outline),
      _ => null,
    };
    return Align(
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: m.text.isEmpty ? null : () => _copy(m.text),
        child: Container(
          constraints: BoxConstraints(maxWidth: maxWidth),
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(14)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (m.text.isNotEmpty)
              MarkdownBody(
                data: m.text,
                selectable: true,
                styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                  code: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                  codeblockDecoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  blockquoteDecoration: BoxDecoration(
                    color: scheme.surface.withValues(alpha: 0.5),
                    border: Border(left: BorderSide(color: scheme.outlineVariant, width: 3)),
                  ),
                ),
              ),
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  status ?? const SizedBox(height: 4),
                  if (ai.usedLabel(engineId, m, showMode: AppPlatform.allowsAiEdit) case final used when used.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(used,
                          style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline)),
                    ),
                ]),
              ),
              if (m.text.isNotEmpty && !m.active)
                IconButton(
                  tooltip: '复制',
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  icon: const Icon(Icons.copy),
                  onPressed: () => _copy(m.text),
                ),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _statusRow(String text, {bool spinner = false, Color? color, VoidCallback? stop}) {
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: color);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        if (spinner) ...[
          const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 8),
        ],
        Flexible(child: Text(text, style: style)),
        if (stop != null)
          TextButton.icon(
            onPressed: stop,
            icon: const Icon(Icons.stop_circle_outlined, size: 18),
            label: const Text('停止'),
          ),
      ]),
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
