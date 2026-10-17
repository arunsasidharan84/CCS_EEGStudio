import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/linux_user_install.dart';

void main() {
  test(
    'rootless update keeps previous versions and installs per-user launchers',
    () async {
      final dir = Directory.systemTemp.createTempSync('ccs-user-install');
      addTearDown(() => dir.deleteSync(recursive: true));
      final bundle = Directory('${dir.path}/bundle')..createSync();
      for (final name in ['ccs_eeg_app', 'ccs-eeg-engine']) {
        File('${bundle.path}/$name').writeAsStringSync('#!/bin/sh\nexit 0\n');
      }
      final archive = '${dir.path}/bundle.tar.gz';
      expect(
        (await Process.run('tar', [
          '-C',
          bundle.path,
          '-czf',
          archive,
          '.',
        ])).exitCode,
        0,
      );
      final helper = File('${dir.path}/install.sh')
        ..writeAsStringSync(LinuxUserInstaller.script);
      final environment = {
        'XDG_DATA_HOME': '${dir.path}/share',
        'XDG_BIN_HOME': '${dir.path}/bin',
        'CCS_EEG_NO_LAUNCH': '1',
      };
      for (final version in ['1.2.20', '1.2.21']) {
        final r = await Process.run('/bin/bash', [
          helper.path,
          archive,
          version,
          '0',
          '${dir.path}/ready-$version',
        ], environment: environment);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        expect(File('${dir.path}/ready-$version').existsSync(), true);
      }
      expect(
        File(
          '${dir.path}/share/ccseegstudio/releases/1.2.20/ccs_eeg_app',
        ).existsSync(),
        true,
      );
      expect(
        await Link('${dir.path}/share/ccseegstudio/current').target(),
        endsWith('/1.2.21'),
      );
      expect(File('${dir.path}/bin/ccseegstudio').existsSync(), true);
      expect(
        File(
          '${dir.path}/share/applications/ccseegstudio.desktop',
        ).existsSync(),
        true,
      );
      expect(
        Directory('${dir.path}/share/ccseegstudio/.update-lock').existsSync(),
        false,
      );
      final broken = File('${dir.path}/broken.tar.gz')
        ..writeAsStringSync('invalid archive');
      final failure = await Process.run('/bin/bash', [
        helper.path,
        broken.path,
        '1.2.22',
        '0',
        '${dir.path}/failed-ready',
      ], environment: environment);
      expect(failure.exitCode, isNot(0));
      expect(File('${dir.path}/failed-ready.failed').existsSync(), true);
      expect(
        await Link('${dir.path}/share/ccseegstudio/current').target(),
        endsWith('/1.2.21'),
      );
    },
    skip: Platform.isWindows ? 'Linux installer shell integration test' : false,
  );
}
