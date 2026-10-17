import 'dart:convert';
import 'dart:io';

/// Extension-only migration. Unknown files and raw vendor recordings are untouched.
class LegacyFileMigration {
  static Future<Map<String, String>> plan(String folder) async {
    final files = (await Directory(
      folder,
    ).list().toList()).whereType<File>().toList();
    final moves = <String, String>{};
    for (final file in files) {
      final path = file.path;
      String? target;
      if (path.endsWith('.preprocessing.json') ||
          path.endsWith('.preparation.json'))
        continue;
      if (path.endsWith('.json')) {
        final handle = await file.open();
        String header;
        try {
          final length = await handle.length();
          final first = await handle.read(4096);
          await handle.setPosition(length > 4096 ? length - 4096 : length);
          header = utf8.decode([
            ...first,
            ...await handle.read(4096),
          ], allowMalformed: true);
        } finally {
          await handle.close();
        }
        if (RegExp(r'"format"\s*:\s*"ccseeg-v1"').hasMatch(header)) {
          target = path.replaceFirst(
            RegExp(r'(?:\.(?:ccseeg|json))+$'),
            '.ccseeg',
          );
        } else if (header.contains('"ccs-erp-protocol-v1"')) {
          target = path.replaceFirst(
            RegExp(r'(?:\.protocol)?\.json$'),
            '.ccsprotocol',
          );
        } else if (header.contains('"ccs-erp-workbench-v1"')) {
          target = path.replaceFirst(RegExp(r'\.json$'), '.ccserp');
        }
      } else if (RegExp(r'(?:\.ccseeg){2,}$').hasMatch(path)) {
        target = path.replaceFirst(RegExp(r'(?:\.ccseeg)+$'), '.ccseeg');
      }
      if (target != null && target != path) moves[path] = target;
    }
    for (final file in files) {
      for (final pair in [
        ('.preprocessing.json', '.ccshistory'),
        ('.preparation.json', '.ccspreparation'),
        ('.analysis.json', '.ccsanalysis'),
      ]) {
        if (file.path.endsWith(pair.$1)) {
          final source = file.path.substring(
            0,
            file.path.length - pair.$1.length,
          );
          moves[file.path] = '${moves[source] ?? source}${pair.$2}';
        }
      }
    }
    if (moves.values.toSet().length != moves.length)
      throw const FormatException(
        'Duplicate target filenames; resolve duplicates first.',
      );
    for (final target in moves.values) {
      if (await File(target).exists())
        throw FormatException(
          'Would overwrite $target. No files were changed.',
        );
    }
    return moves;
  }

  static Future<void> apply(String folder, Map<String, String> moves) async {
    final manifest = File('$folder/legacy_names.ccsmigration');
    if (await manifest.exists())
      throw const FormatException('A migration manifest already exists.');
    // Recheck before mutation, including collisions introduced since preview.
    for (final entry in moves.entries) {
      if (!await File(entry.key).exists() || await File(entry.value).exists())
        throw const FormatException(
          'Files changed since preview. Review the folder again.',
        );
    }
    await manifest.writeAsString(
      jsonEncode({'schema': 'ccs-name-migration-v1', 'renames': moves}),
    );
    final done = <MapEntry<String, String>>[];
    try {
      for (final entry in moves.entries) {
        await File(entry.key).rename(entry.value);
        done.add(entry);
      }
    } catch (_) {
      for (final entry in done.reversed) {
        await File(entry.value).rename(entry.key);
      }
      await manifest.delete();
      rethrow;
    }
    for (final path in moves.values.where(
      (p) => [
        '.ccshistory',
        '.ccspreparation',
        '.ccsprotocol',
        '.ccserp',
        '.ccsanalysis',
      ].any(p.endsWith),
    )) {
      final file = File(path);
      String normalise(String value) {
        final path = value.replaceAll('\\', '/');
        return Platform.isWindows ? path.toLowerCase() : path;
      }

      final references = {
        for (final e in moves.entries) normalise(e.key): e.value,
      };
      dynamic rewrite(dynamic value) {
        if (value is String) return references[normalise(value)] ?? value;
        if (value is List) return value.map(rewrite).toList();
        if (value is Map)
          return value.map(
            (key, item) => MapEntry(key.toString(), rewrite(item)),
          );
        return value;
      }

      await file.writeAsString(
        jsonEncode(rewrite(jsonDecode(await file.readAsString()))),
      );
    }
  }
}
