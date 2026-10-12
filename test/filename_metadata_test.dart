import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/filename_metadata.dart';

void main() {
  test('BIDS extraction preserves identifiers and deduplicates rows', () {
    const name = 'sub-PC001_ses-01_task-meditation_Clean-ft';
    final rows = inferFilenameMetadata([name, name]);
    expect(rows.length, 1);
    expect(rows.single, {
      'filename': name,
      'Subject': 'PC001',
      'Session': '01',
      'Task': 'meditation',
    });
  });
  test('custom named groups and missing matches are reviewable', () {
    final rows = inferFilenameMetadata([
      'S01-rest',
      'other',
    ], pattern: r'(?<Subject>S\d+)-(?<State>\w+)');
    expect(rows.first['State'], 'rest');
    expect(rows.last, {'filename': 'other'});
    expect(filenameMetadataCsv(rows), contains('"other","",""'));
  });
}
