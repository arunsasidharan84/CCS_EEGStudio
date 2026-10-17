/// Stable names distinguish continuous, event-epoched and cleaned recordings.
String erpOutputName(
  String path, {
  required bool epoched,
  bool cleaned = false,
  String extension = 'ccseeg',
}) {
  var stem = path.split(RegExp(r'[/\\]')).last;
  stem = stem.replaceFirst(
    RegExp(
      r'(?:\.(?:json|ccseeg|edf|set|vhdr|fif|mat|orb))+$',
      caseSensitive: false,
    ),
    '',
  );
  stem = stem.replaceFirst(
    RegExp(r'(?:[-_]epo(?:ched)?|_clean)+$', caseSensitive: false),
    '',
  );
  return '$stem${epoched ? '-epo' : ''}${cleaned ? '_clean' : ''}.$extension';
}
