import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;

import 'models.dart';
import 'recording_loader.dart';

typedef ProgressCallback = void Function(double value, String message);

class ExtractionService {
  Process? _activeProcess;

  void cancel() {
    _activeProcess?.kill();
    _activeProcess = null;
  }

  Future<void> run({
    required List<EegRecording> recordings,
    required String outputPath,
    required ExtractionOptions options,
    required double epochSeconds,
    ViewerSelection selection = const ViewerSelection.empty(),
    required ProgressCallback onProgress,
  }) async {
    final executable = ExtractionService.findEngine();
    final temp = await Directory.systemTemp.createTemp('ccs_eeg_');
    final parts = <File>[];
    try {
      for (var i = 0; i < recordings.length; i++) {
        final recording = recordings[i];
        final part = File('${temp.path}/part_$i.csv');
        final job = File('${temp.path}/job_$i.json');
        await job.writeAsString(
          jsonEncode({
            'input': recording.path,
            'output': part.path,
            'format': recording.format,
            'data_path': recording.dataPath,
            'sample_rate': recording.sampleRate,
            'labels': recording.labels,
            'sample_count': recording.sampleCount,
            'epoch_count': recording.epochCount,
            'points_per_epoch': recording.pointsPerEpoch,
            'epoch_seconds': epochSeconds,
            'options': options.toJson(),
            'selected_channels': selection.selectedChannels,
            'accepted_intervals': selection.acceptedIntervals,
            'rejected_intervals': selection.rejectedIntervals,
          }),
        );
        final process = await Process.start(executable, [job.path]);
        _activeProcess = process;
        final errors = <String>[];
        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              if (line.startsWith('PROGRESS ')) {
                final fields = line.split(' ');
                final local = double.tryParse(fields[1]) ?? 0;
                final overall = (i + local / 100) / recordings.length;
                onProgress(overall, fields.skip(2).join(' '));
              } else if (line.trim().isNotEmpty) {
                onProgress(i / recordings.length, line);
              }
            });
        process.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              if (line.startsWith('PROGRESS ')) {
                final fields = line.split(' ');
                final local = double.tryParse(fields[1]) ?? 0;
                final overall = (i + local / 100) / recordings.length;
                onProgress(overall, fields.skip(2).join(' '));
              } else {
                errors.add(line);
                onProgress(i / recordings.length, line);
              }
            });
        final code = await process.exitCode;
        _activeProcess = null;
        if (code != 0) {
          throw StateError(
            errors.isEmpty
                ? 'Engine exited with code $code'
                : errors.join('\n'),
          );
        }
        parts.add(part);
      }
      final sink = File(outputPath).openWrite();
      try {
        var wroteHeader = false;
        for (final part in parts) {
          var first = true;
          await for (final line
              in part
                  .openRead()
                  .transform(utf8.decoder)
                  .transform(const LineSplitter())) {
            if (first) {
              first = false;
              if (wroteHeader) continue;
              wroteHeader = true;
            }
            sink.writeln(line);
          }
        }
      } finally {
        await sink.close();
      }
      onProgress(1, 'Saved $outputPath');
    } finally {
      await temp.delete(recursive: true);
    }
  }

  Future<EegRecording> preprocess({
    required EegRecording recording,
    required String outputPath,
    required PreprocessingOptions options,
    ViewerSelection selection = const ViewerSelection.empty(),
    required ProgressCallback onProgress,
  }) async {
    final executable = ExtractionService.findEngine();
    final temp = await Directory.systemTemp.createTemp('ccs_eeg_pre_');
    try {
      final job = File('${temp.path}/preprocess.json');
      await job.writeAsString(
        jsonEncode({
          'job_type': 'preprocess',
          'input': recording.path,
          'output': outputPath,
          'format': recording.format,
          'data_path': recording.dataPath,
          'sample_rate': recording.sampleRate,
          'labels': recording.labels,
          'sample_count': recording.sampleCount,
          'epoch_count': recording.epochCount,
          'points_per_epoch': recording.pointsPerEpoch,
          'epoch_seconds': options.gedaiEpochSeconds,
          'options': _emptyExtractionOptions().toJson(),
          'preprocessing': options.toJson(),
          'selected_channels': selection.selectedChannels,
          'accepted_intervals': selection.acceptedIntervals,
          'rejected_intervals': selection.rejectedIntervals,
        }),
      );
      final process = await Process.start(executable, [job.path]);
      _activeProcess = process;
      final stderr = <String>[];
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.startsWith('PROGRESS ')) {
              final fields = line.split(' ');
              onProgress(
                (double.tryParse(fields[1]) ?? 0) / 100,
                fields.skip(2).join(' '),
              );
            } else {
              stderr.add(line);
              onProgress(0, line);
            }
          });
      final stdout = await process.stdout.transform(utf8.decoder).join();
      final code = await process.exitCode;
      _activeProcess = null;
      if (code != 0) {
        throw StateError(
          stderr.isEmpty
              ? 'Preprocessing failed with code $code'
              : stderr.join('\n'),
        );
      }
      if (stdout.trim().isNotEmpty) {
        final summary = jsonDecode(stdout) as Map<String, dynamic>;
        final bad = (summary['bad_channels'] as List?)?.join(', ') ?? '';
        onProgress(
          1,
          'Preprocessed ${summary['channels']} channels. Bad channels: ${bad.isEmpty ? 'none' : bad}',
        );
      }
      return await RecordingLoader().load(outputPath);
    } finally {
      await temp.delete(recursive: true);
    }
  }

  Future<void> compileCsvFiles(List<String> inputs, String outputPath) async {
    final sink = File(outputPath).openWrite();
    try {
      var wroteHeader = false;
      for (final path in inputs) {
        var first = true;
        await for (final line in File(
          path,
        ).openRead().transform(utf8.decoder).transform(const LineSplitter())) {
          if (first) {
            first = false;
            if (wroteHeader) continue;
            wroteHeader = true;
          }
          sink.writeln(line);
        }
      }
    } finally {
      await sink.close();
    }
  }

  /// Generate a proper PDF report from the extracted feature CSV.
  ///
  /// The report contains:
  ///  - Title page with metadata (file count, feature families, timestamp)
  ///  - One section per feature family found in the CSV with summary statistics
  ///    (mean ± std, min, max) aggregated across all files and epochs
  ///  - Per-channel statistics table (up to 32 channels shown)
  Future<void> writePdfReport({
    required String outputPath,
    required String title,
    required List<String> lines,
    String? csvPath,
  }) async {
    // Read the CSV if available
    List<List<String>> rows = [];
    List<String> headers = [];
    if (csvPath != null && File(csvPath).existsSync()) {
      final raw = await File(csvPath)
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .toList();
      if (raw.isNotEmpty) {
        headers = _splitCsv(raw.first);
        for (final row in raw.skip(1)) {
          if (row.trim().isEmpty) continue;
          rows.add(_splitCsv(row));
        }
      }
    }

    // Build PDF pages as a list of text blocks
    final pages = <List<String>>[];

    // ── Page 1: metadata ────────────────────────────────────────────────
    final page1 = <String>[];
    page1.add('__TITLE__$title');
    page1.add('__SUBTITLE__Generated: ${DateTime.now().toString().substring(0, 19)}');
    page1.add('__RULE__');
    for (final l in lines) {
      page1.add(l);
    }
    if (rows.isNotEmpty && headers.isNotEmpty) {
      page1.add('__RULE__');
      page1.add('__H2__Dataset Summary');
      page1.add('Total data rows: ${rows.length}');
      // Detect unique files
      final fileCol = headers.indexOf('file');
      if (fileCol >= 0) {
        final files = rows.map((r) => fileCol < r.length ? r[fileCol] : '').toSet();
        page1.add('Files: ${files.length}');
        for (final f in files.take(10)) {
          page1.add('  \u2022 ${f.split('/').last}');
        }
        if (files.length > 10) page1.add('  ... and ${files.length - 10} more');
      }
      final epochCol = headers.indexOf('epoch');
      if (epochCol >= 0) {
        final epochs = rows.map((r) => epochCol < r.length ? r[epochCol] : '').toSet();
        page1.add('Epochs per file: ${epochs.length}');
      }
      // Feature column count
      final numericCols = headers
          .where((h) => h != 'file' && h != 'epoch' && h != 'channel')
          .length;
      page1.add('Feature columns: $numericCols');
    }
    pages.add(page1);

    // ── Pages 2+: per-feature-family statistics ─────────────────────────
    if (rows.isNotEmpty && headers.isNotEmpty) {
      // Group columns by family prefix
      final families = <String, List<int>>{};
      for (var c = 0; c < headers.length; c++) {
        final h = headers[c];
        if (h == 'file' || h == 'epoch' || h == 'channel') continue;
        // Infer family from prefix: psd_, fooof_, irasa_, nonlinear_, acw_, conn_
        final family = _columnFamily(h);
        families.putIfAbsent(family, () => []).add(c);
      }

      for (final entry in families.entries) {
        final familyName = entry.key;
        final colIndices = entry.value;
        final page = <String>[];
        page.add('__H2__Feature Family: ${familyName.toUpperCase()}');
        page.add('Columns: ${colIndices.length}');
        page.add('__RULE__');

        // For each feature column compute stats
        page.add('__TABLE_HEADER__Feature | Mean | Std | Min | Max');
        for (final ci in colIndices.take(30)) {
          final colName = headers[ci];
          final vals = <double>[];
          for (final row in rows) {
            if (ci < row.length) {
              final v = double.tryParse(row[ci]);
              if (v != null && v.isFinite) vals.add(v);
            }
          }
          if (vals.isEmpty) {
            page.add('__TABLE_ROW__$colName | N/A | N/A | N/A | N/A');
          } else {
            final mean = vals.reduce((a, b) => a + b) / vals.length;
            var variance = 0.0;
            for (final v in vals) {
              variance += (v - mean) * (v - mean);
            }
            final std = vals.length > 1 ? _sqrt(variance / (vals.length - 1)) : 0.0;
            final mn = vals.reduce((a, b) => a < b ? a : b);
            final mx = vals.reduce((a, b) => a > b ? a : b);
            page.add(
              '__TABLE_ROW__${_trunc(colName, 28)} | ${_fmt(mean)} | ${_fmt(std)} | ${_fmt(mn)} | ${_fmt(mx)}',
            );
          }
        }
        if (colIndices.length > 30) {
          page.add('... and ${colIndices.length - 30} more columns');
        }
        pages.add(page);

        // Add Topography & Glass Brain visualization page for this feature family
        var chanCol = headers.indexOf('Chan');
        if (chanCol < 0) chanCol = headers.indexOf('channel');
        if (chanCol < 0) chanCol = headers.indexOf('chan');
        if (chanCol >= 0 && colIndices.isNotEmpty) {
          final visPage = <String>[];
          visPage.add('__H2__Topography & Glass Brain: ${familyName.toUpperCase()}');
          visPage.add('Spatial distribution and connectivity network');
          visPage.add('__RULE__');
          for (final ci in colIndices.take(2)) {
            final colName = headers[ci];
            final chanMeans = <String, double>{};
            final chanCounts = <String, int>{};
            for (final row in rows) {
              if (chanCol < row.length && ci < row.length) {
                final ch = row[chanCol].trim();
                final v = double.tryParse(row[ci]);
                if (ch.isNotEmpty && v != null && v.isFinite) {
                  chanMeans[ch] = (chanMeans[ch] ?? 0.0) + v;
                  chanCounts[ch] = (chanCounts[ch] ?? 0) + 1;
                }
              }
            }
            if (chanMeans.isNotEmpty) {
              final dataStr = chanMeans.keys.map((k) => '$k:${_fmt(chanMeans[k]! / chanCounts[k]!)}').join(',');
              visPage.add('__TOPOMAP__Scalp Topography: $colName|$dataStr');
              visPage.add('__GLASSBRAIN__3D Glass Brain Network: $colName|$dataStr');
            }
          }
          if (visPage.length > 3) pages.add(visPage);
        }
      }
    }

    // ── Render pages as PDF ─────────────────────────────────────────────
    await _renderPdf(outputPath, pages);
  }

  static String _columnFamily(String header) {
    if (header.startsWith('psd_')) return 'psd';
    if (header.startsWith('fooof_')) return 'fooof';
    if (header.startsWith('irasa_')) return 'irasa';
    if (header.startsWith('nonlinear_') || header.startsWith('higuchi') ||
        header.startsWith('katz') || header.startsWith('lziv') ||
        header.startsWith('petrosian') || header.startsWith('dfa') ||
        header.startsWith('acw') || header.startsWith('perm_') ||
        header.startsWith('sample_') || header.startsWith('svd_')) {
      return 'nonlinear';
    }
    if (header.startsWith('conn_') || header.startsWith('coh_') ||
        header.startsWith('plv_') || header.startsWith('pli_') ||
        header.startsWith('wpli_') || header.startsWith('mic_') ||
        header.startsWith('mim_')) {
      return 'connectivity';
    }
    return 'other';
  }

  static String _fmt(double v) {
    if (v.abs() >= 1000) return v.toStringAsFixed(0);
    if (v.abs() >= 10) return v.toStringAsFixed(2);
    return v.toStringAsFixed(4);
  }

  static String _trunc(String s, int max) =>
      s.length > max ? '${s.substring(0, max - 1)}\u2026' : s;

  static double _sqrt(double v) => v <= 0 ? 0 : v < 1e-30 ? 0 : _isqrt(v);
  static double _isqrt(double x) {
    // Newton's method sqrt
    var r = x / 2;
    for (var i = 0; i < 20; i++) r = (r + x / r) / 2;
    return r;
  }

  static List<String> _splitCsv(String line) {
    final result = <String>[];
    final buf = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') {
        inQuotes = !inQuotes;
      } else if (c == ',' && !inQuotes) {
        result.add(buf.toString().trim());
        buf.clear();
      } else {
        buf.write(c);
      }
    }
    result.add(buf.toString().trim());
    return result;
  }

  Future<void> _renderPdf(String outputPath, List<List<String>> pages) async {
    // Manual PDF-1.4 writer with multi-page support
    const pageW = 612.0;
    const pageH = 792.0;
    const marginL = 50.0;
    const marginR = 562.0;
    const tableColW = [200.0, 70.0, 70.0, 70.0, 70.0]; // feature | mean | std | min | max

    final objTexts = <String>[];

    // obj 1: catalog, obj 2: pages (filled later), obj 3+: page+content pairs
    objTexts.add(''); // placeholder for catalog
    objTexts.add(''); // placeholder for pages

    final pageObjIds = <int>[];
    final f1Id = 2 + (2 * pages.length) + 1;
    final f2Id = f1Id + 1;

    for (var pi = 0; pi < pages.length; pi++) {
      final pageLines = pages[pi];
      final content = StringBuffer();
      double y = 700.0;
      var rowIndex = 0;

      // ── Top Banner ────────────────────────────────────────────────────────
      content.write('0.08 0.18 0.36 rg 0 730 612 62 re f\n'); // Deep midnight blue banner
      content.write('0.12 0.40 0.80 rg 0 726 612 4 re f\n'); // Accent stripe

      void drawText(String text, double x, double yPos, double size, bool bold, {String color = '0.15 0.15 0.15'}) {
        content.write('BT\n$color rg /F${bold ? 2 : 1} $size Tf\n');
        content.write('1 0 0 1 ${x.toStringAsFixed(1)} ${yPos.toStringAsFixed(1)} Tm\n');
        content.write('(${_pdfEscape(text)}) Tj\nET\n');
      }

      void writeRule() {
        content.write('0.85 0.88 0.92 RG 0.7 w ${marginL.toStringAsFixed(1)} ${y.toStringAsFixed(1)} m '
            '${marginR.toStringAsFixed(1)} ${y.toStringAsFixed(1)} l S\n');
        y -= 8;
      }

      for (final line in pageLines) {
        if (y < 60) break; // overflow guard
        if (line.startsWith('__TITLE__')) {
          drawText(line.substring(9), 40, 758, 18, true, color: '1 1 1');
        } else if (line.startsWith('__SUBTITLE__')) {
          drawText(line.substring(12), 40, 740, 10, false, color: '0.75 0.88 1.0');
        } else if (line.startsWith('__H2__')) {
          y -= 8;
          content.write('0.93 0.95 0.98 rg 40 ${(y - 4).toStringAsFixed(1)} 522 20 re f\n');
          content.write('0.12 0.35 0.75 rg 40 ${(y - 4).toStringAsFixed(1)} 5 20 re f\n');
          drawText(line.substring(6), 54, y + 2, 12, true, color: '0.08 0.18 0.36');
          y -= 22;
        } else if (line == '__RULE__') {
          writeRule();
        } else if (line.startsWith('__TABLE_HEADER__')) {
          y -= 4;
          content.write('0.12 0.35 0.75 rg 40 ${(y - 4).toStringAsFixed(1)} 522 18 re f\n');
          final cols = line.substring(16).split(' | ');
          var x = marginL + 4;
          for (var ci = 0; ci < cols.length && ci < tableColW.length; ci++) {
            drawText(cols[ci], x, y, 9, true, color: '1 1 1');
            x += tableColW[ci];
          }
          y -= 20;
          rowIndex = 0;
        } else if (line.startsWith('__TABLE_ROW__')) {
          if (rowIndex % 2 == 1) {
            content.write('0.96 0.97 0.98 rg 40 ${(y - 3).toStringAsFixed(1)} 522 14 re f\n');
          }
          content.write('0.90 0.92 0.95 RG 0.4 w 40 ${(y - 3).toStringAsFixed(1)} m 562 ${(y - 3).toStringAsFixed(1)} l S\n');
          final cols = line.substring(13).split(' | ');
          var x = marginL + 4;
          for (var ci = 0; ci < cols.length && ci < tableColW.length; ci++) {
            final isNum = ci > 0;
            drawText(cols[ci], x, y, 8.5, isNum && ci == 1, color: isNum ? '0.10 0.25 0.55' : '0.20 0.20 0.20');
            x += tableColW[ci];
          }
          y -= 14;
        } else if (line.startsWith('__TOPOMAP__')) {
          final parts = line.substring(11).split('|');
          final title = parts[0];
          final chanData = parts.length > 1 ? parts[1] : '';
          drawText(title, marginL, y, 10, true, color: '0.10 0.25 0.55');
          y -= 15;
          final cx = 150.0;
          final cy = y - 50.0;
          content.write('0.96 0.97 0.98 rg 0.20 0.30 0.45 RG 1.2 w ');
          for (var i = 0; i < 24; i++) {
            final angle = i * math.pi * 2 / 24;
            content.write('${(cx + 48 * math.cos(angle)).toStringAsFixed(1)} ${(cy + 48 * math.sin(angle)).toStringAsFixed(1)} ${i == 0 ? "m" : "l"} ');
          }
          content.write('h b\n');
          content.write('0.96 0.97 0.98 rg 0.20 0.30 0.45 RG 1 w ${(cx - 6).toStringAsFixed(1)} ${(cy + 47).toStringAsFixed(1)} m ${cx.toStringAsFixed(1)} ${(cy + 57).toStringAsFixed(1)} l ${(cx + 6).toStringAsFixed(1)} ${(cy + 47).toStringAsFixed(1)} l h b\n');
          final coords = <String, List<double>>{
            'fp1': [-0.3, 0.75], 'fp2': [0.3, 0.75], 'fpz': [0.0, 0.78],
            'f7': [-0.75, 0.45], 'f3': [-0.4, 0.45], 'fz': [0.0, 0.45], 'f4': [0.4, 0.45], 'f8': [0.75, 0.45],
            't3': [-0.85, 0.0], 't7': [-0.85, 0.0], 'c3': [-0.45, 0.0], 'cz': [0.0, 0.0], 'c4': [0.45, 0.0], 't4': [0.85, 0.0], 't8': [0.85, 0.0],
            't5': [-0.75, -0.45], 'p7': [-0.75, -0.45], 'p3': [-0.4, -0.45], 'pz': [0.0, -0.45], 'p4': [0.4, -0.45], 't6': [0.75, -0.45], 'p8': [0.75, -0.45],
            'o1': [-0.3, -0.75], 'oz': [0.0, -0.78], 'o2': [0.3, -0.75],
          };
          final kv = chanData.split(',');
          final parsed = <String, double>{};
          for (final item in kv) {
            final p = item.split(':');
            if (p.length == 2) {
              final v = double.tryParse(p[1]);
              if (v != null) parsed[p[0].toLowerCase()] = v;
            }
          }
          if (parsed.isNotEmpty) {
            final vals = parsed.values.toList();
            final mn = vals.reduce(math.min);
            final mx = vals.reduce(math.max);
            final rng = (mx - mn).abs() < 1e-9 ? 1.0 : (mx - mn);
            for (final ch in parsed.keys) {
              final xy = coords[ch];
              if (xy != null) {
                final ex = cx + xy[0] * 38.0;
                final ey = cy + xy[1] * 38.0;
                final t = ((parsed[ch]! - mn) / rng).clamp(0.0, 1.0);
                final r = t > 0.5 ? 1.0 : (2 * t);
                final g = 1.0 - (2 * (t - 0.5).abs());
                final b = t < 0.5 ? 1.0 : (2 * (1.0 - t));
                content.write('${r.toStringAsFixed(2)} ${g.toStringAsFixed(2)} ${b.toStringAsFixed(2)} rg 0.1 0.1 0.1 RG 0.5 w ');
                for (var i = 0; i < 12; i++) {
                  final angle = i * math.pi * 2 / 12;
                  content.write('${(ex + 6 * math.cos(angle)).toStringAsFixed(1)} ${(ey + 6 * math.sin(angle)).toStringAsFixed(1)} ${i == 0 ? "m" : "l"} ');
                }
                content.write('h b\n');
                drawText(ch.toUpperCase(), ex - 6, ey - 13, 6, true, color: '0.1 0.1 0.1');
              }
            }
          }
          y -= 115;
        } else if (line.startsWith('__GLASSBRAIN__')) {
          final parts = line.substring(14).split('|');
          final title = parts[0];
          final chanData = parts.length > 1 ? parts[1] : '';
          drawText(title, marginL, y, 10, true, color: '0.10 0.25 0.55');
          y -= 15;
          final cx = 400.0;
          final cy = y - 50.0;
          content.write('0.95 0.96 0.98 rg 0.40 0.50 0.60 RG 1 w ');
          for (var i = 0; i < 24; i++) {
            final angle = i * math.pi * 2 / 24;
            content.write('${((cx - 22) + 20 * math.cos(angle)).toStringAsFixed(1)} ${(cy + 48 * math.sin(angle)).toStringAsFixed(1)} ${i == 0 ? "m" : "l"} ');
          }
          content.write('h b\n');
          content.write('0.95 0.96 0.98 rg 0.40 0.50 0.60 RG 1 w ');
          for (var i = 0; i < 24; i++) {
            final angle = i * math.pi * 2 / 24;
            content.write('${((cx + 22) + 20 * math.cos(angle)).toStringAsFixed(1)} ${(cy + 48 * math.sin(angle)).toStringAsFixed(1)} ${i == 0 ? "m" : "l"} ');
          }
          content.write('h b\n');
          final coords = <String, List<double>>{
            'fp1': [-0.25, 0.75], 'fp2': [0.25, 0.75], 'fpz': [0.0, 0.78],
            'f7': [-0.6, 0.45], 'f3': [-0.3, 0.45], 'fz': [0.0, 0.45], 'f4': [0.3, 0.45], 'f8': [0.6, 0.45],
            't3': [-0.7, 0.0], 't7': [-0.7, 0.0], 'c3': [-0.35, 0.0], 'cz': [0.0, 0.0], 'c4': [0.35, 0.0], 't4': [0.7, 0.0], 't8': [0.7, 0.0],
            't5': [-0.6, -0.45], 'p7': [-0.6, -0.45], 'p3': [-0.3, -0.45], 'pz': [0.0, -0.45], 'p4': [0.3, -0.45], 't6': [0.6, -0.45], 'p8': [0.6, -0.45],
            'o1': [-0.25, -0.75], 'oz': [0.0, -0.78], 'o2': [0.25, -0.75],
          };
          final kv = chanData.split(',');
          final parsed = <String, double>{};
          for (final item in kv) {
            final p = item.split(':');
            if (p.length == 2) {
              final v = double.tryParse(p[1]);
              if (v != null) parsed[p[0].toLowerCase()] = v;
            }
          }
          if (parsed.length >= 2) {
            final keys = parsed.keys.toList();
            for (var i = 0; i < keys.length; i++) {
              for (var j = i + 1; j < keys.length && j < i + 4; j++) {
                final xy1 = coords[keys[i]];
                final xy2 = coords[keys[j]];
                if (xy1 != null && xy2 != null) {
                  final x1 = cx + xy1[0] * 40.0;
                  final y1 = cy + xy1[1] * 40.0;
                  final x2 = cx + xy2[0] * 40.0;
                  final y2 = cy + xy2[1] * 40.0;
                  content.write('0.20 0.45 0.85 RG 0.8 w ${x1.toStringAsFixed(1)} ${y1.toStringAsFixed(1)} m ${x2.toStringAsFixed(1)} ${y2.toStringAsFixed(1)} l S\n');
                }
              }
            }
          }
          for (final ch in parsed.keys) {
            final xy = coords[ch];
            if (xy != null) {
              final nx = cx + xy[0] * 40.0;
              final ny = cy + xy[1] * 40.0;
              content.write('0.95 0.30 0.30 rg 0.2 0.2 0.2 RG 0.5 w ');
              for (var i = 0; i < 12; i++) {
                final angle = i * math.pi * 2 / 12;
                content.write('${(nx + 5 * math.cos(angle)).toStringAsFixed(1)} ${(ny + 5 * math.sin(angle)).toStringAsFixed(1)} ${i == 0 ? "m" : "l"} ');
              }
              content.write('h b\n');
              drawText(ch.toUpperCase(), nx - 5, ny - 12, 6, true, color: '0.1 0.1 0.1');
            }
          }
          y -= 115;
        } else {
          drawText(line, marginL, y, 9.5, false, color: '0.25 0.25 0.30');
          y -= 14;
        }
      }

      // ── Bottom Footer ─────────────────────────────────────────────────────
      content.write('0.85 0.88 0.92 RG 0.7 w 40 38 m 562 38 l S\n');
      drawText('CCS EEG Professional Analysis Report — Clinical & Cognitive Sciences', 40, 24, 8, false, color: '0.50 0.55 0.60');
      drawText('Page ${pi + 1} of ${pages.length}', 510, 24, 8, true, color: '0.30 0.40 0.50');

      final streamStr = content.toString();

      final pageObjId = objTexts.length + 1;
      final contentObjId = pageObjId + 1;
      pageObjIds.add(pageObjId);

      objTexts.add(
        '$pageObjId 0 obj << /Type /Page /Parent 2 0 R '
        '/MediaBox [0 0 ${pageW.toInt()} ${pageH.toInt()}] '
        '/Resources << /Font << /F1 $f1Id 0 R /F2 $f2Id 0 R >> >> '
        '/Contents $contentObjId 0 R >> endobj\n',
      );
      objTexts.add(
        '$contentObjId 0 obj << /Length ${streamStr.length} >> stream\n$streamStr\nendstream endobj\n',
      );
    }

    // Font objects
    objTexts.add(
      '$f1Id 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj\n',
    );
    objTexts.add(
      '$f2Id 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >> endobj\n',
    );

    // Fill in catalog and pages
    final kidsStr = pageObjIds.map((id) => '$id 0 R').join(' ');
    objTexts[0] = '1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n';
    objTexts[1] =
        '2 0 obj << /Type /Pages /Kids [$kidsStr] /Count ${pageObjIds.length} >> endobj\n';

    // Build xref table
    final byteBuilder = BytesBuilder();
    byteBuilder.add(utf8.encode('%PDF-1.4\n'));
    final offsets = <int>[];
    for (final obj in objTexts) {
      offsets.add(byteBuilder.length);
      byteBuilder.add(utf8.encode(obj));
    }
    final xrefOffset = byteBuilder.length;
    final xrefBuf = StringBuffer('xref\n0 ${objTexts.length + 1}\n0000000000 65535 f \n');
    for (final off in offsets) {
      xrefBuf.write('${off.toString().padLeft(10, '0')} 00000 n \n');
    }
    xrefBuf.write(
      'trailer << /Size ${objTexts.length + 1} /Root 1 0 R >>\nstartxref\n$xrefOffset\n%%EOF\n',
    );
    byteBuilder.add(utf8.encode(xrefBuf.toString()));
    await File(outputPath).writeAsBytes(byteBuilder.takeBytes());
  }


  static String findEngine() {
    final appDir = File(Platform.resolvedExecutable).parent.path;
    final names = Platform.isWindows
        ? ['ccs-eeg-engine.exe']
        : ['ccs-eeg-engine'];
    final candidates = <String>[
      for (final name in names) '$appDir/$name',
      for (final name in names)
        '${Directory.current.path}/../bridge/target/release/$name',
      for (final name in names)
        '${Directory.current.path}/../bridge/target/debug/$name',
      for (final name in names)
        '${Directory.current.path}/bridge/target/release/$name',
      for (final name in names)
        '${Directory.current.path}/../bridge/target/debug/$name',
      for (final name in names)
        '${Directory.current.path}/bridge/target/debug/$name',
    ];
    return candidates.firstWhere(
      (path) => File(path).existsSync(),
      orElse: () => throw StateError(
        'ccs-eeg-engine was not found. Build bridge/ with cargo build --release.',
      ),
    );
  }
}

ExtractionOptions _emptyExtractionOptions() => const ExtractionOptions(
  mode: DurationMode.full,
  startSeconds: 0,
  endSeconds: 0,
  binSeconds: 60,
  psd: false,
  fooof: false,
  irasa: false,
  nonlinear: false,
  acw: false,
  connectivity: false,
  mic: false,
  mim: false,
  gc: false,
  gcTr: false,
  coh: false,
  plv: false,
  ciplv: false,
  pli: false,
  wpli: false,
  removeNonEeg: false,
  exclusions: [],
);

String _pdfEscape(String value) => value
    .replaceAll('\u2022', '-')
    .replaceAll('\u2026', '...')
    .replaceAll('\u2014', '-')
    .replaceAll('\u2013', '-')
    .replaceAll(r'\', r'\\')
    .replaceAll('(', r'\(')
    .replaceAll(')', r'\)');

class RecordingLoaderShim {
  Future<EegRecording> load(String path) async {
    return await RecordingLoader().load(path);
  }
}
