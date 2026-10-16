import 'package:flutter/material.dart';
import '../models.dart';
import 'erp_workbench_view.dart';

/// Interactive ERP consumes the active saved trials. Multi-file work lives in Batch Workspace.
class ErpAnalysisView extends StatelessWidget {
  const ErpAnalysisView({
    super.key,
    this.activeRecording,
    this.config,
    this.extraFiles = const [],
    this.onPrepare,
    this.onOpenBatch,
  });
  final EegRecording? activeRecording;
  final AnalysisConfig? config;
  final List<String> extraFiles;
  final VoidCallback? onPrepare, onOpenBatch;
  @override
  Widget build(BuildContext context) => ErpWorkbenchView(
    activeRecording: activeRecording,
    config: config,
    batchMode: false,
    onPrepare: onPrepare,
    onOpenBatch: onOpenBatch,
  );
}
