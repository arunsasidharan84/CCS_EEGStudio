/// Channel type classification for EEG recordings.
///
/// The engine needs to know which channels carry cortical EEG and which are
/// auxiliary (ECG, EOG, EMG, GSR, respiration, accelerometer, references,
/// triggers).  Auxiliary channels must be excluded before average referencing
/// and before any topographic plotting, otherwise they contaminate the common
/// average and break montage lookup.
///
/// Previously this list lived hardcoded inside the Rust bridge
/// (`remove_non_eeg_and_reference`) and inside `eeg_viewer.dart`, and the two
/// copies had drifted apart.  This module is now the single source of truth:
/// the UI auto-detects on load, lets the user override per channel, and ships
/// the resolved explicit list to the engine in the job JSON.
library;

/// Broad classification of a single recording channel.
enum ChannelKind {
  /// Scalp EEG — included in analysis and in the common average reference.
  eeg,

  /// Electrocardiogram.
  ecg,

  /// Electrooculogram (vertical / horizontal eye channels).
  eog,

  /// Electromyogram (chin, limb).
  emg,

  /// Galvanic skin response / electrodermal activity.
  gsr,

  /// Respiration belt, airflow, thermistor.
  resp,

  /// Photoplethysmography / pulse oximetry.
  ppg,

  /// Accelerometer / gyroscope / position.
  motion,

  /// Mastoid, earlobe or explicit reference channel.
  reference,

  /// Trigger, status, marker or annotation channel.
  trigger,

  /// Recognised as non-EEG but not one of the specific families above.
  other;

  bool get isEeg => this == ChannelKind.eeg;

  String get label => switch (this) {
    ChannelKind.eeg => 'EEG',
    ChannelKind.ecg => 'ECG',
    ChannelKind.eog => 'EOG',
    ChannelKind.emg => 'EMG',
    ChannelKind.gsr => 'GSR',
    ChannelKind.resp => 'RESP',
    ChannelKind.ppg => 'PPG',
    ChannelKind.motion => 'MOTION',
    ChannelKind.reference => 'REF',
    ChannelKind.trigger => 'TRIG',
    ChannelKind.other => 'OTHER',
  };
}

/// Detection rules, evaluated in order.  The first matching rule wins, so more
/// specific patterns must appear before broader ones.
///
/// Matching is deliberately conservative: a rule fires on an exact label match,
/// on a token match (label split on separators), or on a prefix match.  We do
/// *not* use naive substring matching, because that misclassifies legitimate
/// EEG labels — e.g. "FT9"/"FT10" contain no aux token but the old substring
/// rule for "T9" would have caught them, and "Fp1" contains "P1".
class _Rule {
  const _Rule(this.kind, this.exact, {this.prefixes = const []});
  final ChannelKind kind;
  final List<String> exact;
  final List<String> prefixes;
}

const List<_Rule> _rules = [
  _Rule(
    ChannelKind.ecg,
    ['ECG', 'EKG', 'ECG1', 'ECG2', 'EKG1', 'EKG2', 'HEART'],
    prefixes: ['ECG', 'EKG'],
  ),
  _Rule(
    ChannelKind.eog,
    [
      'EOG', 'VEOG', 'HEOG', 'LEOG', 'REOG',
      'EOG1', 'EOG2', 'VEO', 'HEO', 'IO', 'LO1', 'LO2', 'SO1', 'SO2',
      // PSG conventions: left/right outer canthus.
      //
      // Deliberately NOT including 'E1'/'E2' here: AASM uses those for the eye
      // channels, but EGI HydroCel nets number every EEG electrode E1…E256, so
      // the rule would silently delete real EEG data on those recordings.
      // Users can mark them by hand in the Channel Types panel.
      'LOC', 'ROC',
    ],
    prefixes: ['EOG', 'VEOG', 'HEOG'],
  ),
  _Rule(
    ChannelKind.emg,
    ['EMG', 'EMG1', 'EMG2', 'CHIN', 'CHIN1', 'CHIN2', 'SUBMENTAL'],
    prefixes: ['EMG'],
  ),
  _Rule(
    ChannelKind.gsr,
    ['GSR', 'EDA', 'SCL', 'SCR', 'SKINCONDUCTANCE'],
    prefixes: ['GSR', 'EDA'],
  ),
  _Rule(
    ChannelKind.resp,
    [
      'RESP', 'RESPIRATION', 'THOR', 'THORAX', 'ABDO', 'ABDOMEN',
      'FLOW', 'AIRFLOW', 'NASAL', 'THERM', 'SNORE', 'CO2', 'ETCO2',
    ],
    prefixes: ['RESP', 'THOR', 'ABDO'],
  ),
  _Rule(
    ChannelKind.ppg,
    ['PPG', 'PLETH', 'PULSE', 'SPO2', 'SAO2', 'OXIMETRY', 'BVP'],
    prefixes: ['PPG', 'PLETH', 'SPO2'],
  ),
  _Rule(
    ChannelKind.motion,
    [
      'ACC', 'ACCX', 'ACCY', 'ACCZ', 'ACC_X', 'ACC_Y', 'ACC_Z',
      'GYRO', 'GYROX', 'GYROY', 'GYROZ',
      'X_DIR', 'Y_DIR', 'Z_DIR', 'POSITION', 'ACTIVITY', 'PIEZO',
    ],
    prefixes: ['ACC', 'GYRO', 'MAG'],
  ),
  _Rule(
    ChannelKind.reference,
    ['REF', 'A1', 'A2', 'M1', 'M2', 'CMS', 'DRL', 'LM', 'RM', 'EARREF'],
    prefixes: ['REF'],
  ),
  _Rule(
    ChannelKind.trigger,
    [
      'STATUS', 'TRIGGER', 'TRIG', 'MARKER', 'EVENT', 'STI', 'STI014',
      'ANNOTATIONS', 'EDF ANNOTATIONS', 'DC1', 'DC2', 'DC3', 'DC4',
    ],
    prefixes: ['STI', 'TRIG', 'DC'],
  ),
];

final RegExp _modalityPrefix =
    RegExp(r'^(EEG|EOG|ECG|EKG|EMG|RESP|PPG|MISC)\s+(.+)$');

/// The modality word an EDF-style label declares about itself, if any.
///
/// EDF headers commonly read "EOG LOC-A2" or "ECG ECGL-ECGR": the modality is
/// stated up front and the rest is an electrode pair that no name rule would
/// recognise.  Honouring the declared modality catches those.
ChannelKind? _declaredModality(String raw) {
  final m = _modalityPrefix.firstMatch(raw.trim().toUpperCase());
  return switch (m?.group(1)) {
    'EOG' => ChannelKind.eog,
    'ECG' || 'EKG' => ChannelKind.ecg,
    'EMG' => ChannelKind.emg,
    'RESP' => ChannelKind.resp,
    'PPG' => ChannelKind.ppg,
    'MISC' => ChannelKind.other,
    _ => null, // 'EEG' or no prefix — fall through to name rules.
  };
}

/// Normalises a raw channel label for matching: uppercases, strips a leading
/// modality prefix ("EEG Fp1-REF" → "FP1"), and drops the common
/// "-REF"/"-LE"/"-A1" referencing suffix that EDF headers carry.
String normaliseLabel(String raw) {
  var s = raw.trim().toUpperCase();
  final m = _modalityPrefix.firstMatch(s);
  final prefixWord = m?.group(1);
  if (m != null) s = m.group(2)!;
  // Strip trailing reference suffix.
  s = s.replaceAll(RegExp(r'[-_](REF|LE|RE|A1|A2|M1|M2|AVG|CAR)$'), '');
  s = s.replaceAll(RegExp(r'\s+'), '');
  // If the modality word itself was an aux type and nothing else identifies
  // the channel, keep the modality so the rules can fire on it.
  if (prefixWord != null && prefixWord != 'EEG' && s.isEmpty) return prefixWord;
  return s;
}

/// Splits a normalised label into comparison tokens.
List<String> _tokens(String norm) =>
    norm.split(RegExp(r'[-_ .]')).where((t) => t.isNotEmpty).toList();

/// Classifies a single channel label.
ChannelKind classifyChannel(String rawLabel) {
  final norm = normaliseLabel(rawLabel);
  if (norm.isEmpty) return ChannelKind.other;
  final tokens = _tokens(norm);

  for (final rule in _rules) {
    if (rule.exact.contains(norm)) return rule.kind;
    for (final t in tokens) {
      if (rule.exact.contains(t)) return rule.kind;
    }
    for (final p in rule.prefixes) {
      // Prefix match only when the remainder is numeric or empty, so "ACC3"
      // matches but "ACCELERATION_OF_ALPHA" style custom EEG names do not.
      if (norm.startsWith(p)) {
        final rest = norm.substring(p.length);
        if (rest.isEmpty || RegExp(r'^[0-9]+$').hasMatch(rest)) return rule.kind;
      }
    }
  }

  // No name rule fired.  Fall back to what the label declared about itself,
  // e.g. "EOG LOC-A2" where the electrode pair is unrecognisable but the
  // modality is stated explicitly.
  return _declaredModality(rawLabel) ?? ChannelKind.eeg;
}

/// Auto-detected, user-overridable channel type assignment for one recording.
class ChannelTypeMap {
  ChannelTypeMap(this.labels, Map<String, ChannelKind> kinds)
    : _kinds = Map.of(kinds);

  /// Builds a map by running auto-detection over [labels].
  factory ChannelTypeMap.autoDetect(List<String> labels) => ChannelTypeMap(
    List.of(labels),
    {for (final l in labels) l: classifyChannel(l)},
  );

  /// Empty map — no channels known yet.
  factory ChannelTypeMap.empty() => ChannelTypeMap(const [], const {});

  final List<String> labels;
  final Map<String, ChannelKind> _kinds;

  ChannelKind kindOf(String label) => _kinds[label] ?? ChannelKind.eeg;

  bool isEeg(String label) => kindOf(label).isEeg;

  /// Labels classified as EEG, in original recording order.
  List<String> get eegChannels =>
      labels.where((l) => kindOf(l).isEeg).toList(growable: false);

  /// Labels classified as anything other than EEG, in original order.
  List<String> get nonEegChannels =>
      labels.where((l) => !kindOf(l).isEeg).toList(growable: false);

  int get eegCount => eegChannels.length;
  int get nonEegCount => nonEegChannels.length;

  /// Returns a copy with [label] reassigned to [kind].
  ChannelTypeMap withKind(String label, ChannelKind kind) =>
      ChannelTypeMap(labels, {..._kinds, label: kind});

  /// Returns a copy with every channel reset to its auto-detected kind.
  ChannelTypeMap resetToAuto() => ChannelTypeMap.autoDetect(labels);

  /// Returns a copy where [label] is toggled between EEG and its auto-detected
  /// non-EEG kind (falling back to `other` when auto-detection said EEG).
  ChannelTypeMap toggleEeg(String label) {
    if (kindOf(label).isEeg) {
      final auto = classifyChannel(label);
      return withKind(label, auto.isEeg ? ChannelKind.other : auto);
    }
    return withKind(label, ChannelKind.eeg);
  }

  /// True when the user has overridden at least one auto-detected assignment.
  bool get hasOverrides =>
      labels.any((l) => kindOf(l) != classifyChannel(l));

  /// Re-applies the current assignments onto a new channel list (e.g. after
  /// preprocessing dropped channels).  Unknown labels are auto-detected.
  ChannelTypeMap rebaseOnto(List<String> newLabels) => ChannelTypeMap(
    List.of(newLabels),
    {
      for (final l in newLabels)
        l: _kinds.containsKey(l) ? _kinds[l]! : classifyChannel(l),
    },
  );

  /// Serialised form sent to the Rust engine.
  Map<String, dynamic> toJson() => {
    'non_eeg_channels': nonEegChannels,
    'channel_kinds': {
      for (final l in labels) l: kindOf(l).name,
    },
  };
}
