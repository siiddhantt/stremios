#!/usr/bin/env python3
"""Offline package-format and maintainer-script checks; no real installer calls."""
import gzip
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import struct
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('packager', ROOT / 'scripts/package-deb.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


def members(data):
    assert data[:8] == b'!<arch>\n'
    result, offset = {}, 8
    while offset < len(data):
        h = data[offset:offset + 60]
        assert h[-2:] == b'`\n'
        size = int(h[48:58])
        result[h[:16].decode().strip().rstrip('/')] = data[offset + 60:offset + 60 + size]
        offset += 60 + size + size % 2
    assert offset == len(data)
    return result


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.ipa = self.root / 'sample.ipa'
        info = {'CFBundleIdentifier': p.TEST_ID, 'CFBundleExecutable': 'StremIOS',
                'MinimumOSVersion': '12.0', 'UIDeviceFamily': [2], 'UIRequiredDeviceCapabilities': ['arm64'],
                'CFBundleShortVersionString': '0.8.3', 'CFBundleVersion': '16'}
        self.files = {'Info.plist': plistlib.dumps(info), 'StremIOS': struct.pack('<II', 0xFEEDFACF, 0x0100000C) + b'\0' * 24,
                      'ThirdPartyNotices.txt': b'License notice\n', 'Frameworks/MobileVLCKit.framework/MobileVLCKit': b'runtime',
                      '_CodeSignature/CodeResources': b'signature', 'Icon-76@2x.png': b'icon'}
        self.write_zip()

    def tearDown(self):
        self.tmp.cleanup()

    def write_zip(self, extra=None):
        with zipfile.ZipFile(self.ipa, 'w') as z:
            for name, data in self.files.items():
                z.writestr('Payload/StremIOS.app/' + name, data)
            if extra:
                z.writestr(*extra)

    def build(self, directory):
        with patch.object(p, 'verify_signature', return_value=True):
            return p.generate(self.ipa, self.root / directory, 'https://example.org/repo/', '0.8.3~beta1', True)

    def test_deb_format_indexes_and_payload(self):
        receipt = self.build('one')
        repo = self.root / 'one'
        deb = next((repo / 'pool').glob('*.deb')).read_bytes()
        parts = members(deb)
        self.assertEqual(set(parts), {'debian-binary', 'control.tar.gz', 'data.tar.gz'})
        self.assertEqual(parts['debian-binary'], b'2.0\n')
        self.assertEqual(p.sha256(deb), receipt['debSHA256'])
        with tarfile.open(fileobj=io.BytesIO(parts['data.tar.gz']), mode='r:gz') as tar:
            for entry in tar:
                self.assertEqual((entry.uid, entry.gid, entry.mtime), (0, 0, 0))
                self.assertFalse(entry.issym() or entry.islnk())
                self.assertTrue(entry.name.startswith(('./Applications', './usr')))
            self.assertEqual(tar.extractfile('./Applications/StremIOSPackageTest.app/StremIOS').read(), self.files['StremIOS'])
        with tarfile.open(fileobj=io.BytesIO(parts['control.tar.gz']), mode='r:gz') as tar:
            control = tar.extractfile('./control').read().decode()
            self.assertIn('Architecture: iphoneos-arm\n', control)
            self.assertIn('firmware (<< 13.0)', control)
            self.assertIn('Pre-Depends: uikittools (>= 2.1)', control)
            self.assertNotIn('postrm', tar.getnames())
        packages = (repo / 'Packages').read_bytes()
        self.assertEqual(gzip.decompress((repo / 'Packages.gz').read_bytes()), packages)
        self.assertIn(p.sha256(deb).encode(), packages)
        self.assertIn(p.sha256(packages), (repo / 'Release').read_text())
        self.assertFalse(receipt['deviceLifecycleTested'])
        self.assertFalse(receipt['repositorySigned'])
        self.assertEqual(json.loads((repo / 'depictions' / (p.TEST_ID + '.json')).read_text())['minVersion'], '0.4')

    def test_reproducible(self):
        self.assertEqual(self.build('one'), self.build('two'))

    def test_existing_output_is_untouched(self):
        self.build('one')
        with self.assertRaises(ValueError):
            self.build('one')

    def test_production_requires_complete_bundled_notices(self):
        info = plistlib.loads(self.files['Info.plist'])
        info['CFBundleIdentifier'] = 'local.ministream.ipad'
        self.files['Info.plist'] = plistlib.dumps(info)
        self.write_zip()
        notices, instructions = self.root / 'notices.txt', self.root / 'source.txt'
        notices.write_text('Complete additional notices')
        instructions.write_text('Exact release source and relinking instructions')
        with patch.object(p, 'verify_signature', return_value=True):
            with self.assertRaises(ValueError):
                p.generate(self.ipa, self.root / 'no-docs', 'https://example.org/', '0.8.3~beta1')
            with self.assertRaises(ValueError):
                p.generate(self.ipa, self.root / 'old-ipa', 'https://example.org/', '0.8.3~beta1', False, notices, instructions)
            self.files['ThirdPartyNotices.txt'] += notices.read_bytes()
            self.write_zip()
            receipt = p.generate(self.ipa, self.root / 'complete', 'https://example.org/', '0.8.3~beta1', False, notices, instructions)
            self.assertEqual(receipt['supplementaryNoticesSHA256'], p.sha256(notices.read_bytes()))
            self.assertEqual(receipt['sourceInstructionsSHA256'], p.sha256(instructions.read_bytes()))

    def test_unsafe_url_rejected(self):
        for value in ('http://example.org/', 'https://user:secret@example.org/', 'https://example.org/?token=x',
                      'https://example.org/../other/', 'https://example.org/#fragment'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                p.base_url(value)

    def test_traversal_and_external_files_rejected(self):
        for name in ('Payload/StremIOS.app/../outside', '/absolute', 'Payload/Other.app/Info.plist', 'secret.json'):
            self.write_zip((name, b'bad'))
            with self.subTest(name=name), self.assertRaises(ValueError):
                p.read_app(self.ipa, p.TEST_ID)

    def test_symlink_rejected(self):
        info = zipfile.ZipInfo('Payload/StremIOS.app/link')
        info.external_attr = 0o120777 << 16
        self.write_zip((info, b'/var/mobile'))
        with self.assertRaises(ValueError):
            p.read_app(self.ipa, p.TEST_ID)

    def test_identity_and_wrong_binary_rejected(self):
        with self.assertRaises(ValueError):
            p.read_app(self.ipa, 'local.ministream.ipad')
        self.files['StremIOS'] = b'not Mach-O'
        self.write_zip()
        with self.assertRaises(ValueError):
            p.read_app(self.ipa, p.TEST_ID)


class ScriptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.app = self.root / 'Applications/StremIOS.app'
        self.tools = self.root / 'tools'
        self.tools.mkdir()
        self.env = dict(os.environ, TOOL_LOG=str(self.root / 'calls'), REGISTRATION='', OWNER='', UI_FAIL='0')
        for name, source in {
            'uicache': '#!/bin/sh\nprintf "%s\\n" "$*" >> "$TOOL_LOG"\n[ "$UI_FAIL" = 0 ] || exit 1\n[ "$1" != -l ] || printf "%s\\n" "$REGISTRATION"\n',
            'dpkg-query': '#!/bin/sh\n[ -n "$OWNER" ] || exit 1\nprintf "%s\\n" "$OWNER"\n'
        }.items():
            (self.tools / name).write_text(source)
            (self.tools / name).chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, name, action):
        text = (ROOT / 'packaging/templates' / name).read_text()
        text = p.replace_tokens(text, {'PACKAGE': 'local.ministream.ipad', 'BUNDLE': 'local.ministream.ipad', 'APP_PATH': str(self.app)})
        text = text.replace('PATH=/usr/sbin:/usr/bin:/sbin:/bin', 'PATH=' + str(self.tools))
        script = self.root / name
        script.write_text(text)
        return subprocess.run(['/bin/sh', str(script), action], env=self.env, capture_output=True)

    def test_no_awk_or_extra_parser_dependency(self):
        self.assertIsNone(shutil.which('awk', path=str(self.tools)))
        self.env['REGISTRATION'] = 'irrelevant.app : /Applications/Other.app\nlocal.ministream.ipad : /var/containers/Bundle/Application/UUID/StremIOS.app'
        result = self.run_script('preinst', 'install')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'already installed through an IPA', result.stderr)

    def test_existing_ipa_refused_without_changes(self):
        self.env['REGISTRATION'] = 'local.ministream.ipad : /var/containers/Bundle/Application/UUID/StremIOS.app'
        result = self.run_script('preinst', 'install')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'already installed through an IPA', result.stderr)
        self.assertFalse(self.app.exists())
        self.assertEqual((self.root / 'calls').read_text(), '-l\n')

    def test_fresh_install_allowed(self):
        self.assertEqual(self.run_script('preinst', 'install').returncode, 0)

    def test_unmanaged_and_linked_target_refused(self):
        self.app.mkdir(parents=True)
        self.assertNotEqual(self.run_script('preinst', 'upgrade').returncode, 0)
        self.app.rmdir()
        self.app.symlink_to(self.root)
        self.assertNotEqual(self.run_script('preinst', 'install').returncode, 0)

    def test_owned_upgrade_allowed(self):
        self.app.mkdir(parents=True)
        self.env['OWNER'] = 'local.ministream.ipad: ' + str(self.app / 'Info.plist')
        self.env['REGISTRATION'] = 'local.ministream.ipad : ' + str(self.app)
        self.assertEqual(self.run_script('preinst', 'upgrade').returncode, 0)

    def test_registration_query_fails_closed(self):
        self.env['UI_FAIL'] = '1'
        self.assertNotEqual(self.run_script('preinst', 'install').returncode, 0)

    def test_upgrade_does_not_unregister(self):
        self.assertEqual(self.run_script('prerm', 'upgrade').returncode, 0)
        self.assertFalse((self.root / 'calls').exists())

    def test_remove_unregisters_only_exact_app(self):
        self.assertEqual(self.run_script('prerm', 'remove').returncode, 0)
        self.assertEqual((self.root / 'calls').read_text(), '-u ' + str(self.app) + '\n')

    def test_configure_and_abort_restore_registration(self):
        for action in ('configure', 'abort-upgrade', 'abort-remove', 'abort-deconfigure'):
            self.assertEqual(self.run_script('postinst', action).returncode, 0)
        self.assertEqual((self.root / 'calls').read_text(), ('-p ' + str(self.app) + '\n') * 4)


if __name__ == '__main__':
    unittest.main(verbosity=2)
