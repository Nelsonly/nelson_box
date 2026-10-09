import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nelson_box_app/ai_chat.dart';
import 'package:nelson_box_app/platform.dart';
import 'package:nelson_box_app/update_service.dart';

void main() {
  group('uniqueFileName', () {
    test('keeps the name when free, adds (n) before the extension on clashes', () {
      final taken = {'a.txt', 'a (1).txt', 'README', '.env'};
      expect(uniqueFileName('b.txt', taken.contains), 'b.txt');
      expect(uniqueFileName('a.txt', taken.contains), 'a (2).txt');
      expect(uniqueFileName('README', taken.contains), 'README (1)');
      expect(uniqueFileName('.env', taken.contains), '.env (1)', reason: 'leading dot is not an extension');
      expect(uniqueFileName('照片.tar.gz', {'照片.tar.gz'}.contains), '照片.tar (1).gz');
    });

    test('works against a real directory', () {
      final dir = Directory.systemTemp.createTempSync('uniq');
      try {
        File('${dir.path}/x.bin').writeAsStringSync('1');
        bool exists(String n) => File('${dir.path}/$n').existsSync();
        expect(uniqueFileName('x.bin', exists), 'x (1).bin');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  test('device type per platform', () {
    expect(AppPlatform.deviceTypeFor('android'), 'android');
    expect(AppPlatform.deviceTypeFor('windows'), 'windows');
    expect(AppPlatform.deviceTypeFor('macos'), 'mac');
    expect(AppPlatform.deviceTypeFor('linux'), 'linux');
  });

  group('AI edit mode payload', () {
    Map<String, dynamic> payload({required bool allowEdit, bool edit = false, String passcode = ''}) =>
        AiChat.sendPayload(
          engine: 'codex',
          project: 'p',
          text: 'fix it',
          req: 'r',
          allowEdit: allowEdit,
          edit: edit,
          passcode: passcode,
        );

    test('Android (allowEdit=false) is always ask and never sends a passcode', () {
      final p = payload(allowEdit: false, edit: true, passcode: 'secret');
      expect(p['mode'], 'ask');
      expect(p.containsKey('passcode'), isFalse);
    });

    test('Windows sends edit + passcode only when edit is chosen with a passcode', () {
      final e = payload(allowEdit: true, edit: true, passcode: 'secret');
      expect(e['mode'], 'edit');
      expect(e['passcode'], 'secret');
      final ask = payload(allowEdit: true, edit: false, passcode: 'secret');
      expect(ask['mode'], 'ask');
      expect(ask.containsKey('passcode'), isFalse);
      final noCode = payload(allowEdit: true, edit: true);
      expect(noCode['mode'], 'ask');
      expect(noCode.containsKey('passcode'), isFalse);
    });

    test('edit_enabled, message modes and mode label', () {
      final ai = AiChat()
        ..apply({
          'type': 'ai:hosts',
          'hosts': [
            {'id': 'm', 'name': 'Mac', 'engines': [], 'projects': [], 'edit_enabled': true}
          ],
        });
      expect(ai.editEnabled, isTrue);
      ai.apply({'type': 'ai:hosts', 'hosts': [{'id': 'm', 'name': 'Mac'}]});
      expect(ai.editEnabled, isFalse);

      final user = AiMessage.fromJson({'id': 'u', 'role': 'user', 'text': 'q', 'status': 'done', 'mode': 'edit'});
      expect(user.mode, 'edit');
      final reply = AiMessage.fromJson(
          {'id': 'a', 'role': 'assistant', 'text': 'x', 'status': 'done', 'mode_used': 'edit', 'effort': 'high'});
      expect(ai.usedLabel('codex', reply), 'high', reason: 'Android hides the mode');
      expect(ai.usedLabel('codex', reply, showMode: true), 'high · 可修改');
      final ro = AiMessage.fromJson({'id': 'b', 'role': 'assistant', 'text': 'x', 'status': 'done', 'mode_used': 'ask'});
      expect(ai.usedLabel('codex', ro, showMode: true), '只读');
    });
  });

  test('release picks the Windows zip and the APK separately', () {
    final release = AppRelease.fromJson({
      'tag_name': 'v1.2.0+4',
      'html_url': 'https://example.test/r',
      'assets': [
        {'name': 'NelsonBox-Windows-v1.2.0+4.zip', 'browser_download_url': 'win', 'size': 30 * 1024 * 1024},
        {'name': 'NelsonBox.apk', 'browser_download_url': 'apk', 'size': 1024},
        {'name': 'other.zip', 'browser_download_url': 'nope'},
      ],
    });
    expect(release.downloadUrl(windows: true), 'win');
    expect(release.downloadUrl(windows: false), 'apk');
    expect(release.formattedSizeFor(windows: true), '30.0 MB');
    expect(AppRelease.isWindowsAsset('nelsonbox-windows-v1.zip'), isTrue);
    expect(AppRelease.isWindowsAsset('NelsonBox.apk'), isFalse);
    final apkOnly = AppRelease.fromJson({
      'tag_name': 'v1',
      'assets': [
        {'name': 'NelsonBox.apk', 'browser_download_url': 'apk'}
      ]
    });
    expect(apkOnly.downloadUrl(windows: true), isEmpty);
  });
}
