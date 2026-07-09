import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;

import 'models.dart';
import 'recording_loader.dart';

typedef ProgressCallback = void Function(double value, String message);

// ── ReportContext ─────────────────────────────────────────────────────────────
// Carries all metadata and preview data the PDF report needs.
// Constructed by app.dart immediately after a successful extraction run.
class ReportContext {
  const ReportContext({
    required this.fileName,
    required this.channelCount,
    required this.epochCount,
    required this.durationSeconds,
    required this.sampleRate,
    required this.channelLabels,
    this.rawPreview,
    this.cleanedPreview,
    this.sourceLocalized = false,
    this.sourceRoiLabels = const [],
    this.prepOptions,
    this.extractOptions,
  });

  /// Base name of the source recording (used on the cover page).
  final String fileName;
  final int channelCount;
  final int epochCount;
  final double durationSeconds;
  final double sampleRate;

  /// Channel labels in order — used to label topomap electrodes and signal traces.
  final List<String> channelLabels;

  /// Decimated waveform snapshots. Both are [channels × samples] lists of
  /// Float32List.  rawPreview holds the pre-preprocessing signal; cleanedPreview
  /// holds the post-preprocessing signal.  Either may be null if that data is
  /// not available.
  final List<Float32List>? rawPreview;
  final List<Float32List>? cleanedPreview;

  /// Whether source localisation was performed (controls whether the ROI page
  /// is rendered).
  final bool sourceLocalized;

  /// ROI channel labels from the source-localised recording (e.g.
  /// "lh_caudalanteriorcingulate", "rh_fusiform", …).
  final List<String> sourceRoiLabels;

  final PreprocessingOptions? prepOptions;
  final ExtractionOptions? extractOptions;
}

// ── ExtractionService ─────────────────────────────────────────────────────────

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

  // ── PDF Report ─────────────────────────────────────────────────────────────

  /// Generate a visual multi-page dashboard PDF from the extracted feature CSV.
  ///
  /// Pages produced:
  ///  1. Cover — file metadata, pipeline summary, feature-family pills
  ///  2. Preprocessing signal traces — raw vs cleaned 30-second EEG panel
  ///  3. Scalp topography — MNE-style per-band jet-colourmap topomaps
  ///  4. Source ROI map (only when [ctx.sourceLocalized] is true)
  ///  5+. Per-family statistics tables (zebra-striped, styled)
  Future<void> writePdfReport({
    required String outputPath,
    required String title,
    required List<String> lines,
    String? csvPath,
    ReportContext? ctx,
  }) async {
    // ── Parse CSV ────────────────────────────────────────────────────────────
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

    // ── Compute per-channel mean for each feature column ────────────────────
    // chanCol index and per-band channel→mean maps built once for topomap pages.
    var chanCol = headers.indexWhere((h) => h == 'Chan' || h == 'channel' || h == 'chan');
    // Group columns by family
    final familyCols = <String, List<int>>{};
    for (var c = 0; c < headers.length; c++) {
      final h = headers[c];
      if (h == 'file' || h == 'epoch' || h == 'channel' || h == 'Chan' || h == 'chan' || h == 'bin' || h == 'start' || h == 'end' || h == 'epoch_label') continue;
      familyCols.putIfAbsent(_columnFamily(h), () => []).add(c);
    }

    // ── Determine active feature flags from options or CSV headers ───────────
    final opts = ctx?.extractOptions;
    final hasPsd = opts?.psd ?? familyCols.containsKey('psd');
    final hasIrasa = opts?.irasa ?? familyCols.containsKey('irasa');
    final hasFooof = opts?.fooof ?? familyCols.containsKey('fooof');
    final hasNl = opts?.nonlinear ?? familyCols.containsKey('nonlinear');
    final hasAcw = opts?.acw ?? false;
    final hasConn = (opts != null)
        ? (opts.mic || opts.mim || opts.gc || opts.gcTr || opts.coh || opts.plv || opts.ciplv || opts.pli || opts.wpli)
        : familyCols.containsKey('connectivity');

    // ── Collect pages ────────────────────────────────────────────────────────
    final renderer = _PdfRenderer();

    // Page 1 — Cover / Dashboard
    renderer.addPage(_buildCoverPage(
      title: title,
      ctx: ctx,
      rows: rows,
      headers: headers,
      hasPsd: hasPsd, hasIrasa: hasIrasa, hasFooof: hasFooof,
      hasNl: hasNl, hasAcw: hasAcw, hasConn: hasConn,
      lines: lines,
    ));

    // Page 2 — Preprocessing signal traces (raw → cleaned)
    if (ctx != null && (ctx.rawPreview != null || ctx.cleanedPreview != null)) {
      renderer.addPage(_buildPreprocessingPage(ctx));
    }

    // Page 3 — Scalp topography (only when scalp EEG channel labels are present)
    final spectralFamily = hasPsd ? 'psd' : (hasIrasa ? 'irasa' : null);
    if (spectralFamily != null && chanCol >= 0 && rows.isNotEmpty) {
      final spectralCols = familyCols[spectralFamily] ?? [];
      if (spectralCols.isNotEmpty) {
        renderer.addPage(_buildTopoPage(
          headers: headers,
          rows: rows,
          chanCol: chanCol,
          spectralCols: spectralCols,
          channelLabels: ctx?.channelLabels ?? [],
          family: spectralFamily,
        ));
      }
    }

    // Page 4 — Source ROI map
    if (ctx != null && ctx.sourceLocalized && ctx.sourceRoiLabels.isNotEmpty) {
      renderer.addPage(_buildSourceRoiPage(ctx, headers, rows, chanCol, familyCols));
    }

    // Pages 5+ — Per-family statistics tables
    for (final entry in familyCols.entries) {
      final familyName = entry.key;
      final colIndices = entry.value;
      // Split into pages of ≤40 rows
      const rowsPerPage = 40;
      for (var start = 0; start < colIndices.length; start += rowsPerPage) {
        final chunk = colIndices.sublist(start, math.min(start + rowsPerPage, colIndices.length));
        renderer.addPage(_buildStatsPage(
          familyName: familyName,
          colIndices: chunk,
          headers: headers,
          rows: rows,
          pageNum: start ~/ rowsPerPage,
          totalCols: colIndices.length,
        ));
      }
    }

    // ── Render ───────────────────────────────────────────────────────────────
    await renderer.write(outputPath);
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Page builders
  // ──────────────────────────────────────────────────────────────────────────

  /// Page 1 — Cover dashboard with metadata, pipeline badges, feature pills.
  _PdfPage _buildCoverPage({
    required String title,
    required ReportContext? ctx,
    required List<List<String>> rows,
    required List<String> headers,
    required bool hasPsd,
    required bool hasIrasa,
    required bool hasFooof,
    required bool hasNl,
    required bool hasAcw,
    required bool hasConn,
    required List<String> lines,
  }) {
    final p = _PdfPage();

    // ── Deep navy gradient header (full width, 120 pt tall) ──────────────────
    p.rect(0, 672, 612, 120, fill: _Rgb(0.055, 0.11, 0.25));
    p.rect(0, 668, 612, 4, fill: _Rgb(0.23, 0.51, 0.97));

    p.text('CCS EEG Studio', x: 36, y: 748, size: 20, bold: true, rgb: _Rgb.white);
    p.text('Quantitative EEG Analysis Report', x: 36, y: 726, size: 12, rgb: _Rgb(0.7, 0.82, 1.0));
    final ts = DateTime.now().toLocal().toString().substring(0, 19);
    p.text(ts, x: 36, y: 710, size: 9, rgb: _Rgb(0.55, 0.68, 0.88));
    if (ctx != null) {
      p.text(ctx.fileName, x: 36, y: 693, size: 9, rgb: _Rgb(0.55, 0.68, 0.88));
    }

    // ── Summary card row (four KPI cards) ────────────────────────────────────
    double cy = 640.0;
    final cardDefs = <(String, String)>[
      ('CHANNELS',     '${ctx?.channelCount ?? '—'}'),
      ('EPOCHS',       '${ctx?.epochCount ?? (rows.isNotEmpty ? rows.length : '—')}'),
      ('DURATION',     ctx != null ? '${(ctx.durationSeconds / 60).toStringAsFixed(1)} min' : '—'),
      ('SAMPLE RATE',  ctx != null ? '${ctx.sampleRate.toStringAsFixed(0)} Hz' : '—'),
    ];
    const cardW = 124.0, cardH = 60.0, cardGap = 12.0;
    var cardX = 36.0;
    for (final (label, value) in cardDefs) {
      p.roundRect(cardX, cy - cardH, cardW, cardH, r: 8, fill: _Rgb(0.11, 0.18, 0.36));
      p.rect(cardX, cy - 4, cardW, 4, fill: _Rgb(0.23, 0.51, 0.97));
      p.text(label, x: cardX + 10, y: cy - 20, size: 7.5, rgb: _Rgb(0.55, 0.68, 0.88));
      p.text(value, x: cardX + 10, y: cy - 42, size: 18, bold: true, rgb: _Rgb.white);
      cardX += cardW + cardGap;
    }

    // ── Pipeline stages row ───────────────────────────────────────────────────
    cy -= cardH + 20;
    p.text('PIPELINE STAGES', x: 36, y: cy, size: 8, bold: true, rgb: _Rgb(0.55, 0.68, 0.88));
    cy -= 16;

    final prepOpts = ctx?.prepOptions;
    final badges = <(String, bool)>[
      ('Bandpass Filter',    prepOpts?.filter ?? false),
      ('Notch Filter',       prepOpts?.filter ?? false),
      ('Downsample',         prepOpts?.downsample ?? false),
      ('Bad Ch Detection',   prepOpts?.badchannel ?? false),
      ('GEDAI Denoising',    prepOpts?.gedai ?? false),
      ('Bad Ch Interpolate', prepOpts?.interpolate ?? false),
      ('CAR Reference',      true),
      ('Source Localisation',ctx?.sourceLocalized ?? false),
    ];
    double bx = 36; double by = cy;
    for (final (label, active) in badges) {
      final bw = label.length * 5.8 + 16;
      if (bx + bw > 576) { bx = 36; by -= 22; }
      final fg = active ? _Rgb(0.23, 0.51, 0.97) : _Rgb(0.35, 0.42, 0.52);
      final bg = active ? _Rgb(0.09, 0.18, 0.40) : _Rgb(0.13, 0.18, 0.26);
      p.roundRect(bx, by - 14, bw, 18, r: 9, fill: bg);
      p.roundRectStroke(bx, by - 14, bw, 18, r: 9, stroke: fg, lw: active ? 1.0 : 0.5);
      if (active) p.circle(bx + 8, by - 5, 3, fill: fg);
      p.text(label, x: bx + (active ? 16 : 8), y: by - 9, size: 7.5, bold: active, rgb: fg);
      bx += bw + 8;
    }
    cy = by - 30;

    // ── Feature families ──────────────────────────────────────────────────────
    p.hRule(36, cy, 540, rgb: _Rgb(0.22, 0.30, 0.45));
    cy -= 14;
    p.text('FEATURE FAMILIES COMPUTED', x: 36, y: cy, size: 8, bold: true, rgb: _Rgb(0.55, 0.68, 0.88));
    cy -= 16;

    final featDefs = <(String, bool, _Rgb)>[
      ('Relative PSD (Welch/Hamming)',      hasPsd,  _Rgb(0.23, 0.69, 0.40)),
      ('FOOOF Aperiodic Decomposition',     hasFooof, _Rgb(0.95, 0.60, 0.13)),
      ('IRASA Fractal/Oscillatory PSD',     hasIrasa, _Rgb(0.23, 0.69, 0.40)),
      ('Nonlinear Dynamics (8 metrics)',    hasNl,   _Rgb(0.68, 0.35, 0.97)),
      ('Autocorrelation Window (ACW)',      hasAcw,  _Rgb(0.95, 0.60, 0.13)),
      ('Functional Connectivity (9 measures)', hasConn, _Rgb(0.97, 0.35, 0.35)),
    ];
    for (final (label, active, col) in featDefs) {
      p.circle(44, cy - 3, 4, fill: active ? col : _Rgb(0.25, 0.30, 0.38));
      p.text(label, x: 54, y: cy - 6, size: 10,
          rgb: active ? _Rgb(0.90, 0.94, 1.0) : _Rgb(0.40, 0.46, 0.56));
      if (!active) {
        // strike-through
        p.hRule(54, cy - 3, 54 + label.length * 5.0, rgb: _Rgb(0.40, 0.46, 0.56), lw: 0.5);
      }
      cy -= 16;
    }

    // ── Metadata lines ────────────────────────────────────────────────────────
    cy -= 8;
    p.hRule(36, cy, 540, rgb: _Rgb(0.22, 0.30, 0.45));
    cy -= 14;
    for (final l in lines) {
      p.text(l, x: 36, y: cy, size: 9, rgb: _Rgb(0.60, 0.68, 0.78));
      cy -= 13;
    }

    return p;
  }

  /// Page 2 — Preprocessing signal traces: raw (left) → cleaned (right).
  ///
  /// Up to 16 channels are shown.  A random 30-second window is drawn from the
  /// middle of each preview buffer (which is already decimated for display).
  _PdfPage _buildPreprocessingPage(ReportContext ctx) {
    final p = _PdfPage();

    // Banner
    p.rect(0, 752, 612, 40, fill: _Rgb(0.055, 0.11, 0.25));
    p.rect(0, 748, 612, 4, fill: _Rgb(0.23, 0.51, 0.97));
    p.text('PREPROCESSING PIPELINE', x: 36, y: 762, size: 13, bold: true, rgb: _Rgb.white);
    p.text('30-second EEG segment: raw signal (left) vs cleaned signal (right)', x: 36, y: 749, size: 8, rgb: _Rgb(0.7, 0.82, 1.0));

    const panelTop = 720.0;
    const panelH = 420.0;
    const panelW = 246.0;
    const panelL = 36.0;  // left panel x
    const panelR = 330.0; // right panel x

    void drawSignalPanel(List<Float32List>? preview, double px, String label, _Rgb traceCol) {
      // Panel background
      p.roundRect(px, panelTop - panelH, panelW, panelH, r: 6, fill: _Rgb(0.07, 0.12, 0.22));
      p.roundRectStroke(px, panelTop - panelH, panelW, panelH, r: 6, stroke: _Rgb(0.18, 0.28, 0.50), lw: 0.8);

      // Label strip
      p.rect(px, panelTop - 20, panelW, 20, fill: _Rgb(0.09, 0.16, 0.33));
      p.text(label, x: px + 8, y: panelTop - 14, size: 9, bold: true, rgb: _Rgb.white);

      if (preview == null || preview.isEmpty) {
        p.text('(no data)', x: px + panelW / 2 - 20, y: panelTop - panelH / 2, size: 9, rgb: _Rgb(0.45, 0.52, 0.62));
        return;
      }

      final nCh = math.min(preview.length, 16);
      final chH = (panelH - 30) / nCh; // vertical space per channel

      // 1-second grid lines (light)
      final nSamples = preview[0].length;
      // We display the middle 30 seconds; sample rate is estimated from sampleCount
      // The preview is decimated, so we estimate rate from buffer size & duration
      final estRate = ctx.sampleRate > 0 ? ctx.sampleRate : 250.0;
      final samplesFor30s = (estRate * 30).round().clamp(1, nSamples);
      final midStart = ((nSamples - samplesFor30s) / 2).round().clamp(0, nSamples - 1);
      final segLen = math.min(samplesFor30s, nSamples - midStart);

      // vertical grid every 1 second
      final sampPerSec = segLen / 30.0;
      for (var sec = 0; sec <= 30; sec++) {
        final gx = px + 2 + (sec * sampPerSec / segLen) * (panelW - 4);
        p.vLine(gx, panelTop - panelH + 10, panelH - 30,
            rgb: _Rgb(0.15, 0.22, 0.38), lw: sec % 5 == 0 ? 0.6 : 0.3);
      }

      // Draw each channel trace
      for (var ch = 0; ch < nCh; ch++) {
        final chSamples = preview[ch];
        final centerY = panelTop - 20 - (ch + 0.5) * chH;
        final ampScale = chH * 0.38;

        // Compute robust scale (IQR normalisation)
        final seg = <double>[];
        for (var s = midStart; s < midStart + segLen; s++) {
          seg.add(chSamples[s < chSamples.length ? s : chSamples.length - 1].toDouble());
        }
        seg.sort();
        final q25 = seg[(seg.length * 0.25).round().clamp(0, seg.length - 1)];
        final q75 = seg[(seg.length * 0.75).round().clamp(0, seg.length - 1)];
        final iqr = (q75 - q25).abs().clamp(1e-6, double.infinity);

        // Channel label on y-axis
        final chLabel = ch < ctx.channelLabels.length ? ctx.channelLabels[ch] : 'Ch${ch + 1}';
        p.text(chLabel, x: px + 2, y: centerY - 4, size: 5.5, rgb: _Rgb(0.55, 0.68, 0.88));

        // Trace
        final buf = StringBuffer();
        bool first = true;
        for (var s = 0; s < segLen; s++) {
          final si = midStart + s;
          final raw = chSamples[si < chSamples.length ? si : chSamples.length - 1].toDouble();
          final norm = (raw - (q25 + q75) / 2) / iqr;
          final tx = px + 2 + (s / (segLen - 1).clamp(1, segLen)) * (panelW - 4);
          final ty = centerY + norm.clamp(-1.0, 1.0) * ampScale;
          buf.write('${tx.toStringAsFixed(1)} ${ty.toStringAsFixed(1)} ${first ? 'm' : 'l'} ');
          first = false;
        }
        p.raw('${traceCol.r.toStringAsFixed(2)} ${traceCol.g.toStringAsFixed(2)} ${traceCol.b.toStringAsFixed(2)} RG 0.5 w $buf S\n');
      }

      // 1-second scale bar at bottom-right
      final scaleX = px + panelW - 36.0;
      final scaleY = panelTop - panelH + 6.0;
      p.hRule(scaleX, scaleY, scaleX + sampPerSec / segLen * (panelW - 4), rgb: _Rgb.white, lw: 1.2);
      p.text('1s', x: scaleX, y: scaleY + 2, size: 7, bold: true, rgb: _Rgb.white);
    }

    drawSignalPanel(ctx.rawPreview, panelL, 'RAW', _Rgb(0.25, 0.55, 0.92));
    drawSignalPanel(ctx.cleanedPreview, panelR, 'CLEANED', _Rgb(0.20, 0.20, 0.22));

    // ── Arrow between panels ──────────────────────────────────────────────────
    const arrowMidY = panelTop - panelH / 2;
    const arrowX1 = panelL + panelW + 4;
    const arrowX2 = panelR - 4;
    const arrowMid = (arrowX1 + arrowX2) / 2;
    p.raw('0.23 0.51 0.97 RG 2.0 w ${arrowX1.toStringAsFixed(1)} ${arrowMidY.toStringAsFixed(1)} m ${arrowX2.toStringAsFixed(1)} ${arrowMidY.toStringAsFixed(1)} l S\n');
    // Arrowhead
    p.raw('0.23 0.51 0.97 rg ${arrowX2.toStringAsFixed(1)} ${arrowMidY.toStringAsFixed(1)} m '
        '${(arrowX2 - 8).toStringAsFixed(1)} ${(arrowMidY + 5).toStringAsFixed(1)} l '
        '${(arrowX2 - 8).toStringAsFixed(1)} ${(arrowMidY - 5).toStringAsFixed(1)} l h f\n');
    p.text('preprocessing', x: arrowMid - 22, y: arrowMidY + 6, size: 7.5, bold: true, rgb: _Rgb(0.23, 0.51, 0.97));

    // ── Preprocessing parameters box ─────────────────────────────────────────
    final prepOpts = ctx.prepOptions;
    if (prepOpts != null) {
      const infoY = panelTop - panelH - 16.0;
      p.roundRect(36, infoY - 60, 540, 60, r: 6, fill: _Rgb(0.07, 0.12, 0.22));
      p.roundRectStroke(36, infoY - 60, 540, 60, r: 6, stroke: _Rgb(0.18, 0.28, 0.50), lw: 0.6);
      p.text('PREPROCESSING PARAMETERS', x: 44, y: infoY - 8, size: 8, bold: true, rgb: _Rgb(0.55, 0.68, 0.88));

      final params = <String>[
        if (prepOpts.filter) 'Bandpass: ${prepOpts.lowHz}–${prepOpts.highHz} Hz',
        if (prepOpts.filter && prepOpts.notchHz > 0) 'Notch: ${prepOpts.notchHz} Hz',
        if (prepOpts.downsample) 'Downsample → ${prepOpts.downsampleFreq.toStringAsFixed(0)} Hz',
        if (prepOpts.badchannel) 'Bad channel detection',
        if (prepOpts.gedai) 'GEDAI artefact rejection',
        if (prepOpts.interpolate) 'Spherical interpolation',
        'Common-average reference',
      ];
      var px2 = 44.0;
      double parY = infoY - 24;
      for (var i = 0; i < params.length; i++) {
        if (i == 4) { px2 = 44; parY -= 14; }
        p.text('• ${params[i]}', x: px2, y: parY, size: 8.5, rgb: _Rgb(0.80, 0.88, 1.0));
        px2 += 132;
      }
    }

    return p;
  }

  /// Page 3 — MNE-style per-band scalp topomaps in a grid.
  _PdfPage _buildTopoPage({
    required List<String> headers,
    required List<List<String>> rows,
    required int chanCol,
    required List<int> spectralCols,
    required List<String> channelLabels,
    required String family,
  }) {
    final p = _PdfPage();

    // Banner
    p.rect(0, 752, 612, 40, fill: _Rgb(0.055, 0.11, 0.25));
    p.rect(0, 748, 612, 4, fill: _Rgb(0.23, 0.51, 0.97));
    p.text('SCALP TOPOGRAPHY', x: 36, y: 762, size: 13, bold: true, rgb: _Rgb.white);
    p.text('Per-band mean ${family.toUpperCase()} relative power — spatial distribution across electrodes', x: 36, y: 749, size: 8, rgb: _Rgb(0.7, 0.82, 1.0));

    // Band definitions (label, Hz range) — match the 7 CCS bands
    const bands = [
      ('Delta',      '1–4 Hz',  ),
      ('Theta',      '4–8 Hz',  ),
      ('ThetaAlpha', '6–10 Hz', ),
      ('Alpha',      '8–12 Hz', ),
      ('Beta1',      '12–18 Hz',),
      ('Beta2',      '18–30 Hz',),
      ('Gamma1',     '30–40 Hz',),
    ];

    // Map spectral cols to bands by matching the band name in the column header
    final bandCols = <int, int>{}; // band index → colIndex
    for (var bi = 0; bi < bands.length; bi++) {
      final bname = bands[bi].$1.toLowerCase();
      for (final ci in spectralCols) {
        if (ci < headers.length && headers[ci].toLowerCase().contains(bname)) {
          bandCols[bi] = ci;
          break;
        }
      }
    }

    // Compute per-channel mean for each band column
    Map<String, double> chanMeans(int ci) {
      final sums = <String, double>{};
      final cnts = <String, int>{};
      for (final row in rows) {
        if (chanCol < row.length && ci < row.length) {
          final ch = row[chanCol].trim();
          final v = double.tryParse(row[ci]);
          if (ch.isNotEmpty && v != null && v.isFinite) {
            sums[ch] = (sums[ch] ?? 0) + v;
            cnts[ch] = (cnts[ch] ?? 0) + 1;
          }
        }
      }
      return {for (final k in sums.keys) k: sums[k]! / cnts[k]!};
    }

    // Layout: 4 columns × 2 rows (7 maps + 1 empty)
    const cols = 4, rows2 = 2;
    const topoR = 62.0;        // radius of scalp circle
    const topoW = 150.0;       // cell width
    const topoH = 175.0;       // cell height
    const startX = 36.0;
    const startY = 720.0;

    for (var bi = 0; bi < bands.length; bi++) {
      final col = bi % cols;
      final row2 = bi ~/ cols;
      final cx = startX + col * topoW + topoW / 2;
      final cy = startY - row2 * topoH - topoH / 2 + 20;

      final ci = bandCols[bi];
      final means = ci != null ? chanMeans(ci) : <String, double>{};

      _drawTopomap(p, cx: cx, cy: cy, radius: topoR, channelMeans: means,
          title: bands[bi].$1, hzLabel: bands[bi].$2);
    }

    // Legend note
    p.text('Jet colormap: blue = min, red = max (per-band normalised)',
        x: 36, y: startY - rows2 * topoH - 8, size: 8, rgb: _Rgb(0.55, 0.68, 0.88));

    return p;
  }

  /// Page 4 — Source ROI brain map.
  _PdfPage _buildSourceRoiPage(
    ReportContext ctx,
    List<String> headers,
    List<List<String>> rows,
    int chanCol,
    Map<String, List<int>> familyCols,
  ) {
    final p = _PdfPage();

    // Banner
    p.rect(0, 752, 612, 40, fill: _Rgb(0.055, 0.11, 0.25));
    p.rect(0, 748, 612, 4, fill: _Rgb(0.68, 0.35, 0.97));
    p.text('SOURCE LOCALISATION — ROI MAP', x: 36, y: 762, size: 13, bold: true, rgb: _Rgb.white);
    p.text('eLORETA inverse solution — FreeSurfer fsaverage parcellation', x: 36, y: 749, size: 8, rgb: _Rgb(0.82, 0.70, 1.0));

    // Compute per-ROI means from first spectral column available
    Map<String, double> roiMeans = {};
    final spectralFamilyCols = (familyCols['psd'] ?? familyCols['irasa'] ?? familyCols['fooof'] ?? []);
    if (chanCol >= 0 && spectralFamilyCols.isNotEmpty) {
      final ci = spectralFamilyCols.first;
      for (final row in rows) {
        if (chanCol < row.length && ci < row.length) {
          final ch = row[chanCol].trim();
          final v = double.tryParse(row[ci]);
          if (ch.isNotEmpty && v != null && v.isFinite) {
            roiMeans[ch] = (roiMeans[ch] ?? 0.0) + v;
          }
        }
      }
    }

    // Draw two schematic brain lateral views (left hemisphere: lateral + medial)
    const brainCx1 = 190.0; // lateral view centre
    const brainCx2 = 420.0; // medial view centre
    const brainCy = 550.0;
    _drawBrainSilhouette(p, cx: brainCx1, cy: brainCy, view: 'lateral');
    _drawBrainSilhouette(p, cx: brainCx2, cy: brainCy, view: 'medial');
    p.text('Lateral', x: brainCx1 - 18, y: brainCy + 90, size: 9, bold: true, rgb: _Rgb(0.70, 0.80, 1.0));
    p.text('Medial',  x: brainCx2 - 16, y: brainCy + 90, size: 9, bold: true, rgb: _Rgb(0.70, 0.80, 1.0));
    p.text('Left hemisphere', x: 270, y: brainCy + 105, size: 8, rgb: _Rgb(0.55, 0.68, 0.88));

    // ROI list — two columns
    final rois = ctx.sourceRoiLabels;
    const listTop = 420.0;
    p.hRule(36, listTop, 576, rgb: _Rgb(0.22, 0.30, 0.45));
    p.text('PARCELLATION REGIONS (${rois.length} ROIs)', x: 36, y: listTop - 12, size: 8, bold: true, rgb: _Rgb(0.55, 0.68, 0.88));

    // Compute min/max for colour scale
    final vals = roiMeans.values.toList();
    final vmin = vals.isEmpty ? 0.0 : vals.reduce(math.min);
    final vmax = vals.isEmpty ? 1.0 : vals.reduce(math.max);
    final vrange = (vmax - vmin).abs().clamp(1e-9, double.infinity);

    const roiColW = 270.0;
    const roiRowH = 13.0;
    for (var i = 0; i < rois.length; i++) {
      final col = i % 2;
      final row = i ~/ 2;
      final rx = 36.0 + col * roiColW;
      final ry = listTop - 26 - row * roiRowH;
      if (ry < 40) break;

      final roi = rois[i];
      final v = roiMeans[roi];
      final t = v != null ? ((v - vmin) / vrange).clamp(0.0, 1.0) : 0.0;
      final dotCol = _jetColor(t);
      p.circle(rx + 5, ry - 1, 4, fill: dotCol);
      // Shorten label for display
      final shortLabel = roi.replaceAll('_', ' ').replaceAll('lh ', 'L·').replaceAll('rh ', 'R·');
      p.text(shortLabel, x: rx + 12, y: ry - 4, size: 7.5, rgb: _Rgb(0.80, 0.88, 1.0));
    }

    // Colorbar
    _drawColorbar(p, x: 560, y: listTop - 16, h: 120, vmin: vmin, vmax: vmax, label: 'Rel. power');

    return p;
  }

  /// Per-family statistics table page.
  _PdfPage _buildStatsPage({
    required String familyName,
    required List<int> colIndices,
    required List<String> headers,
    required List<List<String>> rows,
    required int pageNum,
    required int totalCols,
  }) {
    final p = _PdfPage();

    // Banner
    final famCol = _familyAccentColor(familyName);
    p.rect(0, 752, 612, 40, fill: _Rgb(0.055, 0.11, 0.25));
    p.rect(0, 748, 612, 4, fill: famCol);
    p.text('${familyName.toUpperCase()} — Feature Statistics',
        x: 36, y: 762, size: 13, bold: true, rgb: _Rgb.white);
    final pageLabel = pageNum == 0
        ? '$totalCols columns total'
        : 'columns ${pageNum * 40 + 1}–${pageNum * 40 + colIndices.length} of $totalCols';
    p.text(pageLabel, x: 36, y: 749, size: 8, rgb: _Rgb(0.7, 0.82, 1.0));

    // Column headers
    const tableL = 36.0;
    const colW = <double>[218, 70, 70, 70, 70]; // feature | mean | std | min | max
    const rowH = 15.0;
    const headers2 = ['Feature', 'Mean', 'Std Dev', 'Min', 'Max'];
    double y = 720.0;

    // Header row
    p.rect(tableL, y - 2, 500, 18, fill: famCol.scaled(0.8));
    var tx = tableL + 4.0;
    for (var hi = 0; hi < headers2.length; hi++) {
      p.text(headers2[hi], x: tx, y: y + 2, size: 9, bold: true, rgb: _Rgb.white);
      tx += colW[hi];
    }
    y -= rowH + 2;

    // Data rows
    for (var ri = 0; ri < colIndices.length; ri++) {
      final ci = colIndices[ri];
      final colName = ci < headers.length ? headers[ci] : '?';

      // Compute stats
      final vals = <double>[];
      for (final row in rows) {
        if (ci < row.length) {
          final v = double.tryParse(row[ci]);
          if (v != null && v.isFinite) vals.add(v);
        }
      }

      // Zebra striping
      if (ri % 2 == 1) {
        p.rect(tableL, y - 3, 500, rowH, fill: _Rgb(0.10, 0.15, 0.28));
      }
      // Left accent border
      p.rect(tableL, y - 3, 3, rowH, fill: famCol.scaled(0.5));
      // Separator line
      p.hRule(tableL, y - 3, tableL + 500, rgb: _Rgb(0.16, 0.22, 0.36), lw: 0.3);

      tx = tableL + 8.0;
      p.text(_trunc(colName, 36), x: tx, y: y, size: 8, rgb: _Rgb(0.85, 0.90, 1.0));
      tx += colW[0];

      if (vals.isEmpty) {
        for (var ci2 = 1; ci2 < headers2.length; ci2++) {
          p.text('—', x: tx, y: y, size: 8, rgb: _Rgb(0.45, 0.52, 0.62));
          tx += colW[ci2];
        }
      } else {
        final mean = vals.reduce((a, b) => a + b) / vals.length;
        var variance = 0.0;
        for (final v in vals) variance += (v - mean) * (v - mean);
        final std = vals.length > 1 ? _isqrt(variance / (vals.length - 1)) : 0.0;
        final mn = vals.reduce((a, b) => a < b ? a : b);
        final mx = vals.reduce((a, b) => a > b ? a : b);
        for (final (vi, stat) in [(mean, 1), (std, 2), (mn, 3), (mx, 4)]) {
          p.text(_fmt(vi), x: tx, y: y, size: 8, bold: stat == 1, rgb: _Rgb(0.42, 0.72, 1.0));
          tx += colW[stat];
        }
      }
      y -= rowH;
      if (y < 50) break;
    }

    return p;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Drawing helpers
  // ──────────────────────────────────────────────────────────────────────────

  /// MNE-style scalp topomap with jet colormap electrode dots and contour rings.
  void _drawTopomap(_PdfPage p, {
    required double cx, required double cy, required double radius,
    required Map<String, double> channelMeans,
    required String title, required String hzLabel,
  }) {
    // Scalp circle
    p.circle(cx, cy, radius, fill: _Rgb(0.07, 0.12, 0.22));
    p.circleStroke(cx, cy, radius, stroke: _Rgb(0.28, 0.38, 0.58), lw: 1.0);

    // Ear markers (small arcs left/right)
    p.raw('0.28 0.38 0.58 RG 1.0 w '
        '${(cx - radius - 6).toStringAsFixed(1)} ${(cy - 8).toStringAsFixed(1)} m '
        '${(cx - radius - 2).toStringAsFixed(1)} ${(cy - 8).toStringAsFixed(1)} l '
        '${(cx - radius - 2).toStringAsFixed(1)} ${(cy + 8).toStringAsFixed(1)} l '
        '${(cx - radius - 6).toStringAsFixed(1)} ${(cy + 8).toStringAsFixed(1)} l h S\n');
    p.raw('0.28 0.38 0.58 RG 1.0 w '
        '${(cx + radius + 2).toStringAsFixed(1)} ${(cy - 8).toStringAsFixed(1)} m '
        '${(cx + radius + 6).toStringAsFixed(1)} ${(cy - 8).toStringAsFixed(1)} l '
        '${(cx + radius + 6).toStringAsFixed(1)} ${(cy + 8).toStringAsFixed(1)} l '
        '${(cx + radius + 2).toStringAsFixed(1)} ${(cy + 8).toStringAsFixed(1)} l h S\n');

    // Nose triangle
    p.raw('0.28 0.38 0.58 RG 1.0 w '
        '${(cx - 5).toStringAsFixed(1)} ${(cy + radius - 2).toStringAsFixed(1)} m '
        '${cx.toStringAsFixed(1)} ${(cy + radius + 10).toStringAsFixed(1)} l '
        '${(cx + 5).toStringAsFixed(1)} ${(cy + radius - 2).toStringAsFixed(1)} l S\n');

    // Cross-hairs (faint)
    p.raw('0.15 0.22 0.38 RG 0.3 w '
        '${cx.toStringAsFixed(1)} ${(cy - radius + 4).toStringAsFixed(1)} m '
        '${cx.toStringAsFixed(1)} ${(cy + radius - 4).toStringAsFixed(1)} l S\n');
    p.raw('0.15 0.22 0.38 RG 0.3 w '
        '${(cx - radius + 4).toStringAsFixed(1)} ${cy.toStringAsFixed(1)} m '
        '${(cx + radius - 4).toStringAsFixed(1)} ${cy.toStringAsFixed(1)} l S\n');

    // 10-20 electrode positions (normalised [-1,1] relative to scalp circle)
    // Format: label → [normX, normY] (Y+ = anterior)
    const pos10_20 = <String, List<double>>{
      'Fp1': [-0.31, 0.78], 'Fpz': [0.00, 0.82], 'Fp2': [0.31, 0.78],
      'F7':  [-0.77, 0.44], 'F3':  [-0.41, 0.44], 'Fz': [0.00, 0.44], 'F4': [0.41, 0.44], 'F8': [0.77, 0.44],
      'T3':  [-0.88, 0.00], 'T7':  [-0.88, 0.00], 'C3': [-0.46, 0.00], 'Cz': [0.00, 0.00], 'C4': [0.46, 0.00], 'T4': [0.88, 0.00], 'T8': [0.88, 0.00],
      'T5':  [-0.77,-0.44], 'P7':  [-0.77,-0.44], 'P3': [-0.41,-0.44], 'Pz': [0.00,-0.44], 'P4': [0.41,-0.44], 'T6': [0.77,-0.44], 'P8': [0.77,-0.44],
      'O1':  [-0.31,-0.78], 'Oz':  [0.00,-0.82],  'O2': [0.31,-0.78],
      'AF3': [-0.22, 0.63], 'AF4': [0.22, 0.63],
      'FC1': [-0.22, 0.22], 'FC2': [0.22, 0.22], 'FC5': [-0.64, 0.22], 'FC6': [0.64, 0.22],
      'CP1': [-0.22,-0.22], 'CP2': [0.22,-0.22], 'CP5': [-0.64,-0.22], 'CP6': [0.64,-0.22],
      'PO3': [-0.22,-0.63], 'PO4': [0.22,-0.63],
    };

    if (channelMeans.isEmpty) {
      // Draw faint dots for all standard electrodes
      for (final e in pos10_20.entries) {
        final ex = cx + e.value[0] * radius * 0.92;
        final ey = cy + e.value[1] * radius * 0.92;
        p.circle(ex, ey, 3.5, fill: _Rgb(0.20, 0.30, 0.48));
      }
    } else {
      // Normalise
      final vals = channelMeans.values.toList();
      final vmin = vals.reduce(math.min);
      final vmax = vals.reduce(math.max);
      final vrange = (vmax - vmin).abs().clamp(1e-9, double.infinity);

      // Draw contour rings (3 iso-rings from centre outward)
      for (var ring = 1; ring <= 3; ring++) {
        final r = radius * ring / 4;
        p.circleStroke(cx, cy, r, stroke: _Rgb(0.14, 0.22, 0.40), lw: 0.3);
      }

      // Draw electrode dots sized by value
      for (final entry in channelMeans.entries) {
        final ch = entry.key;
        final v = entry.value;
        // Match key case-insensitively
        List<double>? xy;
        for (final e in pos10_20.entries) {
          if (e.key.toLowerCase() == ch.toLowerCase()) { xy = e.value; break; }
        }
        if (xy == null) continue;

        final ex = cx + xy[0] * radius * 0.90;
        final ey = cy + xy[1] * radius * 0.90;
        final t = ((v - vmin) / vrange).clamp(0.0, 1.0);
        final col = _jetColor(t);

        // Outer glow ring
        p.circle(ex, ey, 7.0, fill: col.scaled(0.35));
        // Electrode dot
        p.circle(ex, ey, 5.0, fill: col);
        p.circleStroke(ex, ey, 5.0, stroke: _Rgb(0.08, 0.10, 0.18), lw: 0.5);

        // Channel label
        p.text(ch, x: ex - ch.length * 2.2, y: ey - 13, size: 5.5, rgb: _Rgb(0.85, 0.90, 1.0));
      }

      // Vertical colorbar to the right of map
      _drawColorbar(p, x: cx + radius + 8, y: cy - radius * 0.7,
          h: radius * 1.4, vmin: vmin, vmax: vmax);
    }

    // Band title below map
    p.text(title, x: cx - title.length * 3.0, y: cy - radius - 16, size: 9, bold: true, rgb: _Rgb.white);
    p.text(hzLabel, x: cx - hzLabel.length * 2.5, y: cy - radius - 28, size: 7.5, rgb: _Rgb(0.55, 0.68, 0.88));
  }

  /// Draw a schematic cortical brain silhouette (lateral or medial left-hemisphere view).
  /// Uses closed Bézier cubic paths approximating the folded cortex outline.
  void _drawBrainSilhouette(_PdfPage p, {
    required double cx, required double cy, required String view,
  }) {
    const w = 130.0, h = 100.0;
    final l = cx - w / 2, r = cx + w / 2, t = cy + h / 2, b = cy - h / 2;

    if (view == 'lateral') {
      // Lateral view: roughly oval with frontal lobe protrusion and occipital flare
      p.raw('0.10 0.16 0.30 rg 0.25 0.40 0.65 RG 1.2 w '
          '${l.toStringAsFixed(1)} ${(cy - 10).toStringAsFixed(1)} m '
          '${(l + 10).toStringAsFixed(1)} ${t.toStringAsFixed(1)} '
          '${(cx - 20).toStringAsFixed(1)} ${(t + 15).toStringAsFixed(1)} '
          '${cx.toStringAsFixed(1)} ${(t + 8).toStringAsFixed(1)} c '
          '${(cx + 20).toStringAsFixed(1)} ${t.toStringAsFixed(1)} '
          '${(r - 10).toStringAsFixed(1)} ${(t - 10).toStringAsFixed(1)} '
          '${r.toStringAsFixed(1)} ${(cy + 5).toStringAsFixed(1)} c '
          '${(r + 5).toStringAsFixed(1)} ${(cy - 15).toStringAsFixed(1)} '
          '${(r - 5).toStringAsFixed(1)} ${(b + 5).toStringAsFixed(1)} '
          '${(cx + 30).toStringAsFixed(1)} ${b.toStringAsFixed(1)} c '
          '${(cx).toStringAsFixed(1)} ${(b - 8).toStringAsFixed(1)} '
          '${(l + 25).toStringAsFixed(1)} ${(b + 5).toStringAsFixed(1)} '
          '${(l + 10).toStringAsFixed(1)} ${(cy - 30).toStringAsFixed(1)} c '
          '${l.toStringAsFixed(1)} ${(cy - 20).toStringAsFixed(1)} '
          '${l.toStringAsFixed(1)} ${(cy - 15).toStringAsFixed(1)} '
          '${l.toStringAsFixed(1)} ${(cy - 10).toStringAsFixed(1)} c h b\n');
      // A few sulcal lines
      for (final yoff in [-8.0, 15.0, -25.0]) {
        p.raw('0.20 0.30 0.50 RG 0.5 w '
            '${(l + 25).toStringAsFixed(1)} ${(cy + yoff).toStringAsFixed(1)} m '
            '${(cx + 20).toStringAsFixed(1)} ${(cy + yoff + 5).toStringAsFixed(1)} l S\n');
      }
    } else {
      // Medial view: corpus callosum visible, more vertical
      p.raw('0.10 0.16 0.30 rg 0.25 0.40 0.65 RG 1.2 w '
          '${(l + 20).toStringAsFixed(1)} ${cy.toStringAsFixed(1)} m '
          '${(l + 15).toStringAsFixed(1)} ${(t - 5).toStringAsFixed(1)} '
          '${cx.toStringAsFixed(1)} ${(t + 10).toStringAsFixed(1)} '
          '${(r - 10).toStringAsFixed(1)} ${t.toStringAsFixed(1)} c '
          '${(r + 5).toStringAsFixed(1)} ${(cy + 20).toStringAsFixed(1)} '
          '${(r + 5).toStringAsFixed(1)} ${(cy - 10).toStringAsFixed(1)} '
          '${(r - 10).toStringAsFixed(1)} ${(b + 5).toStringAsFixed(1)} c '
          '${cx.toStringAsFixed(1)} ${b.toStringAsFixed(1)} '
          '${(l + 20).toStringAsFixed(1)} ${(cy - 15).toStringAsFixed(1)} '
          '${(l + 20).toStringAsFixed(1)} ${cy.toStringAsFixed(1)} c h b\n');
      // Corpus callosum arc
      p.raw('0.30 0.50 0.80 RG 1.0 w '
          '${(cx - 20).toStringAsFixed(1)} ${(cy + 5).toStringAsFixed(1)} m '
          '${cx.toStringAsFixed(1)} ${(cy + 20).toStringAsFixed(1)} '
          '${(cx + 20).toStringAsFixed(1)} ${(cy + 20).toStringAsFixed(1)} '
          '${(cx + 30).toStringAsFixed(1)} ${(cy + 5).toStringAsFixed(1)} c S\n');
    }
  }

  /// Draw a vertical jet-colormap colorbar at position (x, y), height h.
  void _drawColorbar(_PdfPage p, {
    required double x, required double y, required double h,
    required double vmin, required double vmax, String label = '',
  }) {
    const barW = 10.0;
    const steps = 40;
    final stepH = h / steps;
    for (var i = 0; i < steps; i++) {
      final t = i / (steps - 1);
      final col = _jetColor(t);
      p.rect(x, y + i * stepH, barW, stepH + 0.5, fill: col);
    }
    p.rectStroke(x, y, barW, h, stroke: _Rgb(0.35, 0.45, 0.60), lw: 0.5);
    p.text(_fmt(vmax), x: x + barW + 3, y: y + h - 5, size: 6.5, rgb: _Rgb(0.80, 0.88, 1.0));
    p.text(_fmt(vmin), x: x + barW + 3, y: y,          size: 6.5, rgb: _Rgb(0.80, 0.88, 1.0));
    if (label.isNotEmpty) {
      p.text(label, x: x - 2, y: y + h + 4, size: 6, rgb: _Rgb(0.55, 0.68, 0.88));
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Utility
  // ──────────────────────────────────────────────────────────────────────────

  /// Jet colormap: t ∈ [0,1] → RGB.
  static _Rgb _jetColor(double t) {
    final r = (1.5 - (4 * t - 3).abs()).clamp(0.0, 1.0);
    final g = (1.5 - (4 * t - 2).abs()).clamp(0.0, 1.0);
    final b = (1.5 - (4 * t - 1).abs()).clamp(0.0, 1.0);
    return _Rgb(r, g, b);
  }

  static _Rgb _familyAccentColor(String family) => switch (family) {
    'psd'          => _Rgb(0.23, 0.69, 0.40),
    'fooof'        => _Rgb(0.95, 0.60, 0.13),
    'irasa'        => _Rgb(0.15, 0.60, 0.85),
    'nonlinear'    => _Rgb(0.68, 0.35, 0.97),
    'connectivity' => _Rgb(0.97, 0.35, 0.35),
    _              => _Rgb(0.23, 0.51, 0.97),
  };

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
        header.startsWith('mim_') || header.startsWith('gc_')) {
      return 'connectivity';
    }
    return 'other';
  }

  static String _fmt(double v) {
    if (v.abs() >= 1000) return v.toStringAsFixed(0);
    if (v.abs() >= 10)   return v.toStringAsFixed(2);
    return v.toStringAsFixed(4);
  }

  static String _trunc(String s, int max) =>
      s.length > max ? '${s.substring(0, max - 1)}\u2026' : s;

  static double _isqrt(double x) {
    if (x <= 0) return 0;
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

  static String findEngine() {
    final appDir = File(Platform.resolvedExecutable).parent.path;
    final names = Platform.isWindows ? ['ccs-eeg-engine.exe'] : ['ccs-eeg-engine'];
    final candidates = <String>[
      for (final name in names) '$appDir/$name',
      for (final name in names) '${Directory.current.path}/../bridge/target/release/$name',
      for (final name in names) '${Directory.current.path}/../bridge/target/debug/$name',
      for (final name in names) '${Directory.current.path}/bridge/target/release/$name',
      for (final name in names) '${Directory.current.path}/bridge/target/debug/$name',
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
  startSeconds: 0, endSeconds: 0, binSeconds: 60,
  psd: false, fooof: false, irasa: false, nonlinear: false, acw: false,
  connectivity: false, mic: false, mim: false, gc: false, gcTr: false,
  coh: false, plv: false, ciplv: false, pli: false, wpli: false,
  removeNonEeg: false, exclusions: [],
);

// ── _Rgb ──────────────────────────────────────────────────────────────────────

class _Rgb {
  const _Rgb(this.r, this.g, this.b);
  static const white = _Rgb(1, 1, 1);

  final double r, g, b;

  /// Return a dimmer version of this colour (multiply each channel by [f]).
  _Rgb scaled(double f) => _Rgb((r * f).clamp(0, 1), (g * f).clamp(0, 1), (b * f).clamp(0, 1));

  /// PDF fill operator string ("R G B rg").
  String get fill => '${r.toStringAsFixed(3)} ${g.toStringAsFixed(3)} ${b.toStringAsFixed(3)} rg';
  /// PDF stroke operator string ("R G B RG").
  String get stroke => '${r.toStringAsFixed(3)} ${g.toStringAsFixed(3)} ${b.toStringAsFixed(3)} RG';
}

// ── _PdfPage ──────────────────────────────────────────────────────────────────

/// Accumulates PDF content-stream commands for one page.
class _PdfPage {
  final StringBuffer _sb = StringBuffer();

  // ── Primitive operations ──────────────────────────────────────────────────

  void raw(String s) => _sb.write(s);

  void rect(double x, double y, double w, double h, {_Rgb? fill, _Rgb? stroke, double lw = 0}) {
    if (fill != null) _sb.write('${fill.fill} ');
    if (stroke != null) _sb.write('${stroke.stroke} ${lw.toStringAsFixed(2)} w ');
    _sb.write('${x.toStringAsFixed(1)} ${y.toStringAsFixed(1)} '
        '${w.toStringAsFixed(1)} ${h.toStringAsFixed(1)} re ');
    _sb.write(fill != null && stroke != null ? 'B\n' : fill != null ? 'f\n' : 'S\n');
  }

  void rectStroke(double x, double y, double w, double h, {required _Rgb stroke, double lw = 0.8}) {
    _sb.write('${stroke.stroke} ${lw.toStringAsFixed(2)} w '
        '${x.toStringAsFixed(1)} ${y.toStringAsFixed(1)} '
        '${w.toStringAsFixed(1)} ${h.toStringAsFixed(1)} re S\n');
  }

  /// Rounded rectangle filled (approximated with 4 Bézier arcs).
  void roundRect(double x, double y, double w, double h, {required double r, required _Rgb fill}) {
    _sb.write('${fill.fill} ');
    _roundRectPath(x, y, w, h, r);
    _sb.write('f\n');
  }

  void roundRectStroke(double x, double y, double w, double h, {required double r, required _Rgb stroke, double lw = 0.8}) {
    _sb.write('${stroke.stroke} ${lw.toStringAsFixed(2)} w ');
    _roundRectPath(x, y, w, h, r);
    _sb.write('S\n');
  }

  void _roundRectPath(double x, double y, double w, double h, double r) {
    const k = 0.5523; // Bézier constant for circle approximation
    final kr = k * r;
    _sb.write('${(x + r).toStringAsFixed(2)} ${y.toStringAsFixed(2)} m '
        '${(x + w - r).toStringAsFixed(2)} ${y.toStringAsFixed(2)} l '
        '${(x + w - r + kr).toStringAsFixed(2)} ${y.toStringAsFixed(2)} ${(x + w).toStringAsFixed(2)} ${(y + r - kr).toStringAsFixed(2)} ${(x + w).toStringAsFixed(2)} ${(y + r).toStringAsFixed(2)} c '
        '${(x + w).toStringAsFixed(2)} ${(y + h - r).toStringAsFixed(2)} l '
        '${(x + w).toStringAsFixed(2)} ${(y + h - r + kr).toStringAsFixed(2)} ${(x + w - r + kr).toStringAsFixed(2)} ${(y + h).toStringAsFixed(2)} ${(x + w - r).toStringAsFixed(2)} ${(y + h).toStringAsFixed(2)} c '
        '${(x + r).toStringAsFixed(2)} ${(y + h).toStringAsFixed(2)} l '
        '${(x + r - kr).toStringAsFixed(2)} ${(y + h).toStringAsFixed(2)} ${x.toStringAsFixed(2)} ${(y + h - r + kr).toStringAsFixed(2)} ${x.toStringAsFixed(2)} ${(y + h - r).toStringAsFixed(2)} c '
        '${x.toStringAsFixed(2)} ${(y + r).toStringAsFixed(2)} l '
        '${x.toStringAsFixed(2)} ${(y + r - kr).toStringAsFixed(2)} ${(x + r - kr).toStringAsFixed(2)} ${y.toStringAsFixed(2)} ${(x + r).toStringAsFixed(2)} ${y.toStringAsFixed(2)} c h ');
  }

  void circle(double cx, double cy, double r, {_Rgb? fill}) {
    _circlePath(cx, cy, r);
    _sb.write(fill != null ? '${fill.fill} f\n' : 'f\n');
  }

  void circleStroke(double cx, double cy, double r, {required _Rgb stroke, double lw = 0.8}) {
    _sb.write('${stroke.stroke} ${lw.toStringAsFixed(2)} w ');
    _circlePath(cx, cy, r);
    _sb.write('S\n');
  }

  void _circlePath(double cx, double cy, double r) {
    const k = 0.5523;
    final kr = k * r;
    _sb.write('${(cx + r).toStringAsFixed(2)} ${cy.toStringAsFixed(2)} m '
        '${(cx + r).toStringAsFixed(2)} ${(cy + kr).toStringAsFixed(2)} ${(cx + kr).toStringAsFixed(2)} ${(cy + r).toStringAsFixed(2)} ${cx.toStringAsFixed(2)} ${(cy + r).toStringAsFixed(2)} c '
        '${(cx - kr).toStringAsFixed(2)} ${(cy + r).toStringAsFixed(2)} ${(cx - r).toStringAsFixed(2)} ${(cy + kr).toStringAsFixed(2)} ${(cx - r).toStringAsFixed(2)} ${cy.toStringAsFixed(2)} c '
        '${(cx - r).toStringAsFixed(2)} ${(cy - kr).toStringAsFixed(2)} ${(cx - kr).toStringAsFixed(2)} ${(cy - r).toStringAsFixed(2)} ${cx.toStringAsFixed(2)} ${(cy - r).toStringAsFixed(2)} c '
        '${(cx + kr).toStringAsFixed(2)} ${(cy - r).toStringAsFixed(2)} ${(cx + r).toStringAsFixed(2)} ${(cy - kr).toStringAsFixed(2)} ${(cx + r).toStringAsFixed(2)} ${cy.toStringAsFixed(2)} c h ');
  }

  void hRule(double x1, double y, double x2, {_Rgb? rgb, double lw = 0.6}) {
    final col = rgb ?? _Rgb(0.22, 0.30, 0.45);
    _sb.write('${col.stroke} ${lw.toStringAsFixed(2)} w '
        '${x1.toStringAsFixed(1)} ${y.toStringAsFixed(1)} m '
        '${x2.toStringAsFixed(1)} ${y.toStringAsFixed(1)} l S\n');
  }

  void vLine(double x, double y, double h, {_Rgb? rgb, double lw = 0.4}) {
    final col = rgb ?? _Rgb(0.22, 0.30, 0.45);
    _sb.write('${col.stroke} ${lw.toStringAsFixed(2)} w '
        '${x.toStringAsFixed(1)} ${y.toStringAsFixed(1)} m '
        '${x.toStringAsFixed(1)} ${(y + h).toStringAsFixed(1)} l S\n');
  }

  void text(String s, {required double x, required double y, required double size, bool bold = false, _Rgb? rgb}) {
    final col = rgb ?? _Rgb(0.85, 0.90, 1.0);
    _sb.write('BT\n${col.fill} /F${bold ? 2 : 1} ${size.toStringAsFixed(1)} Tf\n'
        '1 0 0 1 ${x.toStringAsFixed(1)} ${y.toStringAsFixed(1)} Tm\n'
        '(${_pdfEsc(s)}) Tj\nET\n');
  }

  String get content => _sb.toString();
}

// ── _PdfRenderer ─────────────────────────────────────────────────────────────

/// Assembles a multi-page PDF-1.4 file from _PdfPage objects.
class _PdfRenderer {
  final List<_PdfPage> _pages = [];

  void addPage(_PdfPage page) => _pages.add(page);

  Future<void> write(String outputPath) async {
    final totalPages = _pages.length;
    final objs = <String>[];

    objs.add(''); // obj 1: catalog placeholder
    objs.add(''); // obj 2: pages placeholder

    final f1 = 2 + 2 * totalPages + 1;
    final f2 = f1 + 1;

    final pageObjIds = <int>[];

    for (var pi = 0; pi < totalPages; pi++) {
      final pageContent = _pages[pi];

      // Footer
      final footer = StringBuffer();
      footer.write('0.16 0.22 0.35 RG 0.5 w 36 38 m 576 38 l S\n');
      _addTextToBuffer(footer, 'CCS EEG Studio — Quantitative Analysis Report', 36, 24, 7.5, false, _Rgb(0.45, 0.55, 0.65));
      _addTextToBuffer(footer, 'Page ${pi + 1} of $totalPages', 520, 24, 7.5, true, _Rgb(0.35, 0.50, 0.80));

      final streamStr = pageContent.content + footer.toString();
      final pageObjId = objs.length + 1;
      final contentObjId = pageObjId + 1;
      pageObjIds.add(pageObjId);

      objs.add('$pageObjId 0 obj << /Type /Page /Parent 2 0 R '
          '/MediaBox [0 0 612 792] '
          '/Resources << /Font << /F1 $f1 0 R /F2 $f2 0 R >> >> '
          '/Contents $contentObjId 0 R >> endobj\n');
      objs.add('$contentObjId 0 obj << /Length ${streamStr.length} >> stream\n'
          '$streamStr\nendstream endobj\n');
    }

    objs.add('$f1 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj\n');
    objs.add('$f2 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >> endobj\n');

    final kids = pageObjIds.map((id) => '$id 0 R').join(' ');
    objs[0] = '1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n';
    objs[1] = '2 0 obj << /Type /Pages /Kids [$kids] /Count ${pageObjIds.length} >> endobj\n';

    final bb = BytesBuilder();
    bb.add(utf8.encode('%PDF-1.4\n'));
    final offsets = <int>[];
    for (final obj in objs) {
      offsets.add(bb.length);
      bb.add(utf8.encode(obj));
    }
    final xrefOff = bb.length;
    final xref = StringBuffer('xref\n0 ${objs.length + 1}\n0000000000 65535 f \n');
    for (final off in offsets) {
      xref.write('${off.toString().padLeft(10, '0')} 00000 n \n');
    }
    xref.write('trailer << /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n$xrefOff\n%%EOF\n');
    bb.add(utf8.encode(xref.toString()));
    await File(outputPath).writeAsBytes(bb.takeBytes());
  }

  void _addTextToBuffer(StringBuffer buf, String s, double x, double y, double size, bool bold, _Rgb rgb) {
    buf.write('BT\n${rgb.fill} /F${bold ? 2 : 1} ${size.toStringAsFixed(1)} Tf\n'
        '1 0 0 1 ${x.toStringAsFixed(1)} ${y.toStringAsFixed(1)} Tm\n'
        '(${_pdfEsc(s)}) Tj\nET\n');
  }
}

// ── PDF string escaping ────────────────────────────────────────────────────────

String _pdfEsc(String value) => value
    .replaceAll('\u2022', '-')
    .replaceAll('\u2026', '...')
    .replaceAll('\u2014', '-')
    .replaceAll('\u2013', '-')
    .replaceAll('\u00b2', '2')
    .replaceAll(r'\', r'\\')
    .replaceAll('(', r'\(')
    .replaceAll(')', r'\)');

class RecordingLoaderShim {
  Future<EegRecording> load(String path) async {
    return await RecordingLoader().load(path);
  }
}
