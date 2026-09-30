// lib/src/topostats/topostats_runner.dart
//
// Runs the (CPU-heavy) e-TFCE pipeline in a background isolate so the UI
// stays responsive, streaming progress back.

import 'dart:async';
import 'dart:isolate';

import 'topostats_engine.dart';

class TopoStatsJob {
  TopoStatsJob._(this._isolate, this.results, this._cancel);
  final Isolate _isolate;
  final Stream<TopoStatsResult> results;
  final void Function() _cancel;
  void cancel() {
    _cancel();
    _isolate.kill(priority: Isolate.immediate);
  }
}

/// Computes one feature in a background isolate.
Future<TopoStatsResult> runTopoStats({
  required List<String> files,
  required TopoStatsSettings settings,
  TopoProgress? onProgress,
}) async {
  final job = await startTopoStatsJob(
    files: files,
    settings: settings,
    features: [settings.feature],
    onProgress: onProgress,
  );
  return job.results.first;
}

/// Computes several features (files parsed once), yielding each result as
/// soon as it is ready. Errors for individual features are reported through
/// [onFeatureError] and do not stop the job.
Future<TopoStatsJob> startTopoStatsJob({
  required List<String> files,
  required TopoStatsSettings settings,
  required List<String> features,
  TopoProgress? onProgress,
  void Function(String feature, String error)? onFeatureError,
}) async {
  final rp = ReceivePort();
  final ctrl = StreamController<TopoStatsResult>();
  final exitPort = ReceivePort();
  final errPort = ReceivePort();
  final iso = await Isolate.spawn<List<Object?>>(
    _entry,
    [rp.sendPort, files, settings, features],
    errorsAreFatal: true,
    onExit: exitPort.sendPort,
    onError: errPort.sendPort,
  );
  var closed = false;
  void close() {
    if (closed) return;
    closed = true;
    rp.close();
    exitPort.close();
    errPort.close();
    ctrl.close();
  }

  errPort.listen((e) {
    if (closed) return;
    final msg = e is List && e.isNotEmpty ? '${e.first}' : '$e';
    ctrl.addError(TopoStatsException('Statistics worker crashed: $msg'));
    close();
  });
  // Safety net: if the worker dies without saying 'done', finish the stream
  // (after letting any in-flight result messages arrive).
  exitPort.listen((_) {
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      if (!closed) {
        if (features.length == 1) {
          ctrl.addError(
            TopoStatsException('Statistics worker stopped unexpectedly.'),
          );
        }
        close();
      }
    });
  });

  rp.listen((msg) {
    final m = msg as List;
    switch (m[0]) {
      case 'p':
        onProgress?.call(m[1] as double, m[2] as String);
      case 'r':
        ctrl.add(m[1] as TopoStatsResult);
      case 'fe':
        onFeatureError?.call(m[1] as String, m[2] as String);
        if (features.length == 1)
          ctrl.addError(TopoStatsException(m[2] as String));
      case 'e':
        ctrl.addError(TopoStatsException(m[1] as String));
        close();
      case 'done':
        close();
    }
  });
  return TopoStatsJob._(iso, ctrl.stream, close);
}

void _entry(List<Object?> args) {
  final send = args[0] as SendPort;
  final files = (args[1] as List).cast<String>();
  final settings = args[2] as TopoStatsSettings;
  final features = (args[3] as List).cast<String>();
  try {
    Map<String, ParsedSession>? parsed;
    if (features.length > 1) {
      parsed = {};
      for (var i = 0; i < files.length; i++) {
        send.send([
          'p',
          0.05 * i / files.length,
          'Reading ${files[i].split(RegExp(r'[\\/]')).last}…',
        ]);
        parsed[files[i]] = parseFeatureCsv(
          files[i],
          features,
          settings.channels,
        );
      }
    }
    for (var fi = 0; fi < features.length; fi++) {
      final f = features[fi];
      try {
        final r = computeTopoStats(
          files: files,
          settings: settings.copyWith(feature: f),
          parsed: parsed,
          onProgress: (p, msg) {
            final overall = features.length == 1
                ? p
                : 0.05 + 0.95 * (fi + p) / features.length;
            send.send(['p', overall, features.length == 1 ? msg : '[$f] $msg']);
          },
        );
        send.send(['r', r]);
      } catch (e) {
        send.send(['fe', f, e.toString()]);
      }
    }
    send.send(['done']);
  } catch (e) {
    send.send(['e', e.toString()]);
  }
}
