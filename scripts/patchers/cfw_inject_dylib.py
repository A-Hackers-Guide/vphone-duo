"""LC_LOAD_DYLIB injection module."""

from .cfw_asm import *

def _align(n, alignment):
    return (n + alignment - 1) & ~(alignment - 1)


def _find_first_section_offset(data):
    """Find the file offset of the earliest section data in the Mach-O.

    This tells us how much space is available after load commands.
    For fat/universal binaries, we operate on the first slice.
    """
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != 0xFEEDFACF:
        return -1

    ncmds = struct.unpack_from("<I", data, 16)[0]
    offset = 32  # sizeof(mach_header_64)
    earliest = len(data)

    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if cmd == 0x19:  # LC_SEGMENT_64
            nsects = struct.unpack_from("<I", data, offset + 64)[0]
            sect_off = offset + 72
            for _ in range(nsects):
                file_off = struct.unpack_from("<I", data, sect_off + 48)[0]
                size = struct.unpack_from("<Q", data, sect_off + 40)[0]
                if file_off > 0 and size > 0 and file_off < earliest:
                    earliest = file_off
                sect_off += 80
        offset += cmdsize
    return earliest


def _get_fat_slices(data):
    """Parse FAT (universal) binary header and return list of (offset, size) tuples.

    Returns [(0, len(data))] for thin binaries.
    """
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic == 0xCAFEBABE:  # FAT_MAGIC
        nfat = struct.unpack_from(">I", data, 4)[0]
        slices = []
        for i in range(nfat):
            off = 8 + i * 20
            slice_off = struct.unpack_from(">I", data, off + 8)[0]
            slice_size = struct.unpack_from(">I", data, off + 12)[0]
            slices.append((slice_off, slice_size))
        return slices
    elif magic == 0xBEBAFECA:  # FAT_MAGIC_64
        nfat = struct.unpack_from(">I", data, 4)[0]
        slices = []
        for i in range(nfat):
            off = 8 + i * 32
            slice_off = struct.unpack_from(">Q", data, off + 8)[0]
            slice_size = struct.unpack_from(">Q", data, off + 16)[0]
            slices.append((slice_off, slice_size))
        return slices
    else:
        return [(0, len(data))]


def _check_existing_dylib(data, base, dylib_path):
    """Check if the dylib is already loaded in this Mach-O slice."""
    magic = struct.unpack_from("<I", data, base)[0]
    if magic != 0xFEEDFACF:
        return False

    ncmds = struct.unpack_from("<I", data, base + 16)[0]
    offset = base + 32

    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if cmd in (0xC, 0xD, 0x18, 0x1F, 0x80000018):
            # LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_LAZY_LOAD_DYLIB,
            # LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            name_end = data.index(0, offset + name_offset)
            name = data[offset + name_offset : name_end].decode(
                "ascii", errors="replace"
            )
            if name == dylib_path:
                return True
        offset += cmdsize
    return False


def _strip_codesig(data, base):
    """Strip LC_CODE_SIGNATURE if it's the last load command.

    Zeros out the command bytes and decrements ncmds/sizeofcmds.
    Returns the cmdsize of the removed command, or 0 if not stripped.
    Since the binary will be re-signed by ldid, this is always safe.
    """
    ncmds = struct.unpack_from("<I", data, base + 16)[0]
    sizeofcmds = struct.unpack_from("<I", data, base + 20)[0]

    offset = base + 32
    last_offset = -1
    last_cmd = 0
    last_cmdsize = 0

    for i in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if i == ncmds - 1:
            last_offset = offset
            last_cmd = cmd
            last_cmdsize = cmdsize
        offset += cmdsize

    if last_cmd != 0x1D:  # LC_CODE_SIGNATURE
        return 0

    # Zero out the LC_CODE_SIGNATURE command
    data[last_offset : last_offset + last_cmdsize] = b"\x00" * last_cmdsize

    # Update header
    struct.pack_into("<I", data, base + 16, ncmds - 1)
    struct.pack_into("<I", data, base + 20, sizeofcmds - last_cmdsize)

    print(f"  Stripped LC_CODE_SIGNATURE ({last_cmdsize} bytes freed)")
    return last_cmdsize


def _inject_lc_load_dylib(data, base, dylib_path):
    """Inject LC_LOAD_DYLIB into a single Mach-O slice starting at `base`.

    Strategy (matches optool/insert_dylib behavior):
    1. Try to fit new LC in existing zero-padding after load commands.
    2. If not enough space, strip LC_CODE_SIGNATURE (re-signed by ldid anyway).
    3. If still not enough, allow header to overflow into section data
       (same approach as optool — the overwritten bytes are typically stub
       code that the jailbreak hook replaces).

    Returns True on success.
    """
    magic = struct.unpack_from("<I", data, base)[0]
    if magic != 0xFEEDFACF:
        print(f"  [-] Not a 64-bit Mach-O at offset 0x{base:X}")
        return False

    ncmds = struct.unpack_from("<I", data, base + 16)[0]
    sizeofcmds = struct.unpack_from("<I", data, base + 20)[0]

    # Build the LC_LOAD_DYLIB command
    name_bytes = dylib_path.encode("ascii") + b"\x00"
    name_offset_in_cmd = 24  # sizeof(dylib_command) header
    cmd_size = _align(name_offset_in_cmd + len(name_bytes), 8)
    lc_data = bytearray(cmd_size)

    struct.pack_into("<I", lc_data, 0, 0xC)  # cmd = LC_LOAD_DYLIB
    struct.pack_into("<I", lc_data, 4, cmd_size)  # cmdsize
    struct.pack_into("<I", lc_data, 8, name_offset_in_cmd)  # name offset
    struct.pack_into("<I", lc_data, 12, 2)  # timestamp
    struct.pack_into("<I", lc_data, 16, 0)  # current_version
    struct.pack_into("<I", lc_data, 20, 0)  # compat_version
    lc_data[name_offset_in_cmd : name_offset_in_cmd + len(name_bytes)] = name_bytes

    # Check available space
    header_end = base + 32 + sizeofcmds  # end of current load commands
    first_section = _find_first_section_offset(data[base:])
    if first_section < 0:
        print(f"  [-] Could not determine section offsets")
        return False
    first_section_abs = base + first_section
    available = first_section_abs - header_end

    print(
        f"  Header end: 0x{header_end:X}, first section: 0x{first_section_abs:X}, "
        f"available: {available}, need: {cmd_size}"
    )

    if available < cmd_size:
        # Strip LC_CODE_SIGNATURE to reclaim header space (re-signed by ldid)
        freed = _strip_codesig(data, base)
        if freed > 0:
            ncmds = struct.unpack_from("<I", data, base + 16)[0]
            sizeofcmds = struct.unpack_from("<I", data, base + 20)[0]
            header_end = base + 32 + sizeofcmds
            available = first_section_abs - header_end
            print(f"  After strip: available={available}, need={cmd_size}")

    if available < cmd_size:
        overflow = cmd_size - available
        # Allow up to 256 bytes overflow (same behavior as optool/insert_dylib)
        if overflow > 256:
            print(f"  [-] Would overflow {overflow} bytes into section data (too much)")
            return False
        print(
            f"  [!] Header overflow: {overflow} bytes into section data "
            f"(same as optool — binary will be re-signed)"
        )

    # Write the new load command at the end of existing commands
    data[header_end : header_end + cmd_size] = lc_data

    # Update header: ncmds += 1, sizeofcmds += cmd_size
    struct.pack_into("<I", data, base + 16, ncmds + 1)
    struct.pack_into("<I", data, base + 20, sizeofcmds + cmd_size)

    return True


def inject_dylib(filepath, dylib_path):
    """Inject LC_LOAD_DYLIB into a Mach-O binary (thin or universal/FAT).

    Equivalent to: optool install -c load -p <dylib_path> -t <filepath>
    """
    data = bytearray(open(filepath, "rb").read())
    slices = _get_fat_slices(bytes(data))

    injected = 0
    for slice_off, slice_size in slices:
        if _check_existing_dylib(data, slice_off, dylib_path):
            print(f"  [!] Dylib already loaded in slice at 0x{slice_off:X}, skipping")
            injected += 1
            continue

        if _inject_lc_load_dylib(data, slice_off, dylib_path):
            print(
                f"  [+] Injected LC_LOAD_DYLIB '{dylib_path}' at slice 0x{slice_off:X}"
            )
            injected += 1

    if injected == len(slices):
        open(filepath, "wb").write(data)
        print(f"  [+] Wrote {filepath} ({injected} slice(s) patched)")
        return True
    else:
        print(f"  [-] Only {injected}/{len(slices)} slices patched")
        return False


# ══════════════════════════════════════════════════════════════════
# BuildManifest parsing
# ══════════════════════════════════════════════════════════════════


