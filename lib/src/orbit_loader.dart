// lib/src/orbit_loader.dart
//
// Loader for the Orbit EEG recorder file format (.orb / .signal).
//
// File format: JSON Lines — each line is a JSON object with:
//   T  — List<int>  timestamp indices at 250 Hz
//   A  — List<num>  EEG channel 1 (AF7) raw ADC counts
//   B  — List<num>  EEG channel 2 (AF8) raw ADC counts
//   C  — List<num>  EEG channel 3 (optional, 4-ch device)
//   D  — List<num>  EEG channel 4 (optional, 4-ch device)
//   E  — List<num> | num   PPG channel
//
// Scaling applied after interpolation:
//   EEG channels  ×  -0.01  →  microvolts
//   PPG channel   ×   0.10  →  arbitrary PPG units

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'models.dart';

class OrbLoader {
  static const double _sampleRate = 250.0;

  EegRecording load(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw FileSystemException('File not found', path);
    }

    final lines = file.readAsLinesSync();
    if (lines.isEmpty) {
      throw const FormatException('Orbit file is empty.');
    }

    // Temporary maps: timestamp-index → sample value for each channel.
    final Map<int, double> chanA = {};
    final Map<int, double> chanB = {};
    final Map<int, double> chanC = {};
    final Map<int, double> chanD = {};
    final Map<int, double> chanE = {};
    bool has4Channels = false;

    for (var lineNo = 0; lineNo < lines.length; lineNo++) {
      final line = lines[lineNo].trim();
      if (line.isEmpty) continue;

      try {
        final decoded = json.decode(line);
        if (decoded is! Map) continue;

        final tVal = decoded['T'];
        if (tVal is! List) continue;

        final List<int> timestamps =
            tVal.map<int>((e) => (e as num).toInt()).toList();
        final int numSamples = timestamps.length;
        if (numSamples == 0) continue;

        final List<double> aSamples = _parseList(decoded['A'], numSamples);
        final List<double> bSamples = _parseList(decoded['B'], numSamples);

        final cVal = decoded['C'];
        final List<double> cSamples = _parseList(cVal, numSamples);
        if (cVal is List && cVal.length > 1) has4Channels = true;

        final dVal = decoded['D'];
        final List<double> dSamples = _parseList(dVal, numSamples);
        if (dVal is List && dVal.length > 1) has4Channels = true;

        // PPG may arrive as a scalar repeated across the packet.
        final eVal = decoded['E'];
        final List<double> eSamples;
        if (eVal is List) {
          eSamples = _parseList(eVal, numSamples);
        } else if (eVal is num) {
          eSamples = List<double>.filled(numSamples, eVal.toDouble());
        } else {
          eSamples = List<double>.filled(numSamples, 0.0);
        }

        for (var i = 0; i < numSamples; i++) {
          final t = timestamps[i];
          chanA[t] = aSamples[i];
          chanB[t] = bSamples[i];
          if (cSamples.isNotEmpty) chanC[t] = cSamples[i];
          if (dSamples.isNotEmpty) chanD[t] = dSamples[i];
          chanE[t] = eSamples[i];
        }
      } catch (_) {
        // Ignore malformed lines.
        continue;
      }
    }

    if (chanA.isEmpty || chanB.isEmpty) {
      throw const FormatException(
          'Orbit file contains no valid EEG channel data.');
    }

    // Determine continuous timestamp range.
    final allTs = chanA.keys.toList()..sort();
    final minT = allTs.first;
    final maxT = allTs.last;
    final totalSamples = maxT - minT + 1;

    if (totalSamples <= 0) {
      throw const FormatException(
          'Orbit file contains invalid timestamp range.');
    }

    // Build dense arrays (NaN where data is missing) then interpolate.
    final rawA = List<double>.filled(totalSamples, double.nan);
    final rawB = List<double>.filled(totalSamples, double.nan);
    final List<double>? rawC =
        has4Channels ? List<double>.filled(totalSamples, double.nan) : null;
    final List<double>? rawD =
        has4Channels ? List<double>.filled(totalSamples, double.nan) : null;
    final rawE = List<double>.filled(totalSamples, double.nan);

    for (var i = 0; i < totalSamples; i++) {
      final t = minT + i;
      rawA[i] = chanA[t] ?? double.nan;
      rawB[i] = chanB[t] ?? double.nan;
      if (has4Channels) {
        rawC![i] = chanC[t] ?? double.nan;
        rawD![i] = chanD[t] ?? double.nan;
      }
      rawE[i] = chanE[t] ?? double.nan;
    }

    final interpA = _interpolate(rawA);
    final interpB = _interpolate(rawB);
    final interpC = has4Channels ? _interpolate(rawC!) : null;
    final interpD = has4Channels ? _interpolate(rawD!) : null;
    final interpE = _interpolate(rawE);

    // Apply scaling.
    for (var i = 0; i < totalSamples; i++) {
      interpA[i] *= -0.01;
      interpB[i] *= -0.01;
      if (has4Channels) {
        interpC![i] *= -0.01;
        interpD![i] *= -0.01;
      }
      interpE[i] *= 0.1;
    }

    final List<String> labels = has4Channels
        ? ['AF7', 'AF8', 'Ch3', 'Ch4', 'PPG']
        : ['AF7', 'AF8', 'PPG'];

    final List<List<double>> channelSamples = has4Channels
        ? [interpA, interpB, interpC!, interpD!, interpE]
        : [interpA, interpB, interpE];

    final preview = channelSamples
        .map((ch) => Float32List.fromList(ch.cast<double>()))
        .toList();

    return EegRecording(
      path: path,
      sampleRate: _sampleRate,
      labels: labels,
      preview: preview,
      sampleCount: totalSamples,
      format: 'orb',
    );
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  List<double> _parseList(dynamic value, int expectedLength) {
    if (value is List) {
      return value.map<double>((e) => (e as num).toDouble()).toList();
    }
    return List<double>.filled(expectedLength, 0.0);
  }

  /// Linear interpolation over gaps (NaN runs) in [data].
  List<double> _interpolate(List<double> data) {
    final n = data.length;
    final result = List<double>.from(data);

    // Find first non-NaN index.
    int firstKnown = -1;
    for (var i = 0; i < n; i++) {
      if (!data[i].isNaN) {
        firstKnown = i;
        break;
      }
    }
    if (firstKnown == -1) return List<double>.filled(n, 0.0);

    // Fill leading NaNs with the first known value.
    for (var i = 0; i < firstKnown; i++) {
      result[i] = data[firstKnown];
    }

    int lastKnownIdx = firstKnown;
    double lastKnownVal = data[firstKnown];
    var i = firstKnown + 1;

    while (i < n) {
      if (!data[i].isNaN) {
        lastKnownIdx = i;
        lastKnownVal = data[i];
        i++;
      } else {
        // Find next known sample.
        int nextKnownIdx = -1;
        for (var j = i; j < n; j++) {
          if (!data[j].isNaN) {
            nextKnownIdx = j;
            break;
          }
        }
        if (nextKnownIdx == -1) {
          // Trailing NaN block — fill with last known value.
          for (var j = i; j < n; j++) {
            result[j] = lastKnownVal;
          }
          break;
        } else {
          final double nextKnownVal = data[nextKnownIdx];
          final double step =
              (nextKnownVal - lastKnownVal) / (nextKnownIdx - lastKnownIdx);
          for (var j = i; j < nextKnownIdx; j++) {
            result[j] = lastKnownVal + step * (j - lastKnownIdx);
          }
          lastKnownIdx = nextKnownIdx;
          lastKnownVal = nextKnownVal;
          i = nextKnownIdx + 1;
        }
      }
    }

    return result;
  }
}
