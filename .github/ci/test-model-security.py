#!/usr/bin/env python3
"""Focused supply-chain checks; no model downloads or Apple compiler required."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('model_download', HERE / 'get-model.py')
download = importlib.util.module_from_spec(spec)
spec.loader.exec_module(download)


class ModelSecurityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.out = Path(self.temporary.name) / 'Models'
        self.content = b'pinned model bytes'
        self.expected = {'size': len(self.content), 'sha256': hashlib.sha256(self.content).hexdigest()}

    def test_same_size_tampering_rejected_and_repaired(self):
        path = self.out / 'file'
        path.parent.mkdir()
        path.write_bytes(b'X' * len(self.content))
        self.assertFalse(download.valid_file(path, self.expected))
        with patch.object(download.urllib.request, 'urlopen', return_value=io.BytesIO(self.content)):
            download.download_verified('https://example.test/immutable', path, self.expected)
        self.assertTrue(download.valid_file(path, self.expected))

    def test_invalid_download_never_replaces_valid_cache(self):
        path = self.out / 'file'
        with patch.object(download.urllib.request, 'urlopen', side_effect=lambda *a, **k: io.BytesIO(b'bad')), patch.object(download.time, 'sleep'):
            with self.assertRaises(ValueError):
                download.download_verified('https://example.test/immutable', path, self.expected)
        self.assertFalse(path.exists())
        self.assertFalse(path.with_name('file.download').exists())

    def test_verified_cache_avoids_network(self):
        path = self.out / 'file'
        path.parent.mkdir()
        path.write_bytes(self.content)
        with patch.object(download.urllib.request, 'urlopen', side_effect=AssertionError('network should not run')):
            download.download_verified('https://example.test/immutable', path, self.expected)

    def test_old_compiled_cache_rebuilt_and_extra_inputs_ignored(self):
        model = {'name': 'Fixture', 'repository': 'owner/model', 'revision': 'a' * 40, 'files': {'Manifest.json': self.expected}}
        cache = self.out / '.verified-packages' / model['revision'] / 'Fixture.mlpackage'
        cache.mkdir(parents=True)
        (cache / 'Manifest.json').write_bytes(self.content)
        (cache / 'untrusted').write_bytes(b'not in lock')
        old = self.out / 'Fixture.mlmodelc'
        old.mkdir()
        (old / 'old').write_bytes(b'old compiled cache')
        def compiler(command, check):
            self.assertEqual(command[:3], ['xcrun', 'coremlcompiler', 'compile'])
            package = Path(command[3])
            self.assertEqual([p.name for p in package.iterdir()], ['Manifest.json'])
            generated = Path(command[4]) / 'Fixture.mlmodelc'
            generated.mkdir()
            (generated / 'verified').write_bytes(b'new compiler output')
        with patch.object(download.subprocess, 'run', side_effect=compiler), patch.object(download.urllib.request, 'urlopen', side_effect=AssertionError('network should not run')):
            download.compile_model(model, self.out)
        self.assertFalse((old / 'old').exists())
        self.assertTrue((old / 'verified').exists())

    def test_compiler_failure_preserves_existing_output(self):
        model = {'name': 'Fixture', 'repository': 'owner/model', 'revision': 'a' * 40, 'files': {'Manifest.json': self.expected}}
        cache = self.out / '.verified-packages' / model['revision'] / 'Fixture.mlpackage'
        cache.mkdir(parents=True)
        (cache / 'Manifest.json').write_bytes(self.content)
        old = self.out / 'Fixture.mlmodelc'
        old.mkdir()
        (old / 'old').write_bytes(b'existing')
        with patch.object(download.subprocess, 'run', side_effect=RuntimeError('compiler failed')):
            with self.assertRaises(RuntimeError):
                download.compile_model(model, self.out)
        self.assertTrue((old / 'old').exists())

    def test_lock_contains_only_immutable_validated_packages(self):
        lock = json.loads((HERE / 'model-lock.json').read_text())
        self.assertEqual(set(lock['models']), {'depth', 'seg', 'heal'})
        for model in lock['models'].values():
            self.assertRegex(model['revision'], r'^[0-9a-f]{40}$')
            self.assertEqual(set(model['files']), {'Manifest.json', 'Data/com.apple.CoreML/model.mlmodel', 'Data/com.apple.CoreML/weights/weight.bin'})
            for expected in model['files'].values():
                self.assertGreater(expected['size'], 0)
                self.assertRegex(expected['sha256'], r'^[0-9a-f]{64}$')


if __name__ == '__main__':
    unittest.main()
