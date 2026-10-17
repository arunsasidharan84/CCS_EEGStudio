import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/recording_storage.dart';
import 'package:ccs_eeg_app/src/processing_settings_dialog.dart';

void main() {
  testWidgets('settings exposes and applies all three recording formats', (
    tester,
  ) async {
    final previous = RecordingStorage.preferredFormat;
    addTearDown(() => RecordingStorage.preferredFormat = previous);
    await tester.binding.setSurfaceSize(const Size(1100, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showProcessingSettings(
                context,
                AnalysisConfig(),
                'Preprocessing',
              ),
              child: const Text('Settings'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<RecordingFileFormat>));
    await tester.pumpAndSettle();
    expect(find.text('CCSEEG · native portable'), findsWidgets);
    expect(find.text('FIF · floating-point EEG / epochs'), findsOneWidget);
    await tester.tap(find.text('EDF+ · 16-bit + .ccsmeta metadata').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(RecordingStorage.preferredFormat, RecordingFileFormat.edf);
    expect(tester.takeException(), isNull);
  });
}
