import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'models.dart';

Future<bool> showProcessingSettings(
  BuildContext context,
  AnalysisConfig config,
  String stage,
) async {
  final taps = TextEditingController(text: '${config.firTaps}'),
      width = TextEditingController(text: '${config.notchWidthHz}'),
      transition = TextEditingController(text: '${config.notchTransitionHz}'),
      references = TextEditingController(
        text: config.referenceChannels.join(', '),
      ),
      snr = TextEditingController(text: '${config.sourceSnr}'),
      regions = TextEditingController(text: config.sourceRegions.join(', ')),
      window = TextEditingController(text: '${config.psdWindowSeconds}'),
      bands = TextEditingController(
        text: config.psdBands
            .map((b) => '${b['label']}: ${b['low']}-${b['high']}')
            .join('\n'),
      );
  final featureRefs = TextEditingController(
    text: config.featureReferenceChannels.join(', '),
  );
  var featureReference = config.featureReferenceMode;
  final order = TextEditingController(text: '${config.iirOrder}');
  var filterType = config.filterType,
      reference = config.referenceMode,
      average = config.psdAverage;
  final definitions = <String, (String, String, double, double, bool)>{
    'fooof_max_peaks': ('FOOOF maximum peaks', '20', 0, 20, true),
    'fooof_peak_threshold': ('FOOOF peak threshold (SD)', '2', 0.01, 10, false),
    'sample_entropy_tolerance': (
      'Sample entropy tolerance (× SD)',
      '0.2',
      0.001,
      0.999,
      false,
    ),
    'higuchi_kmax': ('Higuchi kmax', '10', 2, 100, true),
    'acw_fraction': ('ACW correlation crossing', '0.5', 0.01, 0.99, false),
    'gc_lags': ('GC autoregressive lags', '25', 1, 27, true),
  };
  final advanced = {
    for (final entry in definitions.entries)
      entry.key: TextEditingController(
        text: '${config.featureParameters[entry.key] ?? entry.value.$2}',
      ),
  };
  final factors = TextEditingController(
    text: (config.featureParameters['irasa_factors'] as List? ?? []).join(', '),
  );
  final sourceNames = stage == 'Source Space'
      ? (jsonDecode(await rootBundle.loadString('assets/source_regions.json'))
                as List)
            .cast<String>()
      : <String>[];
  if (!context.mounted) return false;
  final variance = TextEditingController(text: '${config.badVarianceRatio}'),
      stiffness = TextEditingController(text: '${config.splineStiffness}'),
      regularization = TextEditingController(
        text: '${config.splineRegularization}',
      );
  String? error;
  Widget field(
    TextEditingController c,
    String label, {
    String? help,
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: c,
      maxLines: lines,
      decoration: InputDecoration(
        labelText: label,
        helperText: help,
        helperMaxLines: 4,
      ),
    ),
  );
  final changed = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('$stage parameters'),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (stage == 'Preprocessing') ...[
                  DropdownButtonFormField<String>(
                    initialValue: filterType,
                    decoration: const InputDecoration(
                      labelText: 'Bandpass filter type',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'fir',
                        child: Text('FIR Hamming (centred)'),
                      ),
                      DropdownMenuItem(
                        value: 'iir',
                        child: Text('Butterworth IIR (forward / backward)'),
                      ),
                    ],
                    onChanged: (v) => setState(() => filterType = v!),
                  ),
                  if (filterType == 'iir')
                    field(
                      order,
                      'IIR order per pass (2-12, even)',
                      help:
                          'Forward/backward filtering squares the magnitude response.',
                    ),
                  if (filterType == 'fir')
                    const Text(
                      'FIR Hamming, centred zero-phase filtering. Order = taps − 1.',
                    ),
                  field(
                    taps,
                    'FIR taps (0 = automatic)',
                    help: 'Custom taps must be odd and at least 3.',
                  ),
                  field(
                    variance,
                    'Bad-channel variance / median ratio',
                    help: 'Flat channels are also flagged. Default 25.',
                  ),
                  field(stiffness, 'Spherical spline stiffness (2-8)'),
                  field(
                    regularization,
                    'Spline regularization',
                    help: 'Positive; default 0.00001.',
                  ),
                  field(width, 'Notch stop-band width (Hz)'),
                  field(transition, 'Notch transition width (Hz)'),
                  DropdownButtonFormField<String>(
                    initialValue: reference,
                    decoration: const InputDecoration(
                      labelText: 'Output reference',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'none',
                        child: Text('Keep cleaned reference'),
                      ),
                      DropdownMenuItem(
                        value: 'average',
                        child: Text('Common average'),
                      ),
                      DropdownMenuItem(
                        value: 'channels',
                        child: Text(
                          'Selected electrode(s) / linked references',
                        ),
                      ),
                    ],
                    onChanged: (v) => setState(() => reference = v!),
                  ),
                  if (reference == 'channels')
                    field(
                      references,
                      'Reference channel labels',
                      help:
                          'Comma-separated. These channels must be included among EEG channels.',
                    ),
                  const Text(
                    'GEDAI still uses its internal full-rank pseudo-average reference. The chosen output reference is applied after cleaning.',
                  ),
                ],
                if (stage == 'Source Space') ...[
                  field(
                    snr,
                    'eLORETA assumed SNR',
                    help: 'Positive value; default 3.',
                  ),
                  ExpansionTile(
                    title: const Text('Choose source regions'),
                    children: [
                      for (final name in sourceNames)
                        CheckboxListTile(
                          dense: true,
                          title: Text(name),
                          value:
                              regions.text.trim().isEmpty ||
                              regions.text
                                  .split(',')
                                  .map((s) => s.trim())
                                  .contains(name),
                          onChanged: (v) => setState(() {
                            final selected = regions.text.trim().isEmpty
                                ? sourceNames.toSet()
                                : regions.text
                                      .split(',')
                                      .map((s) => s.trim())
                                      .where((s) => s.isNotEmpty)
                                      .toSet();
                            if (v == true) {
                              selected.add(name);
                            } else {
                              if (selected.length == 1) return;
                              selected.remove(name);
                            }
                            regions.text = selected.join(', ');
                          }),
                        ),
                    ],
                  ),
                  field(
                    regions,
                    'Source region labels (empty = all 68)',
                    lines: 3,
                    help:
                        'Comma-separated fsaverage atlas labels; unknown names are rejected.',
                  ),
                ],
                if (stage == 'Feature Extraction') ...[
                  DropdownButtonFormField<String>(
                    initialValue: featureReference,
                    decoration: const InputDecoration(
                      labelText: 'Feature-analysis reference',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'none',
                        child: Text('Keep input reference'),
                      ),
                      DropdownMenuItem(
                        value: 'average',
                        child: Text('Common average'),
                      ),
                      DropdownMenuItem(
                        value: 'channels',
                        child: Text('Selected electrode(s)'),
                      ),
                    ],
                    onChanged: (v) => setState(() => featureReference = v!),
                  ),
                  if (featureReference == 'channels')
                    field(featureRefs, 'Feature reference channels'),
                  DropdownButtonFormField<String>(
                    initialValue: average,
                    decoration: const InputDecoration(
                      labelText: 'Welch PSD estimator',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'median',
                        child: Text('Median average (robust)'),
                      ),
                      DropdownMenuItem(
                        value: 'mean',
                        child: Text('Mean average'),
                      ),
                    ],
                    onChanged: (v) => setState(() => average = v!),
                  ),
                  field(
                    window,
                    'PSD window (s)',
                    help: '50% overlap; cannot exceed the analysis epoch.',
                  ),
                  for (final entry in definitions.entries)
                    field(advanced[entry.key]!, entry.value.$1),
                  field(
                    factors,
                    'IRASA resampling factors',
                    help:
                        'Empty = standard 17 factors. Custom list between 1 and 2; rounded to two decimals.',
                  ),
                  field(
                    bands,
                    'Frequency bands: label: low-high',
                    lines: 7,
                    help:
                        'One band per line, e.g. Alpha: 8-12. Empty uses standard bands. FOOOF/IRASA support 1-40 Hz; connectivity uses 4-40 Hz (lower bands omitted).',
                  ),
                ],
                if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.redAccent)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              try {
                if (stage == 'Preprocessing') {
                  final n = int.parse(taps.text),
                      w = double.parse(width.text),
                      t = double.parse(transition.text);
                  if (n < 0 ||
                      (n != 0 && (n < 3 || n.isEven)) ||
                      !w.isFinite ||
                      w <= 0 ||
                      !t.isFinite ||
                      t <= 0)
                    throw const FormatException(
                      'Invalid FIR taps or notch widths.',
                    );
                  final refs = references.text
                      .split(',')
                      .map((v) => v.trim())
                      .where((v) => v.isNotEmpty)
                      .toList();
                  if (reference == 'channels' && refs.isEmpty)
                    throw const FormatException('Choose reference channels.');
                  final vr = double.parse(variance.text),
                      sr = double.parse(regularization.text);
                  final ss = int.parse(stiffness.text);
                  if (!vr.isFinite ||
                      vr < 2 ||
                      !sr.isFinite ||
                      sr <= 0 ||
                      ss < 2 ||
                      ss > 8)
                    throw const FormatException(
                      'Invalid bad-channel or spline parameters.',
                    );
                  final o = int.parse(order.text);
                  if (o < 2 || o > 12 || o.isOdd)
                    throw const FormatException(
                      'IIR order must be even, 2-12.',
                    );
                  config
                    ..badVarianceRatio = vr
                    ..splineStiffness = ss
                    ..splineRegularization = sr
                    ..filterType = filterType
                    ..iirOrder = o
                    ..firTaps = n
                    ..notchWidthHz = w
                    ..notchTransitionHz = t
                    ..referenceMode = reference
                    ..referenceChannels = refs;
                  if (reference != 'none')
                    config
                      ..featureReferenceMode = 'none'
                      ..featureReferenceChannels = [];
                } else if (stage == 'Source Space') {
                  final value = double.parse(snr.text);
                  if (!value.isFinite || value <= 0)
                    throw const FormatException('SNR must be positive.');
                  config
                    ..sourceSnr = value
                    ..sourceRegions = regions.text
                        .split(',')
                        .map((s) => s.trim())
                        .where((s) => s.isNotEmpty)
                        .toList();
                } else {
                  final value = double.parse(window.text);
                  if (!value.isFinite || value <= 0)
                    throw const FormatException('PSD window must be positive.');
                  final parsed = <Map<String, dynamic>>[];
                  for (final line
                      in bands.text
                          .split('\n')
                          .where((l) => l.trim().isNotEmpty)) {
                    final match = RegExp(
                      r'^\s*([A-Za-z][A-Za-z0-9_]*)\s*:\s*([0-9.]+)\s*-\s*([0-9.]+)\s*$',
                    ).firstMatch(line);
                    if (match == null)
                      throw const FormatException(
                        'Use label: low-high for each band.',
                      );
                    final low = double.parse(match[2]!),
                        high = double.parse(match[3]!);
                    if (!low.isFinite ||
                        !high.isFinite ||
                        high <= low ||
                        parsed.any((b) => b['label'] == match[1]))
                      throw const FormatException(
                        'Band limits and labels must be valid and unique.',
                      );
                    parsed.add({'label': match[1], 'low': low, 'high': high});
                  }
                  final advancedValues = <String, dynamic>{};
                  for (final entry in definitions.entries) {
                    final value = double.parse(advanced[entry.key]!.text);
                    if (!value.isFinite ||
                        value < entry.value.$3 ||
                        value > entry.value.$4 ||
                        (entry.value.$5 && value != value.roundToDouble()))
                      throw FormatException('Invalid ${entry.value.$1}');
                    advancedValues[entry.key] = entry.value.$5
                        ? value.toInt()
                        : value;
                  }
                  final hs = factors.text
                      .split(',')
                      .where((s) => s.trim().isNotEmpty)
                      .map((s) => double.parse(s.trim()))
                      .toList();
                  if (hs.any(
                    (h) =>
                        !h.isFinite ||
                        (h * 100).round() <= 100 ||
                        (h * 100).round() >= 200,
                  ))
                    throw const FormatException(
                      'IRASA factors must round to values strictly between 1 and 2.',
                    );
                  advancedValues['irasa_factors'] = hs;
                  final refs = featureRefs.text
                      .split(',')
                      .map((v) => v.trim())
                      .where((v) => v.isNotEmpty)
                      .toList();
                  if (featureReference == 'channels' && refs.isEmpty)
                    throw const FormatException(
                      'Choose feature reference channels.',
                    );
                  config
                    ..featureReferenceMode = featureReference
                    ..featureReferenceChannels = refs
                    ..psdAverage = average
                    ..psdWindowSeconds = value
                    ..psdBands = parsed
                    ..featureParameters = advancedValues;
                }
                Navigator.pop(context, true);
              } catch (e) {
                setState(() => error = '$e');
              }
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    ),
  );
  for (final c in [
    ...advanced.values,
    factors,
    variance,
    stiffness,
    regularization,
    taps,
    width,
    transition,
    references,
    snr,
    regions,
    window,
    bands,
    order,
    featureRefs,
  ]) {
    c.dispose();
  }
  return changed == true;
}
