"""Read the icon and version back out of a stamped Wend.exe, and fail if either is wrong.

release.sh refuses to emit an unsigned or un-notarized artifact; this is the same idea for
the Windows side, and package_win.ps1 runs it before it will call a build packaged.

Both checks go through the APIs the shell itself uses rather than re-parsing the bytes
that were just written — PrivateExtractIcons is what Explorer's icon lookup calls, and a
subtly malformed version block still parses while showing blank fields, so only reading it
back proves anything.

    python scripts/verify_resources.py <exe> <short-version> <build-version>
"""

import ctypes
import sys
from ctypes import wintypes

EXPECTED_SIZES = (16, 24, 32, 48, 64, 128, 256)
VS_SIGNATURE = 0xFEEF04BD
STRING_FIELDS = ["CompanyName", "FileDescription", "FileVersion", "InternalName",
                 "LegalCopyright", "OriginalFilename", "ProductName", "ProductVersion"]

user32 = ctypes.WinDLL("user32", use_last_error=True)
gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)
version_dll = ctypes.WinDLL("version", use_last_error=True)


class ICONINFO(ctypes.Structure):
    _fields_ = [("fIcon", wintypes.BOOL), ("xHotspot", wintypes.DWORD),
                ("yHotspot", wintypes.DWORD), ("hbmMask", wintypes.HBITMAP),
                ("hbmColor", wintypes.HBITMAP)]


class BITMAP(ctypes.Structure):
    _fields_ = [("bmType", ctypes.c_long), ("bmWidth", ctypes.c_long),
                ("bmHeight", ctypes.c_long), ("bmWidthBytes", ctypes.c_long),
                ("bmPlanes", wintypes.WORD), ("bmBitsPixel", wintypes.WORD),
                ("bmBits", ctypes.c_void_p)]


class FIXEDFILEINFO(ctypes.Structure):
    _fields_ = [("dwSignature", wintypes.DWORD), ("dwStrucVersion", wintypes.DWORD),
                ("dwFileVersionMS", wintypes.DWORD), ("dwFileVersionLS", wintypes.DWORD),
                ("dwProductVersionMS", wintypes.DWORD), ("dwProductVersionLS", wintypes.DWORD),
                ("dwFileFlagsMask", wintypes.DWORD), ("dwFileFlags", wintypes.DWORD),
                ("dwFileOS", wintypes.DWORD), ("dwFileType", wintypes.DWORD),
                ("dwFileSubtype", wintypes.DWORD), ("dwFileDateMS", wintypes.DWORD),
                ("dwFileDateLS", wintypes.DWORD)]


user32.PrivateExtractIconsW.argtypes = [
    wintypes.LPCWSTR, ctypes.c_int, ctypes.c_int, ctypes.c_int,
    ctypes.POINTER(wintypes.HICON), ctypes.POINTER(wintypes.UINT),
    wintypes.UINT, wintypes.DWORD,
]
user32.PrivateExtractIconsW.restype = wintypes.UINT
user32.GetIconInfo.argtypes = [wintypes.HICON, ctypes.POINTER(ICONINFO)]
user32.GetIconInfo.restype = wintypes.BOOL
user32.DestroyIcon.argtypes = [wintypes.HICON]
gdi32.GetObjectW.argtypes = [wintypes.HGDIOBJ, ctypes.c_int, ctypes.c_void_p]
gdi32.GetObjectW.restype = ctypes.c_int
gdi32.DeleteObject.argtypes = [wintypes.HGDIOBJ]
version_dll.GetFileVersionInfoSizeW.argtypes = [wintypes.LPCWSTR, wintypes.LPDWORD]
version_dll.GetFileVersionInfoSizeW.restype = wintypes.DWORD
version_dll.GetFileVersionInfoW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD,
                                            wintypes.DWORD, wintypes.LPVOID]
version_dll.GetFileVersionInfoW.restype = wintypes.BOOL
version_dll.VerQueryValueW.argtypes = [wintypes.LPCVOID, wintypes.LPCWSTR,
                                       ctypes.POINTER(wintypes.LPVOID),
                                       ctypes.POINTER(wintypes.UINT)]
version_dll.VerQueryValueW.restype = wintypes.BOOL


def check_icons(exe):
    """Every expected size must come back at exactly that size.

    A size Windows can't satisfy is answered with a stretched neighbour rather than a
    failure, so measuring the bitmap is the only way to tell a real entry from a guess.
    """
    problems = 0
    for want in EXPECTED_SIZES:
        icon, index = wintypes.HICON(), wintypes.UINT()
        found = user32.PrivateExtractIconsW(exe, 0, want, want,
                                            ctypes.byref(icon), ctypes.byref(index), 1, 0)
        if found != 1 or not icon.value:
            print(f"  icon {want:>3}px  MISSING")
            problems += 1
            continue

        info, bitmap = ICONINFO(), BITMAP()
        if user32.GetIconInfo(icon, ctypes.byref(info)):
            gdi32.GetObjectW(info.hbmColor, ctypes.sizeof(bitmap), ctypes.byref(bitmap))
            if bitmap.bmWidth == want:
                print(f"  icon {want:>3}px  ok ({bitmap.bmBitsPixel}bpp)")
            else:
                print(f"  icon {want:>3}px  STRETCHED from {bitmap.bmWidth}px")
                problems += 1
            gdi32.DeleteObject(info.hbmColor)
            gdi32.DeleteObject(info.hbmMask)
        user32.DestroyIcon(icon)
    return problems


def check_version(exe, short, build):
    size = version_dll.GetFileVersionInfoSizeW(exe, None)
    if not size:
        print("  version   MISSING — no version resource")
        return 1

    buffer = ctypes.create_string_buffer(size)
    if not version_dll.GetFileVersionInfoW(exe, 0, size, buffer):
        print("  version   UNREADABLE — GetFileVersionInfo failed")
        return 1

    pointer, length = wintypes.LPVOID(), wintypes.UINT()
    problems = 0

    version_dll.VerQueryValueW(buffer, "\\", ctypes.byref(pointer), ctypes.byref(length))
    info = ctypes.cast(pointer, ctypes.POINTER(FIXEDFILEINFO)).contents
    if info.dwSignature != VS_SIGNATURE:
        print(f"  version   BAD SIGNATURE 0x{info.dwSignature:08X}")
        return 1

    def quad(most, least):
        return f"{most >> 16}.{most & 0xFFFF}.{least >> 16}.{least & 0xFFFF}"

    expected = f"{short}.{build}"
    binary = quad(info.dwFileVersionMS, info.dwFileVersionLS)
    if binary != expected:
        print(f"  version   binary is {binary}, expected {expected}")
        problems += 1
    else:
        print(f"  version   binary {binary}  ok")

    for name in STRING_FIELDS:
        ok = version_dll.VerQueryValueW(
            buffer, f"\\StringFileInfo\\040904B0\\{name}",
            ctypes.byref(pointer), ctypes.byref(length)
        )
        if ok and length.value:
            print(f"    {name:<17} {ctypes.wstring_at(pointer, length.value - 1)}")
        else:
            print(f"    {name:<17} MISSING")
            problems += 1
    return problems


def main() -> int:
    exe, short, build = sys.argv[1], sys.argv[2], sys.argv[3]
    problems = check_icons(exe) + check_version(exe, short, build)
    if problems:
        print(f"{problems} problem(s) — not a shippable build")
        return 1
    print("icon and version resources verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
