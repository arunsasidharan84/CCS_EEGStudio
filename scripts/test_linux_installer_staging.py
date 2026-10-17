"""Exercise installer staging without root, networking or package installation."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = (Path(__file__).parent / 'install_linux.sh').read_text()


class InstallerStagingTest(unittest.TestCase):
    def test_packages_and_cleanup(self):
        setup = SOURCE[SOURCE.index('INSTALL_WORK_DIR='):SOURCE.index('# Detect Linux Distribution')]
        for asset in ('RPM', 'DEB'):
            assignment = next(line.strip() for line in SOURCE.splitlines()
                              if line.strip().startswith('PKG_TMP=') and f'{asset}_ASSET_NAME' in line)
            for result in (0, 1):
                with self.subTest(asset=asset, result=result), tempfile.TemporaryDirectory() as tmp:
                    legacy = Path(tmp) / 'package'
                    legacy.write_text('another user’s package')
                    legacy.chmod(0o400)
                    script = setup + f'''\n{asset}_ASSET_NAME=package
{assignment}
printf '%s' "$PKG_TMP"
printf 'download' > "$PKG_TMP"
exit {result}
'''
                    run = subprocess.run(['bash', '-euc', script], env={**os.environ, 'TMPDIR': tmp},
                                         text=True, capture_output=True)
                    self.assertEqual(run.returncode, result, run.stderr)
                    staged = Path(run.stdout)
                    self.assertNotEqual(staged, legacy)
                    self.assertEqual(staged.parent.parent, Path(tmp))
                    self.assertFalse(staged.parent.exists())
                    self.assertEqual(legacy.read_text(), 'another user’s package')

    def test_wrapper_cleanup_on_child_failure(self):
        wrapper = SOURCE.split("cat > \"$UPDATER_BIN\" << 'EOF'\n", 1)[1].split('\nEOF', 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            stub = Path(tmp) / 'curl'
            stub.write_text('#!/bin/bash\nprintf "exit 7\\n" > "${@: -1}"\n')
            stub.chmod(0o755)
            run = subprocess.run(['bash', '-c', wrapper], env={**os.environ, 'TMPDIR': tmp,
                                  'PATH': tmp + os.pathsep + os.environ['PATH']}, capture_output=True)
            self.assertEqual(run.returncode, 7, run.stderr)
            self.assertEqual(list(Path(tmp).iterdir()), [stub])


if __name__ == '__main__':
    unittest.main()
