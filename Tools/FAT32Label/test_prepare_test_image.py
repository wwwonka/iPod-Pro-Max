#!/usr/bin/env python3
"""Integration tests for the image-only FAT32 label experiment."""
import os
import importlib.util
import pathlib
import shutil
import subprocess
import tempfile
import unittest

TOOL = pathlib.Path(__file__).with_name('prepare-test-image.py')


@unittest.skipUnless(shutil.which('mkfs.fat') and shutil.which('mlabel'), 'requires dosfstools and mtools')
class FAT32ImageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.source = pathlib.Path(self.tmp.name) / 'source.img'
        self.output = pathlib.Path(self.tmp.name) / 'output.img'
        with self.source.open('wb') as image:
            image.truncate(128 * 1024 * 1024)
        subprocess.run(['mkfs.fat', '-F', '32', '-n', 'IPOD', str(self.source)], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(['mlabel', '-i', str(self.source), '::iPod Julien'], check=True)

    def run_tool(self, name='Mon iPod'):
        return subprocess.run(['python3', str(TOOL), str(self.source), str(self.output), name], capture_output=True, text=True)

    def test_mixed_case_written_to_root_and_both_boot_sectors(self):
        original_stat = self.source.stat()
        self.assertEqual(self.run_tool().returncode, 0)
        self.assertEqual(self.source.stat().st_mtime_ns, original_stat.st_mtime_ns)
        with self.output.open('rb') as image:
            boot = image.read(512)
            bps = int.from_bytes(boot[11:13], 'little')
            data = int.from_bytes(boot[14:16], 'little') + boot[16] * int.from_bytes(boot[36:40], 'little')
            root = int.from_bytes(boot[44:48], 'little')
            image.seek((data + (root - 2) * boot[13]) * bps)
            directory = image.read(96)
            image.seek(int.from_bytes(boot[50:52], 'little') * bps + 71)
            backup_label = image.read(11)
        self.assertEqual(boot[71:82], b'Mon iPod   ')
        self.assertEqual(backup_label, b'Mon iPod   ')
        self.assertEqual(directory[0], 0xe5)  # old VFAT long-name slot
        self.assertEqual(directory[32:43], b'Mon iPod   ')
        self.assertEqual(directory[43], 0x08)
        if shutil.which('fsck.fat'):
            subprocess.run(['fsck.fat', '-n', str(self.output)], check=True, stdout=subprocess.DEVNULL)

    def test_only_label_sectors_change(self):
        self.assertEqual(self.run_tool().returncode, 0)
        with self.source.open('rb') as before, self.output.open('rb') as after:
            boot = before.read(512)
            bps = int.from_bytes(boot[11:13], 'little')
            data = int.from_bytes(boot[14:16], 'little') + boot[16] * int.from_bytes(boot[36:40], 'little')
            root = int.from_bytes(boot[44:48], 'little')
            root_sector = data + (root - 2) * boot[13]
            allowed = {0, int.from_bytes(boot[50:52], 'little'), root_sector}
            before.seek(0)
            i = 0
            while True:
                a, b = before.read(1024 * 1024), after.read(1024 * 1024)
                if not a:
                    break
                if a != b:
                    for j in range(0, len(a), bps):
                        if a[j:j+bps] != b[j:j+bps]:
                            self.assertIn(i + j // bps, allowed)
                i += len(a) // bps

    def test_exact_expected_label_checks_before_writing(self):
        spec = importlib.util.spec_from_file_location('fat_test', TOOL)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        # Replace the mixed-label fixture with an ordinary IPOD volume.
        subprocess.run(['mkfs.fat', '-F', '32', '-n', 'IPOD', str(self.source)], check=True, stdout=subprocess.DEVNULL)
        with self.assertRaises(ValueError):
            module.patch(self.source, b'iPod       ', expected_label=b'WRONG      ')
        subprocess.run(['fsck.fat', '-n', str(self.source)], check=True, stdout=subprocess.DEVNULL)
        module.patch(self.source, b'iPod       ', expected_label=b'IPOD       ')
        result = subprocess.run(['mlabel', '-i', str(self.source), '-s', '::'], capture_output=True, text=True, check=True)
        self.assertIn('iPod', result.stdout)
        subprocess.run(['fsck.fat', '-n', str(self.source)], check=True, stdout=subprocess.DEVNULL)

    def test_rename_when_root_has_no_volume_label(self):
        spec = importlib.util.spec_from_file_location('fat_test', TOOL)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        subprocess.run(['mkfs.fat', '-F', '32', '-n', 'IPOD', str(self.source)], check=True, stdout=subprocess.DEVNULL)
        with self.source.open('r+b') as image:
            boot = image.read(512)
            bps = int.from_bytes(boot[11:13], 'little')
            root = int.from_bytes(boot[44:48], 'little')
            data = int.from_bytes(boot[14:16], 'little') + boot[16] * int.from_bytes(boot[36:40], 'little')
            root_offset = (data + (root - 2) * boot[13]) * bps
            image.seek(root_offset)
            self.assertEqual(image.read(11), b'IPOD       ')
            image.seek(root_offset)
            image.write(b'\xe5')
        module.patch(self.source, b'iPod       ', expected_label=b'IPOD       ')
        with self.source.open('rb') as image:
            boot = image.read(512)
            self.assertEqual(boot[71:82], b'iPod       ')
            image.seek(int.from_bytes(boot[50:52], 'little') * bps + 71)
            self.assertEqual(image.read(11), b'iPod       ')
            image.seek(root_offset)
            self.assertEqual(image.read(12), b'iPod       \x08')
        subprocess.run(['fsck.fat', '-n', str(self.source)], check=True, stdout=subprocess.DEVNULL)

    def test_marker_boot_and_already_renamed_root(self):
        spec = importlib.util.spec_from_file_location('fat_test', TOOL)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        subprocess.run(['mkfs.fat', '-F', '32', '-n', 'H9G6', str(self.source)], check=True, stdout=subprocess.DEVNULL)
        with self.source.open('r+b') as image:
            boot = image.read(512)
            bps = int.from_bytes(boot[11:13], 'little')
            data = int.from_bytes(boot[14:16], 'little') + boot[16] * int.from_bytes(boot[36:40], 'little')
            root = int.from_bytes(boot[44:48], 'little')
            image.seek((data + (root - 2) * boot[13]) * bps)
            image.write(b'iPod       ')
        module.patch(self.source, b'iPod       ', expected_label=b'H9G6       ', dry_run=True)
        module.patch(self.source, b'iPod       ', expected_label=b'H9G6       ')
        subprocess.run(['fsck.fat', '-n', str(self.source)], check=True, stdout=subprocess.DEVNULL)
        result = subprocess.run(['mlabel', '-i', str(self.source), '-s', '::'], capture_output=True, text=True, check=True)
        self.assertIn('iPod', result.stdout)

    def test_repair_exact_duplicate_preserves_original_attributes(self):
        spec = importlib.util.spec_from_file_location('fat_test', TOOL)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        subprocess.run(['mkfs.fat', '-F', '32', '-n', 'H9G6', str(self.source)], check=True, stdout=subprocess.DEVNULL)
        with self.source.open('r+b') as image:
            boot = image.read(512)
            bps = int.from_bytes(boot[11:13], 'little')
            data = int.from_bytes(boot[14:16], 'little') + boot[16] * int.from_bytes(boot[36:40], 'little')
            root = int.from_bytes(boot[44:48], 'little')
            off = (data + (root - 2) * boot[13]) * bps
            image.seek(71); image.write(b'iPod       ')
            image.seek(off + 11); image.write(b'\x28')
            image.seek(off + 32); image.write(b'iPod       \x08' + bytes(20))
        module.patch(self.source, b'iPod       ', expected_label=b'H9G6       ', repair_duplicate=True)
        with self.source.open('rb') as image:
            image.seek(off); self.assertEqual(image.read(12), b'iPod       \x28')
            image.seek(off + 32); self.assertEqual(image.read(1), b'\xe5')
        subprocess.run(['fsck.fat', '-n', str(self.source)], check=True, stdout=subprocess.DEVNULL)

    def test_generic_name_and_volume_attribute(self):
        spec = importlib.util.spec_from_file_location('fat_test', TOOL)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        subprocess.run(['mkfs.fat', '-F', '32', '-n', 'MUSIC', str(self.source)], check=True, stdout=subprocess.DEVNULL)
        with self.source.open('r+b') as image:
            boot = image.read(512)
            bps = int.from_bytes(boot[11:13], 'little')
            data = int.from_bytes(boot[14:16], 'little') + boot[16] * int.from_bytes(boot[36:40], 'little')
            root = int.from_bytes(boot[44:48], 'little')
            offset = (data + (root - 2) * boot[13]) * bps
            image.seek(offset + 11); image.write(b'\x28')
        info = module.patch(self.source, b'My Music   ', expected_label=b'H9G6       ', dry_run=True, report=True)
        self.assertEqual(info['boot_label'], b'MUSIC      ')
        self.assertEqual(info['labels'], [(b'MUSIC      ', 0x28)])
        module.patch(self.source, b'My Music   ', expected_label=info['boot_label'])
        with self.source.open('rb') as image:
            image.seek(offset); self.assertEqual(image.read(12), b'My Music   \x28')
        subprocess.run(['fsck.fat', '-n', str(self.source)], check=True, stdout=subprocess.DEVNULL)

    def test_invalid_name_does_not_create_output(self):
        self.assertNotEqual(self.run_tool('This is too long').returncode, 0)
        self.assertFalse(self.output.exists())

    def test_refuses_existing_output(self):
        self.output.write_bytes(b'keep')
        self.assertNotEqual(self.run_tool().returncode, 0)
        self.assertEqual(self.output.read_bytes(), b'keep')

    def test_rejects_corrupt_boot_sector_and_cleans_copy(self):
        with self.source.open('r+b') as image:
            image.seek(510)
            image.write(b'\0\0')
        self.assertNotEqual(self.run_tool().returncode, 0)
        self.assertFalse(self.output.exists())


if __name__ == '__main__':
    unittest.main()
