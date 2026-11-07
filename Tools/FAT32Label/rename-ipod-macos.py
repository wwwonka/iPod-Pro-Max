#!/usr/bin/env python3
"""Rename an unambiguously identified mounted FAT32 iPod volume.

Run on macOS from a copy on the computer, with sudo, providing the exact mount
point. The volume is unmounted before any direct disk access and remounted.
"""
import importlib.util
import os
import plistlib
import re
import shlex
import subprocess
import sys
from pathlib import Path


def disk_info(target):
    result = subprocess.run(['/usr/sbin/diskutil', 'info', '-plist', target],
                            capture_output=True, check=True)
    return plistlib.loads(result.stdout)


def main():
    if sys.platform != 'darwin' or os.geteuid() != 0:
        raise ValueError('Lancez ce script sur macOS avec sudo.')
    interactive = len(sys.argv) == 1
    if interactive:
        print('Glisse l’icône du volume de l’iPod dans cette fenêtre, puis appuie sur Entrée.')
        entered = input('iPod : ').strip()
        if not entered:
            raise ValueError('Aucun volume indiqué.')
        if os.path.exists(entered):
            path = entered
        else:
            try:
                parts = shlex.split(entered)
            except ValueError as error:
                raise ValueError('Chemin de volume invalide.') from error
            if len(parts) != 1:
                raise ValueError('Glisse une seule icône de volume dans le Terminal.')
            path = parts[0]
        mode = '--interactive'
    elif len(sys.argv) == 3 and sys.argv[1] in ('--inspect', '--apply', '--repair-duplicate'):
        mode, path = sys.argv[1:]
    else:
        raise ValueError('Usage : sudo python3 rename-ipod-macos.py [--inspect|--apply|--repair-duplicate /Volumes/H9G6]')
    inspect = mode == '--inspect'
    mount = os.path.realpath(path)
    info = disk_info(mount)
    identifier = info.get('DeviceIdentifier', '')
    if (not re.fullmatch(r'disk[0-9]+s[0-9]+', identifier)
        or info.get('MountPoint') != mount or not info.get('VolumeName')
        or info.get('FilesystemType') != 'msdos' or info.get('Internal') is not False
        or not info.get('Ejectable') or not info.get('WritableMedia')
        or not info.get('VolumeUUID') or not isinstance(info.get('Size'), int)
        or not (Path(mount) / 'iPod_Control').is_dir()):
        raise ValueError('Le volume doit être un iPod externe FAT32 monté, avec UUID et iPod_Control.')
    if os.path.commonpath([os.path.realpath(__file__), mount]) == mount:
        raise ValueError('Lancez le script depuis le Mac, pas depuis l’iPod.')
    old_name = info['VolumeName']
    if interactive:
        print(f'Nom actuel : {old_name}')
        new_name = input('Nouveau nom (1 à 11 lettres ASCII, chiffres, espaces, - ou _) : ')
        if (not 1 <= len(new_name) <= 11 or new_name != new_name.strip()
            or not all(c.isascii() and (c.isalnum() or c in ' -_') for c in new_name)):
            raise ValueError('Nom invalide : utiliser 1 à 11 lettres ASCII, chiffres, espaces, tirets ou soulignés.')
    else:
        new_name = 'iPod'
    label = new_name.encode('ascii').ljust(11, b' ')
    node = '/dev/' + identifier
    uuid = info['VolumeUUID']
    size = info['Size']
    block_size = info.get('DeviceBlockSize')
    if block_size not in (512, 1024, 2048, 4096):
        raise ValueError('Taille de bloc du disque non prise en charge.')
    print(f'iPod détecté : {mount} ({node}, {size} octets).', flush=True)
    print('Démontage du volume…', flush=True)
    subprocess.run(['/usr/sbin/diskutil', 'unmount', node], check=True)
    try:
        current = disk_info(node)
        if (current.get('MountPoint') or current.get('DeviceIdentifier') != identifier
            or current.get('VolumeUUID') != uuid or current.get('Size') != size
            or current.get('Internal') is not False or current.get('FilesystemType') != 'msdos'):
            raise ValueError('La partition a changé ou est remontée ; aucune écriture effectuée.')
        module_path = Path(__file__).with_name('prepare-test-image.py')
        spec = importlib.util.spec_from_file_location('fat32_image', module_path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        raw_node = '/dev/r' + identifier
        print('Lecture par le périphérique brut :', flush=True)
        details = module.patch(raw_node, label, device_size=size, expected_label=b'H9G6       ', dry_run=True, report=True, device_block_size=block_size)
        if inspect:
            print('Lecture par le périphérique bloc :', flush=True)
            module.patch(node, label, device_size=size, expected_label=b'H9G6       ', dry_run=True, report=True, device_block_size=block_size)
        if not inspect:
            repair = mode == '--repair-duplicate' or (interactive and new_name == 'iPod'
                and details['boot_label'] == b'iPod       '
                and details['labels'] == [(b'H9G6       ', 0x28), (b'iPod       ', 0x08)])
            if repair:
                print('Deux étiquettes reconnues : correction de l’entrée supplémentaire.', flush=True)
            module.patch(raw_node, label, device_size=size, expected_label=details['boot_label'], device_block_size=block_size, repair_duplicate=repair)
            print(f'Étiquette FAT32 écrite et relue : {new_name}.', flush=True)
        else:
            print('Diagnostic terminé : aucune écriture effectuée.', flush=True)
    finally:
        try:
            current = disk_info(node)
            if (current.get('DeviceIdentifier') == identifier and current.get('VolumeUUID') == uuid
                and current.get('Size') == size and not current.get('MountPoint')):
                subprocess.run(['/usr/sbin/diskutil', 'mount', node], check=True)
        except Exception as error:
            print(f'Impossible de remonter automatiquement {node} : {error}', file=sys.stderr)
    after = disk_info(node)
    if after.get('VolumeName') != (old_name if inspect else new_name) or not after.get('MountPoint'):
        raise ValueError('Le nom après remontage ne correspond pas au nom attendu ; vérifiez le volume dans Utilitaire de disque.')
    print('Vérifié après remontage :', after['VolumeName'])


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        print(f'Erreur : {error}', file=sys.stderr)
        sys.exit(1)
