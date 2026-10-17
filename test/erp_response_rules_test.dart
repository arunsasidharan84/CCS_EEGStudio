import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/erp/protocol_tools.dart';

void main() {
  const markers = [
    EegMarker(type: 'Stimulus', description: 'S10', startSeconds: 1),
    EegMarker(type: 'Response', description: 'R1', startSeconds: 1.3),
    EegMarker(type: 'Stimulus', description: 'S10', startSeconds: 3),
    EegMarker(type: 'Response', description: 'R2', startSeconds: 3.4),
    EegMarker(type: 'Stimulus', description: 'S10', startSeconds: 5),
    EegMarker(type: 'Response', description: 'R1', startSeconds: 7),
    EegMarker(type: 'Stimulus', description: 'S10', startSeconds: 8),
    EegMarker(type: 'Stimulus', description: 'S10', startSeconds: 8.2),
    EegMarker(type: 'Response', description: 'R1', startSeconds: 8.5),
  ];
  StimEpochSpec spec(String mode) => StimEpochSpec(
    markers: const ['S10'],
    markerGroups: const {
      'Target': ['S10'],
    },
    responseRules: {
      'Target': {
        'mode': mode,
        'correct': ['R1'],
        'incorrect': ['R2'],
        'min_s': .1,
        'max_s': 1.0,
      },
    },
  );
  test(
    'correct-only uses first response before next stimulus; excludes missing and late',
    () {
      expect(spec('correct').selectEvents(markers).map((e) => e.$1), [1, 8.2]);
      expect(spec('incorrect').selectEvents(markers).map((e) => e.$1), [3]);
      expect(spec('all').selectEvents(markers), hasLength(5));
    },
  );
  test(
    'button mappings depend on stimulus and missed trials are selectable',
    () {
      StimEpochSpec mapped(String mode) => StimEpochSpec(
        markers: const ['S10'],
        markerGroups: const {
          'Target': ['S10'],
        },
        responseRules: {
          'Target': {
            'mode': mode,
            'expected_by_stimulus': {
              'S10': ['R2'],
            },
            'incorrect': ['R1'],
            'min_s': .1,
            'max_s': 1.0,
          },
        },
      );
      expect(mapped('correct').selectEvents(markers).map((e) => e.$1), [3]);
      expect(mapped('incorrect').selectEvents(markers).map((e) => e.$1), [
        1,
        8.2,
      ]);
      expect(mapped('missed').selectEvents(markers).map((e) => e.$1), [5, 8]);
    },
  );
  test('response rules survive saved reusable protocols', () {
    final config = AnalysisConfig()
      ..stimResponseRules = spec('correct').responseRules;
    final other = AnalysisConfig();
    applyErpProtocol(other, erpProtocolJson(config));
    expect(other.stimResponseRules, config.stimResponseRules);
    expect(
      StimEpochSpec.fromJson(spec('correct').toJson()).selectEvents(markers),
      spec('correct').selectEvents(markers),
    );
  });
  test(
    'undefined response mappings fail instead of treating every trial as correct',
    () {
      const invalid = StimEpochSpec(
        markers: ['S10'],
        markerGroups: {
          'Target': ['S10'],
        },
        responseRules: {
          'Target': {'mode': 'correct'},
        },
      );
      expect(() => invalid.selectEvents(markers), throwsStateError);
    },
  );
}
