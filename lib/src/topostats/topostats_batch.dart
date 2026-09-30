// lib/src/topostats/topostats_batch.dart
//
// Non-interactive generation of PlotFeaturesTopoStats-style figures, used by
// the pipeline ("Generate plots after extraction", Stage 4 "Run Plot
// Generation" and batch "Stage 3: Plots"). Replaces the old overview
// plotter (feature_plotter.dart) for those paths.
//
// Input CSVs are grouped into recordings by rec_ID
// (`<idx>_<rec_ID>_<session>.features.csv`); every group gives one figure
// per feature, exactly like running the script in that folder. A single CSV
// is expanded to all of its sibling sessions. Pooled batch CSVs that carry
// several recordings in a `filename` column are split first.

import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/widgets.dart' as pw;

import 'topostats_engine.dart';
import 'topostats_figure.dart';
import 'topostats_runner.dart';
import 'topo_interp.dart' show isStandard1020Channel;

class TopoBatchOutput {
  TopoBatchOutput(this.path, this.recId, this.feature);
  final String path;
  final String recId;
  final String feature;
}

String _base(String p) => p.split(RegExp(r'[\\/]')).last;
String _dir(String p) {
  final i = p.lastIndexOf(RegExp(r'[\\/]'));
  return i < 0 ? '.' : p.substring(0, i);
}

/// Splits a pooled CSV by its `filename` column into per-recording
/// `<filename>.features.csv` files under [tmpDir]. Returns [path] unchanged
/// when it holds a single recording.
List<String> _splitPooled(String path, String tmpDir) {
  final header = readCsvHeader(path);
  final iFile = header.indexOf('filename');
  if (iFile < 0) return [path];
  final lines = File(path).readAsLinesSync();
  final byFile = <String, StringBuffer>{};
  for (var i = 1; i < lines.length; i++) {
    final l = lines[i];
    if (l.isEmpty) continue;
    final cols = l.split(',');
    if (cols.length <= iFile) continue;
    var key = cols[iFile].trim();
    if (key.isEmpty || key == 'NA') key = _base(path);
    byFile
        .putIfAbsent(key, () => StringBuffer()..writeln(lines.first))
        .writeln(l);
  }
  if (byFile.length <= 1) return [path];
  Directory(tmpDir).createSync(recursive: true);
  final out = <String>[];
  byFile.forEach((key, buf) {
    final stem = key
        .replaceAll(
          RegExp(r'\.(features\.csv|csv|set|edf|vhdr|fif|mat|ccseeg)$'),
          '',
        )
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final p = '$tmpDir${Platform.pathSeparator}$stem.features.csv';
    File(p).writeAsStringSync(buf.toString());
    out.add(p);
  });
  return out;
}

/// Groups session CSVs by recording ID.
Map<String, List<String>> groupByRecording(List<String> csvPaths) {
  final groups = <String, List<String>>{};
  for (final p in csvPaths) {
    final id = inferRecId([p]);
    groups.putIfAbsent(id, () => []).add(p);
  }
  // A single file stands for its whole recording: pull in its siblings.
  final out = <String, List<String>>{};
  groups.forEach((id, files) {
    var fs = files.toSet().toList()..sort();
    if (fs.length == 1 && id.isNotEmpty) {
      final sib = discoverSessionFiles(_dir(fs.first), id);
      if (sib.length > 1) fs = sib;
    }
    final rid = fs.length > 1 ? inferRecId(fs) : id;
    out[rid] = fs;
  });
  return out;
}

/// Generates the script's figures (PNG + stats CSV per feature and
/// recording) into `outputDir/Figures_TopoStats`.
Future<List<TopoBatchOutput>> generateTopoStatsFigures({
  required List<String> csvPaths,
  required String outputDir,
  TopoStatsSettings base = const TopoStatsSettings(),
  List<String>? features,
  bool writePdf = true,
  void Function(double progress, String message)? onProgress,
}) async {
  final outDir = '$outputDir${Platform.pathSeparator}Figures_TopoStats';
  Directory(outDir).createSync(recursive: true);

  final expanded = <String>[];
  for (final p in csvPaths.where((p) => File(p).existsSync())) {
    expanded.addAll(
      _splitPooled(p, '$outDir${Platform.pathSeparator}_sessions'),
    );
  }
  final groups = groupByRecording(expanded);
  final saved = <TopoBatchOutput>[];
  var gi = 0;
  for (final entry in groups.entries) {
    final recId = entry.key;
    final files = entry.value;
    final names = [for (final f in files) cleanSegmentName(_base(f), recId)];
    var s = base.copyWith(recId: recId);
    if (!names.any((n) => n.contains(s.baselineSession))) {
      s = s.copyWith(baselineSession: names.first);
    }
    try {
      final det = detectChannels(files.first);
      final known = det.where(isStandard1020Channel).toList();
      s = s.copyWith(channels: known.length >= 3 ? known : det);
      if (s.reprChan != null && !s.channels.contains(s.reprChan)) {
        s = s.copyWith(reprChan: s.channels.contains('Fz') ? 'Fz' : null);
      }
    } catch (_) {}
    final cols = numericFeatureColumns(files.first);
    var feats = (features ?? kReferenceFeatureList)
        .where(cols.contains)
        .toList();
    if (feats.isEmpty) feats = cols;
    onProgress?.call(
      gi / groups.length,
      '$recId: ${files.length} sessions, ${feats.length} features, baseline ${s.baselineSession}',
    );

    final errors = <String>[];
    final job = await startTopoStatsJob(
      files: files,
      settings: s,
      features: feats,
      onProgress: (p, m) => onProgress?.call((gi + p) / groups.length, ''),
      onFeatureError: (f, e) => errors.add('$f: $e'),
    );
    final pages = <(TopoStatsResult, Uint8List, double, double)>[];
    final stats = StringBuffer();
    try {
      await for (final r in job.results) {
        final fig = TopoFigure(r);
        final stem = '$outDir${Platform.pathSeparator}${r.outputFileName}';
        final png = await fig.toPng(dpi: r.settings.dpi.toDouble());
        await File('$stem.png').writeAsBytes(png);
        // one stats table per recording (feature column first)
        final lines = r.toCsv().split('\n');
        if (stats.isEmpty) stats.writeln('feature,${lines.first}');
        for (final l in lines.skip(1)) {
          if (l.isNotEmpty) stats.writeln('${r.settings.feature},$l');
        }
        // The PDF embeds a lighter render (~110 dpi) so the combined report
        // stays small; the PNG on disk keeps the full script resolution.
        final pdfPng = !writePdf
            ? Uint8List(0)
            : (r.settings.dpi > 110 ? await fig.toPng(dpi: 110) : png);
        pages.add((r, pdfPng, fig.widthIn, fig.heightIn));
        saved.add(TopoBatchOutput('$stem.png', recId, r.settings.feature));
        onProgress?.call((gi + 1) / groups.length, '  ✓ ${_base(stem)}.png');
      }
    } catch (e) {
      onProgress?.call((gi + 1) / groups.length, '  ⚠ $recId: $e');
    }
    if (pages.isNotEmpty) {
      final base = '$outDir${Platform.pathSeparator}${recId}_TopoStats';
      await File('${base}_stats.csv').writeAsString(stats.toString());
      if (writePdf) {
        await File(
          '${base}_report.pdf',
        ).writeAsBytes(await _topoReportPdf(recId, pages));
      }
      onProgress?.call(
        (gi + 1) / groups.length,
        '  ✓ ${_base(base)}${writePdf ? '_report.pdf + ' : ''}_stats.csv (${pages.length} features)',
      );
    }
    for (final e in errors) {
      onProgress?.call((gi + 1) / groups.length, '  ⚠ skipped $e');
    }
    gi++;
  }
  return saved;
}

/// One PDF per recording: a summary page (significant channel-windows per
/// feature and session) followed by every figure on its own page, sized to
/// the figure so nothing is rescaled.
Future<Uint8List> _topoReportPdf(
  String recId,
  List<(TopoStatsResult, Uint8List, double, double)> pages,
) async {
  pw.ThemeData theme;
  try {
    final f = pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans.ttf'));
    theme = pw.ThemeData.withFont(base: f, bold: f);
  } catch (_) {
    theme = pw.ThemeData.base();
  }
  final doc = pw.Document(
    title: '${recId}_TopoStats',
    creator: 'CCS EEG Studio',
    theme: theme,
  );
  final first = pages.first.$1;
  final sessions = [for (final s in first.sessions) s.name];
  const ink = PdfColor.fromInt(0xFF111827);
  const muted = PdfColor.fromInt(0xFF4B5563);
  const accent = PdfColor.fromInt(0xFF1D4ED8);
  int nSig(TopoSession s) => s.windows.fold<int>(
    0,
    (a, w) => a + (w.significant?.where((x) => x).length ?? 0),
  );
  int nTest(TopoSession s) => s.windows
      .where((w) => w.hasStats)
      .fold<int>(0, (a, w) => a + (w.significant?.length ?? 0));
  final st = first.settings;
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape.copyWith(
        marginLeft: 36,
        marginRight: 36,
        marginTop: 30,
        marginBottom: 30,
      ),
      build: (ctx) => [
        pw.Text(
          '$recId · TopoStats',
          style: pw.TextStyle(
            fontSize: 18,
            color: ink,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        pw.SizedBox(height: 4),
        pw.Text(
          'Baseline ${first.baselineName} [${pyFloat(first.baselineTmin)}–${pyFloat(first.baselineTmax)} min] · '
          '${pyFloat(st.segmentDurationMin)}-min windows · e-TFCE (${st.nPermutations} permutations, '
          'seed ${st.randomSeed}) + BH-FDR (${st.fdrScope}), alpha = ${pyFloat(st.alpha)}',
          style: const pw.TextStyle(fontSize: 9, color: muted),
        ),
        pw.SizedBox(height: 12),
        pw.Text(
          'Significant channel-windows vs baseline (of those tested)',
          style: pw.TextStyle(
            fontSize: 11,
            color: accent,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        pw.SizedBox(height: 4),
        pw.TableHelper.fromTextArray(
          headers: ['Feature', ...sessions, 'Colour ±'],
          data: [
            for (final (r, _, _, _) in pages)
              [
                r.settings.feature,
                for (final s in r.sessions) '${nSig(s)} / ${nTest(s)}',
                r.vmax.toStringAsFixed(2),
              ],
          ],
          headerStyle: pw.TextStyle(
            fontSize: 8,
            color: PdfColors.white,
            fontWeight: pw.FontWeight.bold,
          ),
          headerDecoration: const pw.BoxDecoration(color: accent),
          cellStyle: const pw.TextStyle(fontSize: 8, color: ink),
          oddRowDecoration: const pw.BoxDecoration(
            color: PdfColor.fromInt(0xFFF3F4F6),
          ),
          cellAlignment: pw.Alignment.centerRight,
          cellAlignments: {0: pw.Alignment.centerLeft},
          cellPadding: const pw.EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 2.5,
          ),
          border: null,
        ),
        pw.SizedBox(height: 8),
        pw.Text(
          'One page per feature follows (same figure as the PNG). Full per-channel '
          't, p, q and significance values: ${recId}_TopoStats_stats.csv.',
          style: const pw.TextStyle(fontSize: 8.5, color: muted),
        ),
      ],
    ),
  );
  for (final (_, png, wIn, hIn) in pages) {
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(wIn * 72, hIn * 72, marginAll: 0),
        build: (ctx) => pw.Image(pw.MemoryImage(png), fit: pw.BoxFit.fill),
      ),
    );
  }
  return doc.save();
}
