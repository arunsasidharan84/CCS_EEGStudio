import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'models.dart';

enum RecordingFileFormat { ccseeg, fif, edf }

/// EDF/FIF retain application-only metadata in JSON-content .ccsmeta files.
/// Signal files and settings can therefore never be confused by their extension.
class RecordingStorage {
  static RecordingFileFormat preferredFormat = RecordingFileFormat.edf;
  static String get extension => preferredFormat.name;
  static String get preferencesPath {
    final env = Platform.environment;
    final root = Platform.isWindows ? env['APPDATA'] : env['XDG_CONFIG_HOME'];
    return '${root ?? '${env['HOME'] ?? Directory.current.path}/.config'}/ccs-eeg-studio/storage.ccssettings';
  }

  static Future<void> loadPreferences({String? path}) async {
    try {
      final value = jsonDecode(
        await File(path ?? preferencesPath).readAsString(),
      );
      preferredFormat = RecordingFileFormat.values.firstWhere(
        (f) => f.name == value['recording_format'],
      );
    } catch (_) {
      /* First launch or invalid preference: retain the safe default. */
    }
  }

  static Future<void> setPreferredFormat(
    RecordingFileFormat value, {
    String? path,
  }) async {
    if (path == null && Platform.environment['FLUTTER_TEST'] == 'true') {
      preferredFormat = value;
      return;
    }
    final file = File(path ?? preferencesPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({'recording_format': value.name}));
    preferredFormat = value;
  }

  static String withExtension(String path, [RecordingFileFormat? format]) {
    final base = path.replaceFirst(
      RegExp(r'(?:\.(?:ccseeg|json|edf|fif))+$', caseSensitive: false),
      '',
    );
    return '$base.${(format ?? preferredFormat).name}';
  }

  static Map<String, dynamic> metadata(EegRecording r) => {
    'sample_rate': r.sampleRate,
    'labels': r.labels,
    'sample_count': r.sampleCount,
    'source_epoch_samples': r.pointsPerEpoch,
    'epoch_count': r.epochCount,
    'epoch_labels': r.epochLabels,
    'epoch_tmin': r.epochTmin,
    'epoch_tmax': r.isEpoched
        ? (r.epochTmin ?? 0) + (r.pointsPerEpoch! - 1) / r.sampleRate
        : null,
    'epoch_onsets': [
      for (final s in r.epochStartSeconds) s - (r.epochTmin ?? 0),
    ],
    'markers': [for (final m in r.markers) m.toJson()],
    'completed_stages': r.completedStages,
    'epoch_start_seconds': r.epochStartSeconds,
    'source_duration_seconds': r.sourceDurationSeconds,
  };
  static Future<void> save(
    EegRecording recording,
    String path, {
    Map<String, dynamic> provenance = const {},
  }) => _saveInWorker(recording, path, provenance);
}

Future<void> _saveInWorker(
  EegRecording r,
  String path,
  Map<String, dynamic> provenance,
) => Isolate.run(() async {
  if (r.labels.isEmpty ||
      r.preview.length != r.labels.length ||
      r.preview.any((c) => c.length != r.sampleCount) ||
      r.sampleRate <= 0 ||
      !r.sampleRate.isFinite ||
      r.sampleCount == 0) {
    throw const FormatException(
      'Saving requires full-resolution, equal-length channels.',
    );
  }
  if (r.isEpoched &&
      (r.sampleCount % r.pointsPerEpoch! != 0 ||
          (r.epochLabels != null &&
              r.epochLabels!.length != r.sampleCount ~/ r.pointsPerEpoch!))) {
    throw const FormatException(
      'Saved trial labels and sample boundaries must match.',
    );
  }
  if (r.preview.any((c) => c.any((v) => !v.isFinite)))
    throw const FormatException('Cannot export nonfinite signal samples.');
  final target = File(path), staging = File('$path.writing');
  final meta = <String, dynamic>{
    'schema': 'ccs-recording-metadata-v1',
    ...RecordingStorage.metadata(r),
    'provenance': {...r.provenance, ...provenance},
  };
  try {
    if (path.toLowerCase().endsWith('.edf')) {
      meta['encoding'] = await _writeEdf(r, staging);
    } else if (path.toLowerCase().endsWith('.fif')) {
      await _writeFif(r, staging);
      meta['encoding'] = {
        'format': 'fif',
        'sample_storage': 'float32',
        'physical_unit': 'V',
      };
    } else {
      await staging.writeAsString(
        jsonEncode({
          'format': 'ccseeg-v1',
          ...RecordingStorage.metadata(r),
          'channels': r.preview,
          'provenance': {...r.provenance, ...provenance},
        }),
      );
    }
    final external =
        path.toLowerCase().endsWith('.edf') ||
        path.toLowerCase().endsWith('.fif');
    if (external) {
      meta['data_file'] = target.uri.pathSegments.last;
      meta['data_bytes'] = await staging.length();
      await File('$path.ccsmeta.writing').writeAsString(jsonEncode(meta));
    }
    if (external) {
      await _commitPair(staging, target, File('$path.ccsmeta.writing'));
    } else {
      await staging.rename(path);
    }
  } finally {
    if (await staging.exists()) await staging.delete();
    final pending = File('$path.ccsmeta.writing');
    if (await pending.exists()) await pending.delete();
  }
});

// Keep a prior signal/metadata pair recoverable if replacing either file fails.
Future<void> _commitPair(
  File staging,
  File target,
  File pendingMetadata,
) async {
  final metadata = File('${target.path}.ccsmeta');
  final backup = await target.parent.createTemp('.ccs-save-');
  File? oldData, oldMetadata;
  var newData = false, newMetadata = false;
  try {
    if (await target.exists())
      oldData = await target.rename('${backup.path}/signal');
    if (await metadata.exists())
      oldMetadata = await metadata.rename('${backup.path}/metadata');
    await staging.rename(target.path);
    newData = true;
    await pendingMetadata.rename(metadata.path);
    newMetadata = true;
  } catch (_) {
    if (newData && await target.exists()) await target.delete();
    if (newMetadata && await metadata.exists()) await metadata.delete();
    if (oldData != null) await oldData.rename(target.path);
    if (oldMetadata != null) await oldMetadata.rename(metadata.path);
    await backup.delete(recursive: true);
    rethrow;
  }
  await backup.delete(recursive: true);
}

List<String> _shortLabels(List<String> labels, int limit) {
  final used = <String>{};
  return [
    for (var i = 0; i < labels.length; i++)
      (() {
        var value = labels[i].replaceAll(RegExp(r'[^ -~]'), '_');
        if (value.length > limit) value = value.substring(0, limit);
        if (value.isEmpty || used.contains(value)) value = 'Ch${i + 1}';
        while (used.contains(value)) value = '_$value';
        used.add(value);
        return value;
      })(),
  ];
}

String _ascii(Object value, int width) {
  final text = '$value';
  if (text.length > width || text.codeUnits.any((v) => v < 32 || v > 126))
    throw FormatException('EDF header value exceeds its field: $text');
  return text.padRight(width);
}

String _signed(double v) =>
    '${v >= 0 ? '+' : ''}${v.toStringAsFixed(7).replaceFirst(RegExp(r'\.?0+$'), '')}';
Future<Map<String, dynamic>> _writeEdf(EegRecording r, File file) async {
  var samples = r.sampleRate.round(), duration = 1;
  if ((samples - r.sampleRate).abs() > 1e-9) {
    var found = false;
    for (final scale in [1000, 1000000]) {
      final numerator = (r.sampleRate * scale).round();
      if ((numerator / scale - r.sampleRate).abs() > r.sampleRate * 1e-12)
        continue;
      final divisor = numerator.gcd(scale);
      samples = numerator ~/ divisor;
      duration = scale ~/ divisor;
      found = true;
      break;
    }
    if (!found || samples > 99999999)
      throw const FormatException(
        'This sampling rate cannot be represented exactly in an EDF header. Choose FIF or CCSEEG.',
      );
  }
  final records = (r.sampleCount / samples).ceil(), n = r.labels.length + 1;
  final limits = <double>[], physicalText = <String>[];
  for (final ch in r.preview) {
    final peak = ch.fold(0.0, (a, b) => math.max(a, b.abs()));
    var fitted = false;
    for (var digits = 6; digits >= 1 && !fitted; digits--) {
      final power = peak == 0 ? 0 : (math.log(peak) / math.ln10).floor();
      final step = math.pow(10, power - digits + 1).toDouble();
      final rounded = peak == 0 ? 1.0 : ((peak / step).ceil() + 1) * step;
      for (final text in [
        rounded.toStringAsPrecision(digits),
        rounded.toStringAsExponential(digits - 1),
      ]) {
        final value = double.parse(text);
        if (text.length + 1 <= 8 &&
            value >= peak &&
            value > 0 &&
            value.isFinite) {
          limits.add(value);
          physicalText.add(text);
          fitted = true;
          break;
        }
      }
    }
    if (!fitted)
      throw const FormatException(
        'Signal range cannot be represented in EDF physical scaling. Choose FIF or CCSEEG.',
      );
  }
  final events = <List<String>>[
    for (var i = 0; i < records; i++)
      ['${_signed((i * duration).toDouble())}\x14\x14\x00'],
  ];
  for (final m in r.markers) {
    final onset =
        (m.epochIndex ?? 0) * (r.pointsPerEpoch ?? 0) / r.sampleRate +
        m.startSeconds;
    if (onset < 0 || onset >= r.durationSeconds) continue;
    final desc = (m.description.isEmpty ? m.type : m.description).replaceAll(
      RegExp(r'[\x00\x14\x15]'),
      ' ',
    );
    events[(onset / duration).floor().clamp(0, records - 1)].add(
      '${_signed(onset)}${m.durationSeconds > 0 ? '\x15${m.durationSeconds}' : ''}\x14$desc\x14\x00',
    );
  }
  if (r.isEpoched) {
    for (var e = 0; e < r.sampleCount ~/ r.pointsPerEpoch!; e++) {
      final onset = e * r.pointsPerEpoch! / r.sampleRate;
      final label = (r.epochLabels?[e] ?? 'Epoch ${e + 1}').replaceAll(
        RegExp(r'[\x00\x14\x15]'),
        ' ',
      );
      events[(onset / duration).floor().clamp(0, records - 1)].add(
        '${_signed(onset)}\x15${r.pointsPerEpoch! / r.sampleRate}\x14CCS epoch ${e + 1}: $label\x14\x00',
      );
      if (e > 0)
        events[(onset / duration).floor().clamp(0, records - 1)].add(
          '${_signed(onset)}\x14EDGE boundary\x14\x00',
        );
    }
  }
  final annotationBytes = [for (final e in events) utf8.encode(e.join())];
  final annSamples = math.max(
    16,
    (annotationBytes.map((b) => b.length).reduce(math.max) + 1) ~/ 2,
  );
  final names = [..._shortLabels(r.labels, 16), 'EDF Annotations'];
  final header = StringBuffer()
    ..write(_ascii('0', 8))
    ..write(_ascii('X X X X', 80))
    ..write(_ascii('Startdate X X X X', 80))
    ..write(_ascii('01.01.85', 8))
    ..write(_ascii('00.00.00', 8))
    ..write(_ascii(256 + n * 256, 8))
    ..write(_ascii('EDF+C', 44))
    ..write(_ascii(records, 8))
    ..write(_ascii(duration, 8))
    ..write(_ascii(n, 4));
  void fields(List<Object> values, int width) {
    for (final v in values) header.write(_ascii(v, width));
  }

  fields(names, 16);
  fields(List.filled(n, ''), 80);
  fields([...List.filled(r.labels.length, 'uV'), ''], 8);
  fields([for (final v in physicalText) '-$v', '-1'], 8);
  fields([...physicalText, '1'], 8);
  fields(List.filled(n, -32768), 8);
  fields(List.filled(n, 32767), 8);
  fields(List.filled(n, ''), 80);
  fields([...List.filled(r.labels.length, samples), annSamples], 8);
  fields(List.filled(n, ''), 32);
  final out = await file.open(mode: FileMode.write);
  try {
    await out.writeFrom(ascii.encode(header.toString()));
    final buffer = ByteData(samples * 2);
    for (var record = 0; record < records; record++) {
      for (var c = 0; c < r.labels.length; c++) {
        final limit = limits[c];
        for (var s = 0; s < samples; s++) {
          final index = record * samples + s;
          final value = index < r.sampleCount ? r.preview[c][index] : 0.0;
          final q = ((value + limit) / (2 * limit) * 65535 - 32768)
              .round()
              .clamp(-32768, 32767);
          buffer.setInt16(s * 2, q, Endian.little);
        }
        await out.writeFrom(buffer.buffer.asUint8List());
      }
      final annotation = Uint8List(annSamples * 2)
        ..setRange(0, annotationBytes[record].length, annotationBytes[record]);
      await out.writeFrom(annotation);
    }
  } finally {
    await out.close();
  }
  return {
    'format': 'edf+',
    'quantization_step_uv': [for (final v in limits) 2 * v / 65535],
    'padded_samples': records * samples - r.sampleCount,
    'record_duration_seconds': duration,
  };
}

class _FifWriter {
  _FifWriter(this.file);
  final RandomAccessFile file;
  void tag(int kind, int type, Uint8List bytes, {int next = 0}) {
    final header = ByteData(16)
      ..setInt32(0, kind)
      ..setInt32(4, type)
      ..setInt32(8, bytes.length)
      ..setInt32(12, next);
    file.writeFromSync(header.buffer.asUint8List());
    file.writeFromSync(bytes);
  }

  void integers(int kind, List<int> values) {
    final b = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) b.setInt32(i * 4, values[i]);
    tag(kind, 3, b.buffer.asUint8List());
  }

  void floats(int kind, List<double> values) {
    final b = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) b.setFloat32(i * 4, values[i]);
    tag(kind, 4, b.buffer.asUint8List());
  }

  void text(int kind, String value) =>
      tag(kind, 10, Uint8List.fromList(utf8.encode(value)));
  void start(int block) => integers(104, [block]);
  void end(int block) => integers(105, [block]);
}

Future<void> _writeFif(EegRecording r, File file) async {
  final w = _FifWriter(file.openSync(mode: FileMode.write));
  try {
    final id = ByteData(20)..setInt32(0, 65540);
    w.tag(100, 31, id.buffer.asUint8List());
    w.integers(101, [-1]);
    w.integers(106, [-1]);
    w.start(100);
    w.tag(103, 31, id.buffer.asUint8List());
    w.start(101);
    w.integers(200, [r.labels.length]);
    w.floats(201, [r.sampleRate]);
    w.floats(219, [r.sampleRate / 2]);
    w.floats(223, [0]);
    final names = _shortLabels(r.labels, 15);
    for (var c = 0; c < names.length; c++) {
      final info = ByteData(96)
        ..setInt32(0, c + 1)
        ..setInt32(4, c + 1)
        ..setInt32(8, 2)
        ..setFloat32(12, 1)
        ..setFloat32(16, 1)
        ..setInt32(20, 1)
        ..setInt32(72, 107)
        ..setInt32(76, 0);
      info.buffer.asUint8List().setRange(
        80,
        80 + names[c].length,
        ascii.encode(names[c]),
      );
      w.tag(203, 30, info.buffer.asUint8List());
    }
    for (var c = 0; c < r.labels.length; c++) {
      w.start(113);
      w.integers(250, [c + 1]);
      w.text(258, r.labels[c]);
      w.end(113);
    }
    w.end(101);
    if (r.markers.isNotEmpty) {
      w.start(3810);
      final onsets = [
        for (final m in r.markers)
          (m.epochIndex != null && m.epochIndex! < r.epochStartSeconds.length
                  ? r.epochStartSeconds[m.epochIndex!]
                  : (m.epochIndex ?? 0) *
                        (r.pointsPerEpoch ?? 0) /
                        r.sampleRate) +
              m.startSeconds,
      ];
      w.floats(3568, onsets);
      w.floats(3569, [
        for (var i = 0; i < onsets.length; i++)
          onsets[i] + r.markers[i].durationSeconds,
      ]);
      w.text(
        206,
        r.markers
            .map(
              (m) => (m.description.isEmpty ? m.type : m.description)
                  .replaceAll(':', '{COLON}'),
            )
            .join(':'),
      );
      w.end(3810);
    }
    if (r.isEpoched) {
      final pts = r.pointsPerEpoch!, epochs = r.sampleCount ~/ pts;
      w.start(103);
      w.start(373);
      w.start(361);
      final conditions = r.epochLabels ?? List.filled(epochs, 'Epoch');
      final codes = <String, int>{};
      for (final label in conditions)
        codes.putIfAbsent(label, () => codes.length + 1);
      w.integers(3561, [
        for (var e = 0; e < epochs; e++) ...[
          e < r.epochStartSeconds.length
              ? ((r.epochStartSeconds[e] - (r.epochTmin ?? 0)) * r.sampleRate)
                    .round()
              : e * pts - ((r.epochTmin ?? 0) * r.sampleRate).round(),
          0,
          codes[conditions[e]]!,
        ],
      ]);
      w.text(
        206,
        codes.entries
            .map(
              (e) =>
                  '${e.key.replaceAll(':', '_').replaceAll(';', '_')}:${e.value}',
            )
            .join(';'),
      );
      w.end(361);
      final first = ((r.epochTmin ?? 0) * r.sampleRate).round();
      w.integers(208, [first]);
      w.integers(209, [first + pts - 1]);
      if (epochs * r.labels.length * pts * 4 + 16 >= 0x7fffffff)
        throw const FormatException(
          'FIF epoch data exceeds the 2-GB tag limit; split the trials or choose CCSEEG.',
        );
      final bytes = ByteData(epochs * r.labels.length * pts * 4 + 16);
      var at = 0;
      for (var e = 0; e < epochs; e++)
        for (final ch in r.preview)
          for (var s = 0; s < pts; s++) {
            bytes.setFloat32(at, ch[e * pts + s] * 1e-6);
            at += 4;
          }
      for (final dim in [pts, r.labels.length, epochs, 3]) {
        bytes.setInt32(at, dim);
        at += 4;
      }
      w.tag(302, 0x40000004, bytes.buffer.asUint8List());
      w.text(3801, jsonEncode(List.generate(epochs, (_) => [])));
      w.integers(3800, List.generate(epochs, (i) => i));
      w.end(373);
      w.end(103);
    } else {
      w.start(102);
      w.integers(208, [0]);
      for (var start = 0; start < r.sampleCount; start += 4096) {
        final count = math.min(4096, r.sampleCount - start),
            bytes = ByteData(count * r.labels.length * 4);
        var at = 0;
        for (var s = 0; s < count; s++)
          for (final ch in r.preview) {
            bytes.setFloat32(at, ch[start + s] * 1e-6);
            at += 4;
          }
        w.tag(300, 4, bytes.buffer.asUint8List());
      }
      w.end(102);
    }
    w.end(100);
    w.tag(108, 0, Uint8List(0), next: -1);
  } finally {
    w.file.closeSync();
  }
}
