import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'recording_storage.dart';

String recordingDialogStem(String filename) => filename.replaceFirst(
  RegExp(
    r'(?:\.(?:edf|fif|ccseeg|json|vhdr|set|mat|orb|xdf))+$',
    caseSensitive: false,
  ),
  '',
);

/// Native save panels append their selected type. Do not supply it twice.
Future<String?> saveRecordingDialog(
  BuildContext context, {
  required String dialogTitle,
  required String fileName,
  FileType? type,
  List<String>? allowedExtensions,
}) async {
  final picked = await FilePicker.saveFile(
    dialogTitle: dialogTitle,
    fileName: recordingDialogStem(fileName),
    type: FileType.custom,
    allowedExtensions: [RecordingStorage.extension],
  );
  if (picked == null) return null;
  final canonical = RecordingStorage.withExtension(picked);
  if (canonical != picked && File(canonical).existsSync()) {
    if (!context.mounted) return null;
    final replace = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Replace existing recording?'),
        content: Text(canonical),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    if (replace != true) return null;
  }
  return canonical;
}
