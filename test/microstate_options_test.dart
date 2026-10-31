import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/microstate_analysis.dart';

void main() {
  test('syntax and epoch preparation options serialize for both workflows', () {
    final defaults = const MicrostateOptions().toJson();
    expect(defaults['syntax_word_length'], 6);
    expect(defaults['syntax_legacy_windows'], false);
    expect(defaults['remove_epoch_dc'], true);
    final custom = const MicrostateOptions(
      syntaxWordLength: 3,
      syntaxLegacyWindows: true,
      removeEpochDc: false,
    ).toJson();
    expect(custom['syntax_word_length'], 3);
    expect(custom['syntax_legacy_windows'], true);
    expect(custom['remove_epoch_dc'], false);
  });
}
