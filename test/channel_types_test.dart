// test/channel_types_test.dart
//
// Guards the channel auto-detection heuristics.  The regression these tests
// exist for: the previous engine-side rule used naive substring matching, so a
// legitimate EEG label containing an aux token anywhere ("FT9" vs "T9",
// "Fp1" vs "P1") could be silently dropped from the analysis and from the
// common average reference.

import 'package:ccs_eeg_app/src/channel_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifyChannel — EEG labels stay EEG', () {
    const eegLabels = [
      'Fp1', 'Fp2', 'Fpz', 'AF3', 'AF4', 'AF7', 'AF8',
      'F1', 'F2', 'F3', 'F4', 'F7', 'F8', 'Fz',
      'FC1', 'FC5', 'FT7', 'FT9', 'FT10',
      'C1', 'C3', 'C4', 'Cz', 'T7', 'T8',
      'CP1', 'CP5', 'TP7', 'TP9', 'TP10',
      'P1', 'P3', 'P7', 'Pz', 'PO3', 'PO7', 'POz',
      'O1', 'O2', 'Oz',
    ];

    for (final label in eegLabels) {
      test('$label → eeg', () {
        expect(classifyChannel(label), ChannelKind.eeg,
            reason: '$label is a standard 10-10 EEG position');
      });
    }
  });

  group('classifyChannel — auxiliary channels', () {
    const cases = <String, ChannelKind>{
      'ECG': ChannelKind.ecg,
      'EKG1': ChannelKind.ecg,
      'EOG': ChannelKind.eog,
      'VEOG': ChannelKind.eog,
      'HEOG': ChannelKind.eog,
      'LOC': ChannelKind.eog,
      'ROC': ChannelKind.eog,
      'EMG': ChannelKind.emg,
      'Chin1': ChannelKind.emg,
      'GSR': ChannelKind.gsr,
      'EDA': ChannelKind.gsr,
      'RESP': ChannelKind.resp,
      'Thorax': ChannelKind.resp,
      'PPG': ChannelKind.ppg,
      'Pleth': ChannelKind.ppg,
      'SpO2': ChannelKind.ppg,
      'ACC_X': ChannelKind.motion,
      'X_DIR': ChannelKind.motion,
      'Gyro': ChannelKind.motion,
      'A1': ChannelKind.reference,
      'M2': ChannelKind.reference,
      'REF': ChannelKind.reference,
      'Status': ChannelKind.trigger,
      'STI014': ChannelKind.trigger,
      'DC1': ChannelKind.trigger,
    };

    cases.forEach((label, expected) {
      test('$label → ${expected.name}', () {
        expect(classifyChannel(label), expected);
      });
    });

    test('EGI-style E1..E256 stay EEG', () {
      // AASM uses E1/E2 for eye channels, but EGI HydroCel nets number every
      // EEG electrode this way. Auto-detection must not delete them.
      for (final label in ['E1', 'E2', 'E17', 'E128', 'E256']) {
        expect(classifyChannel(label), ChannelKind.eeg, reason: label);
      }
    });
  });

  group('normaliseLabel strips EDF decoration', () {
    test('modality prefix and reference suffix', () {
      expect(normaliseLabel('EEG Fp1-REF'), 'FP1');
      expect(normaliseLabel('EEG C3-A2'), 'C3');
      expect(normaliseLabel(' Pz '), 'PZ');
    });

    test('decorated EEG label still classifies as EEG', () {
      expect(classifyChannel('EEG Fp1-REF'), ChannelKind.eeg);
      expect(classifyChannel('EEG C3-A2'), ChannelKind.eeg);
    });

    test('declared modality wins when the electrode pair is unrecognised', () {
      expect(classifyChannel('EOG LOC-A2'), ChannelKind.eog);
      expect(classifyChannel('ECG ECGL-ECGR'), ChannelKind.ecg);
      expect(classifyChannel('RESP Airflow'), ChannelKind.resp);
    });
  });

  group('ChannelTypeMap', () {
    final labels = ['Fp1', 'Cz', 'O2', 'ECG', 'GSR', 'Status'];

    test('auto-detect splits EEG from auxiliary', () {
      final map = ChannelTypeMap.autoDetect(labels);
      expect(map.eegChannels, ['Fp1', 'Cz', 'O2']);
      expect(map.nonEegChannels, ['ECG', 'GSR', 'Status']);
      expect(map.eegCount, 3);
      expect(map.nonEegCount, 3);
      expect(map.hasOverrides, isFalse);
    });

    test('preserves recording order', () {
      final map = ChannelTypeMap.autoDetect(['ECG', 'Fp1', 'GSR', 'Cz']);
      expect(map.eegChannels, ['Fp1', 'Cz']);
      expect(map.nonEegChannels, ['ECG', 'GSR']);
    });

    test('user override survives and is reported', () {
      var map = ChannelTypeMap.autoDetect(labels);
      map = map.toggleEeg('Cz'); // an EEG channel the user knows is bad
      expect(map.isEeg('Cz'), isFalse);
      expect(map.nonEegChannels, contains('Cz'));
      expect(map.hasOverrides, isTrue);

      map = map.toggleEeg('ECG'); // force an aux channel back into analysis
      expect(map.isEeg('ECG'), isTrue);
    });

    test('reset returns to auto-detection', () {
      final map = ChannelTypeMap.autoDetect(labels).toggleEeg('Cz');
      expect(map.resetToAuto().isEeg('Cz'), isTrue);
      expect(map.resetToAuto().hasOverrides, isFalse);
    });

    test('rebase keeps overrides for surviving channels', () {
      final map = ChannelTypeMap.autoDetect(labels).toggleEeg('Cz');
      // Preprocessing dropped the aux channels and added a new one.
      final rebased = map.rebaseOnto(['Fp1', 'Cz', 'O2', 'Pz']);
      expect(rebased.isEeg('Cz'), isFalse, reason: 'override must survive');
      expect(rebased.isEeg('Pz'), isTrue, reason: 'new channel auto-detected');
      expect(rebased.labels, ['Fp1', 'Cz', 'O2', 'Pz']);
    });

    test('serialises the explicit non-EEG list for the engine', () {
      final json = ChannelTypeMap.autoDetect(labels).toJson();
      expect(json['non_eeg_channels'], ['ECG', 'GSR', 'Status']);
      expect((json['channel_kinds'] as Map)['Fp1'], 'eeg');
      expect((json['channel_kinds'] as Map)['ECG'], 'ecg');
    });

    test('empty map is safe', () {
      final map = ChannelTypeMap.empty();
      expect(map.eegChannels, isEmpty);
      expect(map.nonEegChannels, isEmpty);
      expect(map.hasOverrides, isFalse);
    });
  });
}
