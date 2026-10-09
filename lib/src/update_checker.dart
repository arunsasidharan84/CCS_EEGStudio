import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

const _repoOwner = 'arunsasidharan84';
const _repoName = 'CCS_EEGStudio';

enum UpdatePlatform { macOS, windows, linuxDebian, linuxRpm }

class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.sizeBytes,
  });

  final String name;
  final String downloadUrl;
  final int sizeBytes;
}

class UpdateInfo {
  const UpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.hasUpdate,
    required this.releaseNotes,
    required this.releaseUrl,
    required this.asset,
  });

  final String currentVersion;
  final String latestVersion;
  final bool hasUpdate;
  final String releaseNotes;
  final String releaseUrl;
  final ReleaseAsset? asset;
}

class UpdateChecker {
  static int compareVersions(String first, String second) {
    List<int> parts(String value) {
      final match = RegExp(r'\d+(?:\.\d+){0,3}').firstMatch(value);
      return (match?.group(0) ?? '0')
          .split('.')
          .map((part) => int.tryParse(part) ?? 0)
          .toList();
    }

    final a = parts(first);
    final b = parts(second);
    final length = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < length; i++) {
      final av = i < a.length ? a[i] : 0;
      final bv = i < b.length ? b[i] : 0;
      if (av != bv) return av.compareTo(bv);
    }
    return 0;
  }

  static UpdatePlatform get currentPlatform {
    if (Platform.isMacOS) return UpdatePlatform.macOS;
    if (Platform.isWindows) return UpdatePlatform.windows;
    try {
      final osRelease = File(
        '/etc/os-release',
      ).readAsStringSync().toLowerCase();
      const rpmFamilies = [
        'fedora',
        'rhel',
        'centos',
        'rocky',
        'almalinux',
        'opensuse',
        'suse',
      ];
      if (rpmFamilies.any(
        (family) =>
            osRelease.contains('id=$family') ||
            osRelease.contains('id_like=$family') ||
            osRelease.contains('id_like="$family'),
      )) {
        return UpdatePlatform.linuxRpm;
      }
    } on FileSystemException {
      // Debian packages remain the safest default when distro metadata is
      // unavailable (for example in a constrained desktop sandbox).
    }
    return UpdatePlatform.linuxDebian;
  }

  static ReleaseAsset? findAsset(
    List<dynamic> assets, {
    UpdatePlatform? platform,
  }) {
    final target = platform ?? currentPlatform;
    ReleaseAsset? fallback;
    for (final raw in assets) {
      if (raw is! Map<String, dynamic>) continue;
      final originalName = raw['name'] as String? ?? '';
      final name = originalName.toLowerCase();
      final url = raw['browser_download_url'] as String? ?? '';
      if (url.isEmpty) continue;
      final asset = ReleaseAsset(
        name: originalName,
        downloadUrl: url,
        sizeBytes: (raw['size'] as num?)?.toInt() ?? 0,
      );
      switch (target) {
        case UpdatePlatform.macOS:
          if (name == 'ccseegstudio-macos.zip') return asset;
          if (name.endsWith('.zip') && name.contains('mac')) fallback ??= asset;
        case UpdatePlatform.windows:
          if (name == 'ccseegstudio-installer.exe') return asset;
          if (name.endsWith('.exe')) fallback ??= asset;
        case UpdatePlatform.linuxDebian:
          if (name == 'ccseegstudio-linux-amd64.deb') return asset;
          if (name.endsWith('.deb')) fallback ??= asset;
        case UpdatePlatform.linuxRpm:
          if (name == 'ccseegstudio-linux-x86_64.rpm') return asset;
          if (name.endsWith('.rpm')) fallback ??= asset;
      }
    }
    return fallback;
  }

  static Future<UpdateInfo> check() async {
    final package = await PackageInfo.fromPlatform();
    final currentVersion = package.version;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.getUrl(
        Uri.https('api.github.com', '/repos/$_repoOwner/$_repoName/releases', {
          'per_page': '30',
        }),
      );
      request.headers
        ..set(HttpHeaders.userAgentHeader, 'CCS-EEGStudio-Updater')
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'GitHub returned HTTP ${response.statusCode}',
          uri: request.uri,
        );
      }
      final releases = jsonDecode(body) as List<dynamic>;
      final candidates =
          releases.whereType<Map<String, dynamic>>().where((release) {
            final tag = release['tag_name'] as String? ?? '';
            return release['draft'] != true &&
                RegExp(r'^v?\d+\.\d+\.\d+').hasMatch(tag);
          }).toList()..sort(
            (a, b) => compareVersions(
              b['tag_name'] as String? ?? '',
              a['tag_name'] as String? ?? '',
            ),
          );
      if (candidates.isEmpty) {
        throw const FormatException(
          'No versioned CCS EEG Studio release was found.',
        );
      }
      final latest = candidates.first;
      final tag = latest['tag_name'] as String? ?? '';
      final latestVersion = tag.startsWith('v') ? tag.substring(1) : tag;
      return UpdateInfo(
        currentVersion: currentVersion,
        latestVersion: latestVersion,
        hasUpdate: compareVersions(latestVersion, currentVersion) > 0,
        releaseNotes: (latest['body'] as String?)?.trim().isNotEmpty == true
            ? (latest['body'] as String).trim()
            : 'No release notes were provided.',
        releaseUrl: latest['html_url'] as String? ?? '',
        asset: findAsset(latest['assets'] as List<dynamic>? ?? const []),
      );
    } on SocketException catch (error) {
      throw HttpException('Could not connect to GitHub: ${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  static Future<File> download(
    ReleaseAsset asset,
    void Function(double progress, int received, int total) onProgress,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(Uri.parse(asset.downloadUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'CCS-EEGStudio-Updater');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('Download returned HTTP ${response.statusCode}');
      }
      final total = response.contentLength > 0
          ? response.contentLength
          : asset.sizeBytes;
      final safeName = asset.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}$safeName',
      );
      if (file.existsSync()) file.deleteSync();
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          onProgress(
            total > 0 ? (received / total).clamp(0.0, 1.0).toDouble() : 0,
            received,
            total,
          );
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      if (total > 0 && received != total) {
        file.deleteSync();
        throw const FormatException('The downloaded update is incomplete.');
      }
      return file;
    } finally {
      client.close(force: true);
    }
  }
}

class AppUpdateDialog extends StatefulWidget {
  const AppUpdateDialog({super.key, required this.info});

  final UpdateInfo info;

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  bool _downloading = false;
  double _progress = 0;
  String _status = '';
  File? _downloaded;

  String _megabytes(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

  Future<void> _downloadAndInstall() async {
    final asset = widget.info.asset;
    if (asset == null) return;
    setState(() {
      _downloading = true;
      _progress = 0;
      _status = 'Downloading ${asset.name}…';
    });
    try {
      final file = await UpdateChecker.download(asset, (
        progress,
        received,
        total,
      ) {
        if (!mounted) return;
        setState(() {
          _progress = progress;
          _status = total > 0
              ? '${_megabytes(received)} / ${_megabytes(total)} MB'
              : '${_megabytes(received)} MB downloaded';
        });
      });
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _downloaded = file;
        _status = 'Download complete.';
      });
      await _launchInstaller(file);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _status = 'Update failed: $error';
      });
    }
  }

  String? _currentMacApp() {
    var directory = File(Platform.resolvedExecutable).parent;
    while (directory.path != directory.parent.path) {
      if (directory.path.endsWith('.app')) return directory.path;
      directory = directory.parent;
    }
    return null;
  }

  Future<void> _launchInstaller(File file) async {
    if (Platform.isWindows) {
      await Process.start(file.path, const [], mode: ProcessStartMode.detached);
      if (mounted)
        setState(
          () => _status = 'Installer launched. Close the app when prompted.',
        );
      return;
    }
    if (Platform.isLinux) {
      await _installLinuxUpdate(file);
      return;
    }
    await _installMacUpdate(file);
  }

  Future<void> _installLinuxUpdate(File file) async {
    if (mounted) {
      setState(() => _status = 'Launching package installer (sudo required)…');
    }

    try {
      final helperScript = File('${Directory.systemTemp.path}${Platform.pathSeparator}apply_ccs_eeg_update.sh');
      final scriptContent = '''#!/bin/bash
set -e
echo "======================================================================"
echo "          CCS EEG Studio - Installing System Update                   "
echo "======================================================================"
echo "Package: ${file.path}"
echo "Administrative (sudo) privileges are required to update this package."
echo "Please enter your password when prompted below."
echo "----------------------------------------------------------------------"

if command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y "${file.path}"
elif command -v yum >/dev/null 2>&1; then
  sudo yum install -y "${file.path}"
elif command -v rpm >/dev/null 2>&1; then
  sudo rpm -Uvh --replacepkgs "${file.path}"
elif command -v apt-get >/dev/null 2>&1; then
  sudo apt-get install -y "${file.path}"
elif command -v dpkg >/dev/null 2>&1; then
  sudo dpkg -i "${file.path}" || sudo apt-get install -f -y
else
  echo "Error: Supported package manager (dnf/yum/rpm/apt-get/dpkg) not found." >&2
  exit 1
fi

EXIT_CODE=\$?
if [ \$EXIT_CODE -eq 0 ]; then
  echo ""
  echo "======================================================================"
  echo "  CCS EEG Studio updated successfully!                                "
  echo "======================================================================"
  echo "Press Enter to exit and restart the application..."
  read -r
else
  echo ""
  echo "======================================================================"
  echo "  Update failed or sudo permission denied.                            "
  echo "======================================================================"
  echo "Press Enter to close this window..."
  read -r
fi
''';
      await helperScript.writeAsString(scriptContent);
      await Process.run('chmod', ['+x', helperScript.path]);

      final terminals = [
        'xfce4-terminal',
        'gnome-terminal',
        'konsole',
        'x-terminal-emulator',
        'mate-terminal',
        'lxterminal',
        'xterm',
      ];

      bool launched = false;
      for (final term in terminals) {
        final whichRes = await Process.run('which', [term]);
        if (whichRes.exitCode == 0) {
          final termPath = (whichRes.stdout as String).trim();
          if (term == 'gnome-terminal') {
            await Process.start(termPath, ['--title=Updating CCS EEG Studio', '--', '/bin/bash', helperScript.path], mode: ProcessStartMode.detached);
          } else if (term == 'xfce4-terminal') {
            await Process.start(termPath, ['--title=Updating CCS EEG Studio', '-e', '/bin/bash ${helperScript.path}'], mode: ProcessStartMode.detached);
          } else {
            await Process.start(termPath, ['-e', '/bin/bash ${helperScript.path}'], mode: ProcessStartMode.detached);
          }
          launched = true;
          break;
        }
      }

      if (launched) {
        if (mounted) {
          setState(() => _status = 'Installer terminal opened. Please enter your password to authorize sudo privileges.\n'
              'Alternatively, run in terminal: sudo dnf install -y "${file.path}"');
        }
      } else {
        final pkexecCheck = await Process.run('which', ['pkexec']);
        if (pkexecCheck.exitCode == 0) {
          Process.start('pkexec', ['/bin/bash', helperScript.path], mode: ProcessStartMode.detached);
          if (mounted) {
            setState(() => _status = 'Authorization prompt requested via pkexec.');
          }
        } else {
          Process.run('xdg-open', [file.path]);
          if (mounted) {
            setState(() => _status = 'Package downloaded to: ${file.path}\nRun with sudo in terminal: sudo dnf install -y "${file.path}"');
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _status = 'Error launching installer: $e\nRun manually: sudo dnf install -y "${file.path}"');
      }
    }
  }

  Future<void> _installMacUpdate(File archive) async {
    final currentApp = _currentMacApp();
    if (currentApp == null) {
      await Process.run('open', ['-R', archive.path]);
      if (mounted)
        setState(
          () => _status =
              'Archive revealed in Finder; development mode cannot replace itself.',
        );
      return;
    }
    final staging = await Directory.systemTemp.createTemp('ccs_eeg_update_');
    final extract = await Process.run('ditto', [
      '-x',
      '-k',
      archive.path,
      staging.path,
    ]);
    if (extract.exitCode != 0) {
      throw ProcessException(
        'ditto',
        const [],
        extract.stderr.toString(),
        extract.exitCode,
      );
    }
    final applications = staging
        .listSync(recursive: true, followLinks: false)
        .whereType<Directory>()
        .where((entry) => entry.path.endsWith('.app'))
        .toList();
    if (applications.isEmpty) {
      throw const FormatException(
        'The update archive contains no macOS application.',
      );
    }
    final newApp = applications.first.path;
    final verification = await Process.run('codesign', [
      '--verify',
      '--deep',
      '--strict',
      newApp,
    ]);
    if (verification.exitCode != 0) {
      throw const FormatException(
        'The downloaded macOS application failed signature verification.',
      );
    }
    if (mounted) setState(() => _status = 'Installing and restarting…');
    final helper = File(
      '${staging.path}${Platform.pathSeparator}install_update.sh',
    );
    await helper.writeAsString(r'''#!/bin/bash
PID="$1"
TARGET="$2"
NEW_APP="$3"
STAGING="$4"
ARCHIVE="$5"
BACKUP="${TARGET}.update-backup"

while kill -0 "$PID" 2>/dev/null; do sleep 0.25; done
rm -rf "$BACKUP"
if ! mv "$TARGET" "$BACKUP"; then
  open -R "$NEW_APP"
  exit 1
fi
if ditto "$NEW_APP" "$TARGET"; then
  xattr -rd com.apple.quarantine "$TARGET" 2>/dev/null || true
  open "$TARGET"
  rm -rf "$BACKUP" "$STAGING"
  rm -f "$ARCHIVE"
else
  rm -rf "$TARGET"
  mv "$BACKUP" "$TARGET"
  open -R "$NEW_APP"
fi
''');
    await Process.run('chmod', ['+x', helper.path]);
    await Process.start('/bin/bash', [
      helper.path,
      pid.toString(),
      currentApp,
      newApp,
      staging.path,
      archive.path,
    ], mode: ProcessStartMode.detached);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final updateColor = info.hasUpdate
        ? const Color(0xFF3B82F6)
        : const Color(0xFF22C55E);
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            info.hasUpdate ? Icons.system_update_alt : Icons.verified_outlined,
            color: updateColor,
          ),
          const SizedBox(width: 10),
          Text(info.hasUpdate ? 'CCS EEG Studio update' : 'You are up to date'),
        ],
      ),
      content: SizedBox(
        width: 580,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Installed: ${info.currentVersion}   •   Latest: ${info.latestVersion}',
            ),
            if (info.hasUpdate) ...[
              const SizedBox(height: 16),
              const Text(
                'Release notes',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Container(
                height: 180,
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white12),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(info.releaseNotes),
                ),
              ),
              const SizedBox(height: 12),
              if (info.asset == null)
                const Text(
                  'This release has no installer for the current operating system.',
                )
              else
                Text(
                  '${info.asset!.name} • ${_megabytes(info.asset!.sizeBytes)} MB',
                ),
              if (_downloading) ...[
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: _progress > 0 ? _progress : null,
                ),
              ],
              if (_status.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(_status, style: const TextStyle(fontSize: 12)),
              ],
            ] else
              const Padding(
                padding: EdgeInsets.only(top: 14),
                child: Text('No newer versioned release is available.'),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _downloading ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        if (info.hasUpdate && info.asset != null && !_downloading)
          FilledButton.icon(
            onPressed: _downloaded == null
                ? _downloadAndInstall
                : () => _launchInstaller(_downloaded!),
            icon: Icon(_downloaded == null ? Icons.download : Icons.launch),
            label: Text(
              _downloaded == null ? 'Download & update' : 'Launch installer',
            ),
          ),
      ],
    );
  }
}
