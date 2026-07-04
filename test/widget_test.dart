import 'package:ccs_eeg_app/src/app.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders extraction workspace', (tester) async {
    await tester.pumpWidget(const CcsEegApp());
    expect(find.text('CCS EEG'), findsOneWidget);
    expect(find.text('Feature Studio'), findsOneWidget);
    expect(
      find.text(
        'Load an EDF, SET, or CCSEEG file to preview signals',
      ),
      findsOneWidget,
    );
  });
}
