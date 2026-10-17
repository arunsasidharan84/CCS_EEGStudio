import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/update_checker.dart';

void main() {
  test('update download verifies digest and rejects mismatch', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    const body = [1, 2, 3, 4];
    server.listen((request) {
      request.response.contentLength = body.length;
      request.response.add(body);
      request.response.close();
    });
    ReleaseAsset asset(String digest) => ReleaseAsset(
      name: 'fixture.zip',
      downloadUrl: 'http://127.0.0.1:${server.port}/fixture.zip',
      sizeBytes: 4,
      sha256Digest: 'sha256:$digest',
    );
    final file = await UpdateChecker.download(
      asset(sha256.convert(body).toString()),
      (_, _, _) {},
    );
    expect(file.readAsBytesSync(), body);
    addTearDown(() => file.parent.deleteSync(recursive: true));
    await expectLater(
      UpdateChecker.download(asset('0' * 64), (_, _, _) {}),
      throwsFormatException,
    );
  });
  test('Linux prefers portable archive for both distribution families', () {
    final assets = [
      {
        'name': 'CCSEEGStudio-linux-amd64.deb',
        'browser_download_url': 'https://example.com/a.deb',
      },
      {
        'name': 'CCSEEGStudio-linux-x86_64.tar.gz',
        'browser_download_url': 'https://example.com/a.tar.gz',
      },
    ];
    for (final platform in [
      UpdatePlatform.linuxDebian,
      UpdatePlatform.linuxRpm,
    ]) {
      expect(
        UpdateChecker.findAsset(assets, platform: platform)?.name,
        'CCSEEGStudio-linux-x86_64.tar.gz',
      );
    }
  });
}
