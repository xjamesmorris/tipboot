#!/usr/bin/env python3

import argparse
import os
from pathlib import Path
import re
import stat
import struct
import sys
import tempfile
import zlib


NEWC_MAGIC = b"070701"
NEWC_HEADER_SIZE = 110
TRAILER = "TRAILER!!!"
RELEASE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+~-]{0,127}\Z")

ELF_HEADER = struct.Struct("<16sHHIQQQIHHHHHH")
PROGRAM_HEADER = struct.Struct("<IIQQQQQQ")
ET_EXEC = 2
EM_AARCH64 = 183
PT_LOAD = 1
PT_DYNAMIC = 2
PT_INTERP = 3
PF_X = 1


class ValidationError(Exception):
    pass


def validate_release(release):
    if not RELEASE_RE.fullmatch(release):
        raise ValidationError(
            "kernel release must be 1-128 ASCII alphanumeric, '.', '_', '+', "
            "'~', or '-' characters and start with an alphanumeric character"
        )
    return release.encode("ascii")


def validate_init(data, release):
    if len(data) < ELF_HEADER.size:
        raise ValidationError("/init is too small to be an ELF executable")

    (
        ident,
        elf_type,
        machine,
        version,
        entry,
        program_offset,
        _section_offset,
        _flags,
        elf_header_size,
        program_entry_size,
        program_count,
        _section_entry_size,
        _section_count,
        _section_names,
    ) = ELF_HEADER.unpack_from(data)

    if ident[:4] != b"\x7fELF":
        raise ValidationError("/init is not an ELF executable")
    if ident[4] != 2 or ident[5] != 1 or ident[6] != 1:
        raise ValidationError("/init must be ELF64, little-endian, ELF version 1")
    if elf_type != ET_EXEC:
        raise ValidationError("/init must be an ET_EXEC executable")
    if machine != EM_AARCH64:
        raise ValidationError("/init must target AArch64")
    if version != 1 or elf_header_size != ELF_HEADER.size:
        raise ValidationError("/init has an invalid ELF header")
    if program_count == 0 or program_entry_size < PROGRAM_HEADER.size:
        raise ValidationError("/init has no usable program headers")

    program_end = program_offset + program_entry_size * program_count
    if program_end > len(data):
        raise ValidationError("/init has truncated program headers")

    load_count = 0
    entry_is_executable = False
    for index in range(program_count):
        offset = program_offset + index * program_entry_size
        (
            segment_type,
            segment_flags,
            file_offset,
            virtual_address,
            _physical_address,
            file_size,
            memory_size,
            _alignment,
        ) = PROGRAM_HEADER.unpack_from(data, offset)

        if segment_type in (PT_DYNAMIC, PT_INTERP):
            raise ValidationError("/init must be static and have no dynamic loader")
        if segment_type != PT_LOAD:
            continue

        load_count += 1
        if file_offset + file_size > len(data):
            raise ValidationError("/init has a truncated load segment")
        if (
            segment_flags & PF_X
            and virtual_address <= entry < virtual_address + memory_size
        ):
            entry_is_executable = True

    if load_count == 0:
        raise ValidationError("/init has no loadable segments")
    if not entry_is_executable:
        raise ValidationError("/init entry point is not in an executable segment")

    release_bytes = validate_release(release)
    marker = b"TIPBOOT_OK kernel_release=" + release_bytes + b"\n"
    if data.count(marker) != 1:
        raise ValidationError("/init must contain exactly one expected success marker")
    if data.count(b"TIPBOOT_OK") != 1:
        raise ValidationError("/init contains an unexpected TIPBOOT_OK marker")


def newc_header(
    inode,
    mode,
    uid,
    gid,
    links,
    mtime,
    size,
    device_major,
    device_minor,
    rdevice_major,
    rdevice_minor,
    name_size,
    checksum=0,
):
    values = (
        inode,
        mode,
        uid,
        gid,
        links,
        mtime,
        size,
        device_major,
        device_minor,
        rdevice_major,
        rdevice_minor,
        name_size,
        checksum,
    )
    return NEWC_MAGIC + b"".join(f"{value:08x}".encode("ascii") for value in values)


def pad(buffer, alignment):
    remainder = len(buffer) % alignment
    if remainder:
        buffer.extend(b"\0" * (alignment - remainder))


def append_entry(
    archive,
    *,
    inode,
    name,
    mode,
    links,
    payload=b"",
    rdevice_major=0,
    rdevice_minor=0,
):
    encoded_name = name.encode("ascii") + b"\0"
    archive.extend(
        newc_header(
            inode=inode,
            mode=mode,
            uid=0,
            gid=0,
            links=links,
            mtime=0,
            size=len(payload),
            device_major=0,
            device_minor=0,
            rdevice_major=rdevice_major,
            rdevice_minor=rdevice_minor,
            name_size=len(encoded_name),
        )
    )
    archive.extend(encoded_name)
    pad(archive, 4)
    archive.extend(payload)
    pad(archive, 4)


def build_archive(init_data):
    archive = bytearray()
    append_entry(
        archive,
        inode=1,
        name="dev",
        mode=stat.S_IFDIR | 0o755,
        links=2,
    )
    append_entry(
        archive,
        inode=2,
        name="dev/console",
        mode=stat.S_IFCHR | 0o600,
        links=1,
        rdevice_major=5,
        rdevice_minor=1,
    )
    append_entry(
        archive,
        inode=3,
        name="init",
        mode=stat.S_IFREG | 0o755,
        links=1,
        payload=init_data,
    )
    append_entry(
        archive,
        inode=0,
        name=TRAILER,
        mode=0,
        links=1,
    )
    pad(archive, 512)
    return bytes(archive)


def gzip_archive(data):
    compressor = zlib.compressobj(level=9, wbits=-zlib.MAX_WBITS)
    compressed = compressor.compress(data) + compressor.flush()
    header = b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff"
    trailer = struct.pack("<II", zlib.crc32(data) & 0xFFFFFFFF, len(data) & 0xFFFFFFFF)
    return header + compressed + trailer


def unwrap_archive(data):
    if not data.startswith(b"\x1f\x8b"):
        return data, False
    if len(data) < 18:
        raise ValidationError("gzip-wrapped initramfs is truncated")
    if data[:10] != b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff":
        raise ValidationError("gzip wrapper is not in Tipboot deterministic format")

    expected_crc, expected_size = struct.unpack("<II", data[-8:])
    decompressor = zlib.decompressobj(wbits=-zlib.MAX_WBITS)
    try:
        archive = decompressor.decompress(data[10:-8]) + decompressor.flush()
    except zlib.error as error:
        raise ValidationError("gzip-wrapped initramfs is corrupt") from error

    if decompressor.unused_data or decompressor.unconsumed_tail:
        raise ValidationError("gzip-wrapped initramfs has trailing compressed data")
    if zlib.crc32(archive) & 0xFFFFFFFF != expected_crc:
        raise ValidationError("gzip-wrapped initramfs has an invalid CRC")
    if len(archive) & 0xFFFFFFFF != expected_size:
        raise ValidationError("gzip-wrapped initramfs has an invalid size")
    return archive, True


def parse_archive(data):
    entries = []
    offset = 0
    trailer_seen = False

    while not trailer_seen:
        if offset + NEWC_HEADER_SIZE > len(data):
            raise ValidationError("newc archive has a truncated header")

        header = data[offset : offset + NEWC_HEADER_SIZE]
        if header[:6] != NEWC_MAGIC:
            raise ValidationError("initramfs is not an uncompressed newc archive")

        try:
            fields = [
                int(header[index : index + 8], 16)
                for index in range(6, NEWC_HEADER_SIZE, 8)
            ]
        except ValueError as error:
            raise ValidationError("newc archive contains a malformed header") from error

        (
            inode,
            mode,
            uid,
            gid,
            links,
            mtime,
            size,
            device_major,
            device_minor,
            rdevice_major,
            rdevice_minor,
            name_size,
            checksum,
        ) = fields

        offset += NEWC_HEADER_SIZE
        if name_size < 1 or offset + name_size > len(data):
            raise ValidationError("newc archive has a malformed filename")

        raw_name = data[offset : offset + name_size]
        if raw_name[-1:] != b"\0":
            raise ValidationError("newc archive filename is not NUL terminated")
        try:
            name = raw_name[:-1].decode("ascii")
        except UnicodeDecodeError as error:
            raise ValidationError("newc archive filename is not ASCII") from error

        offset = (offset + name_size + 3) & ~3
        if offset + size > len(data):
            raise ValidationError("newc archive has truncated file data")
        payload = data[offset : offset + size]
        offset = (offset + size + 3) & ~3

        entry = {
            "inode": inode,
            "mode": mode,
            "uid": uid,
            "gid": gid,
            "links": links,
            "mtime": mtime,
            "device_major": device_major,
            "device_minor": device_minor,
            "rdevice_major": rdevice_major,
            "rdevice_minor": rdevice_minor,
            "checksum": checksum,
            "name": name,
            "payload": payload,
        }

        if name == TRAILER:
            if size != 0:
                raise ValidationError("newc trailer has unexpected data")
            trailer_seen = True
        else:
            entries.append(entry)

    if len(data) % 512 != 0:
        raise ValidationError("newc archive is not padded to a 512-byte boundary")
    if any(data[offset:]):
        raise ValidationError("newc archive contains non-zero data after the trailer")

    return entries


def validate_archive(data, release):
    entries = parse_archive(data)
    names = [entry["name"] for entry in entries]
    if names != ["dev", "dev/console", "init"]:
        raise ValidationError(
            "newc archive must contain only dev, dev/console, and init in order"
        )

    dev, console, init = entries
    common = ("uid", "gid", "mtime", "device_major", "device_minor", "checksum")
    if any(entry[field] != 0 for entry in entries for field in common):
        raise ValidationError("newc archive metadata is not deterministic")

    if (
        dev["inode"] != 1
        or dev["mode"] != stat.S_IFDIR | 0o755
        or dev["links"] != 2
        or dev["payload"]
    ):
        raise ValidationError("newc dev directory metadata is invalid")
    if (
        console["inode"] != 2
        or console["mode"] != stat.S_IFCHR | 0o600
        or console["links"] != 1
        or console["rdevice_major"] != 5
        or console["rdevice_minor"] != 1
        or console["payload"]
    ):
        raise ValidationError("newc dev/console metadata is invalid")
    if (
        init["inode"] != 3
        or init["mode"] != stat.S_IFREG | 0o755
        or init["links"] != 1
        or init["rdevice_major"] != 0
        or init["rdevice_minor"] != 0
    ):
        raise ValidationError("newc /init metadata is invalid")

    validate_init(init["payload"], release)


def validate_initramfs(data, release):
    archive, compressed = unwrap_archive(data)
    validate_archive(archive, release)
    return compressed


def atomic_write(path, data, mode):
    path = Path(path)
    parent = path.parent
    if not parent.is_dir():
        raise ValidationError(f"output directory does not exist: {parent}")

    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=str(parent)
    )
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def create_command(args):
    init_data = Path(args.init).read_bytes()
    validate_init(init_data, args.kernel_release)
    archive = build_archive(init_data)
    validate_archive(archive, args.kernel_release)
    output_data = gzip_archive(archive) if args.gzip else archive
    validate_initramfs(output_data, args.kernel_release)
    atomic_write(args.output, output_data, 0o644)
    wrapper = "deterministic gzip-wrapped " if args.gzip else ""
    print(
        f"created {wrapper}newc initramfs: {args.output} "
        f"({len(output_data)} bytes)"
    )


def verify_command(args):
    data = Path(args.archive).read_bytes()
    compressed = validate_initramfs(data, args.kernel_release)
    wrapper = "deterministic gzip-wrapped " if compressed else ""
    print(
        f"verified AArch64 static /init and {wrapper}newc archive: "
        f"{args.archive}"
    )


def build_parser():
    parser = argparse.ArgumentParser(
        description="Create and verify Tipboot deterministic newc initramfs images."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    create = subparsers.add_parser("create", help="create a deterministic archive")
    create.add_argument("--init", required=True, help="AArch64 static init executable")
    create.add_argument("--output", required=True, help="output newc archive")
    create.add_argument("--kernel-release", required=True, help="embedded release")
    create.add_argument(
        "--gzip",
        action="store_true",
        help="use a deterministic gzip wrapper around the newc archive",
    )
    create.set_defaults(function=create_command)

    verify = subparsers.add_parser("verify", help="verify a generated archive")
    verify.add_argument("--archive", required=True, help="newc archive to verify")
    verify.add_argument("--kernel-release", required=True, help="expected release")
    verify.set_defaults(function=verify_command)

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.function(args)
    except (OSError, ValidationError) as error:
        parser.exit(1, f"boot-newc.py: error: {error}\n")


if __name__ == "__main__":
    main()
