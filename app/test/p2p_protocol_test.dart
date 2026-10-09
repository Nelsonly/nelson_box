import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nelson_box_app/p2p_protocol.dart';

/// 假的 DataChannel：记录发出的消息，模拟 bufferedAmount 和网络排空
class FakePipe implements DataPipe {
  final List<Object> sent = []; // String 或 Uint8List
  int buffered = 0;
  int maxBuffered = 0;
  int waits = 0;
  int queries = 0;

  @override
  Future<void> sendText(String text) async => sent.add(text);

  @override
  Future<void> sendBytes(Uint8List bytes) async {
    sent.add(bytes);
    buffered += bytes.length;
    if (buffered > maxBuffered) maxBuffered = buffered;
  }

  @override
  Future<int> bufferedAmount() async {
    queries++;
    return buffered;
  }

  @override
  Future<void> waitBufferLow() async {
    waits++;
    buffered = bufferLow ~/ 2; // 网络把缓冲区排到阈值以下
  }
}

/// 内存里的接收端
class MemSink implements ReceiveSink {
  final Map<int, BytesBuilder> files = {};
  final List<String> finished = [];
  int? current;

  @override
  Future<void> open(int index, String name, int size) async {
    current = index;
    files[index] = BytesBuilder();
  }

  @override
  Future<void> write(Uint8List bytes) async => files[current]!.add(bytes);

  @override
  Future<void> finish(int index, String name) async => finished.add(name);
}

Uint8List bytesOf(int n, [int seed = 0]) => Uint8List.fromList(List.generate(n, (i) => (i * 7 + seed) % 256));

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('p2ptest'));
  tearDown(() => dir.deleteSync(recursive: true));

  File writeFile(String name, Uint8List data) => File('${dir.path}/$name')..writeAsBytesSync(data);

  group('frames', () {
    test('encode matches the wire format', () {
      expect(jsonDecode(const FileStartFrame(0, 'a.jpg', 12345).encode()),
          {'t': 'file', 'index': 0, 'name': 'a.jpg', 'size': 12345});
      expect(jsonDecode(const FileEndFrame(2).encode()), {'t': 'end', 'index': 2});
      expect(jsonDecode(const DoneFrame().encode()), {'t': 'done'});
      expect(jsonDecode(const AckFrame().encode()), {'t': 'ack'});
      expect(jsonDecode(const ErrorFrame('x').encode()), {'t': 'error', 'message': 'x'});
    });

    test('decode round-trips and rejects garbage', () {
      final f = Frame.decode('{"t":"file","index":1,"name":"中文.txt","size":5}') as FileStartFrame;
      expect((f.index, f.name, f.size), (1, '中文.txt', 5));
      expect(Frame.decode('{"t":"done"}'), isA<DoneFrame>());
      expect(Frame.decode('{"t":"ack"}'), isA<AckFrame>());
      expect((Frame.decode('{"t":"error","message":"磁盘满"}') as ErrorFrame).message, '磁盘满');
      expect(() => Frame.decode('not json'), throwsFormatException);
      expect(() => Frame.decode('[1]'), throwsFormatException);
      expect(() => Frame.decode('{"t":"nope"}'), throwsFormatException);
      expect(() => Frame.decode('{"t":"end"}'), throwsFormatException);
      expect(() => Frame.decode('{"t":"file","index":0,"name":"a"}'), throwsFormatException);
    });
  });

  test('signal messages follow the spec', () {
    final offer = Signal.offerFile('tid', const [FileMeta('a', 3), FileMeta('b', 4)]);
    expect(offer, {
      'kind': 'offer-file',
      'transfer_id': 'tid',
      'files': [
        {'name': 'a', 'size': 3},
        {'name': 'b', 'size': 4},
      ],
      'total': 7,
    });
    expect(Signal.sdp('t', 'offer', 'v=0')['sdp'], {'type': 'offer', 'sdp': 'v=0'});
    expect(Signal.ice('t', 'candidate:1', '0', 0)['candidate'],
        {'candidate': 'candidate:1', 'sdpMid': '0', 'sdpMLineIndex': 0});
    expect(Signal.cancel('t', 'r'), {'kind': 'cancel', 'transfer_id': 't', 'reason': 'r'});
    expect(FileMeta.listFromJson(offer['files']).map((f) => f.size), [3, 4]);
    expect(() => FileMeta.listFromJson([]), throwsFormatException);
    expect(() => FileMeta.listFromJson([{'name': 1, 'size': 2}]), throwsFormatException);
    expect(newTransferId(), hasLength(16));
  });

  test('sender chunks files in order with file/end/done frames', () async {
    final a = bytesOf(chunkSize * 2 + 100);
    final b = bytesOf(10, 3);
    final metas = [FileMeta('a.bin', a.length), FileMeta('b.bin', b.length)];
    final pipe = FakePipe();
    final progress = <int>[];
    await FileSender(pipe, onProgress: progress.add)
        .sendAll([writeFile('a', a), writeFile('b', b)], metas);

    final texts = pipe.sent.whereType<String>().map(jsonDecode).toList();
    expect(texts, [
      {'t': 'file', 'index': 0, 'name': 'a.bin', 'size': a.length},
      {'t': 'end', 'index': 0},
      {'t': 'file', 'index': 1, 'name': 'b.bin', 'size': 10},
      {'t': 'end', 'index': 1},
      {'t': 'done'},
    ]);
    final chunks = pipe.sent.whereType<Uint8List>().toList();
    expect(chunks.map((c) => c.length), [chunkSize, chunkSize, 100, 10]);
    expect(chunks.every((c) => c.length <= chunkSize), isTrue);
    expect(progress.last, a.length + b.length);
    // 顺序：file 帧 → 数据 → end 帧
    expect(pipe.sent[0], isA<String>());
    expect(pipe.sent[1], isA<Uint8List>());
    expect(pipe.sent[4], contains('"end"'));
  });

  test('sender pauses when bufferedAmount exceeds 1 MB', () async {
    final data = bytesOf(3 * 1024 * 1024 + 5);
    final pipe = FakePipe();
    await FileSender(pipe).sendAll([writeFile('big', data)], [FileMeta('big', data.length)]);
    expect(pipe.waits, greaterThan(0));
    // 每 256KB 查一次，所以缓冲区最多超出阈值一个检查间隔
    expect(pipe.maxBuffered, lessThanOrEqualTo(bufferHigh + bufferLow + chunkSize));
    final total = pipe.sent.whereType<Uint8List>().fold<int>(0, (s, c) => s + c.length);
    expect(total, data.length);
  });

  test('sender stops when cancelled', () async {
    final data = bytesOf(chunkSize * 10);
    final pipe = FakePipe();
    var n = 0;
    final sender = FileSender(pipe, isCancelled: () => ++n > 3);
    await expectLater(
      sender.sendAll([writeFile('c', data)], [FileMeta('c', data.length)]),
      throwsA(isA<TransferException>()),
    );
    expect(pipe.sent.whereType<String>().any((t) => t.contains('done')), isFalse);
  });

  test('sender + receiver round trip with byte accounting', () async {
    final a = bytesOf(chunkSize * 3 + 7, 1);
    final b = bytesOf(0);
    final c = bytesOf(5000, 2);
    final metas = [FileMeta('a', a.length), FileMeta('empty', 0), FileMeta('c', c.length)];
    final pipe = FakePipe();
    await FileSender(pipe).sendAll([writeFile('a', a), writeFile('e', b), writeFile('c', c)], metas);

    final sink = MemSink();
    final progress = <int>[];
    final r = FileReceiver(sink, metas, onProgress: progress.add);
    Frame? reply;
    for (final m in pipe.sent) {
      if (m is String) {
        reply = await r.handleText(m);
      } else {
        await r.handleBinary(m as Uint8List);
      }
    }
    expect(reply, isA<AckFrame>());
    expect(r.done, isTrue);
    expect(sink.finished, ['a', 'empty', 'c']);
    expect(sink.files[0]!.toBytes(), a);
    expect(sink.files[1]!.toBytes(), isEmpty);
    expect(sink.files[2]!.toBytes(), c);
    expect(r.received, a.length + c.length);
    expect(progress.last, r.total);
  });

  group('receiver rejects protocol violations', () {
    final metas = [const FileMeta('a', 10)];
    String file(int i, int size) => FileStartFrame(i, 'a', size).encode();

    test('data before file frame', () async {
      final r = FileReceiver(MemSink(), metas);
      expect(() => r.handleBinary(bytesOf(3)), throwsA(isA<TransferException>()));
    });

    test('more bytes than declared', () async {
      final r = FileReceiver(MemSink(), metas);
      await r.handleText(file(0, 10));
      await r.handleBinary(bytesOf(8));
      expect(() => r.handleBinary(bytesOf(3)), throwsA(isA<TransferException>()));
    });

    test('end with missing bytes', () async {
      final r = FileReceiver(MemSink(), metas);
      await r.handleText(file(0, 10));
      await r.handleBinary(bytesOf(9));
      expect(() => r.handleText(const FileEndFrame(0).encode()), throwsA(isA<TransferException>()));
    });

    test('size differs from offer', () async {
      final r = FileReceiver(MemSink(), metas);
      expect(() => r.handleText(file(0, 11)), throwsA(isA<TransferException>()));
    });

    test('wrong index / too many files / early done', () async {
      final r = FileReceiver(MemSink(), metas);
      expect(() => r.handleText(file(1, 10)), throwsA(isA<TransferException>()));
      expect(() => r.handleText(const DoneFrame().encode()), throwsA(isA<TransferException>()));
      await r.handleText(file(0, 10));
      await r.handleBinary(bytesOf(10));
      await r.handleText(const FileEndFrame(0).encode());
      expect(() => r.handleText(file(1, 10)), throwsA(isA<TransferException>()));
    });

    test('error frame from sender surfaces its message', () async {
      final r = FileReceiver(MemSink(), metas);
      expect(
        () => r.handleText(const ErrorFrame('读取失败').encode()),
        throwsA(isA<TransferException>().having((e) => e.message, 'message', '读取失败')),
      );
    });
  });

  test('SpeedMeter computes bytes per second', () {
    final m = SpeedMeter();
    final t0 = DateTime(2026);
    m.sample(0, t0);
    m.sample(1000, t0.add(const Duration(milliseconds: 100))); // 太快，忽略
    expect(m.bytesPerSecond, 0);
    m.sample(1024 * 1024, t0.add(const Duration(seconds: 1)));
    expect(m.bytesPerSecond, closeTo(1024 * 1024, 1));
  });

  test('safeFileName strips path and illegal characters', () {
    expect(safeFileName('../../etc/passwd'), '_.._etc_passwd');
    expect(safeFileName('a:b*c?.txt'), 'a_b_c_.txt');
    expect(safeFileName('...'), 'file');
    expect(safeFileName('照片 1.jpg'), '照片 1.jpg');
  });
}
