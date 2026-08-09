// lib/src/orbit_loader.dart
//
// Robust loader for Orbit EEG recorder file format (.orb / .signal).
// Supports both pure JSON lines and timestamp-prefixed lines:
//   timeStamp: 2026-06-28T20:52:29.896074; {"A":[...], "B":[...], "E":37478}

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

    final content = file.readAsStringSync();
    if (content.trim().isEmpty) {
      throw const FormatException('Orbit file is empty.');
    }

    final objRegex = RegExp(r'\{[^{}]*\}');
    final matches = objRegex.allMatches(content);

    final List<double> samplesA = [];
    final List<double> samplesB = [];
    final List<double> samplesC = [];
    final List<double> samplesD = [];
    final List<double> samplesE = [];
    bool has4Channels = false;

    for (final match in matches) {
      var rawJson = match.group(0)!;
      // Quote unquoted json keys: {A:[...]} -> {"A":[...]}
      rawJson = rawJson.replaceAllMapped(RegExp(r'([\{,]\s*)([A-Za-z]+)(\s*:)'), (m) => '${m[1]}"${m[2]}"${m[3]}');

      try {
        final decoded = json.decode(rawJson);
        if (decoded is! Map) continue;

        final aList = _extractNumList(decoded['A']);
        final bList = _extractNumList(decoded['B']);
        final cList = _extractNumList(decoded['C']);
        final dList = _extractNumList(decoded['D']);

        if (cList.isNotEmpty || dList.isNotEmpty) has4Channels = true;

        final eVal = decoded['E'];
        final List<double> eList;
        if (eVal is List) {
          eList = _extractNumList(eVal);
        } else if (eVal is num) {
          final count = _max3(aList.length, bList.length, 1);
          eList = List<double>.filled(count, eVal.toDouble());
        } else {
          eList = const [];
        }

        final n = _max3(aList.length, bList.length, 0);
        if (n == 0) continue;

        for (var i = 0; i < n; i++) {
          samplesA.add(i < aList.length ? aList[i] : 0.0);
          samplesB.add(i < bList.length ? bList[i] : 0.0);
          if (has4Channels) {
            samplesC.add(i < cList.length ? cList[i] : 0.0);
            samplesD.add(i < dList.length ? dList[i] : 0.0);
          }
          samplesE.add(i < eList.length ? eList[i] : 0.0);
        }
      } catch (_) {
        continue;
      }
    }

    if (samplesA.isEmpty || samplesB.isEmpty) {
      throw const FormatException('Orbit file contains no valid EEG channel data.');
    }

    final totalSamples = samplesA.length;

    // Apply standard Orbit Scaling:
    // EEG channels * -0.01 -> microvolts
    // PPG channel  *  0.10 -> arbitrary PPG units
    final interpA = List<double>.generate(totalSamples, (i) => samplesA[i] * -0.01);
    final interpB = List<double>.generate(totalSamples, (i) => samplesB[i] * -0.01);
    final interpC = has4Channels ? List<double>.generate(totalSamples, (i) => samplesC[i] * -0.01) : null;
    final interpD = has4Channels ? List<double>.generate(totalSamples, (i) => samplesD[i] * -0.01) : null;
    final interpE = List<double>.generate(totalSamples, (i) => samplesE[i] * 0.10);

    final List<String> labels = has4Channels
        ? ['AF7', 'AF8', 'Ch3', 'Ch4', 'PPG']
        : ['AF7', 'AF8', 'PPG'];

    final List<List<double>> channelSamples = has4Channels
        ? [interpA, interpB, interpC!, interpD!, interpE]
        : [interpA, interpB, interpE];

    final preview = channelSamples
        .map((ch) => Float32List.fromList(ch))
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

  List<double> _extractNumList(dynamic val) {
    if (val is List) {
      return val.map<double>((e) => (e as num).toDouble()).toList();
    } else if (val is num) {
      return [val.toDouble()];
    }
    return const [];
  }

  int _max3(int a, int b, int c) {
    var m = a > b ? a : b;
    return m > c ? m : c;
  }
}
