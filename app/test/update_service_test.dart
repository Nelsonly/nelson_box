import 'package:flutter_test/flutter_test.dart';
import 'package:nelson_box_app/update_service.dart';

void main() {
  test('version comparison supports tags and build numbers', () {
    expect(UpdateService.isNewer('1.0.0', 1, 'v1.0.1+1'), isTrue);
    expect(UpdateService.isNewer('1.0.0', 1, 'v1.0.0+2'), isTrue);
    expect(UpdateService.isNewer('1.0.0', 2, 'v1.0.0+2'), isFalse);
    expect(UpdateService.isNewer('1.2.0', 1, 'v1.1.9+99'), isFalse);
  });

  test('release selects the first apk asset', () {
    final release = AppRelease.fromJson({
      'tag_name': 'v2.0.0+3',
      'name': 'NelsonBox 2',
      'body': 'changes',
      'html_url': 'https://example.test/release',
      'assets': [
        {'name': 'source.zip', 'browser_download_url': 'zip'},
        {'name': 'NelsonBox.apk', 'browser_download_url': 'apk', 'size': 1024},
      ],
    });
    expect(release.apkUrl, 'apk');
    expect(release.apkSize, 1024);
    expect(release.tag, 'v2.0.0+3');
  });
}
