// lib/src/erp/ccseeg_reader.dart
//
// Fast reader for (epoched) ccseeg-v1 JSON files. The large "channels" array
// is parsed straight into Float64 buffers, so a 100 MB file is not turned into
// ten million boxed JSON numbers. Every other key goes through jsonDecode.
// Values are parsed with double.parse, which gives the same float64 values
// as Python's json module.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class CcsEegData {
  CcsEegData({
    required this.path,
    required this.sampleRate,
    required this.labels,
    required this.channels,
    required this.meta,
  });

  final String path;
  final double sampleRate;
  final List<String> labels;

  /// One flat buffer per channel (all epochs concatenated).
  final List<Float64List> channels;

  /// All other top-level keys (source_epoch_samples, epoch_labels,
  /// epoch_tmin, epoch_tmax, markers, ...).
  final Map<String, dynamic> meta;

  int? get sourceEpochSamples =>
      (meta['source_epoch_samples'] as num?)?.toInt();
  List<String>? get epochLabels =>
      (meta['epoch_labels'] as List?)?.map((e) => e.toString()).toList();
  double? get epochTmin => (meta['epoch_tmin'] as num?)?.toDouble();
  double? get epochTmax => (meta['epoch_tmax'] as num?)?.toDouble();

  String get fileLabel {
    final base = path.split(RegExp(r'[\\/]')).last;
    return base
        .replaceAll('.ccseeg.json', '')
        .replaceAll(RegExp(r'\.json$'), '');
  }

  static CcsEegData read(
    String path, {
    bool Function(String label)? keepChannel,
  }) {
    final bytes = File(path).readAsBytesSync();
    return parse(bytes, path, keepChannel: keepChannel);
  }

  static CcsEegData parse(
    Uint8List b,
    String path, {
    bool Function(String label)? keepChannel,
  }) {
    final p = _Parser(b);
    final meta = <String, dynamic>{};
    List<Float64List>? channels;
    p.ws();
    p.expect(0x7B); // {
    // First pass: collect everything except "channels" (whose byte range is
    // remembered) so labels are known before the channel filter is applied.
    int? chStart, chEnd;
    while (true) {
      p.ws();
      if (p.peek == 0x7D) {
        p.i++;
        break;
      }
      final key = p.string();
      p.ws();
      p.expect(0x3A); // :
      p.ws();
      final start = p.i;
      p.skipValue();
      if (key == 'channels') {
        chStart = start;
        chEnd = p.i;
      } else {
        meta[key] = jsonDecode(
          utf8.decode(Uint8List.sublistView(b, start, p.i)),
        );
      }
      p.ws();
      if (p.peek == 0x2C) {
        p.i++;
      }
    }
    if (meta['format'] != null && meta['format'] != 'ccseeg-v1') {
      throw const FormatException('Unsupported portable EEG file.');
    }
    final labels = [
      for (final l in (meta['labels'] as List? ?? const [])) l.toString(),
    ];
    if (chStart != null) {
      p.i = chStart;
      channels = p.channelArrays(labels, keepChannel);
      assert(p.i <= chEnd!);
    }
    return CcsEegData(
      path: path,
      sampleRate: (meta['sample_rate'] as num?)?.toDouble() ?? 0,
      labels: labels,
      channels: channels ?? const [],
      meta: meta,
    );
  }
}

class _Parser {
  _Parser(this.b);
  final Uint8List b;
  int i = 0;

  int get peek => i < b.length ? b[i] : -1;

  void ws() {
    while (i < b.length) {
      final c = b[i];
      if (c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09) {
        i++;
      } else {
        break;
      }
    }
  }

  void expect(int c) {
    if (peek != c) {
      throw FormatException('Expected ${String.fromCharCode(c)} at byte $i');
    }
    i++;
  }

  String string() {
    final start = i;
    _skipString();
    return jsonDecode(utf8.decode(Uint8List.sublistView(b, start, i)))
        as String;
  }

  void _skipString() {
    expect(0x22);
    while (i < b.length) {
      final c = b[i++];
      if (c == 0x5C) {
        i++;
      } else if (c == 0x22) {
        return;
      }
    }
    throw const FormatException('Unterminated string');
  }

  void skipValue() {
    final c = peek;
    if (c == 0x22) {
      _skipString();
      return;
    }
    if (c == 0x7B || c == 0x5B) {
      var depth = 0;
      while (i < b.length) {
        final d = b[i];
        if (d == 0x22) {
          _skipString();
          continue;
        }
        if (d == 0x7B || d == 0x5B) depth++;
        if (d == 0x7D || d == 0x5D) {
          depth--;
          if (depth == 0) {
            i++;
            return;
          }
        }
        i++;
      }
      throw const FormatException('Unterminated container');
    }
    // number / literal
    while (i < b.length) {
      final d = b[i];
      if (d == 0x2C ||
          d == 0x7D ||
          d == 0x5D ||
          d == 0x20 ||
          d == 0x0A ||
          d == 0x0D ||
          d == 0x09) {
        return;
      }
      i++;
    }
  }

  List<Float64List> channelArrays(
    List<String> labels,
    bool Function(String)? keep,
  ) {
    final out = <Float64List>[];
    expect(0x5B);
    var ch = 0;
    while (true) {
      ws();
      if (peek == 0x5D) {
        i++;
        break;
      }
      final label = ch < labels.length ? labels[ch] : 'Ch${ch + 1}';
      if (keep != null && !keep(label)) {
        skipValue();
        out.add(Float64List(0));
      } else {
        out.add(_numberArray());
      }
      ch++;
      ws();
      if (peek == 0x2C) i++;
    }
    return out;
  }

  Float64List _numberArray() {
    expect(0x5B);
    var buf = Float64List(1 << 16);
    var n = 0;
    final sb = StringBuffer();
    while (true) {
      ws();
      final c = peek;
      if (c == 0x5D) {
        i++;
        break;
      }
      if (c == 0x2C) {
        i++;
        continue;
      }
      final start = i;
      while (i < b.length) {
        final d = b[i];
        if (d == 0x2C ||
            d == 0x5D ||
            d == 0x20 ||
            d == 0x0A ||
            d == 0x0D ||
            d == 0x09)
          break;
        i++;
      }
      final tok = String.fromCharCodes(b, start, i);
      double v;
      if (tok == 'null' || tok == 'NaN') {
        v = double.nan;
      } else {
        v = double.parse(tok);
      }
      if (n == buf.length) {
        final nb = Float64List(buf.length * 2);
        nb.setRange(0, n, buf);
        buf = nb;
      }
      buf[n++] = v;
    }
    sb.clear();
    return Float64List.fromList(Float64List.sublistView(buf, 0, n));
  }
}
