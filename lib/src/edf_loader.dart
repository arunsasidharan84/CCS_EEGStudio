import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'models.dart';

class EdfLoader {
  LoadedEeg load(String path, {bool scaleVoltsToMicrovolts = false}) {
    final bytes = File(path).readAsBytesSync();
    if (bytes.length < 256) {
      throw const FormatException('EDF header is shorter than 256 bytes.');
    }

    final base = _AsciiHeader(bytes);
    final headerBytes = base.intAt(184, 8);
    final dataRecordCount = base.optionalIntAt(236, 8) ?? -1;
    final dataRecordSeconds = base.doubleAt(244, 8);
    final signalCount = base.intAt(252, 4);
    if (signalCount <= 0 || headerBytes < 256 + signalCount * 256) {
      throw const FormatException('EDF signal header is invalid.');
    }

    var offset = 256;
    final labels = _readSignalStrings(bytes, offset, signalCount, 16);
    offset += signalCount * 16;
    offset += signalCount * 80; // transducer
    final physicalDimensions = _readSignalStrings(
      bytes,
      offset,
      signalCount,
      8,
    );
    offset += signalCount * 8;
    final physicalMin = _readSignalDoubles(bytes, offset, signalCount, 8);
    offset += signalCount * 8;
    final physicalMax = _readSignalDoubles(bytes, offset, signalCount, 8);
    offset += signalCount * 8;
    final digitalMin = _readSignalDoubles(bytes, offset, signalCount, 8);
    offset += signalCount * 8;
    final digitalMax = _readSignalDoubles(bytes, offset, signalCount, 8);
    offset += signalCount * 8;
    offset += signalCount * 80; // prefiltering
    final samplesPerRecord = _readSignalInts(bytes, offset, signalCount, 8);

    final totalSamplesPerRecord = samplesPerRecord.fold<int>(
      0,
      (a, b) => a + b,
    );
    final records = dataRecordCount > 0
        ? dataRecordCount
        : ((bytes.length - headerBytes) / (totalSamplesPerRecord * 2)).floor();
    if (records <= 0) {
      throw const FormatException('EDF contains no complete data records.');
    }

    final keptSignalIndexes = <int>[];
    for (var index = 0; index < signalCount; index++) {
      if (_isDisplaySignal(labels[index]) &&
          samplesPerRecord[index] > 0 &&
          digitalMax[index] != digitalMin[index]) {
        keptSignalIndexes.add(index);
      }
    }
    if (keptSignalIndexes.isEmpty) {
      throw const FormatException(
        'EDF contains no displayable signal channels.',
      );
    }

    final keptBySignalIndex = {
      for (
        var displayIndex = 0;
        displayIndex < keptSignalIndexes.length;
        displayIndex++
      )
        keptSignalIndexes[displayIndex]: displayIndex,
    };
    final channelSamples = [
      for (final signalIndex in keptSignalIndexes)
        List<double>.filled(records * samplesPerRecord[signalIndex], 0),
    ];

    final markers = <EegMarker>[];
    final data = ByteData.sublistView(bytes);
    var cursor = headerBytes;
    for (var record = 0; record < records; record++) {
      for (var channel = 0; channel < signalCount; channel++) {
        final samplesInRecord = samplesPerRecord[channel];
        if (labels[channel].toLowerCase().contains('annotation')) {
          final end = cursor + samplesInRecord * 2;
          if (end > bytes.length)
            throw const FormatException('EDF annotation record is truncated.');
          markers.addAll(
            parseEdfAnnotations(
              bytes.sublist(cursor, end),
              displayRecordStart: record * dataRecordSeconds,
            ),
          );
          cursor = end;
          continue;
        }
        final gain =
            (physicalMax[channel] - physicalMin[channel]) /
            (digitalMax[channel] - digitalMin[channel]);
        final intercept = physicalMin[channel] - gain * digitalMin[channel];
        final displayIndex = keptBySignalIndex[channel];
        for (var sample = 0; sample < samplesInRecord; sample++) {
          if (cursor + 2 > bytes.length) {
            throw const FormatException('EDF data ended mid-record.');
          }
          final digital = data.getInt16(cursor, Endian.little);
          cursor += 2;
          if (displayIndex == null) {
            continue;
          }
          var physical = digital * gain + intercept;
          if (scaleVoltsToMicrovolts ||
              physicalDimensions[channel].toLowerCase() == 'v') {
            physical *= 1e6;
          }
          channelSamples[displayIndex][record * samplesInRecord + sample] =
              physical;
        }
      }
    }

    final sampleRate =
        samplesPerRecord[keptSignalIndexes.first] /
        math.max(dataRecordSeconds, 1e-9);
    final displayLabels = [
      for (final index in keptSignalIndexes) labels[index],
    ];
    return LoadedEeg(
      sampleRateHz: sampleRate,
      channelLabels: displayLabels,
      channelSamples: channelSamples,
      markers: markers
        ..sort((a, b) => a.startSeconds.compareTo(b.startSeconds)),
      sourceDescription:
          '${displayLabels.length} channels, ${sampleRate.toStringAsFixed(1)} Hz, ${(records * dataRecordSeconds / 60).toStringAsFixed(1)} min',
    );
  }

  static List<String> _readSignalStrings(
    Uint8List bytes,
    int offset,
    int count,
    int width,
  ) {
    return [
      for (var index = 0; index < count; index++)
        ascii
            .decode(
              bytes.sublist(
                offset + index * width,
                offset + (index + 1) * width,
              ),
            )
            .trim(),
    ];
  }

  static List<int> _readSignalInts(
    Uint8List bytes,
    int offset,
    int count,
    int width,
  ) {
    return [
      for (var index = 0; index < count; index++)
        int.parse(
          ascii
              .decode(
                bytes.sublist(
                  offset + index * width,
                  offset + (index + 1) * width,
                ),
              )
              .trim(),
        ),
    ];
  }

  static List<double> _readSignalDoubles(
    Uint8List bytes,
    int offset,
    int count,
    int width,
  ) {
    return [
      for (var index = 0; index < count; index++)
        double.parse(
          ascii
              .decode(
                bytes.sublist(
                  offset + index * width,
                  offset + (index + 1) * width,
                ),
              )
              .trim()
              .replaceAll(',', '.'),
        ),
    ];
  }
}

bool _isDisplaySignal(String label) {
  final normalized = label.toLowerCase();
  return !normalized.contains('annotation') &&
      !normalized.contains('status') &&
      !normalized.contains('marker');
}

class _AsciiHeader {
  const _AsciiHeader(this.bytes);

  final Uint8List bytes;

  int intAt(int offset, int width) => int.parse(_textAt(offset, width));
  int? optionalIntAt(int offset, int width) {
    final text = _textAt(offset, width);
    return text.isEmpty ? null : int.parse(text);
  }

  double doubleAt(int offset, int width) =>
      double.parse(_textAt(offset, width).replaceAll(',', '.'));

  String _textAt(int offset, int width) {
    return ascii.decode(bytes.sublist(offset, offset + width)).trim();
  }
}

/// EDF+ time-annotated lists are byte strings, not calibrated signal samples.
/// Remap each record's timekeeper to the same concatenated timeline as signals.
List<EegMarker> parseEdfAnnotations(
  Uint8List bytes, {
  double displayRecordStart = 0,
}) {
  final lists = utf8
      .decode(bytes, allowMalformed: true)
      .split('\x00')
      .where((s) => s.isNotEmpty)
      .toList();
  var clock = displayRecordStart;
  if (lists.isNotEmpty) {
    final fields = lists.first.split('\x14');
    if (fields.skip(1).every((s) => s.trim().isEmpty)) {
      final candidate = double.tryParse(fields.first.split('\x15').first);
      if (candidate != null && candidate.isFinite) clock = candidate;
    }
  }
  final markers = <EegMarker>[];
  for (final tal in lists) {
    final fields = tal.split('\x14');
    if (fields.length < 2) continue;
    final timing = fields.first.split('\x15');
    final onset = double.tryParse(timing.first);
    if (onset == null || !onset.isFinite) continue;
    final duration = timing.length > 1
        ? double.tryParse(timing[1]) ?? 0.0
        : 0.0;
    for (final description in fields.skip(1).where((s) => s.trim().isNotEmpty))
      markers.add(
        EegMarker(
          type: 'Annotation',
          description: description,
          startSeconds: onset - clock + displayRecordStart,
          durationSeconds: duration.isFinite && duration >= 0 ? duration : 0,
        ),
      );
  }
  return markers;
}
