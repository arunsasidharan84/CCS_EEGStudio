import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/app_instance.dart';

void main() {
  test('macOS requests a new bundle instance without shell quoting', () {
    final command = instanceLaunchCommand(
      'macos',
      '/Applications/CCS EEG Studio.app/Contents/MacOS/ccs_eeg_app',
    );
    expect(command.executable, '/usr/bin/open');
    expect(command.arguments, ['-n', '/Applications/CCS EEG Studio.app']);
  });
  test('Linux, Windows and unbundled macOS launch executable directly', () {
    for (final os in ['linux', 'windows', 'macos']) {
      final command = instanceLaunchCommand(os, '/test path/ccs_eeg_app');
      expect(command.executable, '/test path/ccs_eeg_app');
      expect(command.arguments, isEmpty);
    }
  });
}
