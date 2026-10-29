import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../models.dart';

/// Portable settings only: recordings and participant paths are never exported.
Map<String, dynamic> erpProtocolJson(AnalysisConfig config) => {
  'schema': 'ccs-erp-protocol-v1',
  'epoch_before_cleaning': config.erpEpochFirst,
  'epoching': {
    'markers': config.stimMarkers,
    'marker_groups': config.stimMarkerGroups,
    'response_rules': config.stimResponseRules,
    'pattern': config.stimPattern,
    'tmin': config.stimTmin,
    'tmax': config.stimTmax,
    'baseline': config.stimBaseline
        ? [config.stimBaselineStart, config.stimBaselineEnd]
        : null,
    'crop_start_marker': config.stimCropMarker,
    'crop_minutes': config.stimCropMinutes,
  },
  'analysis': config.erpAnalysisProtocol,
};

void applyErpProtocol(AnalysisConfig config, Map<String, dynamic> json) {
  if (json['schema'] != 'ccs-erp-protocol-v1')
    throw const FormatException('Unsupported ERP protocol');
  final spec = StimEpochSpec.fromJson(
    Map<String, dynamic>.from(json['epoching'] as Map),
  );
  if (!spec.tmin.isFinite ||
      !spec.tmax.isFinite ||
      spec.tmax <= spec.tmin ||
      (spec.baseline &&
          (spec.baselineStart < spec.tmin ||
              spec.baselineEnd > spec.tmax ||
              spec.baselineStart >= spec.baselineEnd))) {
    throw const FormatException('Invalid trial or baseline window');
  }
  final analysis = Map<String, dynamic>.from(json['analysis'] as Map? ?? {});
  config
    ..erpEpochFirst = json['epoch_before_cleaning'] as bool? ?? false
    ..stimEpochs = true
    ..epochBeforeGedai = false
    ..stimMarkers = spec.markers.toList()
    ..stimMarkerGroups = {
      for (final e in spec.markerGroups.entries) e.key: e.value.toList(),
    }
    ..stimResponseRules = Map<String, dynamic>.from(spec.responseRules)
    ..stimPattern = spec.pattern
    ..stimTmin = spec.tmin
    ..stimTmax = spec.tmax
    ..stimBaseline = spec.baseline
    ..stimBaselineStart = spec.baselineStart
    ..stimBaselineEnd = spec.baselineEnd
    ..stimCropMarker = spec.cropStartMarker
    ..stimCropMinutes = spec.cropMinutes
    ..erpAnalysisProtocol = analysis;
}

class ProtocolTools extends StatelessWidget {
  const ProtocolTools({
    super.key,
    required this.config,
    required this.onChanged,
    this.beforeSave,
  });
  final AnalysisConfig config;
  final VoidCallback onChanged;
  final VoidCallback? beforeSave;
  Future<void> _file(BuildContext context, bool save) async {
    try {
      if (save) {
        beforeSave?.call();
        final path = await FilePicker.saveFile(
          dialogTitle: 'Save epoching and averaging protocol',
          fileName: 'erp.ccsprotocol',
        );
        if (path != null)
          await File(path).writeAsString(
            const JsonEncoder.withIndent('  ').convert(erpProtocolJson(config)),
          );
      } else {
        final pick = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['ccsprotocol', 'json'],
        );
        final path = pick?.files.single.path;
        if (path == null) return;
        applyErpProtocol(
          config,
          Map<String, dynamic>.from(
            jsonDecode(await File(path).readAsString()) as Map,
          ),
        );
        onChanged();
      }
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Protocol: $e')));
    }
  }

  @override
  Widget build(BuildContext context) => Wrap(
    children: [
      Tooltip(
        message:
            'Reuse locking events, named conditions, baseline, task, averaging groups and analysis settings in this recording or the ERP Batch Workspace. Review marker matches for each dataset.',
        child: TextButton.icon(
          onPressed: () => _file(context, false),
          icon: const Icon(Icons.file_open, size: 16),
          label: const Text('Load protocol'),
        ),
      ),
      Tooltip(
        message:
            'Save the shared epoching settings and the most recently configured ERP analysis. No signal data or participant file paths are included.',
        child: TextButton.icon(
          onPressed: () => _file(context, true),
          icon: const Icon(Icons.save_outlined, size: 16),
          label: const Text('Save protocol'),
        ),
      ),
      Tooltip(
        message:
            '1. Select locking events and name condition groups. 2. Set trial and baseline windows. 3. Clean and save event epochs, or save epochs directly. 4. Choose saved groups A/B and a task. 5. Average trials, inspect A/B and B−A, then review measurements and statistics. Batch Workspace uses the same protocol.',
        child: const Padding(
          padding: EdgeInsets.all(10),
          child: Icon(Icons.help_outline, size: 18),
        ),
      ),
    ],
  );
}
