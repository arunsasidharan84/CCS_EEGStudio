import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/erp/review_math.dart';
import 'package:ccs_eeg_app/src/erp/publication_plots.dart';

void main() {
  test(
    'smoothing changes every named condition without changing analysis data',
    () {
      final wave = [0.0, 10.0, 0.0, 10.0, 0.0];
      final data = <String, dynamic>{
        'times': [0.0, .01, .02, .03, .04],
        'condition_waves': {
          'Standard': wave,
          'Pleasant': wave,
          'Neutral': wave,
        },
      };
      final displayed = smoothedErpDisplay(data, 40);
      for (final name in ['Standard', 'Pleasant', 'Neutral']) {
        expect(displayed['condition_waves'][name], isNot(wave));
        expect(displayed['condition_waves'][name][1], lessThan(10));
      }
      expect(wave, [0, 10, 0, 10, 0]);
      expect(smoothedErpDisplay(data, 0)['condition_waves']['Standard'], wave);
    },
  );
  test('interaction range includes negative data and omits missing groups', () {
    final component = ErpComponentDef(name: 'P3', startMs: 300, endMs: 600);
    final files = <Map<String, dynamic>>[
      {
        'subject': 'S1',
        'labels': ['Pz'],
        'times': [.3, .4, .5, .6],
        'channel_conditions': {
          'Standard': [
            [-7.0, -6.0, -5.0, -4.0],
          ],
        },
      },
    ];
    final values = interactionValues(
      files: files,
      groups: ['Observed', 'Missing'],
      participantGroups: {'S1': 'Observed'},
      conditions: ['Standard'],
      electrodes: ['Pz', 'Cz'],
      component: component,
      metric: 'mean',
    );
    expect(values['Standard']!['Observed']!.length, 1);
    expect(values['Standard']!['Missing'], isEmpty);
    final (low, high) = interactionRange(values);
    expect(low, lessThan(-5.5));
    expect(high, greaterThan(0));
    final svg = generateInteractionPlotSvg(
      files: files,
      groups: ['Observed', 'Missing'],
      participantGroups: {'S1': 'Observed'},
      conditions: ['Standard'],
      electrodes: ['Pz'],
      component: component,
      metric: 'peak_lat',
      monochrome: true,
    );
    expect(svg, contains('Peak latency (ms)'));
    expect(svg, contains('clip-path'));
    expect(svg, contains('Observed'));
    expect(svg, isNot(contains('CONTROL')));
  });
}
