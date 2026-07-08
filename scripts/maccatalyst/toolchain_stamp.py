#!/usr/bin/env python3
"""Patch LC_BUILD_VERSION platform field from iOS (2) to macCatalyst (6) in Mach-O object files.

LC_BUILD_VERSION layout (little-endian on arm64/x86_64):
  cmd     uint32  = 0x19
  cmdsize uint32  = 24
  platform uint32
  minos   uint32  (packed)
  sdk     uint32  (packed)
  ntools  uint32
"""
import sys
import struct
import shutil
import subprocess
import os
import tempfile

LC_BUILD_VERSION = 0x32
PLATFORM_IOS = 2
PLATFORM_IOSSIMULATOR = 7
PLATFORM_MACCATALYST = 6

MH_MAGIC_64 = 0xFEEDFACF


def patch_object(path: str) -> bool:
    """Patch platform field in LC_BUILD_VERSION. Returns True if changed."""
    with open(path, "rb") as f:
        data = bytearray(f.read())

    if len(data) < 32:
        return False

    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != MH_MAGIC_64:
        # 32-bit MH_MAGIC = 0xFEEDFACE; not expected for arm64/x86_64 catalyst
        return False

    ncmds = struct.unpack_from("<I", data, 16)[0]
    sizeofcmds = struct.unpack_from("<I", data, 20)[0]
    off = 32  # 64-bit header size
    end = off + sizeofcmds
    changed = False
    for _ in range(ncmds):
        if off + 8 > end:
            break
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_BUILD_VERSION and cmdsize >= 24:
            platform_off = off + 8
            (platform,) = struct.unpack_from("<I", data, platform_off)
            if platform in (PLATFORM_IOS, PLATFORM_IOSSIMULATOR):
                struct.pack_into("<I", data, platform_off, PLATFORM_MACCATALYST)
                changed = True
        off += cmdsize

    if changed:
        with open(path, "wb") as f:
            f.write(data)
    return changed


def restamp_archive(archive: str) -> int:
    """Extract archive members, patch each .o, re-archive. Returns count patched."""
    tmp = tempfile.mkdtemp(prefix="restamp_")
    try:
        # Extract
        subprocess.run(["ar", "x", archive], cwd=tmp, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # Ensure readable (ar preserves member perms which can be -w--wx--x etc.)
        subprocess.run(["chmod", "-R", "u+rw", tmp], check=False)
        count = 0
        members = []
        for fn in sorted(os.listdir(tmp)):
            full = os.path.join(tmp, fn)
            if not os.path.isfile(full):
                continue
            # Skip non-object members like __.SYMDEF
            try:
                with open(full, "rb") as f:
                    head = f.read(4)
            except PermissionError:
                continue
            if head[:4] != struct.pack("<I", MH_MAGIC_64):
                # Not a 64-bit Mach-O object; skip (e.g. SYMDEF)
                continue
            if patch_object(full):
                count += 1
            members.append(fn)
        # Re-archive. Use `ar rcs` to recreate.
        # Remove original archive then recreate with same members.
        os.remove(archive)
        if members:
            # ar rcs <archive> <members...>  (in tmp dir order)
            cmd = ["ar", "rcs", archive] + [os.path.join(tmp, m) for m in members]
            subprocess.run(cmd, check=True)
        # ranlib to rebuild symbol table
        subprocess.run(["ranlib", archive], check=True)
        return count
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    if len(sys.argv) < 2:
        print("usage: toolchain_stamp.py <archive.a> [archive2.a ...]", file=sys.stderr)
        sys.exit(2)
    total = 0
    for archive in sys.argv[1:]:
        if not os.path.exists(archive):
            print(f"missing: {archive}", file=sys.stderr)
            continue
        n = restamp_archive(archive)
        total += n
        print(f"{archive}: patched {n} object(s)")
    print(f"TOTAL patched: {total}")


if __name__ == "__main__":
    main()