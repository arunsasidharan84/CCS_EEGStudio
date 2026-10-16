import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'workbench_figures.dart';

Future<String> writeErpWorkbenchReport(
  Map<String, dynamic> result,
  String output,
) async {
  final font = pw.Font.ttf(
    await rootBundle.load('assets/fonts/DejaVuSans.ttf'),
  );
  final doc = pw.Document(
    title: 'ERP analysis report',
    creator: 'CCS EEG Studio',
    theme: pw.ThemeData.withFont(base: font, bold: font),
  );
  final groups = (result['groups'] as List? ?? []).map(erpMap).toList();
  final files = (result['files'] as List? ?? []).map(erpMap).toList();
  final failures = (result['failures'] as List? ?? []).map(erpMap).toList();
  const blue = PdfColor.fromInt(0xFF1D4ED8),
      muted = PdfColor.fromInt(0xFF64748B);
  String f(dynamic value, [int digits = 3]) =>
      value is num ? value.toStringAsFixed(digits) : 'not available';
  pw.Widget note(String text) =>
      pw.Text(text, style: const pw.TextStyle(fontSize: 9, color: muted));
  pw.Widget title(String text) => pw.Text(
    text,
    style: pw.TextStyle(
      fontSize: 20,
      color: blue,
      fontWeight: pw.FontWeight.bold,
    ),
  );
  pw.Widget table(List<List<String>> data) => pw.TableHelper.fromTextArray(
    data: data,
    headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
    cellStyle: const pw.TextStyle(fontSize: 9),
    headerDecoration: const pw.BoxDecoration(
      color: PdfColor.fromInt(0xFFEFF6FF),
    ),
    cellPadding: const pw.EdgeInsets.all(5),
  );
  pw.Widget footer(pw.Context context) => pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    children: [
      note('CCS EEG Studio | ERP workbench'),
      note('${context.pageNumber} / ${context.pagesCount}'),
    ],
  );
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(30),
      footer: footer,
      build: (_) => [
        title('ERP analysis overview'),
        pw.SizedBox(height: 12),
        pw.Text(
          '${files.length} recordings analysed | ${groups.length} components | ${failures.length} files needing attention',
          style: const pw.TextStyle(fontSize: 13),
        ),
        pw.SizedBox(height: 14),
        table([
          ['Component', 'Participants', 'Recordings', 'Inference'],
          for (final g in groups)
            [
              '${g['task']}',
              '${g['n_subjects']}',
              '${g['n_files']}',
              (g['n_subjects'] as num? ?? 0) > 1
                  ? 'Paired subject-level'
                  : 'Descriptive only',
            ],
        ]),
        pw.SizedBox(height: 14),
        note(
          'Suggestions and event classes were reviewed in the workbench. Presets are starting points, not a claim of reproducing every ERP CORE preprocessing or behavioral exclusion. No extra filtering or monitor-delay correction is silently applied.',
        ),
        pw.SizedBox(height: 8),
        note(
          'Mean amplitudes use the sample mean in the reviewed window; signed/positive/negative AUC use trapezoids (µV s). Peak and fractional latency definitions are in the methods documentation. Difference-wave measurements are measured on B minus A, not obtained by subtracting condition peak latencies.',
        ),
        pw.SizedBox(height: 8),
        note(
          'Group inference uses participants, averaging repeated recordings within participant. The shaded difference band is between-participant SEM. Max-|t| sign-flip correction controls the reported channel or channel-time family; TANOVA compares normalized component-window maps. Measurement p values have within-component BH-FDR q values. Trial-level details and all model coefficients remain in the CSV/JSON exports.',
        ),
        if (failures.isNotEmpty) ...[
          pw.SizedBox(height: 14),
          pw.Text(
            'Files needing attention',
            style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
          ),
          for (final failure in failures.take(8))
            note(
              '${failure['path'].toString().split(RegExp(r'[\\/]')).last}: ${failure['error']}',
            ),
          if (failures.length > 8)
            note('All failures are listed in erp_results.json.'),
        ],
        pw.SizedBox(height: 18),
        note(
          'References: Kappenman et al. (2021), ERP CORE, doi:10.1016/j.neuroimage.2020.117465. Ehinger & Dimigen (2019), Unfold, doi:10.7717/peerj.7838. The native overlap model implements sparse FIR/stick-basis least squares; it is not the entire Unfold toolbox. Decoding uses purged blocked CV and train-fold scaling; scores alone do not establish above-chance significance.',
        ),
      ],
    ),
  );
  for (final g in groups) {
    final wave = await erpPainterPng(
      ErpWorkbenchWavePainter(g),
      width: 1350,
      height: 480,
    );
    final topo = await erpPainterPng(
      ErpWorkbenchTopoPainter(g),
      width: 450,
      height: 450,
    );
    final profile = erpMap(g['profile']);
    final window = erpNumbers(profile['window']),
        baseline = erpNumbers(profile['baseline']);
    final taskFiles = files.where((f) => f['task'] == g['task']).toList();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(28),
        footer: footer,
        build: (_) => [
          title(
            '${g['component_name'] ?? g['task']} | ${g['n_subjects']} participants',
          ),
          pw.SizedBox(height: 5),
          note(
            'ROI ${(profile['roi'] as List? ?? []).join(', ')} | baseline ${(baseline.first * 1000).round()} to ${(baseline.last * 1000).round()} ms | window ${(window.first * 1000).round()} to ${(window.last * 1000).round()} ms | negative up',
          ),
          pw.SizedBox(height: 8),
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(flex: 3, child: pw.Image(pw.MemoryImage(wave))),
              pw.SizedBox(width: 8),
              pw.Expanded(child: pw.Image(pw.MemoryImage(topo))),
            ],
          ),
          if (g['grand_difference_measurements'] is Map) ...[
            pw.SizedBox(height: 7),
            note(
              'Grand-average difference wave (descriptive): mean ${f(erpMap(g['grand_difference_measurements'])['mean'])} µV; peak ${f(erpMap(g['grand_difference_measurements'])['peak_amplitude'])} µV at ${f((erpMap(g['grand_difference_measurements'])['peak_latency'] as num) * 1000, 1)} ms; 50% area ${f(erpMap(g['grand_difference_measurements'])['fractional_area_latency'] is num ? (erpMap(g['grand_difference_measurements'])['fractional_area_latency'] as num) * 1000 : null, 1)} ms.',
            ),
          ],
          pw.SizedBox(height: 10),
          table([
            [
              'Measure (B - A across paired participants)',
              'N',
              'Mean difference',
              'p',
              'q (FDR)',
            ],
            for (final s
                in (g['statistics'] as List? ?? [])
                    .map(erpMap)
                    .where((s) => (s['n_subjects'] as num? ?? 0) > 0))
              [
                {
                      'mean': 'Mean amplitude (µV)',
                      'signed_auc': 'Signed AUC (µV s)',
                      'peak_amplitude': 'Peak amplitude (µV)',
                      'peak_latency': 'Peak latency (ms)',
                      'fractional_area_latency': '50% area latency (ms)',
                    }[s['metric']] ??
                    '${s['metric']}',
                '${s['n_subjects']}',
                f(
                  s['mean_difference'] is num &&
                          s['metric'].toString().endsWith('latency')
                      ? (s['mean_difference'] as num) * 1000
                      : s['mean_difference'],
                ),
                s['p'] is num && (s['p'] as num) < .001 ? '<.001' : f(s['p']),
                s['q_fdr'] is num && (s['q_fdr'] as num) < .001
                    ? '<.001'
                    : f(s['q_fdr']),
              ],
          ]),
          pw.SizedBox(height: 8),
          note(
            'Topography: component-window B - A; rings indicate max-|t|-corrected p <= .05. TANOVA GMD ${f(g['tanova_gmd'])}, p ${f(g['tanova_p'])}. ${g['permutation_patterns']} sign patterns. ${g['warning']}',
          ),
          if (profile['lateralized'] == true)
            note(
              'Lateralized ERP: ipsilateral/contralateral ROI traces, canonical left-event scalp alignment. Maps are contra minus homologous ipsi (antisymmetric); decoding/regression use original physical left/right classes.',
            ),
          pw.SizedBox(height: 8),
          note(
            'Accepted event counts by recording: ${taskFiles.take(10).map((f) => '${f['subject']}: ${f['n_a']}/${f['n_b']}').join(' | ')}${taskFiles.length > 10 ? ' | full counts in JSON' : ''}. ${taskFiles.fold<int>(0, (n, f) => n + (f['rejected_behavior'] as int) + (f['rejected_boundary'] as int) + (f['rejected_amplitude'] as int))} events excluded by behavior, boundaries, or amplitude.',
          ),
        ],
      ),
    );
    final advanced = taskFiles
        .where(
          (f) =>
              f['regression'] != null ||
              f['deconvolution'] != null ||
              f['decoding'] != null,
        )
        .toList();
    if (advanced.isNotEmpty) {
      final first = advanced.first;
      final decoding = erpMap(first['decoding']);
      final png = decoding.isNotEmpty
          ? await erpPainterPng(
              ErpWorkbenchWavePainter(decoding, decode: true),
              width: 1300,
              height: 400,
            )
          : null;
      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.all(30),
          footer: footer,
          build: (_) => [
            title('${g['task']} | advanced analyses'),
            pw.SizedBox(height: 10),
            table([
              [
                'Recording / participant',
                'rERP',
                'Overlap correction',
                'Decoding usable folds',
              ],
              for (final f0 in advanced.take(12))
                [
                  '${f0['subject']}',
                  f0['regression'] != null ? 'OLS fitted' : 'off',
                  f0['deconvolution'] != null ? 'FIR/LSQR fitted' : 'off',
                  '${erpMap(f0['decoding'])['folds_used'] ?? 'off'}',
                ],
            ]),
            pw.SizedBox(height: 12),
            if (png != null) ...[
              pw.Text(
                'Representative participant ${first['subject']} | time-resolved decoding',
                style: const pw.TextStyle(fontSize: 12),
              ),
              pw.Image(pw.MemoryImage(png), height: 215),
              note(
                'AUC and balanced accuracy use original physical event classes. Purged blocked CV avoids shared epoch samples across train/test; all scaling/covariance fitting is training-only. No permutation-based decoding p value is supplied.',
              ),
            ],
            note(
              'rERP exports intercept, class effect, centered RT (when complete), and any numeric trial metadata predictors at every channel/time bin. Overlap correction fits continuous data with class events and other stimulus/response nuisance events. Inspect convergence, event counts and coefficients in the Models tab and erp_results.json. Conventional trial exclusions do not mask the continuous overlap model; its population/design must be reviewed separately.',
            ),
          ],
        ),
      );
    }
  }
  final file = File('$output/erp_report.pdf');
  await file.writeAsBytes(await doc.save());
  return file.path;
}
