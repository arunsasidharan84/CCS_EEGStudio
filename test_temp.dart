import 'dart:io';
import 'lib/src/feature_plotter.dart';

void main() async {
  final dir = Directory('/Users/arunsasidharan/EEGdata/ThukdamStudy/20260709');
  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.features.csv')).toList();
  files.sort((a, b) => a.path.compareTo(b.path));
  
  final saved = await generateFeaturePlots(
    csvPaths: files.map((f) => f.path).toList(),
    outputDir: '.',
    options: PlotOptions(
      nTopoWindows: 10,
      smoothingWindow: 3,
    ),
  );
  print('Saved files:');
}
