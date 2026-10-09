import 'package:flutter_test/flutter_test.dart';
import 'package:nelson_box_app/hub.dart';

void main() {
  test('ClipItem parses server json', () {
    final item = ClipItem.fromJson({'text': 'hi', 'sender': 'Mac', 'sender_id': 'mac_1', 'updated_at': 1.5});
    expect(item.text, 'hi');
    expect(item.sender, 'Mac');
    expect(item.updatedAt, 1.5);
  });

  test('formatBytes is human readable', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(1023), '1023 B');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(1024 * 1024), '1 MB');
    expect(formatBytes(1280 * 1024 * 1024), '1.25 GB');
    expect(formatBytes(200 * 1024 * 1024), '200 MB');
    expect(formatBytes(23 * 1024 * 1024 + 400 * 1024), '23.4 MB');
    expect(formatBytes(2 * 1024 * 1024 * 1024), '2 GB');
  });
}
