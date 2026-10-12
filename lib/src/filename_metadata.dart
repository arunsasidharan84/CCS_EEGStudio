/// Filename metadata is descriptive: no demographic/clinical fields are guessed.
List<Map<String, String>> inferFilenameMetadata(
  Iterable<String> names, {
  String? pattern,
}) {
  final custom = pattern == null || pattern.trim().isEmpty
      ? null
      : RegExp(pattern);
  const fields = {
    'sub': 'Subject',
    'ses': 'Session',
    'task': 'Task',
    'run': 'Run',
    'acq': 'Acquisition',
  };
  return names.toSet().map((name) {
    final row = <String, String>{'filename': name};
    if (custom != null) {
      final match = custom.firstMatch(name);
      if (match != null) {
        for (final key in match.groupNames) {
          final value = match.namedGroup(key);
          if (value != null && value.isNotEmpty && key != 'filename')
            row[key] = value;
        }
      }
    } else {
      for (final match in RegExp(
        r'(?:^|_)(sub|ses|task|run|acq)-([^_]+)',
      ).allMatches(name)) {
        row[fields[match[1]]!] = match[2]!;
      }
      final legacy = RegExp(
        r'^(Sub\d+)_',
        caseSensitive: false,
      ).firstMatch(name);
      if (!row.containsKey('Subject') && legacy != null)
        row['Subject'] = legacy[1]!;
    }
    return row;
  }).toList();
}

String filenameMetadataCsv(List<Map<String, String>> rows) {
  final cols = <String>{
    'filename',
    for (final row in rows) ...row.keys,
  }.toList();
  String quote(String value) => '"${value.replaceAll('"', '""')}"';
  return '${cols.map(quote).join(',')}\n${rows.map((row) => cols.map((col) => quote(row[col] ?? '')).join(',')).join('\n')}\n';
}
