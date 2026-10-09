// P2P 文件传输：WebRTC DataChannel 直传，服务器只转发信令。协议见 docs/p2p-protocol.md。
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'hub.dart';
import 'p2p_protocol.dart';

enum TransferDir { send, receive }

enum TransferStatus { waiting, connecting, transferring, done, failed }

/// 已保存到“下载/NelsonBox”的文件
class SavedFile {
  final String name;
  final String uri; // content:// URI，用于打开
  SavedFile(this.name, this.uri);
}

/// 本地要发送的文件（路径 + 显示名）
class LocalFile {
  final String path;
  final String name;
  LocalFile(this.path, this.name);
}

/// 一次传输（界面上的一条记录）
class Transfer {
  final String id;
  final TransferDir dir;
  final String peerId;
  final String peerName;
  final List<FileMeta> files;
  final DateTime startedAt = DateTime.now();

  TransferStatus status;
  String? error;
  int bytes = 0;
  final SpeedMeter speed = SpeedMeter();
  String? connType; // 局域网直连 / 打洞直连 / 服务器中转
  final List<SavedFile> saved = [];

  Transfer(this.id, this.dir, this.peerId, this.peerName, this.files, this.status);

  int get total => files.fold(0, (s, f) => s + f.size);
  bool get active => status != TransferStatus.done && status != TransferStatus.failed;
  double get fraction => total > 0 ? bytes / total : (status == TransferStatus.done ? 1 : 0);

  String get statusText => switch (status) {
        TransferStatus.waiting => '等待对方',
        TransferStatus.connecting => '连接中',
        TransferStatus.transferring => '传输中',
        TransferStatus.done => '完成',
        TransferStatus.failed => '失败：${error ?? '未知错误'}',
      };
}

/// 每次传输对应的 WebRTC 对象和状态
class _Session {
  final Transfer t;
  _Session(this.t);

  // 发送端
  List<File> localFiles = [];
  bool deleteAfter = false;
  final ack = Completer<void>();

  // 接收端
  Directory? tmpDir;
  FileReceiver? receiver;
  _DiskSink? sink;
  Future<void> chain = Future.value(); // 按顺序处理 DataChannel 消息
  Future<void> saves = Future.value(); // 按顺序把收好的文件存到“下载”
  String? saveError;

  final pc = Completer<RTCPeerConnection>();
  RTCDataChannel? dc;
  Timer? timer;
  bool remoteSet = false;
  final List<RTCIceCandidate> pendingIce = [];
  bool opened = false;
  Completer<void>? lowWaiter;
  DateTime lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
}

class P2P extends ChangeNotifier {
  final Hub hub;
  final MethodChannel native;

  /// 本次运行内的传输记录（最新的在前）
  final List<Transfer> transfers = [];
  final Map<String, _Session> _sessions = {};

  /// 文件已保存到“下载/NelsonBox”
  void Function(Transfer t, SavedFile f)? onSaved;

  /// 收到别的设备发来的文件请求（已自动接收）
  void Function(Transfer t)? onIncoming;

  /// 传输失败（用于提示）
  void Function(Transfer t)? onFailed;

  P2P(this.hub, this.native) {
    hub.onSignal = _onSignal;
    hub.onSignalError = _onSignalError;
  }

  // ================= 发送 =================
  /// 发起一次发送；返回 null 表示已发起，否则返回错误信息
  Future<String?> sendFiles(Device peer, List<LocalFile> files, {bool deleteAfter = false}) async {
    Future<void> cleanupLocal() async {
      if (deleteAfter) await Future.wait(files.map((f) => _deleteWithDir(f.path)));
    }

    if (files.isEmpty) return '没有文件';
    if (hub.status != HubStatus.online) {
      await cleanupLocal();
      return '未连接服务器';
    }
    final metas = <FileMeta>[];
    final locals = <File>[];
    for (final f in files) {
      final file = File(f.path);
      try {
        metas.add(FileMeta(f.name, await file.length()));
        locals.add(file);
      } catch (_) {
        await cleanupLocal();
        return '无法读取文件：${f.name}';
      }
    }

    final t = Transfer(newTransferId(), TransferDir.send, peer.id, peer.name, metas, TransferStatus.waiting);
    final s = _Session(t)
      ..localFiles = locals
      ..deleteAfter = deleteAfter;
    _add(s);
    if (!hub.sendSignal(peer.id, Signal.offerFile(t.id, metas))) {
      _fail(s, '未连接服务器');
      return null;
    }
    s.timer = Timer(connectTimeout, () => _fail(s, errNoDirect, cancelPeer: true));
    return null;
  }

  Future<void> _startOffer(_Session s) async {
    if (!s.t.active || s.pc.isCompleted) return;
    s.t.status = TransferStatus.connecting;
    notifyListeners();
    try {
      final pc = await _createPc(s);
      final dc = await pc.createDataChannel(channelLabel, RTCDataChannelInit()..ordered = true);
      _setupChannel(s, dc);
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      _signal(s, Signal.sdp(s.t.id, offer.type ?? 'offer', offer.sdp ?? ''));
    } catch (e) {
      _fail(s, errNoDirect, cancelPeer: true);
    }
  }

  Future<void> _runSender(_Session s) async {
    final dc = s.dc!;
    final pipe = _RtcPipe(dc, s);
    try {
      final sender = FileSender(
        pipe,
        onProgress: (b) => _progress(s, b),
        isCancelled: () => !s.t.active,
      );
      await sender.sendAll(s.localFiles, s.t.files);
      // 等接收方回 ack 再关闭，避免缓冲区里的数据被丢掉
      await s.ack.future.timeout(const Duration(seconds: 60));
      _finish(s);
    } on TransferException catch (e) {
      _fail(s, e.message, cancelPeer: true);
    } catch (_) {
      _fail(s, errInterrupted, cancelPeer: true);
    }
  }

  // ================= 接收 =================
  Future<void> _onOffer(String from, String fromName, String id, Map<String, dynamic> data) async {
    if (_sessions.containsKey(id)) return;
    final List<FileMeta> metas;
    try {
      metas = FileMeta.listFromJson(data['files']);
    } on FormatException {
      hub.sendSignal(from, Signal.decline(id, '文件信息格式错误'));
      return;
    }
    final t = Transfer(id, TransferDir.receive, from, fromName, metas, TransferStatus.connecting);
    final s = _Session(t);
    _add(s);
    onIncoming?.call(t);
    s.timer = Timer(connectTimeout, () => _fail(s, errNoDirect, cancelPeer: true));

    try {
      // Android 9 及以下要先拿到存储权限
      final ok = await native.invokeMethod<bool>('ensureStoragePermission') ?? true;
      if (!ok) {
        hub.sendSignal(from, Signal.decline(id, '对方没有存储权限'));
        _fail(s, '没有存储权限，无法保存');
        return;
      }
      final cache = await native.invokeMethod<String>('cacheDir');
      s.tmpDir = await Directory('${cache ?? Directory.systemTemp.path}/p2p_recv/$id').create(recursive: true);
      s.sink = _DiskSink(this, s);
      s.receiver = FileReceiver(s.sink!, metas, onProgress: (b) => _progress(s, b));
      if (!s.t.active) return await _cleanup(s);

      final pc = await _createPc(s);
      pc.onDataChannel = (dc) => _setupChannel(s, dc);
      _signal(s, Signal.accept(id));
    } catch (e) {
      _fail(s, '无法接收：$e', cancelPeer: true);
    }
  }

  Future<void> _handleIncoming(_Session s, RTCDataChannelMessage msg) async {
    final r = s.receiver;
    if (!s.t.active || r == null) return;
    try {
      if (msg.isBinary) {
        await r.handleBinary(msg.binary);
      } else {
        final reply = await r.handleText(msg.text);
        if (reply != null) {
          await s.dc?.send(RTCDataChannelMessage(reply.encode()));
          await _finishReceive(s);
        }
      }
    } on TransferException catch (e) {
      await _sendErrorFrame(s, e.message);
      _fail(s, e.message);
    } catch (e) {
      await _sendErrorFrame(s, '接收方保存失败');
      _fail(s, '保存失败：$e');
    }
  }

  Future<void> _finishReceive(_Session s) async {
    // ack 已发出；等所有文件存进“下载”后再标记完成
    await s.saves;
    if (s.saveError != null) {
      _fail(s, s.saveError!);
    } else {
      _finish(s);
    }
  }

  /// 收齐一个文件后排队保存（不阻塞后续数据的接收）
  void _queueSave(_Session s, File tmp, String name) {
    s.saves = s.saves.then((_) async {
      try {
        if (s.saveError == null && s.t.status != TransferStatus.failed) {
          final r = await native.invokeMapMethod<String, dynamic>(
              'saveToDownloads', {'path': tmp.path, 'name': safeFileName(name)});
          final saved = SavedFile(r?['name'] as String? ?? name, r?['uri'] as String? ?? '');
          s.t.saved.add(saved);
          notifyListeners();
          onSaved?.call(s.t, saved);
        }
      } catch (e) {
        s.saveError = '保存到下载目录失败：${e is PlatformException ? e.message : e}';
      } finally {
        try {
          await tmp.delete();
        } catch (_) {}
      }
    });
  }

  // ================= 公共 =================
  /// 用户取消
  void cancel(Transfer t) {
    final s = _sessions[t.id];
    if (s != null) _fail(s, '已取消', cancelPeer: true);
  }

  /// 打开已保存的文件
  Future<String?> open(SavedFile f) async {
    try {
      await native.invokeMethod('openFile', {'uri': f.uri, 'name': f.name});
      return null;
    } on PlatformException catch (e) {
      return e.message ?? '无法打开';
    }
  }

  void clearFinished() {
    transfers.removeWhere((t) => !t.active);
    notifyListeners();
  }

  void _add(_Session s) {
    _sessions[s.t.id] = s;
    transfers.insert(0, s.t);
    notifyListeners();
  }

  void _signal(_Session s, Map<String, dynamic> data) {
    if (!hub.sendSignal(s.t.peerId, data) && !s.opened) {
      _fail(s, '与服务器的连接已断开');
    }
  }

  void _onSignal(String from, String fromName, Map<String, dynamic> data) {
    final id = data['transfer_id'];
    if (id is! String || id.isEmpty) return;
    final kind = data['kind'];
    if (kind == 'offer-file') {
      _onOffer(from, fromName, id, data);
      return;
    }
    final s = _sessions[id];
    if (s == null || s.t.peerId != from || !s.t.active) return;
    switch (kind) {
      case 'accept':
        if (s.t.dir == TransferDir.send) _startOffer(s);
      case 'decline':
        final reason = data['reason'];
        _fail(s, reason is String && reason.isNotEmpty ? '对方拒绝接收：$reason' : '对方拒绝接收');
      case 'cancel':
        _fail(s, errPeerCancelled);
      case 'sdp':
        _onSdp(s, data['sdp']);
      case 'ice':
        _onIce(s, data['candidate']);
    }
  }

  void _onSignalError(String? id, String error) {
    final s = _sessions[id];
    if (s != null && !s.opened) _fail(s, error);
  }

  Future<void> _onSdp(_Session s, Object? raw) async {
    if (raw is! Map || raw['sdp'] is! String || raw['type'] is! String) return;
    try {
      final pc = await s.pc.future;
      await pc.setRemoteDescription(RTCSessionDescription(raw['sdp'] as String, raw['type'] as String));
      s.remoteSet = true;
      for (final c in s.pendingIce) {
        await pc.addCandidate(c);
      }
      s.pendingIce.clear();
      if (raw['type'] == 'offer') {
        final answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        _signal(s, Signal.sdp(s.t.id, answer.type ?? 'answer', answer.sdp ?? ''));
      }
    } catch (_) {
      _fail(s, errNoDirect, cancelPeer: true);
    }
  }

  Future<void> _onIce(_Session s, Object? raw) async {
    if (raw is! Map || raw['candidate'] is! String) return;
    final mline = raw['sdpMLineIndex'];
    final c = RTCIceCandidate(raw['candidate'] as String, raw['sdpMid'] as String?, mline is num ? mline.toInt() : null);
    if (!s.remoteSet) {
      s.pendingIce.add(c);
      return;
    }
    try {
      await (await s.pc.future).addCandidate(c);
    } catch (_) {}
  }

  Future<RTCPeerConnection> _createPc(_Session s) async {
    final pc = await createPeerConnection({
      'iceServers': hub.iceServers, // STUN + TURN：优先直连，失败时经服务器转发（端到端加密）
      'sdpSemantics': 'unified-plan',
    });
    if (!s.pc.isCompleted) s.pc.complete(pc);
    pc.onIceCandidate = (c) {
      final cand = c.candidate;
      if (cand == null || cand.isEmpty || !s.t.active) return;
      hub.sendSignal(s.t.peerId, Signal.ice(s.t.id, cand, c.sdpMid, c.sdpMLineIndex));
    };
    pc.onConnectionState = (st) {
      // 接收端收到 done 后，发送方关闭连接是正常的
      if (st == RTCPeerConnectionState.RTCPeerConnectionStateFailed && s.receiver?.done != true) {
        _fail(s, s.opened ? errInterrupted : errNoDirect, cancelPeer: true);
      }
    };
    return pc;
  }

  void _setupChannel(_Session s, RTCDataChannel dc) {
    if (dc.label != channelLabel) return;
    s.dc = dc;
    dc.bufferedAmountLowThreshold = bufferLow;
    dc.onBufferedAmountLow = (_) {
      final w = s.lowWaiter;
      if (w != null && !w.isCompleted) w.complete();
    };
    dc.onDataChannelState = (st) {
      if (st == RTCDataChannelState.RTCDataChannelOpen) {
        _onOpen(s);
      } else if (st == RTCDataChannelState.RTCDataChannelClosed) {
        // 接收端收到 done 之后，发送方关闭连接是正常的
        if (s.receiver?.done != true) _fail(s, errInterrupted);
      }
    };
    dc.onMessage = (msg) {
      if (s.t.dir == TransferDir.send) {
        if (msg.isBinary) return;
        try {
          switch (Frame.decode(msg.text)) {
            case AckFrame():
              if (!s.ack.isCompleted) s.ack.complete();
            case ErrorFrame f:
              _fail(s, f.message);
            default:
              break;
          }
        } on FormatException {
          // 忽略无法识别的帧
        }
      } else {
        s.chain = s.chain.then((_) => _handleIncoming(s, msg));
      }
    };
    if (dc.state == RTCDataChannelState.RTCDataChannelOpen) _onOpen(s);
  }

  void _onOpen(_Session s) {
    if (s.opened || !s.t.active) return;
    s.opened = true;
    s.timer?.cancel();
    s.t.status = TransferStatus.transferring;
    notifyListeners();
    _detectConnType(s);
    if (s.t.dir == TransferDir.send) _runSender(s);
  }

  /// 从 getStats 里取选中的候选对，判断是局域网直连还是打洞直连
  Future<void> _detectConnType(_Session s) async {
    for (var attempt = 0; attempt < 3 && s.t.connType == null; attempt++) {
      await Future.delayed(const Duration(milliseconds: 800));
      try {
        final pc = await s.pc.future;
        final reports = await pc.getStats();
        final byId = {for (final r in reports) r.id: r};
        StatsReport? pair;
        for (final r in reports) {
          final sel = r.values['selectedCandidatePairId'];
          if (r.type == 'transport' && sel is String) pair = byId[sel];
        }
        pair ??= reports.where((r) =>
            r.type == 'candidate-pair' &&
            (r.values['selected'] == true ||
                (r.values['nominated'] == true && r.values['state'] == 'succeeded'))).firstOrNull;
        if (pair == null) continue;
        final types = [
          byId[pair.values['localCandidateId']]?.values['candidateType'],
          byId[pair.values['remoteCandidateId']]?.values['candidateType'],
        ];
        if (types.contains(null)) continue;
        s.t.connType = types.contains('relay')
            ? '服务器中转'
            : types.every((t) => t == 'host')
                ? '局域网直连'
                : '打洞直连';
        notifyListeners();
      } catch (_) {
        return;
      }
    }
  }

  void _progress(_Session s, int bytes) {
    s.t.bytes = bytes;
    s.t.speed.sample(bytes);
    final now = DateTime.now();
    if (now.difference(s.lastNotify).inMilliseconds >= 200 || bytes >= s.t.total) {
      s.lastNotify = now;
      notifyListeners();
    }
  }

  Future<void> _sendErrorFrame(_Session s, String message) async {
    try {
      await s.dc?.send(RTCDataChannelMessage(ErrorFrame(message).encode()));
    } catch (_) {}
  }

  void _finish(_Session s) {
    if (!s.t.active) return;
    s.t.status = TransferStatus.done;
    s.t.bytes = s.t.total;
    notifyListeners();
    _cleanup(s, closeDelay: s.t.dir == TransferDir.receive ? const Duration(seconds: 3) : Duration.zero);
  }

  void _fail(_Session s, String message, {bool cancelPeer = false}) {
    if (!s.t.active) return;
    s.t.status = TransferStatus.failed;
    s.t.error = message;
    if (cancelPeer) hub.sendSignal(s.t.peerId, Signal.cancel(s.t.id, message));
    notifyListeners();
    onFailed?.call(s.t);
    _cleanup(s);
  }

  Future<void> _cleanup(_Session s, {Duration closeDelay = Duration.zero}) async {
    s.timer?.cancel();
    final w = s.lowWaiter;
    if (w != null && !w.isCompleted) w.complete();
    if (!s.ack.isCompleted) s.ack.complete();
    if (s.deleteAfter) {
      await Future.wait(s.localFiles.map((f) => _deleteWithDir(f.path)));
    }
    // 接收端：未完成的临时文件全部删掉
    await s.sink?.close();
    {
      // 等正在进行的保存结束后再删临时目录
      final dir = s.tmpDir;
      if (dir != null) {
        s.saves.whenComplete(() async {
          try {
            await dir.delete(recursive: true);
          } catch (_) {}
        });
      }
    }
    if (closeDelay > Duration.zero) await Future.delayed(closeDelay);
    try {
      await s.dc?.close();
    } catch (_) {}
    if (s.pc.isCompleted) {
      try {
        final pc = await s.pc.future;
        await pc.close();
        await pc.dispose();
      } catch (_) {}
    }
  }

  static Future<void> _deleteWithDir(String path) async {
    try {
      final f = File(path);
      await f.delete();
      await f.parent.delete(); // 临时副本各自在独立的子目录里；非空会失败，忽略
    } catch (_) {}
  }
}

/// 把 RTCDataChannel 包装成协议层的 DataPipe（含流控）
class _RtcPipe implements DataPipe {
  final RTCDataChannel dc;
  final _Session s;
  _RtcPipe(this.dc, this.s);

  void _check() {
    if (!s.t.active) throw const TransferException('已取消');
    if (dc.state == RTCDataChannelState.RTCDataChannelClosed) throw const TransferException(errInterrupted);
  }

  @override
  Future<void> sendText(String text) async {
    _check();
    await dc.send(RTCDataChannelMessage(text));
  }

  @override
  Future<void> sendBytes(Uint8List bytes) async {
    _check();
    await dc.send(RTCDataChannelMessage.fromBinary(bytes));
  }

  @override
  Future<int> bufferedAmount() => dc.getBufferedAmount();

  @override
  Future<void> waitBufferLow() async {
    // 等 bufferedAmountLow 事件；事件可能漏掉，所以同时每 100ms 主动查一次
    while (true) {
      _check();
      final w = s.lowWaiter = Completer<void>();
      await Future.any([w.future, Future.delayed(const Duration(milliseconds: 100))]);
      if (await dc.getBufferedAmount() <= bufferLow) return;
    }
  }
}

/// 接收端：把数据写进缓存目录的临时文件，收齐后交给原生层存到“下载/NelsonBox”
class _DiskSink implements ReceiveSink {
  final P2P p2p;
  final _Session s;
  _DiskSink(this.p2p, this.s);

  RandomAccessFile? _raf;
  File? _file;

  @override
  Future<void> open(int index, String name, int size) async {
    await close();
    final f = File('${s.tmpDir!.path}/$index');
    _file = f;
    _raf = await f.open(mode: FileMode.write);
  }

  @override
  Future<void> write(Uint8List bytes) async {
    final raf = _raf;
    if (raf == null) throw const TransferException('协议错误：文件未打开');
    await raf.writeFrom(bytes);
  }

  @override
  Future<void> finish(int index, String name) async {
    final f = _file!;
    await _raf?.close();
    _raf = null;
    _file = null;
    p2p._queueSave(s, f, name);
  }

  Future<void> close() async {
    final raf = _raf;
    _raf = null;
    try {
      await raf?.close();
    } catch (_) {}
  }
}
