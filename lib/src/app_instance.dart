import 'dart:io';

/// macOS Launch Services needs -n to open an independent application process.
({String executable, List<String> arguments}) instanceLaunchCommand(
  String operatingSystem,
  String executable,
) {
  if (operatingSystem == 'macos') {
    final marker = executable.lastIndexOf('.app/Contents/MacOS/');
    if (marker >= 0) {
      return (
        executable: '/usr/bin/open',
        arguments: ['-n', executable.substring(0, marker + 4)],
      );
    }
  }
  return (executable: executable, arguments: const []);
}

Future<void> openAppInstance() async {
  final command = instanceLaunchCommand(
    Platform.operatingSystem,
    Platform.resolvedExecutable,
  );
  if (command.executable == '/usr/bin/open') {
    final result = await Process.run(command.executable, command.arguments);
    if (result.exitCode != 0) {
      throw ProcessException(
        command.executable,
        command.arguments,
        result.stderr.toString(),
        result.exitCode,
      );
    }
  } else {
    await Process.start(
      command.executable,
      command.arguments,
      mode: ProcessStartMode.detached,
    );
  }
}
