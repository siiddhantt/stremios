#!/usr/bin/env python3
"""Build a rootful Debian package and an offline HTTPS Sileo repository.

No download, install, signing change, credential handling or publication occurs.
Requires Python 3.9+. macOS also checks the existing code signature with codesign.
"""
import argparse
import bz2
import gzip
import hashlib
import html
import io
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
from urllib.parse import quote, urlsplit
import zipfile

PROJECT = Path(__file__).resolve().parents[1]
PACKAGING = PROJECT / 'packaging'
MAX_BYTES = 200 * 1024 * 1024
TEST_ID = 'local.stremios.packaging-test'


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def base_url(value):
    p = urlsplit(value)
    if (p.scheme != 'https' or not p.hostname or p.username or p.password or
            p.query or p.fragment or p.port not in (None, 443) or
            any(c.isspace() or ord(c) < 32 for c in value) or
            any(part in ('.', '..') for part in p.path.split('/'))):
        raise ValueError('Repository base must be an HTTPS URL without credentials, query or fragment.')
    return value.rstrip('/') + '/'


def read_app(ipa, expected_bundle):
    """Read only normal files in one expected app; never extract ZIP paths."""
    files, seen = {}, set()
    prefix = 'Payload/StremIOS.app/'
    with zipfile.ZipFile(ipa) as z:
        infos = z.infolist()
        if len(infos) > 2048 or sum(i.file_size for i in infos) > MAX_BYTES:
            raise ValueError('IPA exceeds bounded package input limits.')
        for item in infos:
            name = item.filename
            path = PurePosixPath(name)
            if (name in seen or '\\' in name or '\x00' in name or path.is_absolute() or
                    any(part in ('.', '..') for part in name.rstrip('/').split('/'))):
                raise ValueError('IPA has an unsafe or duplicate member.')
            seen.add(name)
            if name in ('Payload/', 'Payload/StremIOS.app/'):
                continue
            if not name.startswith(prefix):
                raise ValueError('IPA contains files outside the expected app.')
            mode = item.external_attr >> 16
            kind = stat.S_IFMT(mode)
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError('Links and special files are not accepted in the IPA.')
            if item.is_dir():
                continue
            relative = name[len(prefix):]
            files[relative] = (z.read(item), 0o755 if mode & 0o111 else 0o644)
    info = plistlib.loads(files['Info.plist'][0])
    if (info.get('CFBundleIdentifier') != expected_bundle or
            info.get('CFBundleExecutable') != 'StremIOS' or
            info.get('MinimumOSVersion') != '12.0' or
            info.get('UIDeviceFamily') != [2] or
            'arm64' not in info.get('UIRequiredDeviceCapabilities', [])):
        raise ValueError('IPA does not match the expected iOS 12 arm64 iPad identity.')
    executable = files['StremIOS'][0]
    if len(executable) < 32 or struct.unpack('<II', executable[:8]) != (0xFEEDFACF, 0x0100000C):
        raise ValueError('Expected a thin arm64 Mach-O executable.')
    for required in ('ThirdPartyNotices.txt', 'Frameworks/MobileVLCKit.framework/MobileVLCKit',
                     '_CodeSignature/CodeResources', 'Icon-76@2x.png'):
        if required not in files:
            raise ValueError('IPA is missing required runtime or license resources.')
    files['StremIOS'] = (executable, 0o755)
    return files, info


def verify_signature(files):
    codesign = shutil.which('codesign')
    if sys.platform != 'darwin':
        return False
    if not codesign:
        raise ValueError('macOS codesign is required to verify the existing signature.')
    with tempfile.TemporaryDirectory(prefix='stremios-package-audit-') as tmp:
        app = Path(tmp) / 'StremIOS.app'
        for name, (data, mode) in files.items():
            dest = app / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
            dest.chmod(mode)
        subprocess.run([codesign, '--verify', '--deep', '--strict', str(app)], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return True


def archive(entries):
    """POSIX tar, root ownership, fixed timestamps; deterministic gzip wrapper."""
    out = io.BytesIO()
    directories = set()
    for name in entries:
        for parent in PurePosixPath(name).parents:
            if str(parent) != '.':
                directories.add(str(parent))
    with tarfile.open(fileobj=out, mode='w', format=tarfile.USTAR_FORMAT) as tar:
        for name in sorted(directories):
            meta = tarfile.TarInfo('./' + name)
            meta.type, meta.mode, meta.mtime = tarfile.DIRTYPE, 0o755, 0
            meta.uid = meta.gid = 0
            meta.uname = meta.gname = 'root'
            tar.addfile(meta)
        for name, (data, mode) in sorted(entries.items()):
            meta = tarfile.TarInfo('./' + name)
            meta.size, meta.mode, meta.mtime = len(data), mode, 0
            meta.uid = meta.gid = 0
            meta.uname = meta.gname = 'root'
            tar.addfile(meta, io.BytesIO(data))
    return gzip.compress(out.getvalue(), compresslevel=9, mtime=0)


def deb_archive(control, data):
    result = bytearray(b'!<arch>\n')
    for name, payload in [('debian-binary', b'2.0\n'), ('control.tar.gz', control), ('data.tar.gz', data)]:
        header = f'{name + "/":<16}{0:<12}{0:<6}{0:<6}{"100644":<8}{len(payload):<10}`\n'.encode('ascii')
        assert len(header) == 60
        result.extend(header)
        result.extend(payload)
        if len(payload) % 2:
            result.extend(b'\n')
    return bytes(result)


def replace_tokens(text, tokens):
    for key, value in tokens.items():
        text = text.replace('@' + key + '@', value)
    if re.search(r'@[A-Z_]+@', text):
        raise ValueError('Unresolved template token.')
    return text


def generate(ipa, output, url, version, test_identity=False, extra_notices=None, source_instructions=None):
    if output.exists():
        raise ValueError('Output must be a new directory; existing repository files are never overwritten.')
    if not re.fullmatch(r'[0-9][a-zA-Z0-9.+~:-]{0,63}', version) or ':' in version:
        raise ValueError('Invalid Debian version.')
    url = base_url(url)
    config = json.loads((PACKAGING / 'package.json').read_text())
    package = TEST_ID if test_identity else config['package']
    name = 'StremIOS Packaging Test' if test_identity else config['name']
    app_name = 'StremIOSPackageTest.app' if test_identity else config['appBundle']
    files, info = read_app(ipa, TEST_ID if test_identity else config['bundleIdentifier'])
    if not version.startswith(info['CFBundleShortVersionString'] + '~beta'):
        raise ValueError('Initial package version must match the app version and explicitly identify a beta.')
    if not test_identity and (not extra_notices or not source_instructions):
        raise ValueError('Production packaging requires --extra-notices and --source-instructions.')
    if not test_identity and extra_notices.read_bytes().strip() not in files['ThirdPartyNotices.txt'][0]:
        raise ValueError('The IPA must already contain the complete release notices before packaging.')
    signature_verified = verify_signature(files)
    app_path = '/Applications/' + app_name
    entries = {'Applications/' + app_name + '/' + path: content for path, content in files.items()}
    # Include the project's full license alongside its runtime dependency notices.
    entries[f'usr/share/doc/{package}/copyright'] = ((PROJECT / 'LICENSE').read_bytes(), 0o644)
    entries[f'usr/share/doc/{package}/ThirdPartyNotices.txt'] = (files['ThirdPartyNotices.txt'][0], 0o644)
    for source, filename in ((extra_notices, 'THIRD-PARTY-NOTICES.txt'),
                             (source_instructions, 'SOURCE-AND-RELINKING.txt')):
        if source:
            content = source.read_bytes()
            if not content or len(content) > 4 * 1024 * 1024 or b'\x00' in content:
                raise ValueError('Invalid supplementary notice document.')
            content.decode('utf-8')
            entries[f'usr/share/doc/{package}/{filename}'] = (content, 0o644)
    installed_size = (sum(len(content[0]) for content in entries.values()) + 1023) // 1024
    depiction = 'depictions/' + package + '.json'
    fields = {
        'Package': package, 'Name': name, 'Version': version,
        'Architecture': config['architecture'], 'Maintainer': config['maintainer'],
        'Author': config['maintainer'], 'Section': config['section'], 'Priority': 'optional',
        'Installed-Size': str(installed_size),
        'Pre-Depends': 'uikittools (>= 2.1)',
        'Depends': 'firmware (>= 12.0), firmware (<< 13.0)',
        'Homepage': config['homepage'], 'Depiction': url,
        'SileoDepiction': url + depiction, 'Icon': url + 'icon.png',
        'Description': config['description']
    }
    control = '\n'.join(key + ': ' + value for key, value in fields.items()) + '\n'
    tokens = {'PACKAGE': package, 'BUNDLE': package, 'APP_PATH': app_path,
              'NAME': name, 'VERSION': version, 'HOMEPAGE': config['homepage'], 'SUPPORT': config['support']}
    controls = {'control': (control.encode(), 0o644)}
    for script in ('preinst', 'postinst', 'prerm'):
        rendered = replace_tokens((PACKAGING / 'templates' / script).read_text(), tokens)
        subprocess.run(['/bin/sh', '-n'], input=rendered.encode(), check=True)
        controls[script] = (rendered.encode(), 0o755)
    controls['md5sums'] = (''.join(hashlib.md5(content[0]).hexdigest() + '  ' + path + '\n'
                                  for path, content in sorted(entries.items())).encode(), 0o644)
    deb = deb_archive(archive(controls), archive(entries))
    deb_filename = f'{package}_{version}_iphoneos-arm.deb'
    packages = control + f'Filename: pool/{deb_filename}\nSize: {len(deb)}\nSHA256: {sha256(deb)}\n\n'
    repo_files = {'Packages': packages.encode(), 'Packages.gz': gzip.compress(packages.encode(), mtime=0),
                  'Packages.bz2': bz2.compress(packages.encode()), 'pool/' + deb_filename: deb,
                  'icon.png': files['Icon-76@2x.png'][0], '.nojekyll': b''}
    rendered_depiction = replace_tokens((PACKAGING / 'templates/depiction.json').read_text(), tokens)
    json.loads(rendered_depiction)
    repo_files[depiction] = rendered_depiction.encode()
    release = ('Origin: StremIOS\nLabel: StremIOS Public Beta\nSuite: stable\nVersion: 1.0\n'
               'Codename: stremios\nArchitectures: iphoneos-arm\nComponents: main\n'
               'Description: Rootful iOS 12 iPad packages\nSHA256:\n')
    for filename in ('Packages', 'Packages.gz', 'Packages.bz2'):
        payload = repo_files[filename]
        release += f' {sha256(payload)} {len(payload)} {filename}\n'
    repo_files['Release'] = release.encode()
    link = 'sileo://source/' + url
    repo_files['index.html'] = ('''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>StremIOS public beta</title><style>body{font:17px/1.6 -apple-system,sans-serif;background:#101319;color:#eef2f8;max-width:680px;margin:48px auto;padding:24px}a{color:#7db6ff}img{border-radius:22px;width:96px;height:96px}code{overflow-wrap:anywhere}h1{line-height:1.2}</style><img src="icon.png" alt=""><h1>''' + html.escape(name) + '''</h1><p>A free, open-source public beta of a native Stremio-compatible iPad client.</p><p><strong>Rootful jailbreak · arm64 iPad · iOS 12.x</strong><br>Tested on iPad mini 2 with iOS 12.5.8. The jailbreak must be active.</p><p><a href="''' + html.escape(link, quote=True) + '''">Add this repository to Sileo</a></p><p>Or add this address in Sileo → Sources:<br><code>''' + html.escape(url) + '''</code></p><p><a href="pool/''' + quote(deb_filename) + '''">Download the .deb</a> · <a href="''' + config['homepage'] + '''">Source and license</a> · <a href="''' + config['support'] + '''">Support</a></p><h2>Already installed using an IPA?</h2><p>Keep that installation and update it with the IPA. This package refuses an automatic migration from an IPA. It never uninstalls an IPA or deletes its saved data. Package removal removes the app, not its saved data.</p><h2>Before installing</h2><p>No content, accounts or paid provider access is included. Configure your own supported add-ons. Other devices, rootless jailbreaks and modern iOS are not validated. Prefer 720p on this hardware. This beta does not promise universal source compatibility or battery performance.</p><p>Version ''' + html.escape(version) + '''. Independent project; not affiliated with Stremio.</p></html>\n''').encode()
    receipt = {'schemaVersion': 1, 'package': package, 'version': version, 'appVersion': info['CFBundleShortVersionString'],
               'appBuild': info['CFBundleVersion'], 'bundleIdentifier': info['CFBundleIdentifier'],
               'installPath': app_path, 'architecture': config['architecture'], 'testArtifact': test_identity,
               'inputIPASHA256': sha256(ipa.read_bytes()), 'executableSHA256': sha256(files['StremIOS'][0]),
               'originalSignatureVerifiedOnMac': signature_verified, 'debSHA256': sha256(deb),
               'bundledNoticesSHA256': sha256(files['ThirdPartyNotices.txt'][0]),
               'supplementaryNoticesSHA256': sha256(extra_notices.read_bytes()) if extra_notices else None,
               'sourceInstructionsSHA256': sha256(source_instructions.read_bytes()) if source_instructions else None,
               'repositoryBaseURL': url, 'repositorySigned': False, 'payloadFiles': len(entries),
               'deviceLifecycleTested': False, 'ipaMigrationAllowed': False,
               'files': {path: sha256(data) for path, data in sorted(repo_files.items())}}
    repo_files['package-build.json'] = (json.dumps(receipt, indent=2, sort_keys=True) + '\n').encode()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.stremios-repo-', dir=output.parent) as temp:
        staged = Path(temp) / 'repo'
        staged.mkdir()
        for path, data in repo_files.items():
            dest = staged / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
            dest.chmod(0o644)
        staged.rename(output)
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ipa', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path, help='New offline repository directory')
    parser.add_argument('--base-url', required=True, help='Intended public HTTPS repository URL')
    parser.add_argument('--version', default='0.8.3~beta1')
    parser.add_argument('--extra-notices', type=Path, help='Complete release third-party notice text')
    parser.add_argument('--source-instructions', type=Path, help='Exact release source and relinking instructions')
    parser.add_argument('--test-identity', action='store_true', help='Only accepts pre-signed local.stremios.packaging-test IPA')
    args = parser.parse_args()
    try:
        receipt = generate(args.ipa, args.output, args.base_url, args.version, args.test_identity, args.extra_notices, args.source_instructions)
    except (ValueError, KeyError, OSError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Package generation failed: {error}\n')
    print(json.dumps({'package': receipt['package'], 'version': receipt['version'], 'debSHA256': receipt['debSHA256'],
                      'testArtifact': receipt['testArtifact'], 'deviceLifecycleTested': False}, indent=2))


if __name__ == '__main__':
    main()
