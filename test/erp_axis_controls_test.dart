import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/erp/axis_controls.dart';

void main() {
  testWidgets('axis limits validate, convert ms to seconds and reset', (
    tester,
  ) async {
    Map<String, dynamic>? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ErpAxisControls(onChanged: (v) => selected = v)),
      ),
    );
    await tester.tap(find.text('Plot axis limits'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    for (final entry in [(0, '-200'), (1, '800'), (2, '-10'), (3, '10')]) {
      await tester.enterText(fields.at(entry.$1), entry.$2);
    }
    await tester.tap(find.text('Apply limits'));
    await tester.pump();
    expect(selected, {
      'x_limits': [-.2, .8],
      'y_limits': [-10.0, 10.0],
    });
    await tester.enterText(fields.at(3), '-20');
    await tester.tap(find.text('Apply limits'));
    await tester.pump();
    expect(find.textContaining('minimum < maximum'), findsOneWidget);
    await tester.tap(find.text('Reset to Auto'));
    await tester.pump();
    expect(selected, isEmpty);
  });
}
