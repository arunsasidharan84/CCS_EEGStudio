import 'dart:io';
import 'dart:typed_data';

import 'models.dart';

/// Loader for BrainVision BrainAmp format files (.vhdr / .eeg / .dat).
///
/// Supports:
///   DataOrientation : MULTIPLEXED | VECTORIZED
///   BinaryFormat    : IEEE_FLOAT_32 | INT_16 | UINT_16 | INT_32
///   Resolution      : per-channel float multiplier from [Channel Infos]
class VhdrLoader {
  EegRecording load(String vhdrPath) {
    // ── Parse header ───────────────────────────────────────────────────────
    final lines = File(vhdrPath)
        .readAsStringSync()
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');

    String key(String line) =>
        line.contains('=') ? line.substring(0, line.indexOf('=')).trim() : '';
    String val(String line) =>
        line.contains('=') ? line.substring(line.indexOf('=') + 1).trim() : '';

    String dataFile = '';
    String orientation = 'MULTIPLEXED';
    String binaryFormat = 'IEEE_FLOAT_32';
    int numChannels = 0;
    int samplingIntervalUs = 0; // microseconds

    final channelNames = <int, String>{};
    final channelResolutions = <int, double>{}; // index → µV/bit

    String section = '';
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith(';')) continue;
      if (line.startsWith('[')) {
        section = line.replaceAll('[', '').replaceAll(']', '').trim();
        continue;
      }
      final k = key(line);
      final v = val(line);
      switch (section) {
        case 'Common Infos':
          if (k == 'DataFile') dataFile = v;
          if (k == 'DataOrientation') orientation = v.toUpperCase();
          if (k == 'NumberOfChannels') numChannels = int.tryParse(v) ?? 0;
          if (k == 'SamplingInterval') samplingIntervalUs = int.tryParse(v) ?? 0;
        case 'Binary Infos':
          if (k == 'BinaryFormat') binaryFormat = v.toUpperCase();
        case 'Channel Infos':
          // Ch<N>=name,ref,resolution,unit,...
          if (k.startsWith('Ch')) {
            final idx = int.tryParse(k.substring(2));
            if (idx != null) {
              final parts = v.split(',');
              channelNames[idx] = parts.isNotEmpty ? parts[0].trim() : 'Ch$idx';
              if (parts.length >= 3 && parts[2].trim().isNotEmpty) {
                channelResolutions[idx] = double.tryParse(parts[2].trim()) ?? 1.0;
              } else {
                channelResolutions[idx] = 1.0;
              }
            }
          }
      }
    }

    if (samplingIntervalUs <= 0) {
      throw const FormatException('Invalid SamplingInterval in .vhdr');
    }
    final sampleRate = 1000000.0 / samplingIntervalUs;
    if (numChannels <= 0) {
      throw FormatException('Invalid NumberOfChannels=$numChannels in .vhdr');
    }

    // Build ordered label list
    final labels = <String>[];
    final resolutions = <double>[];
    for (var i = 1; i <= numChannels; i++) {
      labels.add(channelNames[i] ?? 'Ch$i');
      resolutions.add(channelResolutions[i] ?? 1.0);
    }

    // ── Resolve data file path ──────────────────────────────────────────────
    final vhdrDir = File(vhdrPath).parent.path;
    final dataPath = dataFile.isNotEmpty
        ? '$vhdrDir${Platform.pathSeparator}${dataFile.split('/').last}'
        : vhdrPath.replaceAll(RegExp(r'\.vhdr$', caseSensitive: false), '.eeg');
    if (!File(dataPath).existsSync()) {
      throw FileSystemException('Data file not found: $dataPath', dataPath);
    }

    // ── Read binary data ────────────────────────────────────────────────────
    final bytes = File(dataPath).readAsBytesSync();
    final bytesPerSample = switch (binaryFormat) {
      'INT_16' || 'UINT_16' => 2,
      'INT_32' => 4,
      _ => 4, // IEEE_FLOAT_32
    };
    final totalSamples = bytes.length ~/ (numChannels * bytesPerSample);

    if (totalSamples <= 0) {
      throw FormatException('Data file appears empty: $dataPath');
    }

    final bd = ByteData.sublistView(bytes);
    const stride = 1;

    final preview = <Float32List>[];

    if (orientation == 'VECTORIZED') {
      // Each channel is stored contiguously: [ch0_t0, ch0_t1, ..., ch1_t0, ...]
      for (var c = 0; c < numChannels; c++) {
        final res = resolutions[c];
        final channelValues = <double>[];
        for (var s = 0; s < totalSamples; s += stride) {
          final offset = (c * totalSamples + s) * bytesPerSample;
          channelValues.add(_readSample(bd, offset, binaryFormat, res));
        }
        preview.add(Float32List.fromList(channelValues));
      }
    } else {
      // MULTIPLEXED: [ch0_t0, ch1_t0, ..., chN_t0, ch0_t1, ch1_t1, ...]
      for (var c = 0; c < numChannels; c++) {
        final res = resolutions[c];
        final channelValues = <double>[];
        for (var s = 0; s < totalSamples; s += stride) {
          final offset = (s * numChannels + c) * bytesPerSample;
          channelValues.add(_readSample(bd, offset, binaryFormat, res));
        }
        preview.add(Float32List.fromList(channelValues));
      }
    }

    final markers = _loadVmrk(vhdrPath, sampleRate);

    return EegRecording(
      path: vhdrPath,
      dataPath: dataPath,
      sampleRate: sampleRate,
      labels: labels,
      preview: preview,
      sampleCount: totalSamples,
      format: 'vhdr',
      markers: markers,
    );
  }

  List<EegMarker> _loadVmrk(String vhdrPath, double sampleRate) {
    final vmrkPath =
        vhdrPath.replaceAll(RegExp(r'\.vhdr$', caseSensitive: false), '.vmrk');
    final file = File(vmrkPath);
    if (!file.existsSync()) return const [];

    final markers = <EegMarker>[];
    final lines = file
        .readAsStringSync()
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');

    String section = '';
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith(';')) continue;
      if (line.startsWith('[')) {
        section = line.replaceAll('[', '').replaceAll(']', '').trim();
        continue;
      }
      if (section == 'Marker Infos' && line.startsWith('Mk')) {
        final eqIdx = line.indexOf('=');
        if (eqIdx < 0) continue;
        final val = line.substring(eqIdx + 1).trim();
        final parts = val.split(',');
        if (parts.length >= 3) {
          final type = parts[0].trim();
          final desc = parts[1].trim();
          final posSamples = int.tryParse(parts[2].trim()) ?? 1;
          final sizeSamples =
              parts.length >= 4 ? (int.tryParse(parts[3].trim()) ?? 0) : 0;
          final chNum =
              parts.length >= 5 ? (int.tryParse(parts[4].trim()) ?? 0) : 0;

          final startSec = (posSamples - 1) / sampleRate;
          final durSec = sizeSamples / sampleRate;

          markers.add(EegMarker(
            type: type,
            description: desc,
            startSeconds: startSec > 0 ? startSec : 0.0,
            durationSeconds: durSec > 0 ? durSec : 0.0,
            channelIndex: chNum > 0 ? chNum - 1 : null,
          ));
        }
      }
    }
    return markers;
  }


  double _readSample(ByteData bd, int offset, String format, double resolution) {
    if (offset + (format == 'INT_16' || format == 'UINT_16' ? 2 : 4) > bd.lengthInBytes) {
      return 0.0;
    }
    return switch (format) {
      'IEEE_FLOAT_32' => bd.getFloat32(offset, Endian.little),
      'INT_16' => bd.getInt16(offset, Endian.little) * resolution,
      'UINT_16' => bd.getUint16(offset, Endian.little) * resolution,
      'INT_32' => bd.getInt32(offset, Endian.little) * resolution,
      _ => bd.getFloat32(offset, Endian.little),
    };
  }
}
