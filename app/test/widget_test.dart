import 'package:flutter_test/flutter_test.dart';
import 'package:nelson_box_app/hub.dart';

void main() {
  test('ClipItem parses server json', () {
    final item = ClipItem.fromJson({'text': 'hi', 'sender': 'Mac', 'sender_id': 'mac_1', 'updated_at': 1.5});
    expect(item.text, 'hi');
    expect(item.sender, 'Mac');
    expect(item.updatedAt, 1.5);
  });
}
