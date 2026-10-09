// P2P 文件传输协议的纯逻辑部分（不依赖 WebRTC，便于单元测试）。
// 协议说明见 docs/p2p-protocol.md。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

const chunkSize = 16384; // 每个二进制块的最大字节数
const bufferHigh = 1024 * 1024; // bufferedAmount 超过它就暂停发送
const bufferLow = 256 * 1024; // bufferedAmountLow 阈值
const connectTimeout = Duration(seconds: 20); // DataChannel 打开的超时
const channelLabel = 'file';

const errOffline = '对方不在线';
const errNoDirect = '无法建立直连（双方网络都不支持打洞）';
const errPeerCancelled = '对方已取消';
const errInterrupted = '传输中断';

/// 生成 transfer_id
String newTransferId() {
  final r = Random.secure();
  return List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
}

/// 一个要传输的文件（名称 + 大小）
class FileMeta {
  final String name;
  final int size;
  const FileMeta(this.name, this.size);

  Map<String, dynamic> toJson() => {'name': name, 'size': size};

  /// 解析信令里的 files 数组，格式不对时抛 FormatException
  static List<FileMeta> listFromJson(Object? raw) {
    if (raw is! List || raw.isEmpty) throw const FormatException('files 为空');
    return raw.map((e) {
      if (e is! Map) throw const FormatException('files 格式错误');
      final name = e['name'];
      final size = e['size'];
      if (name is! String || size is! num || size < 0) throw const FormatException('files 格式错误');
      return FileMeta(name, size.toInt());
    }).toList();
  }
}

// ---------- 信令消息（rtc:signal 的 data 字段） ----------
class Signal {
  static Map<String, dynamic> offerFile(String id, List<FileMeta> files) => {
        'kind': 'offer-file',
        'transfer_id': id,
        'files': files.map((f) => f.toJson()).toList(),
        'total': files.fold<int>(0, (s, f) => s + f.size),
      };
  static Map<String, dynamic> accept(String id) => {'kind': 'accept', 'transfer_id': id};
  static Map<String, dynamic> decline(String id, String reason) =>
      {'kind': 'decline', 'transfer_id': id, 'reason': reason};
  static Map<String, dynamic> sdp(String id, String type, String sdp) => {
        'kind': 'sdp',
        'transfer_id': id,
        'sdp': {'type': type, 'sdp': sdp},
      };
  static Map<String, dynamic> ice(String id, String candidate, String? sdpMid, int? sdpMLineIndex) => {
        'kind': 'ice',
        'transfer_id': id,
        'candidate': {'candidate': candidate, 'sdpMid': sdpMid, 'sdpMLineIndex': sdpMLineIndex},
      };
  static Map<String, dynamic> cancel(String id, String reason) =>
      {'kind': 'cancel', 'transfer_id': id, 'reason': reason};
}

// ---------- DataChannel 控制帧 ----------
sealed class Frame {
  const Frame();

  Map<String, dynamic> toJson();
  String encode() => jsonEncode(toJson());

  /// 解析文本帧；无法识别时抛 FormatException
  static Frame decode(String text) {
    final Object? raw;
    try {
      raw = jsonDecode(text);
    } catch (_) {
      throw const FormatException('控制帧不是 JSON');
    }
    if (raw is! Map) throw const FormatException('控制帧格式错误');
    final Map j = raw;
    int index() {
      final i = j['index'];
      if (i is! int || i < 0) throw const FormatException('控制帧缺少 index');
      return i;
    }

    switch (j['t']) {
      case 'file':
        final name = j['name'];
        final size = j['size'];
        if (name is! String || size is! num || size < 0) throw const FormatException('file 帧格式错误');
        return FileStartFrame(index(), name, size.toInt());
      case 'end':
        return FileEndFrame(index());
      case 'done':
        return const DoneFrame();
      case 'ack':
        return const AckFrame();
      case 'error':
        return ErrorFrame(j['message']?.toString() ?? '对方出错');
      default:
        throw FormatException('未知控制帧: ${j['t']}');
    }
  }
}

class FileStartFrame extends Frame {
  final int index;
  final String name;
  final int size;
  const FileStartFrame(this.index, this.name, this.size);
  @override
  Map<String, dynamic> toJson() => {'t': 'file', 'index': index, 'name': name, 'size': size};
}

class FileEndFrame extends Frame {
  final int index;
  const FileEndFrame(this.index);
  @override
  Map<String, dynamic> toJson() => {'t': 'end', 'index': index};
}

class DoneFrame extends Frame {
  const DoneFrame();
  @override
  Map<String, dynamic> toJson() => {'t': 'done'};
}

class AckFrame extends Frame {
  const AckFrame();
  @override
  Map<String, dynamic> toJson() => {'t': 'ack'};
}

class ErrorFrame extends Frame {
  final String message;
  const ErrorFrame(this.message);
  @override
  Map<String, dynamic> toJson() => {'t': 'error', 'message': message};
}

/// 传输过程中的错误（消息会直接显示给用户）
class TransferException implements Exception {
  final String message;
  const TransferException(this.message);
  @override
  String toString() => message;
}

// ---------- 发送端 ----------
/// DataChannel 的最小抽象，测试里用假的实现
abstract class DataPipe {
  Future<void> sendText(String text);
  Future<void> sendBytes(Uint8List bytes);

  /// 查询当前真实的 bufferedAmount
  Future<int> bufferedAmount();

  /// 等到 bufferedAmount 降到 [bufferLow] 以下
  Future<void> waitBufferLow();
}

/// 按协议把文件逐个发出去：file 帧 → 二进制块 → end 帧 … → done。
/// 从磁盘边读边发，不把整个文件读进内存。
class FileSender {
  final DataPipe pipe;
  final void Function(int sentBytes)? onProgress;
  final bool Function()? isCancelled;

  /// 每发多少字节查询一次真实的 bufferedAmount（Dart 侧的值是事件推送的，可能滞后）
  final int checkEvery;

  FileSender(this.pipe, {this.onProgress, this.isCancelled, this.checkEvery = bufferLow});

  int _sent = 0;
  int _unchecked = 0;

  Future<void> sendAll(List<File> files, List<FileMeta> metas) async {
    for (var i = 0; i < files.length; i++) {
      await _sendFile(i, files[i], metas[i]);
    }
    await pipe.sendText(const DoneFrame().encode());
  }

  void _checkCancelled() {
    if (isCancelled?.call() ?? false) throw const TransferException('已取消');
  }

  Future<void> _sendFile(int index, File file, FileMeta meta) async {
    _checkCancelled();
    await pipe.sendText(FileStartFrame(index, meta.name, meta.size).encode());
    final raf = await file.open();
    try {
      var remaining = meta.size;
      while (remaining > 0) {
        _checkCancelled();
        final chunk = await raf.read(min(chunkSize, remaining));
        if (chunk.isEmpty) throw TransferException('读取文件失败：${meta.name} 比预期短');
        await _flowControl(chunk.length);
        await pipe.sendBytes(chunk);
        remaining -= chunk.length;
        _sent += chunk.length;
        onProgress?.call(_sent);
      }
    } finally {
      await raf.close();
    }
    await pipe.sendText(FileEndFrame(index).encode());
  }

  Future<void> _flowControl(int next) async {
    _unchecked += next;
    if (_unchecked < checkEvery) return;
    _unchecked = 0;
    if (await pipe.bufferedAmount() > bufferHigh) {
      await pipe.waitBufferLow();
      _checkCancelled();
    }
  }
}

// ---------- 接收端 ----------
/// 接收到的文件写到哪里（测试里用内存实现）
abstract class ReceiveSink {
  /// 开始第 [index] 个文件
  Future<void> open(int index, String name, int size);
  Future<void> write(Uint8List bytes);

  /// 当前文件收齐了（字节数已校验）
  Future<void> finish(int index, String name);
}

/// 接收端状态机：按顺序处理 DataChannel 的消息，做字节校验。
/// 协议错误抛 [TransferException]，调用方应回 error 帧并关闭连接。
class FileReceiver {
  final ReceiveSink sink;
  final List<FileMeta> expected; // offer-file 里声明的文件
  final void Function(int receivedBytes)? onProgress;

  FileReceiver(this.sink, this.expected, {this.onProgress});

  int _received = 0;
  int? _index; // 正在接收的文件
  int _fileSize = 0;
  int _fileReceived = 0;
  String _fileName = '';
  int _nextIndex = 0;
  bool _done = false;

  int get received => _received;
  bool get done => _done;
  int get total => expected.fold(0, (s, f) => s + f.size);

  /// 处理文本控制帧；返回需要回给对方的帧（收到 done 时返回 ack）
  Future<Frame?> handleText(String text) async {
    if (_done) throw const TransferException('传输已结束后又收到数据');
    final Frame frame;
    try {
      frame = Frame.decode(text);
    } on FormatException catch (e) {
      throw TransferException('协议错误：${e.message}');
    }
    switch (frame) {
      case FileStartFrame f:
        if (_index != null) throw const TransferException('协议错误：上一个文件还没结束');
        if (f.index != _nextIndex) throw const TransferException('协议错误：文件序号不对');
        if (f.index >= expected.length) throw const TransferException('协议错误：文件数量超出');
        if (f.size != expected[f.index].size) throw const TransferException('协议错误：文件大小与声明不一致');
        _index = f.index;
        _fileName = f.name;
        _fileSize = f.size;
        _fileReceived = 0;
        await sink.open(f.index, f.name, f.size);
        return null;
      case FileEndFrame f:
        if (_index == null || f.index != _index) throw const TransferException('协议错误：end 序号不对');
        if (_fileReceived != _fileSize) {
          throw TransferException('文件不完整：$_fileName 收到 $_fileReceived / $_fileSize 字节');
        }
        await sink.finish(f.index, _fileName);
        _index = null;
        _nextIndex++;
        return null;
      case DoneFrame():
        if (_index != null) throw const TransferException('协议错误：文件还没结束就收到 done');
        if (_nextIndex != expected.length) throw const TransferException('文件数量不完整');
        _done = true;
        return const AckFrame();
      case ErrorFrame f:
        throw TransferException(f.message);
      case AckFrame():
        throw const TransferException('协议错误：接收方收到 ack');
    }
  }

  Future<void> handleBinary(Uint8List bytes) async {
    if (_index == null) throw const TransferException('协议错误：没有 file 帧就收到数据');
    if (_fileReceived + bytes.length > _fileSize) throw TransferException('数据超出文件大小：$_fileName');
    await sink.write(bytes);
    _fileReceived += bytes.length;
    _received += bytes.length;
    onProgress?.call(_received);
  }
}

// ---------- 速度统计 ----------
/// 平滑的传输速度（字节/秒）
class SpeedMeter {
  DateTime? _lastAt;
  int _lastBytes = 0;
  double bytesPerSecond = 0;

  void sample(int bytes, [DateTime? now]) {
    now ??= DateTime.now();
    final last = _lastAt;
    if (last == null) {
      _lastAt = now;
      _lastBytes = bytes;
      return;
    }
    final ms = now.difference(last).inMilliseconds;
    if (ms < 300) return;
    final inst = (bytes - _lastBytes) * 1000 / ms;
    bytesPerSecond = bytesPerSecond == 0 ? inst : bytesPerSecond * 0.6 + inst * 0.4;
    _lastAt = now;
    _lastBytes = bytes;
  }
}

/// 把文件名里不能用的字符换掉
String safeFileName(String name) {
  var s = name.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), '_').trim();
  s = s.replaceFirst(RegExp(r'^\.+'), '');
  if (s.isEmpty) s = 'file';
  return s.length > 200 ? s.substring(0, 200) : s;
}
