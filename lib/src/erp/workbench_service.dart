import 'dart:convert';
import 'dart:io';
import '../extraction_service.dart';

class ErpWorkbenchService {
  Process? _process;
  void cancel() => _process?.kill();
  Future<Map<String, dynamic>> execute(
    List<Map<String, dynamic>> inputs,
    Map<String, dynamic> options,
    String output, {
    bool inspect = false,
    void Function(double, String)? progress,
  }) async {
    final temp = await Directory.systemTemp.createTemp('ccs_erp_workbench_');
    try {
      final job = File('${temp.path}/job.json');
      await job.writeAsString(
        jsonEncode({
          'job_type': inspect ? 'inspect_erp' : 'erp_workbench',
          'inputs': inputs,
          'output': output,
          'options': options,
        }),
      );
      if (inspect) {
        final result = await Process.run(ExtractionService.findEngine(), [
          job.path,
        ]);
        if (result.exitCode != 0) throw StateError('${result.stderr}');
        return Map<String, dynamic>.from(jsonDecode('${result.stdout}') as Map);
      }
      final process = await Process.start(ExtractionService.findEngine(), [
        job.path,
      ]);
      _process = process;
      final done = process.stdout.drain<void>();
      final errors = <String>[];
      final stderr = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.startsWith('PROGRESS ')) {
              final fields = line.split(' ');
              progress?.call(
                (double.tryParse(fields[1]) ?? 0) / 100,
                fields.skip(2).join(' '),
              );
            } else {
              errors.add(line);
            }
          });
      final code = await process.exitCode;
      await done;
      await stderr.cancel();
      _process = null;
      if (code != 0)
        throw StateError(
          errors.isEmpty ? 'ERP engine stopped' : errors.join('\n'),
        );
      return Map<String, dynamic>.from(
        jsonDecode(
              await File(
                await File('$output/erp_results.ccserp').exists()
                    ? '$output/erp_results.ccserp'
                    : '$output/erp_results.json',
              ).readAsString(),
            )
            as Map,
      );
    } finally {
      if (await temp.exists()) await temp.delete(recursive: true);
    }
  }
}

/// Prefer cleaned counterparts, preserve subject/task pairs, skip resource forks.
List<String> discoverErpRecordings(String directory, {int firstSubjects = 0}) {
  final paths = Directory(directory)
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .map((f) => f.path)
      .where(
        (p) =>
            !p.split(Platform.pathSeparator).last.startsWith('._') &&
            (p.toLowerCase().endsWith('.edf') ||
                p.toLowerCase().endsWith('.fif') ||
                (p.toLowerCase().endsWith('.ccseeg.json') ||
                    p.toLowerCase().endsWith('.ccseeg'))),
      )
      .toList();
  final existing = paths.toSet();
  final chosen = paths
      .where(
        (p) =>
            !p.toLowerCase().endsWith('.edf') ||
            p.toLowerCase().endsWith('.fif') ||
            p.toLowerCase().endsWith('_cleaned.edf') ||
            !existing.contains(
              p.replaceFirst(
                RegExp(r'\.edf$', caseSensitive: false),
                '_cleaned.edf',
              ),
            ),
      )
      .toList();
  chosen.sort((a, b) {
    final x = int.tryParse(
          a.split(Platform.pathSeparator).last.split('_').first,
        ),
        y = int.tryParse(b.split(Platform.pathSeparator).last.split('_').first);
    if (x != null && y != null && x != y) return x.compareTo(y);
    return a.compareTo(b);
  });
  if (firstSubjects <= 0) return chosen;
  final subjects = <String>{};
  return chosen.where((p) {
    final subject = p.split(Platform.pathSeparator).last.split('_').first;
    if (subjects.contains(subject)) return true;
    if (subjects.length >= firstSubjects) return false;
    subjects.add(subject);
    return true;
  }).toList();
}
