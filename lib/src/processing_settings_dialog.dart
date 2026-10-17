import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'models.dart';
import 'recording_storage.dart';
import 'legacy_file_migration.dart';

Future<bool> showProcessingSettings(
  BuildContext context,
  AnalysisConfig config,
  String stage, {
  String? section,
}) async {
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
  final gedaiThreshold = TextEditingController(text: config.gedaiThreshold);
  final sourceModel = TextEditingController(text: config.sourceModelPath);
  var outputFormat = RecordingStorage.preferredFormat;
  var sourceMethod = config.sourceMethod;
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
  final icaEye = TextEditingController(text: config.icaEyeChannel),
      icaEpochs = TextEditingController(text: '${config.icaBlinkEpochs}'),
      icaBlinkHi = TextEditingController(text: '${config.icaBlinkThreshold}'),
      icaBlinkLo = TextEditingController(
        text: '${config.icaBlinkThresholdFloor}',
      ),
      icaArtefacts = TextEditingController(
        text: config.icaArtefacts.join(', '),
      ),
      icaOtherHi = TextEditingController(text: '${config.icaOtherThreshold}'),
      icaOtherLo = TextEditingController(
        text: '${config.icaOtherThresholdFloor}',
      ),
      icaSeed = TextEditingController(text: '${config.icaSeed}'),
      icaFitCutoff = TextEditingController(text: '${config.icaFitAsrCutoff}'),
      asrCutoff = TextEditingController(text: '${config.asrCutoff}'),
      asrAlpha = TextEditingController(text: '${config.asrAdaptAlpha}'),
      asrEmbedDim = TextEditingController(text: '${config.asrEmbedDim}'),
      asrEmbedTau = TextEditingController(text: '${config.asrEmbedTau}'),
      asrModes = TextEditingController(text: '${config.asrModes}'),
      bsscaN = TextEditingController(text: '${config.bsscaNRemove}'),
      iccThr = TextEditingController(text: '${config.iccThreshold}'),
      wicaLevels = TextEditingController(text: '${config.wicaLevels}');
  var icaBlink = config.icaBlink,
      icaOther = config.icaOther,
      icaRemoveEcg = config.icaRemoveEcg,
      icaFitAsr = config.icaFitAsr;
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
                DropdownButtonFormField<RecordingFileFormat>(
                  isExpanded: true,
                  initialValue: outputFormat,
                  decoration: const InputDecoration(
                    labelText: 'Saved recording format (all workflows)',
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: RecordingFileFormat.ccseeg,
                      child: Text('CCSEEG · native portable'),
                    ),
                    DropdownMenuItem(
                      value: RecordingFileFormat.fif,
                      child: Text('FIF · floating-point EEG / epochs'),
                    ),
                    DropdownMenuItem(
                      value: RecordingFileFormat.edf,
                      child: Text('EDF+ · 16-bit + .ccsmeta metadata'),
                    ),
                  ],
                  onChanged: (v) => setState(() => outputFormat = v!),
                ),
                const Text(
                  'EDF/FIF exports include a matching .ccsmeta file (JSON contents). Keep it with the signal file for exact epoch timing, labels and processing history. EDF quantizes amplitudes to 16-bit.',
                ),
                TextButton.icon(
                  icon: const Icon(Icons.drive_file_rename_outline),
                  label: const Text('Organise legacy output filenames…'),
                  onPressed: () async {
                    final folder = await FilePicker.getDirectoryPath();
                    if (folder == null || !context.mounted) return;
                    try {
                      final plan = await LegacyFileMigration.plan(folder);
                      if (!context.mounted) return;
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: Text('${plan.length} legacy filenames'),
                          content: SizedBox(
                            width: 600,
                            child: SingleChildScrollView(
                              child: Text(
                                plan.isEmpty
                                    ? 'No known legacy filenames need changing.'
                                    : plan.entries
                                          .map(
                                            (e) =>
                                                '${e.key.split(RegExp(r"[/\\]")).last} → ${e.value.split(RegExp(r"[/\\]")).last}',
                                          )
                                          .join('\n'),
                              ),
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('Cancel'),
                            ),
                            if (plan.isNotEmpty)
                              FilledButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('Rename outputs'),
                              ),
                          ],
                        ),
                      );
                      if (confirmed == true)
                        await LegacyFileMigration.apply(folder, plan);
                    } catch (e) {
                      if (context.mounted)
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text('$e')));
                    }
                  },
                ),
                if (stage == 'Preprocessing') ...[
                  ExpansionTile(
                    title: const Text('Filter and notch'),
                    initiallyExpanded: section == 'Filter',
                    children: [
                      DropdownButtonFormField<String>(
                        isExpanded: true,
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
                      field(width, 'Notch stop-band width (Hz)'),
                      field(transition, 'Notch transition width (Hz)'),
                    ],
                  ),
                  ExpansionTile(
                    title: const Text('Bad channels and interpolation'),
                    initiallyExpanded: section == 'Bad channels',
                    children: [
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
                    ],
                  ),
                  ExpansionTile(
                    title: const Text('GEDAI'),
                    initiallyExpanded: section == 'GEDAI',
                    children: [
                      field(
                        gedaiThreshold,
                        'GEDAI threshold',
                        help:
                            'auto = balanced; auto- = conservative; numeric values are passed to GEDAI.',
                      ),
                      const Text(
                        'Saved event trials retain their own boundaries. Continuous data use the processing window set in the main panel.',
                      ),
                    ],
                  ),
                  ExpansionTile(
                    title: const Text('Output reference'),
                    initiallyExpanded: section == 'Reference',
                    children: [
                      DropdownButtonFormField<String>(
                        isExpanded: true,
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
                  ),
                  ExpansionTile(
                    title: const Text('ICA and ICLabel'),
                    initiallyExpanded: section == 'ICA',
                    children: [
                      const Divider(height: 24),
                      const Text(
                        'ICA cleaning (choose the algorithm in the Preprocessing panel)',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Blink-locked ICA stage (eye / heart)',
                        ),
                        value: icaBlink,
                        onChanged: (v) => setState(() => icaBlink = v!),
                      ),
                      if (icaBlink) ...[
                        field(
                          icaEye,
                          'Blink detection channel',
                          help:
                              'Empty = Fp1, Fp2, AFz, Fz, F7, F8, AF3 or AF4, whichever exists.',
                        ),
                        field(icaEpochs, 'Blink epochs for the decomposition'),
                        field(
                          icaBlinkHi,
                          'Eye component threshold (start)',
                          help:
                              'ICLabel probability; lowered stepwise to the floor below.',
                        ),
                        field(icaBlinkLo, 'Eye component threshold (floor)'),
                        CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                            'Also remove heart (ECG) components',
                          ),
                          value: icaRemoveEcg,
                          onChanged: (v) => setState(() => icaRemoveEcg = v!),
                        ),
                      ],
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Second ICA stage (muscle / line noise / channel noise)',
                        ),
                        value: icaOther,
                        onChanged: (v) => setState(() => icaOther = v!),
                      ),
                      if (icaOther) ...[
                        field(
                          icaArtefacts,
                          'ICLabel classes to remove',
                          help:
                              'Comma-separated; empty = Muscle, Line Noise, Channel Noise.',
                        ),
                        field(icaOtherHi, 'Component threshold (start)'),
                        field(icaOtherLo, 'Component threshold (floor)'),
                        field(
                          icaFitCutoff,
                          'ASR cutoff for the ICA fit copy (SD)',
                          help:
                              'MATLAB ica2_BurstCriterion (default 15); burst and window rejection apply to this copy only.',
                        ),
                        CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Fit ICA on ASR-cleaned data'),
                          subtitle: const Text(
                            'As the MATLAB pipeline: bursts are rejected from the copy ICA is fitted on only.',
                          ),
                          value: icaFitAsr,
                          onChanged: (v) => setState(() => icaFitAsr = v!),
                        ),
                      ],
                      field(
                        icaSeed,
                        'ICA random seed',
                        help:
                            'Fixed seed makes the decomposition reproducible.',
                      ),
                    ],
                  ),
                  ExpansionTile(
                    title: const Text('ASR and muscle correction'),
                    initiallyExpanded: section == 'ASR',
                    children: [
                      const Divider(height: 24),
                      field(
                        asrCutoff,
                        'ASR burst cutoff (SD)',
                        help:
                            'clean_rawdata BurstCriterion: 5 aggressive, 20 conservative (default).',
                      ),
                      if (config.asrVariant == 'adaptive')
                        field(
                          asrAlpha,
                          'Adaptive ASR update rate (0-1)',
                          help:
                              'Weight of each clean block in the running calibration; 0 = static ASR.',
                        ),
                      if (config.asrVariant == 'easr') ...[
                        field(
                          asrEmbedDim,
                          'E-ASR embedding dimension',
                          help: 'Pseudo-channels per channel (2-32).',
                        ),
                        field(
                          asrEmbedTau,
                          'E-ASR delay (samples)',
                          help: '1-50.',
                        ),
                      ],
                      if (config.asrVariant == 'vmd' ||
                          config.asrVariant == 'emd')
                        field(
                          asrModes,
                          'Number of modes',
                          help:
                              'VMD modes / EMD components used as ASR channels (2-12).',
                        ),
                      if (config.muscleMethod == 'bss_cca')
                        field(
                          bsscaN,
                          'BSS-CCA sources removed',
                          help:
                              'Lowest-autocorrelation sources dropped (1+; typical 1-10% of channels).',
                        ),
                      if (config.muscleMethod == 'icanclean')
                        field(
                          iccThr,
                          'iCanClean R² threshold',
                          help:
                              'Canonical components with R² above this are removed (default 0.7).',
                        ),
                      if (config.muscleMethod == 'wica')
                        field(
                          wicaLevels,
                          'wICA wavelet levels',
                          help:
                              'HAPPE wICA: coif5 SWT levels, soft threshold (default 5).',
                        ),
                    ],
                  ),
                ],
                if (stage == 'Source Space') ...[
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: sourceMethod,
                    decoration: const InputDecoration(
                      labelText: 'Inverse method',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'mne',
                        child: Text('Minimum norm (MNE)'),
                      ),
                      DropdownMenuItem(
                        value: 'dspm',
                        child: Text('dSPM (noise-normalized)'),
                      ),
                      DropdownMenuItem(
                        value: 'sloreta',
                        child: Text('sLORETA (resolution-normalized)'),
                      ),
                      DropdownMenuItem(
                        value: 'lcmv',
                        child: Text(
                          'LCMV (unit gain; 5% covariance regularization)',
                        ),
                      ),
                    ],
                    onChanged: (v) => setState(() => sourceMethod = v!),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Choose forward + atlas model…'),
                    onPressed: () async {
                      final picked = await FilePicker.pickFiles(
                        type: FileType.custom,
                        allowedExtensions: ['json', 'gz'],
                      );
                      if (picked != null &&
                          picked.files.single.path != null &&
                          context.mounted) {
                        setState(() {
                          sourceModel.text = picked.files.single.path!;
                          regions.clear();
                        });
                      }
                    },
                  ),
                  field(
                    sourceModel,
                    'Custom forward + atlas JSON path (empty = bundled fsaverage)',
                    help:
                        'Fixed-orientation channels × sources leadfield and ROI source indices; HCPex requires a matching source grid. Identity noise covariance.',
                  ),

                  field(
                    snr,
                    'Inverse regularization SNR',
                    help: 'Positive value; default 3.',
                  ),
                  if (sourceModel.text.trim().isEmpty)
                    ExpansionTile(
                      title: const Text('Choose bundled source regions'),
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
                    'Source region labels (empty = all model regions)',
                    lines: 3,
                    help:
                        'Comma-separated labels from the selected atlas; unknown names are rejected.',
                  ),
                ],
                if (stage == 'Feature Extraction') ...[
                  DropdownButtonFormField<String>(
                    isExpanded: true,
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
                    isExpanded: true,
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
            onPressed: () async {
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
                  final eh = double.parse(icaBlinkHi.text),
                      el = double.parse(icaBlinkLo.text),
                      oh = double.parse(icaOtherHi.text),
                      ol = double.parse(icaOtherLo.text),
                      ac = double.parse(asrCutoff.text),
                      fc = double.parse(icaFitCutoff.text);
                  final ne = int.parse(icaEpochs.text),
                      sd = int.parse(icaSeed.text);
                  if (!eh.isFinite ||
                      !el.isFinite ||
                      !oh.isFinite ||
                      !ol.isFinite ||
                      eh > 1 ||
                      oh > 1 ||
                      el <= 0 ||
                      ol <= 0 ||
                      ne < 2 ||
                      sd < 0)
                    throw const FormatException(
                      'ICA thresholds must be in (0, 1], blink epochs at least 2, seed non-negative.',
                    );
                  if (!fc.isFinite || fc < 1 || fc > 200)
                    throw const FormatException(
                      'ICA fit ASR cutoff must be between 1 and 200.',
                    );
                  if (!ac.isFinite || ac < 1 || ac > 200)
                    throw const FormatException(
                      'ASR cutoff must be between 1 and 200.',
                    );
                  final aa = double.parse(asrAlpha.text),
                      ed = int.parse(asrEmbedDim.text),
                      et = int.parse(asrEmbedTau.text),
                      am = int.parse(asrModes.text),
                      bn = int.parse(bsscaN.text),
                      it = double.parse(iccThr.text),
                      wl = int.parse(wicaLevels.text);
                  if (!aa.isFinite || aa < 0 || aa > 1)
                    throw const FormatException(
                      'Adaptive ASR rate must be in [0, 1].',
                    );
                  if (ed < 2 || ed > 32 || et < 1 || et > 50)
                    throw const FormatException(
                      'E-ASR dimension must be 2-32 and delay 1-50.',
                    );
                  if (am < 2 || am > 12)
                    throw const FormatException('Mode count must be 2-12.');
                  if (bn < 1)
                    throw const FormatException(
                      'BSS-CCA must remove at least 1 source.',
                    );
                  if (!it.isFinite || it <= 0 || it >= 1)
                    throw const FormatException(
                      'iCanClean R² threshold must be in (0, 1).',
                    );
                  if (wl < 1 || wl > 12)
                    throw const FormatException('wICA levels must be 1-12.');
                  config
                    ..icaBlink = icaBlink
                    ..icaOther = icaOther
                    ..icaRemoveEcg = icaRemoveEcg
                    ..icaFitAsr = icaFitAsr
                    ..icaEyeChannel = icaEye.text.trim()
                    ..icaBlinkEpochs = ne
                    ..icaBlinkThreshold = eh
                    ..icaBlinkThresholdFloor = el
                    ..icaOtherThreshold = oh
                    ..icaOtherThresholdFloor = ol
                    ..icaSeed = sd
                    ..asrCutoff = ac
                    ..asrAdaptAlpha = aa
                    ..asrEmbedDim = ed
                    ..asrEmbedTau = et
                    ..asrModes = am
                    ..bsscaNRemove = bn
                    ..iccThreshold = it
                    ..wicaLevels = wl
                    ..icaFitAsrCutoff = fc
                    ..icaArtefacts = icaArtefacts.text
                        .split(',')
                        .map((v) => v.trim())
                        .where((v) => v.isNotEmpty)
                        .toList();
                  config
                    ..badVarianceRatio = vr
                    ..splineStiffness = ss
                    ..splineRegularization = sr
                    ..gedaiThreshold = gedaiThreshold.text.trim()
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
                    ..sourceMethod = sourceMethod
                    ..sourceModelPath = sourceModel.text.trim()
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
                await RecordingStorage.setPreferredFormat(outputFormat);
                if (context.mounted) Navigator.pop(context, true);
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
    gedaiThreshold,
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
    sourceModel,
    regions,
    window,
    bands,
    order,
    featureRefs,
    icaEye,
    icaEpochs,
    icaBlinkHi,
    icaBlinkLo,
    icaArtefacts,
    icaOtherHi,
    icaOtherLo,
    icaSeed,
    icaFitCutoff,
    asrCutoff,
    asrAlpha,
    asrEmbedDim,
    asrEmbedTau,
    asrModes,
    bsscaN,
    iccThr,
    wicaLevels,
  ]) {
    c.dispose();
  }
  return changed == true;
}
