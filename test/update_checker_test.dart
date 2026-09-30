import 'package:ccs_eeg_app/src/update_checker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('compares release versions numerically', () {
    expect(UpdateChecker.compareVersions('v1.10.0', '1.9.9'), greaterThan(0));
    expect(UpdateChecker.compareVersions('1.2.0', '1.2'), 0);
    expect(UpdateChecker.compareVersions('1.2.0', '1.2.1'), lessThan(0));
  });

  test('selects the canonical package for every platform', () {
    final assets = <Map<String, dynamic>>[
      {
        'name': 'CCSEEGStudio-linux-x86_64.rpm',
        'browser_download_url': 'https://example.test/app.rpm',
        'size': 10,
      },
      {
        'name': 'CCSEEGStudio-macos.zip',
        'browser_download_url': 'https://example.test/app.zip',
        'size': 20,
      },
      {
        'name': 'CCSEEGStudio-Installer.exe',
        'browser_download_url': 'https://example.test/app.exe',
        'size': 30,
      },
      {
        'name': 'CCSEEGStudio-linux-amd64.deb',
        'browser_download_url': 'https://example.test/app.deb',
        'size': 40,
      },
    ];

    expect(
      UpdateChecker.findAsset(assets, platform: UpdatePlatform.macOS)?.name,
      'CCSEEGStudio-macos.zip',
    );
    expect(
      UpdateChecker.findAsset(assets, platform: UpdatePlatform.windows)?.name,
      'CCSEEGStudio-Installer.exe',
    );
    expect(
      UpdateChecker.findAsset(
        assets,
        platform: UpdatePlatform.linuxDebian,
      )?.name,
      'CCSEEGStudio-linux-amd64.deb',
    );
    expect(
      UpdateChecker.findAsset(assets, platform: UpdatePlatform.linuxRpm)?.name,
      'CCSEEGStudio-linux-x86_64.rpm',
    );
  });
}
