"""Rename legacy CCS artifacts without re-encoding signal samples.
Default is a dry run. --apply renames known artifacts, updates metadata source
paths, and writes a reversible mapping. Unknown JSON files are left untouched.
"""
import argparse
import json
import re
from pathlib import Path


def plan(root):
    mapping = {}
    for path in sorted(root.iterdir()):
        if not path.is_file() or path.name.startswith('.'):
            continue
        name = path.name
        if name.endswith('.preprocessing.json') or name.endswith('.preparation.json'):
            continue
        target = None
        if name.endswith('.json'):
            with path.open('rb') as handle:
                header = handle.read(4096).decode('utf-8', errors='replace')
                if path.stat().st_size > 4096:
                    handle.seek(max(0, path.stat().st_size - 4096))
                    header += handle.read().decode('utf-8', errors='replace')
            if re.search(r'"format"\s*:\s*"ccseeg-v1"', header):
                target = re.sub(r'(?:\.(?:ccseeg|json))+$', '', name) + '.ccseeg'
            elif '"ccs-erp-protocol-v1"' in header:
                target = re.sub(r'(?:\.protocol)?\.json$', '', name) + '.ccsprotocol'
            elif '"ccs-erp-workbench-v1"' in header:
                target = name[:-5] + '.ccserp'
        elif re.search(r'(?:\.ccseeg){2,}$', name):
            target = re.sub(r'(?:\.ccseeg)+$', '.ccseeg', name)
        if target and target != name:
            mapping[path] = root / target
    for path in sorted(root.iterdir()):
        for suffix, new_suffix in [('.preprocessing.json', '.ccshistory'), ('.preparation.json', '.ccspreparation'), ('.analysis.json', '.ccsanalysis')]:
            if path.is_file() and path.name.endswith(suffix):
                signal = root / path.name[:-len(suffix)]
                mapping[path] = Path(str(mapping.get(signal, signal)) + new_suffix)
    targets = list(mapping.values())
    if len(set(targets)) != len(targets):
        raise ValueError('Two legacy files resolve to the same name; resolve duplicates first.')
    for old, new in mapping.items():
        if new.exists():
            raise ValueError(f'Would overwrite {new}; resolve duplicates first.')
    return mapping


def apply(root, mapping):
    manifest = root / 'legacy_names.ccsmigration'
    if manifest.exists():
        raise ValueError('A migration manifest already exists; review it before another migration.')
    replacements = {str(k): str(v) for k, v in mapping.items()}
    # Record the plan before touching files. Each rename is within one directory.
    manifest.write_text(json.dumps({'schema': 'ccs-name-migration-v1', 'renames': replacements}, indent=2))
    completed = []
    try:
        for old, new in mapping.items():
            old.rename(new)
            completed.append((old, new))
    except Exception:
        for old, new in reversed(completed):
            new.rename(old)
        manifest.unlink()
        raise
    # Exact path substitutions preserve signal arrays and unknown JSON fields.
    for path in root.iterdir():
        if path.suffix in {'.ccshistory', '.ccspreparation', '.ccsprotocol', '.ccserp', '.ccsanalysis'}:
            text = path.read_text()
            for old, new in replacements.items():
                text = text.replace(json.dumps(old), json.dumps(new))
            path.write_text(text)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    changes = plan(args.folder)
    print(json.dumps({str(k): str(v) for k, v in changes.items()}, indent=2))
    if args.apply and changes:
        apply(args.folder, changes)
