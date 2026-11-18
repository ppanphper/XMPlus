#!/usr/bin/env python3
"""Package an already successful iOS build; never signs or installs it."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile


def package(args):
    app = args.app.resolve()
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    expected = 'iPhoneOS' if args.variant == 'unsigned' else 'iPhoneSimulator'
    if info.get('CFBundleSupportedPlatforms') != [expected]:
        raise ValueError(f'Expected {expected}, found {info.get("CFBundleSupportedPlatforms")}')
    executable = info['CFBundleExecutable']
    if Path(executable).name != executable:
        raise ValueError('Invalid app executable name')
    architectures = subprocess.check_output(
        ['xcrun', 'lipo', '-archs', str(app / executable)], text=True
    ).strip().split()
    if args.variant == 'unsigned':
        if 'arm64' not in architectures:
            raise ValueError('Device package must contain arm64')
        if (app / '_CodeSignature').exists() or (app / 'embedded.mobileprovision').exists():
            raise ValueError('Expected an unsigned app; rebuild with --no-codesign')
        binary = (app / 'Frameworks/App.framework/App').read_bytes()
        for marker in (b'IOS_SMOKE_FINISHED', b'Preparing native smoke checks', b'Export canonical path'):
            if marker in binary:
                raise ValueError('Temporary test entrypoint detected; rebuild lib/main.dart')
    version = info['CFBundleShortVersionString']
    build = info['CFBundleVersion']
    if not re.fullmatch(r'[0-9.]+', str(version)) or not re.fullmatch(r'[0-9.]+', str(build)):
        raise ValueError('Unexpected version/build format')
    stamp = args.stamp or datetime.now().astimezone().strftime('%Y-%m-%d_%H-%M-%S')
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}', stamp):
        raise ValueError('Invalid timestamp')
    args.output_dir.mkdir(parents=True, exist_ok=True)
    args.temp_dir.mkdir(parents=True, exist_ok=True)
    suffix = '.ipa' if args.variant == 'unsigned' else '.app.zip'
    target = args.output_dir / f'XMPlus-iOS-{version}+{build}-{stamp}-{args.variant}{suffix}'
    if target.exists():
        raise FileExistsError(f'Will not overwrite existing artifact: {target}')
    with tempfile.TemporaryDirectory(prefix='package-', dir=args.temp_dir) as work:
        work = Path(work)
        root = work / 'Payload' if args.variant == 'unsigned' else work
        root.mkdir(exist_ok=True)
        staged_app = root / 'Runner.app'
        subprocess.run(['ditto', str(app), str(staged_app)], check=True)
        # Flutter SDK interfaces are unused at runtime and contain source headers.
        for folder in ('Headers', 'Modules'):
            path = staged_app / 'Frameworks/Flutter.framework' / folder
            if path.exists():
                shutil.rmtree(path)
        forbidden = {'.dart', '.swift', '.m', '.mm', '.h', '.hpp', '.c', '.cpp', '.pbxproj'}
        sources = [p.relative_to(staged_app) for p in staged_app.rglob('*') if p.is_file() and p.suffix in forbidden]
        if sources:
            raise ValueError(f'Source files found in runtime package: {sources[:8]}')
        staged_zip = work / 'artifact.zip'
        archived_root = root if args.variant == 'unsigned' else staged_app
        subprocess.run(['ditto', '-c', '-k', '--norsrc', '--keepParent', str(archived_root), str(staged_zip)], check=True)
        prefix = 'Payload/Runner.app/' if args.variant == 'unsigned' else 'Runner.app/'
        with zipfile.ZipFile(staged_zip) as archive:
            if archive.testzip() is not None or prefix + 'Info.plist' not in archive.namelist():
                raise ValueError('Archive integrity or layout check failed')
            packaged_info = plistlib.loads(archive.read(prefix + 'Info.plist'))
            if packaged_info != info:
                raise ValueError('Packaged app metadata changed')
        # Exclusive creation protects completed artifacts, including simultaneous runs.
        with target.open('xb') as destination, staged_zip.open('rb') as source:
            try:
                shutil.copyfileobj(source, destination)
            except BaseException:
                target.unlink(missing_ok=True)
                raise
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    manifest = {
        'createdAt': datetime.now().astimezone().isoformat(),
        'artifact': target.name, 'bytes': target.stat().st_size, 'sha256': digest,
        'variant': args.variant, 'bundleIdentifier': info['CFBundleIdentifier'],
        'version': version, 'build': build, 'minimumOS': info['MinimumOSVersion'],
        'platform': expected, 'architectures': architectures,
        'entrypoint': 'lib/main.dart', 'sourceFilesPackaged': False,
        'signed': False if args.variant == 'unsigned' else 'simulator-ad-hoc',
        'liveContainerRuntimeValidated': False,
    }
    Path(str(target) + '.sha256').write_text(f'{digest}  {target.name}\n')
    Path(str(target) + '.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({**manifest, 'artifact': str(target)}, ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--variant', choices=['unsigned', 'simulator'], required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--temp-dir', type=Path, required=True)
    parser.add_argument('--stamp')
    package(parser.parse_args())


if __name__ == '__main__':
    main()
