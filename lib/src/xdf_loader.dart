import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:xml/xml.dart';
import 'models.dart';

class XdfStreamInfo {
  const XdfStreamInfo(this.id, this.name, this.type, this.rate, this.channels);
  final int id, channels;
  final String name, type;
  final double rate;
  @override
  String toString() => '$name · $type · $channels channels · $rate Hz';
}

class _Stream {
  _Stream(this.id, this.xml);
  final int id;
  final XmlDocument xml;
  String field(String key) =>
      xml.rootElement.getElement(key)?.innerText.trim() ?? '';
  int get count => int.parse(field('channel_count'));
  double get rate => double.parse(field('nominal_srate'));
  String get format => field('channel_format');
  final times = <double>[];
  final values = <List<double>>[];
  final events = <(double, String)>[];
  final clocks = <(double, double)>[];
  double last = 0;
  XdfStreamInfo get info =>
      XdfStreamInfo(id, field('name'), field('type'), rate, count);
  double corrected(double time) {
    if (clocks.isEmpty) return time;
    if (time <= clocks.first.$1) return time + clocks.first.$2;
    for (var i = 1; i < clocks.length; i++) {
      final a = clocks[i - 1], b = clocks[i];
      if (time <= b.$1) {
        final f = (time - a.$1) / (b.$1 - a.$1);
        return time + a.$2 + f * (b.$2 - a.$2);
      }
    }
    return time + clocks.last.$2;
  }
}

class _Reader {
  _Reader(this.bytes);
  final Uint8List bytes;
  int pos = 0;
  ByteData take(int n) {
    if (n < 0 || pos + n > bytes.length)
      throw const FormatException('Truncated XDF chunk');
    final result = ByteData.sublistView(bytes, pos, pos + n);
    pos += n;
    return result;
  }

  int u8() => take(1).getUint8(0);
  int variable() => switch (u8()) {
    1 => u8(),
    4 => take(4).getUint32(0, Endian.little),
    8 => take(8).getUint64(0, Endian.little),
    _ => throw const FormatException('Invalid XDF variable integer'),
  };
  String string(int n) {
    final data = take(n);
    return utf8.decode(data.buffer.asUint8List(data.offsetInBytes, n));
  }

  double number(String format) => switch (format) {
    'float32' => take(4).getFloat32(0, Endian.little),
    'double64' => take(8).getFloat64(0, Endian.little),
    'int8' => take(1).getInt8(0).toDouble(),
    'int16' => take(2).getInt16(0, Endian.little).toDouble(),
    'int32' => take(4).getInt32(0, Endian.little).toDouble(),
    'int64' => take(8).getInt64(0, Endian.little).toDouble(),
    _ => throw FormatException('Unsupported XDF channel format: $format'),
  };
}

/// Chunked XDF 1.0 import. Refuse clock resets/data gaps rather than silently
/// compressing time and moving ERP events. No Python dependency is required.
class XdfLoader {
  Future<Map<int, _Stream>> _read(
    String path, {
    bool headersOnly = false,
    int? streamId,
    bool Function()? isCancelled,
    void Function(double)? onProgress,
  }) async {
    final file = File(path).openSync();
    final streams = <int, _Stream>{};
    try {
      final length = file.lengthSync();
      if (ascii.decode(file.readSync(4)) != 'XDF:')
        throw const FormatException('Not an XDF file');
      while (file.positionSync() < length) {
        await _checkpoint(isCancelled);
        final size = file.readByteSync();
        if (![1, 4, 8].contains(size))
          throw const FormatException('Invalid XDF chunk length');
        final raw = file.readSync(size);
        if (raw.length != size)
          throw const FormatException('Truncated XDF chunk length');
        final data = ByteData.sublistView(raw);
        final n = size == 1
            ? data.getUint8(0)
            : size == 4
            ? data.getUint32(0, Endian.little)
            : data.getUint64(0, Endian.little);
        final start = file.positionSync();
        if (n < 2 || start + n > length)
          throw const FormatException('Truncated XDF chunk');
        final tagBytes = file.readSync(2);
        final tag = ByteData.sublistView(tagBytes).getUint16(0, Endian.little);
        if (tag == 2) {
          final reader = _Reader(file.readSync(n - 2));
          final id = reader.take(4).getUint32(0, Endian.little);
          final stream = _Stream(id, XmlDocument.parse(reader.string(n - 6)));
          if (streams.containsKey(id))
            throw const FormatException('Duplicate XDF stream ID');
          if (stream.count <= 0 ||
              stream.count > 100000 ||
              !stream.rate.isFinite ||
              stream.rate < 0) {
            throw const FormatException('Invalid XDF stream dimensions');
          }
          streams[id] = stream;
        } else if (!headersOnly && (tag == 3 || tag == 4)) {
          final reader = _Reader(file.readSync(n - 2));
          final id = reader.take(4).getUint32(0, Endian.little);
          final stream = streams[id];
          if (stream == null)
            throw const FormatException(
              'XDF sample precedes its stream header',
            );
          final include =
              streamId == null ||
              id == streamId ||
              stream.format == 'string' ||
              stream.rate == 0;
          if (include && tag == 4) {
            stream.clocks.add((
              reader.number('double64'),
              reader.number('double64'),
            ));
          } else if (include) {
            final count = reader.variable();
            if (count > n)
              throw const FormatException('Invalid XDF sample count');
            for (var i = 0; i < count; i++) {
              if (i % 2048 == 0) await _checkpoint(isCancelled);
              final flag = reader.u8();
              final time = flag == 8
                  ? reader.number('double64')
                  : flag == 0
                  ? stream.last + (stream.rate > 0 ? 1 / stream.rate : 0)
                  : throw const FormatException('Invalid XDF timestamp flag');
              if (!time.isFinite)
                throw const FormatException('Non-finite XDF timestamp');
              stream.last = time;
              if (stream.format == 'string') {
                final labels = [
                  for (var c = 0; c < stream.count; c++)
                    reader.string(reader.variable()),
                ];
                stream.events.add((time, labels.join(' | ')));
              } else {
                final values = [
                  for (var c = 0; c < stream.count; c++)
                    reader.number(stream.format),
                ];
                if (stream.rate == 0) {
                  stream.events.add((
                    time,
                    values.map((v) => v.toString()).join(' | '),
                  ));
                } else {
                  stream.times.add(time);
                  stream.values.add(values);
                }
              }
            }
          }
        }
        file.setPositionSync(start + n);
        onProgress?.call(file.positionSync() / length);
      }
      return streams;
    } finally {
      file.closeSync();
    }
  }

  Future<List<XdfStreamInfo>> inspect(String path) async =>
      (await _read(path, headersOnly: true)).values
          .where((s) => s.rate > 0 && s.format != 'string')
          .map((s) => s.info)
          .toList();

  Future<EegRecording> load(
    String path, {
    int? streamId,
    void Function(double)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final streams = await _read(
      path,
      streamId: streamId,
      isCancelled: isCancelled,
      onProgress: (p) => onProgress?.call(p * .75),
    );
    var candidates = streams.values
        .where((s) => s.rate > 0 && s.format != 'string')
        .toList();
    if (streamId != null)
      candidates = candidates.where((s) => s.id == streamId).toList();
    if (candidates.length != 1) {
      final eeg = candidates
          .where((s) => s.field('type').toLowerCase() == 'eeg')
          .toList();
      if (eeg.length == 1) {
        candidates = eeg;
      } else {
        throw const FormatException(
          'Select one numeric XDF stream before loading.',
        );
      }
    }
    final stream = candidates.single;
    if (stream.times.length < 2)
      throw const FormatException('XDF stream has fewer than two samples');
    for (final s in streams.values) {
      for (var i = 1; i < s.clocks.length; i++) {
        if (s.clocks[i].$1 <= s.clocks[i - 1].$1 ||
            (s.clocks[i].$2 - s.clocks[i - 1].$2).abs() > .5) {
          throw const FormatException(
            'XDF contains a clock reset. Repair/split it with pyxdf before ERP analysis.',
          );
        }
      }
    }
    final times = stream.times.map(stream.corrected).toList();
    final rate = (times.length - 1) / (times.last - times.first);
    if (!rate.isFinite || rate <= 0)
      throw const FormatException('Invalid XDF time axis');
    for (var i = 1; i < times.length; i++) {
      if (times[i] <= times[i - 1] ||
          times[i] - times[i - 1] > 5 / stream.rate) {
        throw const FormatException(
          'XDF has non-monotonic timestamps or a data gap; split/repair the stream before analysis.',
        );
      }
    }
    final channelXml =
        stream.xml
            .findAllElements('channels')
            .firstOrNull
            ?.findElements('channel')
            .toList() ??
        [];
    final labels = [
      for (var c = 0; c < stream.count; c++)
        c < channelXml.length
            ? channelXml[c].getElement('label')?.innerText.trim() ??
                  'Ch${c + 1}'
            : 'Ch${c + 1}',
    ];
    final scales = [
      for (var c = 0; c < stream.count; c++)
        _unitScale(
          c < channelXml.length
              ? channelXml[c].getElement('unit')?.innerText ?? ''
              : '',
        ),
    ];
    final channels = [
      for (var c = 0; c < stream.count; c++) Float32List(times.length),
    ];
    var left = 0;
    for (var i = 0; i < times.length; i++) {
      if (i % 2048 == 0) await _checkpoint(isCancelled);
      if (i % 2048 == 0) onProgress?.call(.75 + .25 * i / times.length);
      final t = times.first + i / rate;
      while (left + 1 < times.length - 1 && times[left + 1] < t) {
        left++;
      }
      final f = ((t - times[left]) / (times[left + 1] - times[left])).clamp(
        0.0,
        1.0,
      );
      for (var c = 0; c < stream.count; c++) {
        channels[c][i] =
            (stream.values[left][c] * (1 - f) +
                stream.values[left + 1][c] * f) *
            scales[c];
      }
    }
    final markers = <EegMarker>[];
    for (final s in streams.values) {
      for (final event in s.events) {
        final t = s.corrected(event.$1) - times.first;
        if (t >= 0 && t <= times.last - times.first) {
          markers.add(
            EegMarker(
              type: s.field('name'),
              description: event.$2,
              startSeconds: t,
            ),
          );
        }
      }
    }
    markers.sort((a, b) => a.startSeconds.compareTo(b.startSeconds));
    onProgress?.call(1);
    if (channels.any((channel) => channel.any((v) => !v.isFinite))) {
      throw const FormatException(
        'XDF contains non-finite signal samples. Repair the signal before import.',
      );
    }
    return EegRecording(
      path: path,
      sampleRate: rate,
      labels: labels,
      preview: channels,
      sampleCount: times.length,
      format: 'xdf',
      markers: markers,
      provenance: {
        'xdf_stream_id': stream.id,
        'xdf_stream_name': stream.field('name'),
        'xdf_nominal_rate': stream.rate,
        'xdf_uniform_resampling': true,
        'xdf_units': 'microvolts; unspecified channel units assumed microvolts',
      },
    );
  }

  double _unitScale(String unit) => switch (unit
      .trim()
      .toLowerCase()
      .replaceAll('µ', 'u')
      .replaceAll('μ', 'u')) {
    'v' || 'volt' || 'volts' => 1e6,
    'mv' || 'millivolt' || 'millivolts' => 1e3,
    'nv' || 'nanovolt' || 'nanovolts' => 1e-3,
    _ => 1,
  };
}

Future<void> _checkpoint(bool Function()? isCancelled) async {
  await Future<void>.delayed(Duration.zero);
  if (isCancelled?.call() ?? false) throw StateError('File loading cancelled');
}

Future<List<XdfStreamInfo>> inspectXdfInWorker(String path) =>
    Isolate.run(() => XdfLoader().inspect(path));
