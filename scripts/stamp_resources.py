"""Stamp the icon and the version block into an already-linked Wend.exe.

A Windows executable carries its icon and its version as PE resources, which is what
Explorer, Task Manager and the installer all read. SwiftPM cannot compile a resource
script, so neither can be linked in at build time without committing a generated .res and
threading an unsafe linker flag through Package.swift. Applying both after the link keeps
`swift build` plain and puts them where the macOS side puts its own — in packaging, which
is also where the version already lives (SHORT_VERSION in scripts/package.sh).

Both go in through a single Begin/EndUpdateResource session: each End rewrites the whole
PE, so one pass is faster and leaves a single reproducible result.

    python scripts/stamp_resources.py <exe> <ico> <short-version> <build-version>

The two version arguments mirror CFBundleShortVersionString and CFBundleVersion, which is
what the Windows fields already mean: ProductVersion is the marketing string ("1.2.3") and
FileVersion is the build-precise one ("1.2.3.10").
"""

import ctypes
import struct
import sys
from ctypes import wintypes

RT_ICON = 3
RT_GROUP_ICON = 14
RT_VERSION = 16
LANG_EN_US = 0x0409
CODEPAGE_UNICODE = 0x04B0

ICONDIR = "<HHH"               # reserved, type, count
ICONDIRENTRY = "<BBBBHHII"     # w, h, colors, reserved, planes, bpp, bytes, file offset
GRPICONDIRENTRY = "<BBBBHHIH"  # ...the same, but a resource id in place of the offset

VS_FFI_SIGNATURE = 0xFEEF04BD
VS_FFI_STRUCVERSION = 0x00010000
VOS_NT_WINDOWS32 = 0x00040004
VFT_APP = 0x00000001

COMPANY = "Nachum Shmilovitz"
COPYRIGHT = "© 2026 Nachum Shmilovitz"
DESCRIPTION = "Fix text typed in the wrong keyboard layout"

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
kernel32.BeginUpdateResourceW.argtypes = [wintypes.LPCWSTR, wintypes.BOOL]
kernel32.BeginUpdateResourceW.restype = wintypes.HANDLE
kernel32.UpdateResourceW.argtypes = [wintypes.HANDLE, wintypes.LPVOID, wintypes.LPVOID,
                                     wintypes.WORD, wintypes.LPVOID, wintypes.DWORD]
kernel32.UpdateResourceW.restype = wintypes.BOOL
kernel32.EndUpdateResourceW.argtypes = [wintypes.HANDLE, wintypes.BOOL]
kernel32.EndUpdateResourceW.restype = wintypes.BOOL


def fail(call):
    error = ctypes.get_last_error()
    raise OSError(error, f"{call} failed: {ctypes.FormatError(error)}")


# MARK: - Icon

def icon_resources(path):
    """(RT_ICON images, RT_GROUP_ICON directory) read out of an .ico file.

    Explorer draws the *lowest-numbered* RT_GROUP_ICON as the file's icon, so the caller
    puts the group in as id 1.
    """
    blob = open(path, "rb").read()
    reserved, kind, count = struct.unpack(ICONDIR, blob[:6])
    if reserved != 0 or kind != 1:
        raise ValueError(f"{path} is not an icon file")

    images, group = [], struct.pack(ICONDIR, 0, 1, count)
    for index in range(count):
        width, height, colors, pad, planes, bpp, size, offset = struct.unpack(
            ICONDIRENTRY, blob[6 + index * 16:22 + index * 16]
        )
        icon_id = index + 1
        images.append((icon_id, blob[offset:offset + size]))
        group += struct.pack(GRPICONDIRENTRY, width, height, colors, pad,
                             planes, bpp, size, icon_id)
    return images, group


# MARK: - Version
#
# VS_VERSIONINFO is a tree of variable-length blocks sharing one header — wLength,
# wValueLength, wType, a wide key, then an optional value and any children, each part
# realigned to a 4-byte boundary. wValueLength counts *characters* for a text value and
# *bytes* for a binary one; getting that backwards still parses, but leaves the fields
# blank in the property sheet, which is why verify_resources.py reads them back.

def align(data):
    return data + b"\0" * (-len(data) % 4)


def wide(text):
    return text.encode("utf-16-le") + b"\0\0"


def block(key, value=b"", text=False, children=b""):
    value_length = (len(value) // 2) if text else len(value)
    data = align(struct.pack("<HHH", 0, value_length, 1 if text else 0) + wide(key))
    if value:
        data = align(data + value)
    data += children
    return struct.pack("<H", len(data)) + data[2:]


def join(blocks):
    out = b""
    for item in blocks:
        out = align(out) + item
    return out


def fixed_file_info(quad):
    most = (quad[0] << 16) | quad[1]
    least = (quad[2] << 16) | quad[3]
    return struct.pack(
        "<13I",
        VS_FFI_SIGNATURE, VS_FFI_STRUCVERSION,
        most, least,        # file version
        most, least,        # product version — one build, so these are never allowed to differ
        0x3F, 0,            # flags mask, flags
        VOS_NT_WINDOWS32, VFT_APP, 0,
        0, 0,               # file date: left unset, as essentially every toolchain does
    )


def version_resource(short, build):
    parts = [int(n) for n in short.split(".")]
    while len(parts) < 3:
        parts.append(0)
    quad = (parts[0], parts[1], parts[2], int(build))

    # Ordered as the Windows property sheet lists them, so two builds diff top to bottom.
    strings = {
        "CompanyName": COMPANY,
        "FileDescription": DESCRIPTION,
        "FileVersion": ".".join(str(n) for n in quad),
        "InternalName": "Wend",
        "LegalCopyright": COPYRIGHT,
        "OriginalFilename": "Wend.exe",
        "ProductName": "Wend",
        "ProductVersion": short,
    }

    table = block(f"{LANG_EN_US:04X}{CODEPAGE_UNICODE:04X}", children=join(
        [block(name, value=wide(text), text=True) for name, text in strings.items()]
    ))
    string_info = block("StringFileInfo", children=table)
    var_info = block("VarFileInfo", children=block(
        "Translation", value=struct.pack("<HH", LANG_EN_US, CODEPAGE_UNICODE)
    ))

    return block("VS_VERSION_INFO",
                 value=fixed_file_info(quad),
                 children=join([string_info, var_info]))


# MARK: - Driver

def main() -> int:
    exe, ico, short, build = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

    images, group = icon_resources(ico)
    version = version_resource(short, build)

    handle = kernel32.BeginUpdateResourceW(exe, False)
    if not handle:
        fail("BeginUpdateResource")

    try:
        for icon_id, data in images:
            if not kernel32.UpdateResourceW(handle, RT_ICON, icon_id, LANG_EN_US,
                                            data, len(data)):
                fail("UpdateResource(RT_ICON)")
        if not kernel32.UpdateResourceW(handle, RT_GROUP_ICON, 1, LANG_EN_US,
                                        group, len(group)):
            fail("UpdateResource(RT_GROUP_ICON)")
        if not kernel32.UpdateResourceW(handle, RT_VERSION, 1, LANG_EN_US,
                                        version, len(version)):
            fail("UpdateResource(RT_VERSION)")
    except BaseException:
        kernel32.EndUpdateResourceW(handle, True)   # discard, leaving the exe untouched
        raise

    if not kernel32.EndUpdateResourceW(handle, False):
        # The commonest cause by far is the exe still running: Windows locks a loaded
        # image, and the failure only surfaces here, at the write.
        fail("EndUpdateResource (is Wend.exe still running?)")

    print(f"stamped {len(images)} icon images and version {short} ({build})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
