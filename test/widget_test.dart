import 'dart:ui';
import 'package:ccs_eeg_app/src/app.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders extraction workspace', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(const CcsEegApp());
    expect(find.text('CCS EEG'), findsOneWidget);
    expect(find.text('Studio'), findsOneWidget);
    expect(
      find.text(
        'Load an EDF, SET, or CCSEEG file to preview signals',
      ),
      findsOneWidget,
    );
  });
}
