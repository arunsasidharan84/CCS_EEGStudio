import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/legacy_file_migration.dart';
import 'package:ccs_eeg_app/src/recording_storage.dart';
import 'package:ccs_eeg_app/src/erp/output_naming.dart';

void main() {
  test(
    'migration preserves signals, updates paired paths and ignores unknown JSON',
    () async {
      final dir = Directory.systemTemp.createTempSync('ccs-name-migration');
      addTearDown(() => dir.deleteSync(recursive: true));
      final old = '${dir.path}/trial.ccseeg.json';
      final samples = '{"format":"ccseeg-v1","channels":[[1,2,3]]}';
      File(old).writeAsStringSync(samples);
      File(
        '$old.preprocessing.json',
      ).writeAsStringSync(jsonEncode({'source_path': old}));
      File('${dir.path}/settings.json').writeAsStringSync('{}');
      final plan = await LegacyFileMigration.plan(dir.path);
      expect(plan, hasLength(2));
      await LegacyFileMigration.apply(dir.path, plan);
      final signal = '${dir.path}/trial.ccseeg';
      expect(File(signal).readAsStringSync(), samples);
      expect(
        jsonDecode(
          File('$signal.ccshistory').readAsStringSync(),
        )['source_path'],
        signal,
      );
      expect(File('${dir.path}/settings.json').existsSync(), true);
      expect(File('${dir.path}/legacy_names.ccsmigration').existsSync(), true);
    },
  );
  test(
    'migration refuses overwrites and repeated extensions normalise',
    () async {
      final dir = Directory.systemTemp.createTempSync('ccs-name-collision');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/x.json').writeAsStringSync('{"format":"ccseeg-v1"}');
      File('${dir.path}/x.ccseeg').writeAsStringSync('existing');
      await expectLater(
        LegacyFileMigration.plan(dir.path),
        throwsFormatException,
      );
      expect(
        RecordingStorage.withExtension(
          'x.ccseeg.ccseeg',
          RecordingFileFormat.edf,
        ),
        'x.edf',
      );
      expect(
        erpOutputName(
          'x-epo_clean.ccseeg.ccseeg',
          epoched: true,
          cleaned: true,
          extension: 'edf',
        ),
        'x-epo_clean.edf',
      );
    },
  );
}
