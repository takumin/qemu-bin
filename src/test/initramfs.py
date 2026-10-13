# SPDX-License-Identifier: MIT
#
# Write the initramfs of the test guest: the /init built from init.c and the
# kernel modules it loads, taken from the netboot initramfs of Alpine that
# matches the kernel. Only the Python standard library is used, so the host
# needs no cpio command.
#
# usage: initramfs.py <alpine initramfs> <init> <output> <module>...

import gzip
import stat
import sys

TRAILER = "TRAILER!!!"


def read_cpio(data):
    """Yield (name, mode, body) of the entries of a newc cpio archive."""
    off = 0
    while True:
        hdr = data[off : off + 110]
        if hdr[:6] != b"070701":
            raise ValueError(f"bad cpio magic at {off}")
        fields = [int(hdr[6 + i * 8 : 14 + i * 8], 16) for i in range(13)]
        mode, size, namesize = fields[1], fields[6], fields[11]
        name = data[off + 110 : off + 110 + namesize - 1].decode()
        off = (off + 110 + namesize + 3) & ~3
        body = data[off : off + size]
        off = (off + size + 3) & ~3
        if name == TRAILER:
            return
        yield name, mode, body


def cpio_entry(ino, name, mode, body=b"", rdev=(0, 0)):
    nameb = name.encode() + b"\0"
    fields = [ino, mode, 0, 0, 1, 0, len(body), 0, 0, rdev[0], rdev[1], len(nameb), 0]
    hdr = b"070701" + b"".join(b"%08x" % f for f in fields)
    out = hdr + nameb
    out += b"\0" * (-len(out) % 4)
    out += body
    out += b"\0" * (-len(out) % 4)
    return out


def main():
    alpine, init, output, *modules = sys.argv[1:]

    found = {}
    with gzip.open(alpine) as f:
        for name, mode, body in read_cpio(f.read()):
            base = name.rsplit("/", 1)[-1]
            if stat.S_ISREG(mode) and base.endswith(".ko") and base[:-3] in modules:
                found[base[:-3]] = body
    missing = sorted(set(modules) - set(found))
    if missing:
        sys.exit(f"modules not found in {alpine}: {' '.join(missing)}")

    with open(init, "rb") as f:
        init_body = f.read()

    entries = [
        ("dev", stat.S_IFDIR | 0o755, b"", (0, 0)),
        ("dev/console", stat.S_IFCHR | 0o600, b"", (5, 1)),
        ("proc", stat.S_IFDIR | 0o755, b"", (0, 0)),
        ("sys", stat.S_IFDIR | 0o755, b"", (0, 0)),
        ("lib", stat.S_IFDIR | 0o755, b"", (0, 0)),
        ("lib/modules", stat.S_IFDIR | 0o755, b"", (0, 0)),
        ("init", stat.S_IFREG | 0o755, init_body, (0, 0)),
    ]
    entries += [(f"lib/modules/{m}.ko", stat.S_IFREG | 0o644, found[m], (0, 0)) for m in modules]

    archive = b"".join(cpio_entry(i + 1, *e) for i, e in enumerate(entries))
    archive += cpio_entry(0, TRAILER, 0)
    with open(output, "wb") as f:
        f.write(gzip.compress(archive, mtime=0))


if __name__ == "__main__":
    main()
