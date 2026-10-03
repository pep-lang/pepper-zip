#!/usr/bin/env python3
"""Writes the archives in tests/data that other tools make, for zip_test.pep.

Run it from anywhere; it rewrites tests/data. Each archive is small and
fixed (times are set), so running it again gives the same bytes, apart
from encrypted.zip, whose ZipCrypto header is random.
"""

import io
import os
import struct
import subprocess
import tempfile
import zipfile

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
TIME = (2024, 5, 6, 7, 8, 10)


def info(name, method=zipfile.ZIP_STORED):
    entry = zipfile.ZipInfo(name, TIME)
    entry.compress_type = method
    return entry


def write(name, data):
    with open(os.path.join(DATA, name), "wb") as out:
        out.write(data)


def build(entries, force_zip64=False):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for entry, data in entries:
            if force_zip64:
                with archive.open(entry, "w", force_zip64=True) as out:
                    out.write(data)
            else:
                archive.writestr(entry, data)
    return bytearray(buffer.getvalue())


def main():
    os.makedirs(DATA, exist_ok=True)

    # Methods this package does not read, next to one it does.
    write("methods.zip", build([
        (info("plain.txt"), b"plain"),
        (info("packed.txt", zipfile.ZIP_BZIP2), b"x" * 100),
        (info("lzma.txt", zipfile.ZIP_LZMA), b"y" * 100),
    ]))

    # A name in code page 437 (0x82 is e-acute) without the UTF-8 flag, and
    # one whose Info-ZIP Unicode Path extra field (0x7075) gives its name.
    data = build([(info("cafX.txt"), b"cafe"), (info("old.txt"), b"old")])
    data = data.replace(b"cafX.txt", b"caf\x82.txt")
    unicode_name = "日本.txt".encode()
    crc = zipfile.crc32(b"old.txt") & 0xFFFFFFFF
    extra = struct.pack("<HHBI", 0x7075, 5 + len(unicode_name), 1, crc) + unicode_name
    central = data.index(b"PK\x01\x02" , data.index(b"PK\x01\x02") + 4)
    name_length, extra_length = struct.unpack_from("<HH", data, central + 28)
    struct.pack_into("<H", data, central + 30, extra_length + len(extra))
    at = central + 46 + name_length + extra_length
    data[at:at] = extra
    end = data.index(b"PK\x05\x06")
    size, offset = struct.unpack_from("<II", data, end + 12)
    struct.pack_into("<I", data, end + 12, size + len(extra))
    write("cp437.zip", data)

    # A stored entry with one byte changed: a CRC mismatch.
    data = build([(info("data.txt"), b"abcdef")])
    data[data.index(b"abcdef")] = ord("X")
    write("crc.zip", data)

    # An entry that climbs out of the target directory.
    write("slip.zip", build([(info("ok.txt"), b"ok"), (info("../evil.txt"), b"evil")]))

    # ZIP64 records on small entries, and the same archive after a script,
    # as a self-extracting program has.
    data = build([(info("forced.txt"), b"forced zip64 entry")], force_zip64=True)
    write("zip64.zip", data)
    write("prefixed.zip", b"#!/bin/sh\necho self-extracting\nexit 0\n" + data)

    # ZipCrypto, from Info-ZIP's zip.
    with tempfile.TemporaryDirectory() as folder:
        with open(os.path.join(folder, "secret.txt"), "wb") as out:
            out.write(b"secret\n")
        target = os.path.join(DATA, "encrypted.zip")
        if os.path.exists(target):
            os.remove(target)
        subprocess.run(["zip", "-q", "-X", "-P", "password", target, "secret.txt"], cwd=folder, check=True)


if __name__ == "__main__":
    main()
