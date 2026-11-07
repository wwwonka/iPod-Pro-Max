#!/usr/bin/env python3
"""Create a FAT32 image copy with a mixed-case volume label for Finder testing.

This experimental tool accepts regular image files only. It never opens a disk
or changes the source image. Input must be an unmounted FAT32 volume image,
not an image containing a partition table.
"""
import argparse
import os
import shutil
import stat
import struct
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', help='unmounted FAT32 volume image')
    parser.add_argument('output', help='new image to create; must not already exist')
    parser.add_argument('label', help='1–11 ASCII letters, digits, spaces, hyphens or underscores')
    args = parser.parse_args()
    try:
        label = args.label.encode('ascii')
        if not 1 <= len(label) <= 11 or args.label != args.label.strip() or not all(chr(c).isalnum() or chr(c) in ' -_' for c in label):
            raise ValueError('label must be 1–11 ASCII letters, digits, spaces, hyphens or underscores, with no surrounding spaces')
        src_fd = os.open(args.source, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(src_fd, 'rb') as src:
            if not stat.S_ISREG(os.fstat(src.fileno()).st_mode):
                raise ValueError('source must be a regular image file')
            with open(args.output, 'xb') as dst:
                shutil.copyfileobj(src, dst)
        try:
            patch(args.output, label.ljust(11, b' '))
        except BaseException:
            os.unlink(args.output)
            raise
        print('Created:', args.output)
        print('Mount the copy read-only, verify its name in Finder, eject it and mount it again.')
    except (OSError, ValueError) as error:
        print('Error:', error, file=sys.stderr)
        sys.exit(1)


def patch(path, label, *, device_size=None, expected_label=None, dry_run=False, report=False, device_block_size=512, repair_duplicate=False):
    """Patch an offline FAT32 volume. Callers must ensure exclusive access."""
    with open(path, 'rb' if dry_run else 'r+b', buffering=0) as f:
        size = device_size if device_size is not None else os.fstat(f.fileno()).st_size
        boot = f.read(device_block_size)
        if len(boot) != device_block_size or boot[510:512] != b'\x55\xaa':
            raise ValueError('invalid boot sector')
        u16 = lambda off: struct.unpack_from('<H', boot, off)[0]
        u32 = lambda off: struct.unpack_from('<I', boot, off)[0]
        bps, spc, reserved, fats, fatsz, root = u16(11), boot[13], u16(14), boot[16], u32(36), u32(44)
        total, backup = u32(32), u16(50)
        if bps not in (512, 1024, 2048, 4096) or device_block_size not in (512, 1024, 2048, 4096) or bps % device_block_size or spc == 0 or spc & (spc - 1) or not reserved or not fats or not fatsz or u16(17) or u16(22) or boot[66] != 0x29:
            raise ValueError('unsupported or invalid FAT32 layout')
        data_start = reserved + fats * fatsz
        if not total or total * bps > size or data_start >= total:
            raise ValueError('invalid volume size')
        count = (total - data_start) // spc
        if count < 65525 or root < 2 or root >= count + 2:
            raise ValueError('not a valid FAT32 cluster layout')
        if fatsz * bps < (count + 2) * 4:
            raise ValueError('FAT is too small')
        flags = u16(40)
        fat_index = (flags & 15) if flags & 0x80 else 0
        if fat_index >= fats:
            raise ValueError('invalid active FAT')
        visited = set()
        cluster = root
        labels = []
        preceding = []
        free_slot = None
        while True:
            if cluster in visited or cluster < 2 or cluster >= count + 2:
                raise ValueError('invalid root directory cluster chain')
            visited.add(cluster)
            offset = (data_start + (cluster - 2) * spc) * bps
            f.seek(offset)
            data = f.read(spc * bps)
            if len(data) != spc * bps:
                raise ValueError('truncated root directory')
            end = False
            for i in range(0, len(data), 32):
                entry = data[i:i+32]
                if entry[0] == 0:
                    if free_slot is None and i + 32 < len(data) and not preceding:
                        free_slot = (offset + i, offset + i + 32)
                    end = True
                    break
                if entry[0] == 0xe5:
                    if free_slot is None and not preceding:
                        free_slot = (offset + i, None)
                    preceding = []
                elif entry[11] == 0x0f:
                    preceding.append((offset + i, entry))
                else:
                    if entry[11] & 0x08:
                        labels.append((offset + i, entry, preceding))
                    preceding = []
            if end:
                break
            fat_entry_offset = (reserved + fat_index * fatsz) * bps + cluster * 4
            f.seek((fat_entry_offset // bps) * bps)
            fat_sector = f.read(bps)
            if len(fat_sector) != bps:
                raise ValueError('truncated FAT sector')
            value = struct.unpack_from('<I', fat_sector, fat_entry_offset % bps)[0] & 0x0fffffff
            if value >= 0x0ffffff8:
                break
            cluster = value
        if report and len(labels) > 1:
            print('Secteur principal :', repr(boot[71:82]), '(offset 71)', flush=True)
            for entry_offset, entry, _ in labels:
                print('Étiquette racine candidate :', repr(entry[:11]),
                      '(attribut 0x%02x, offset %d)' % (entry[11], entry_offset), flush=True)
            if dry_run and not repair_duplicate:
                return {'boot_label': boot[71:82], 'labels': [(e[:11], e[11]) for _, e, _ in labels]}
        duplicate_offset = None
        if repair_duplicate:
            if (len(labels) != 2 or boot[71:82] != label
                or labels[0][1][:12] != b'H9G6       \x28'
                or labels[1][1][:12] != b'iPod       \x08'
                or labels[0][2] or labels[1][2]):
                raise ValueError('les deux étiquettes ne correspondent pas exactement au cas attendu ; aucune écriture')
            duplicate_offset = labels[1][0]
            labels = labels[:1]
        if len(labels) > 1 or (not labels and expected_label is None):
            raise ValueError('expected exactly one existing volume label; found %d' % len(labels))
        if not labels and free_slot is None:
            raise ValueError('no safely reusable root directory slot for volume label')
        label_offset, old, lfn = labels[0] if labels else (None, None, [])
        if report:
            print('Secteur principal :', repr(boot[71:82]), '(offset 71)', flush=True)
            print('Étiquette racine :', repr(old[:11]) if old else 'absente',
                  '(offset %d)' % label_offset if label_offset is not None else '(création offset %d)' % free_slot[0], flush=True)
        if expected_label is not None and not dry_run and not repair_duplicate:
            if boot[71:82] != expected_label or (old is not None and old[:11] not in (expected_label, label)):
                raise ValueError('existing root or boot label is not the expected label')
            if lfn:
                raise ValueError('existing label has long-name entries; refusing to change it')
        # Remove an associated VFAT name only after validating the complete chain.
        if lfn:
            checksum = 0
            for byte in old[:11]:
                checksum = (((checksum & 1) << 7) | (checksum >> 1))
                checksum = (checksum + byte) & 0xff
            n = len(lfn)
            if n > 20 or any(e[11] != 0x0f or e[12] != 0 or e[13] != checksum or e[26:28] != b'\0\0' or e[0] != ((n-j) | (0x40 if j == 0 else 0)) for j, (_, e) in enumerate(lfn)):
                raise ValueError('unexpected long-name entries before label')
        backup_offset = None
        if backup not in (0, 0xffff):
            if backup >= reserved:
                raise ValueError('invalid backup boot sector')
            backup_offset = backup * bps
            f.seek(backup_offset)
            backup_boot = f.read(bps)
            if len(backup_boot) != bps or backup_boot[510:512] != b'\x55\xaa' or backup_boot[11:64] != boot[11:64] or backup_boot[66] != 0x29:
                raise ValueError('backup boot sector does not match')
            # System rename utilities need not update the backup label. Its
            # structure was verified above, so it can safely be synchronized.
        # Raw block devices require sector-aligned writes. Gather each changed
        # sector before writing so all layout checks complete before mutation.
        changes = [(offset, b'\xe5') for offset, _ in lfn]
        if duplicate_offset is not None:
            changes.append((duplicate_offset, b'\xe5'))
        if label_offset is not None:
            changes.append((label_offset, label))
        else:
            slot, end_marker = free_slot
            changes.append((slot, label + b'\x08' + bytes(20)))
            if end_marker is not None:
                changes.append((end_marker, b'\x00'))
        changes.append((71, label))
        if backup_offset is not None:
            changes.append((backup_offset + 71, label))
        sectors = {}
        for offset, value in changes:
            base = (offset // bps) * bps
            if offset + len(value) > base + bps:
                raise ValueError('label crosses a sector boundary')
            if base not in sectors:
                f.seek(base)
                sectors[base] = bytearray(f.read(bps))
                if len(sectors[base]) != bps:
                    raise ValueError('cannot read complete sector')
            sectors[base][offset - base:offset - base + len(value)] = value
        if report:
            if backup_offset is not None:
                print('Secteur de secours :', repr(backup_boot[71:82]), '(offset %d)' % (backup_offset + 71))
        if dry_run:
            return {'boot_label': boot[71:82], 'labels': [(e[:11], e[11]) for _, e, _ in labels]}
        for base, sector in sectors.items():
            f.seek(base)
            if f.write(sector) != bps:
                raise OSError('short sector write')
        os.fsync(f.fileno())
        for base, sector in sectors.items():
            f.seek(base)
            if f.read(bps) != sector:
                raise OSError('sector verification failed')


if __name__ == '__main__':
    main()
