"""Capture real VS Code Explorer windows as PNG, with no third-party imaging lib.

Why this exists: the checkpoint asks for actual Explorer screenshots, and the
environment forbids `Add-Type` (so no System.Drawing) and has no Pillow. GDI via
`ctypes` plus a stdlib PNG writer is enough, and it keeps the capture honest:
the bytes come from the screen, not from a re-drawn mock.

Behaviour:
  * optionally opens a folder in a NEW VS Code window (`code -n <folder>`),
  * waits for a window whose title matches,
  * brings it to the foreground, captures its client area,
  * verifies the image is not a single flat colour (a disconnected session
    captures black, and a black PNG must never be passed off as a screenshot),
  * closes only the windows it opened.

Usage:
    python scripts/cp03f_capture_explorer.py --list
    python scripts/cp03f_capture_explorer.py --capture-existing "<title substring>" out.png
    python scripts/cp03f_capture_explorer.py --open <folder> out.png
"""
from __future__ import annotations

import argparse
import ctypes
import ctypes.wintypes as wt
import struct
import subprocess
import sys
import tempfile
import time
import zlib
from pathlib import Path

user32 = ctypes.WinDLL("user32", use_last_error=True)
gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)

SRCCOPY = 0x00CC0020
DIB_RGB_COLORS = 0
BI_RGB = 0
SW_RESTORE = 9
SW_MAXIMIZE = 3
WM_CLOSE = 0x0010
PW_RENDERFULLCONTENT = 0x00000002
KEYEVENTF_KEYUP = 0x0002
MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004

VK_SHIFT, VK_CONTROL, VK_MENU = 0x10, 0x11, 0x12
VK_E, VK_DOWN, VK_RIGHT, VK_LEFT, VK_UP = 0x45, 0x28, 0x27, 0x25, 0x26

# A window is only accepted as the capture target if its title carries this.
# Without it, `find_window("backend")` can happily return a browser tab that
# merely mentions the word, and the "screenshot" becomes a picture of the web.
VSCode_TITLE = "visual studio code"

user32.SetProcessDPIAware()  # physical pixels, so rect and capture agree


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [
        ("biSize", wt.DWORD), ("biWidth", wt.LONG), ("biHeight", wt.LONG),
        ("biPlanes", wt.WORD), ("biBitCount", wt.WORD),
        ("biCompression", wt.DWORD), ("biSizeImage", wt.DWORD),
        ("biXPelsPerMeter", wt.LONG), ("biYPelsPerMeter", wt.LONG),
        ("biClrUsed", wt.DWORD), ("biClrImportant", wt.DWORD),
    ]


class BITMAPINFO(ctypes.Structure):
    _fields_ = [("bmiHeader", BITMAPINFOHEADER), ("bmiColors", wt.DWORD * 3)]


def list_windows() -> list[tuple[int, str]]:
    out: list[tuple[int, str]] = []

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def cb(hwnd, _):
        if not user32.IsWindowVisible(hwnd):
            return True
        n = user32.GetWindowTextLengthW(hwnd)
        if n:
            buf = ctypes.create_unicode_buffer(n + 1)
            user32.GetWindowTextW(hwnd, buf, n + 1)
            out.append((hwnd, buf.value))
        return True

    user32.EnumWindows(cb, 0)
    return out


def window_title(hwnd: int) -> str:
    n = user32.GetWindowTextLengthW(hwnd)
    if not n:
        return ""
    buf = ctypes.create_unicode_buffer(n + 1)
    user32.GetWindowTextW(hwnd, buf, n + 1)
    return buf.value


def find_window(substr: str, require_vscode: bool = True) -> int | None:
    for hwnd, title in list_windows():
        if substr.lower() not in title.lower():
            continue
        if require_vscode and VSCode_TITLE not in title.lower():
            continue
        return hwnd
    return None


def _grab(hwnd: int, w: int, h: int) -> bytes:
    """BGRA buffer for an hwnd of the given client size."""
    hdc_screen = user32.GetDC(0)
    hdc_mem = gdi32.CreateCompatibleDC(hdc_screen)
    hbmp = gdi32.CreateCompatibleBitmap(hdc_screen, w, h)
    gdi32.SelectObject(hdc_mem, hbmp)

    # PrintWindow renders the window's own content into the DC. BitBlt only
    # copies whatever is physically on top at those coordinates, so if Windows
    # refuses our SetForegroundWindow (it often does for background callers)
    # BitBlt silently photographs the wrong application. Prefer PrintWindow.
    ok = user32.PrintWindow(hwnd, hdc_mem, PW_RENDERFULLCONTENT)
    if not ok:
        origin = wt.POINT(0, 0)
        user32.ClientToScreen(hwnd, ctypes.byref(origin))
        gdi32.BitBlt(hdc_mem, 0, 0, w, h, hdc_screen, origin.x, origin.y, SRCCOPY)

    bmi = BITMAPINFO()
    bmi.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    bmi.bmiHeader.biWidth = w
    bmi.bmiHeader.biHeight = -h  # top-down
    bmi.bmiHeader.biPlanes = 1
    bmi.bmiHeader.biBitCount = 32
    bmi.bmiHeader.biCompression = BI_RGB

    buf = ctypes.create_string_buffer(w * h * 4)
    got = gdi32.GetDIBits(hdc_mem, hbmp, 0, h, buf, ctypes.byref(bmi), DIB_RGB_COLORS)

    gdi32.DeleteObject(hbmp)
    gdi32.DeleteDC(hdc_mem)
    user32.ReleaseDC(0, hdc_screen)

    if got != h:
        raise RuntimeError(f"GetDIBits returned {got} of {h} rows")
    return buf.raw


def capture(hwnd: int) -> tuple[bytes, int, int]:
    """BGRA buffer of the window's client area plus its size."""
    rect = wt.RECT()
    user32.GetClientRect(hwnd, ctypes.byref(rect))
    w, h = rect.right - rect.left, rect.bottom - rect.top
    if w <= 0 or h <= 0:
        raise RuntimeError(f"window {hwnd} has an empty client rect ({w}x{h})")

    bgra = _grab(hwnd, w, h)
    if distinct_colours(bgra) < 3:
        # PrintWindow can come back blank for some composited surfaces; a
        # screen grab is then the only option, so retry once before giving up.
        time.sleep(1.0)
        bgra = _grab(hwnd, w, h)
    return bgra, w, h


def widen_sidebar(hwnd: int, fraction: float = 0.20) -> None:
    """Drag the Explorer splitter right so folder names are not truncated.

    A default-width sidebar clips every name to a few characters, which makes
    the screenshot useless as evidence of which modules exist. The drag is
    confined to the splitter and only resizes a panel.
    """
    origin = wt.POINT(0, 0)
    user32.ClientToScreen(hwnd, ctypes.byref(origin))
    rect = wt.RECT()
    user32.GetClientRect(hwnd, ctypes.byref(rect))
    w = rect.right - rect.left
    if w < 400:
        return

    x0 = origin.x + int(w * 0.251)   # default Explorer splitter position
    y0 = origin.y + 300
    dx = int(w * fraction)

    user32.SetCursorPos(x0, y0)
    time.sleep(0.3)
    user32.mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
    for i in range(1, 21):
        user32.SetCursorPos(x0 + dx * i // 20, y0)
        time.sleep(0.02)
    user32.mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
    time.sleep(1.0)


def tap(vk: int, mods: tuple[int, ...] = ()) -> None:
    """Press one non-printable key, optionally with modifiers held.

    Deliberately restricted to arrows and Ctrl/Shift chords: if focus is not
    where we expect, an arrow key only moves a caret, whereas a printable key
    would edit a source file. Nothing here can dirty the working tree.
    """
    for m in mods:
        user32.keybd_event(m, 0, 0, 0)
    user32.keybd_event(vk, 0, 0, 0)
    user32.keybd_event(vk, 0, KEYEVENTF_KEYUP, 0)
    for m in reversed(mods):
        user32.keybd_event(m, 0, KEYEVENTF_KEYUP, 0)
    time.sleep(0.35)


def expand_explorer(hwnd: int, use_keys: bool = False) -> None:
    """Give the window focus and time to paint its tree.

    When a file was revealed with `code -g`, VS Code has already expanded the
    whole ancestor chain, so no keystrokes are needed — and not sending any
    keeps the capture free of side effects. The keystroke path is kept only as
    a fallback for the `--capture-existing` case.
    """
    user32.SetForegroundWindow(hwnd)
    time.sleep(5.0)                       # let the workbench finish loading
    if not use_keys:
        return
    tap(VK_E, (VK_CONTROL, VK_SHIFT))     # focus Explorer
    tap(VK_DOWN)                          # select the root row
    tap(VK_RIGHT)                         # expand it
    time.sleep(1.2)


def write_png(path: Path, bgra: bytes, w: int, h: int) -> None:
    """Minimal PNG writer: 8-bit RGB, filter 0 per scanline."""
    rows = bytearray()
    for y in range(h):
        rows.append(0)
        start = y * w * 4
        line = bgra[start:start + w * 4]
        # BGRA -> RGB
        rows += bytes(b for i in range(0, len(line), 4)
                      for b in (line[i + 2], line[i + 1], line[i]))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(bytes(rows), 6)) + chunk(b"IEND", b""))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def distinct_colours(bgra: bytes, step: int = 97) -> int:
    """Cheap non-flat check: sample the buffer and count distinct RGB triples."""
    seen = set()
    for i in range(0, len(bgra) - 4, 4 * step):
        seen.add(bgra[i:i + 3])
        if len(seen) > 50:
            break
    return len(seen)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--capture-existing")
    ap.add_argument("--open")
    ap.add_argument("--reveal",
                    help="file to reveal with `code -g`, so the tree "
                         "auto-expands along its ancestor chain")
    ap.add_argument("--close", action="store_true",
                    help="close the window after capture (only with --open)")
    ap.add_argument("--clean-profile", action="store_true",
                    help="use a throwaway VS Code profile so the stock "
                         "Explorer renders")
    ap.add_argument("--widen", action="store_true",
                    help="drag the Explorer splitter right before capturing")
    ap.add_argument("out", nargs="?")
    a = ap.parse_args()

    if a.list:
        for hwnd, title in list_windows():
            print(f"{hwnd:>10}  {title}")
        return 0

    opened: int | None = None
    if a.open:
        folder = Path(a.open).resolve()
        target = folder.name
        # Diff the window set instead of matching on title text. A title
        # substring also matches windows that were already open ("backend -
        # Untitled (Workspace)"), and capturing one of those both photographs
        # the wrong tree and — with --close — shuts a window we never opened.
        before = {hwnd for hwnd, _ in list_windows()}
        cmd = ["code", "-n"]
        if a.clean_profile:
            # The default profile has an extension that has taken over the
            # Explorer view slot, so no file tree renders at all — the capture
            # then shows an empty panel labelled "no data provider". A throwaway
            # profile restores the stock Explorer and the default layout.
            prof = Path(tempfile.gettempdir()) / "cp03f_vscode_profile"
            cmd += [
                "--disable-workspace-trust",
                f"--user-data-dir={prof / 'data'}",
                f"--extensions-dir={prof / 'ext'}",
            ]
        if a.reveal:
            # Resolve against the folder being opened, not the process CWD.
            # Resolving against the CWD made `code -g lib/...` point at a
            # non-existent path, and VS Code dutifully opened a phantom empty
            # buffer instead of the real file.
            reveal = Path(a.reveal)
            if not reveal.is_absolute():
                reveal = folder / reveal
            if not reveal.exists():
                print(f"reveal target does not exist: {reveal}", file=sys.stderr)
                return 5
            cmd += ["-g", str(reveal)]
        cmd.append(str(folder))
        subprocess.Popen(cmd, shell=True)
        for _ in range(160):
            time.sleep(0.75)
            for hwnd, title in list_windows():
                if hwnd in before:
                    continue
                if VSCode_TITLE not in title.lower():
                    continue
                if target.lower() not in title.lower():
                    continue
                opened = hwnd
                break
            if opened:
                break
        if not opened:
            print(f"no new VS Code window appeared for {target}", file=sys.stderr)
            return 2
        hwnd = opened
    else:
        if not a.capture_existing:
            ap.error("either --capture-existing or --open is required")
        hwnd = find_window(a.capture_existing)
        if not hwnd:
            print(f"no VS Code window matching {a.capture_existing!r}", file=sys.stderr)
            return 2

    # Refuse to photograph the wrong application. This is the check whose
    # absence produced two screenshots of a browser and of this very chat
    # window while claiming to show the repository.
    title = window_title(hwnd)
    if VSCode_TITLE not in title.lower():
        print(f"target window is not VS Code (title={title!r}); refusing",
              file=sys.stderr)
        return 4

    user32.ShowWindow(hwnd, SW_MAXIMIZE)
    expand_explorer(hwnd, use_keys=not a.reveal)
    if a.widen:
        widen_sidebar(hwnd)

    bgra, w, h = capture(hwnd)
    colours = distinct_colours(bgra)
    if colours < 3:
        print(f"capture looks flat ({colours} colours) — session may be "
              "disconnected; refusing to save a blank screenshot", file=sys.stderr)
        return 3

    out = Path(a.out)
    write_png(out, bgra, w, h)
    print(f"saved {out} ({w}x{h}, {out.stat().st_size} bytes, "
          f"{colours}+ distinct sampled colours)")
    print(f"  window: {title}")

    if a.close and opened:
        user32.PostMessageW(opened, WM_CLOSE, 0, 0)
        time.sleep(1.5)
        print("closed the window this run opened")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
