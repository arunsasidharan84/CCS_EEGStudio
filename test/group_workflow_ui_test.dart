import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/group_statistics.dart';

void main() {
  testWidgets(
    'group workflow stays readable in the dark app and exposes folder selection',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(child: GroupStatisticsWorkbench()),
          ),
        ),
      );
      expect(find.text('Load results folder'), findsOneWidget);
      expect(find.text('Choose feature files'), findsOneWidget);
      final element = tester.element(find.text('1. Feature data and metadata'));
      expect(Theme.of(element).brightness, Brightness.light);
    },
  );
}
