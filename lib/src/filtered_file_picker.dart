import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

bool matchesFilename(String path, String patterns) {
  final name = path.split(RegExp(r'[\\/]')).last;
  return patterns.split(';').where((s) => s.trim().isNotEmpty).any((pattern) {
    final regex = pattern
        .trim()
        .split('')
        .map(
          (c) => c == '*'
              ? '.*'
              : c == '?'
              ? '.'
              : RegExp.escape(c),
        )
        .join();
    return RegExp('^$regex\$', caseSensitive: false).hasMatch(name);
  });
}

Future<FilePickerResult?> pickFilteredFiles(
  BuildContext context, {
  bool allowMultiple = false,
  FileType type = FileType.custom,
  List<String>? allowedExtensions,
  String? dialogTitle,
}) async {
  final pattern = TextEditingController(text: '*');
  var paths = <String>[];
  final selected = <String>{};
  String? error;
  final result = await showDialog<List<String>>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(dialogTitle ?? 'Open files'),
        content: SizedBox(
          width: 600,
          height: 420,
          child: Column(
            children: [
              TextField(
                controller: pattern,
                decoration: const InputDecoration(
                  labelText: 'Filename wildcard',
                  hintText: '*Rest*.edf; *Task*.edf',
                ),
                onChanged: (_) => setState(() {}),
              ),
              Row(
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Browse files'),
                    onPressed: () async {
                      final pick = await FilePicker.pickFiles(
                        allowMultiple: allowMultiple,
                        type: type,
                        allowedExtensions: allowedExtensions,
                      );
                      if (pick != null && context.mounted)
                        setState(() {
                          paths = pick.files
                              .map((f) => f.path)
                              .whereType<String>()
                              .toList();
                          selected
                            ..clear()
                            ..addAll(paths);
                        });
                    },
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.folder),
                    label: const Text('Browse folder'),
                    onPressed: () async {
                      final directory = await FilePicker.getDirectoryPath();
                      if (directory == null) return;
                      try {
                        final found =
                            Directory(directory)
                                .listSync()
                                .whereType<File>()
                                .map((f) => f.path)
                                .where(
                                  (p) =>
                                      allowedExtensions == null ||
                                      allowedExtensions.any(
                                        (ext) => p.toLowerCase().endsWith(
                                          '.${ext.toLowerCase()}',
                                        ),
                                      ),
                                )
                                .toList()
                              ..sort();
                        if (context.mounted)
                          setState(() {
                            paths = found;
                            selected.clear();
                            error = null;
                          });
                      } catch (e) {
                        if (context.mounted) setState(() => error = '$e');
                      }
                    },
                  ),
                ],
              ),
              if (error != null) Text(error!),
              Expanded(
                child: ListView(
                  children: [
                    for (final p in paths.where(
                      (p) => matchesFilename(p, pattern.text),
                    ))
                      CheckboxListTile(
                        dense: true,
                        title: Text(p.split(RegExp(r'[\\/]')).last),
                        value: selected.contains(p),
                        onChanged: (v) => setState(() {
                          if (!allowMultiple) selected.clear();
                          if (v == true) {
                            selected.add(p);
                          } else {
                            selected.remove(p);
                          }
                        }),
                      ),
                  ],
                ),
              ),
              if (allowMultiple)
                TextButton(
                  onPressed: () => setState(
                    () => selected.addAll(
                      paths.where((p) => matchesFilename(p, pattern.text)),
                    ),
                  ),
                  child: const Text('Select matching files'),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed:
                selected.where((p) => matchesFilename(p, pattern.text)).isEmpty
                ? null
                : () => Navigator.pop(
                    context,
                    paths
                        .where(
                          (p) =>
                              selected.contains(p) &&
                              matchesFilename(p, pattern.text),
                        )
                        .toList(),
                  ),
            child: const Text('Open'),
          ),
        ],
      ),
    ),
  );
  pattern.dispose();
  if (result == null) return null;
  return FilePickerResult([
    for (final p in result)
      PlatformFile(
        name: p.split(RegExp(r'[\\/]')).last,
        path: p,
        size: File(p).lengthSync(),
      ),
  ]);
}
