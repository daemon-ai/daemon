#!/usr/bin/env python3
"""Post-install fixups for the vendored kwin-mcp ``core.py`` on NixOS.

Time-box the KWin EIS ``InputBackend`` construction so ``session_start`` /
``session_connect`` cannot block past the MCP client timeout (a headless
``kwin_wayland --virtual`` can leave the EIS handshake hanging forever, which
drops the Cursor <-> server connection and orphans the session).

Applied via the flake's ``postInstall`` as plain string replacements (not a
unified diff) to dodge the whitespace-fragility of blank patch context lines and
Nix indented-string stripping. Fails loudly if an anchor is missing, so a
version bump can never silently no-op.
"""

import sys

path = sys.argv[1]
with open(path) as fh:
    src = fh.read()

HELPER = '''def _make_input_backend_timeboxed(dbus_addr, timeout=6.0):
    """Build an InputBackend without ever blocking longer than ``timeout``.

    Under a headless ``kwin_wayland --virtual`` (and some live sessions reached
    over a detached D-Bus) the KWin EIS handshake can hang indefinitely; run the
    construction in a daemon thread and abandon it on timeout, returning None so
    the caller always returns promptly. Screenshot + AT-SPI still work; live
    sessions fall back to ydotool.
    """
    import os

    if os.environ.get("KWIN_MCP_INPUT_BACKEND", "").lower() == "atspi":
        # NixOS/Wayland: KWin EIS segfaults and ydotool has no uinput access, so
        # drive input through the accessibility layer instead (see atspi_input).
        try:
            from kwin_mcp.atspi_input import AtspiInputBackend

            return AtspiInputBackend(dbus_addr)
        except Exception:
            return None

    import threading

    box = {}

    def _build():
        try:
            box["backend"] = InputBackend(dbus_addr)
        except Exception:
            box["backend"] = None

    worker = threading.Thread(target=_build, daemon=True)
    worker.start()
    worker.join(timeout)
    return box.get("backend")


class AutomationEngine:'''

EDITS = [
    ("class AutomationEngine:", HELPER),
    (
        "        try:\n"
        "            self._input = InputBackend(info.dbus_address)\n"
        "        except RuntimeError:\n"
        "            self._input = None\n",
        "        self._input = _make_input_backend_timeboxed(info.dbus_address)\n",
    ),
    (
        "        try:\n"
        "            self._input = InputBackend(dbus_addr)\n"
        '            result += "\\nInput backend: KWin EIS"\n'
        "        except RuntimeError:\n"
        "            self._input = None\n"
        '            if shutil.which("ydotool"):\n',
        "        self._input = _make_input_backend_timeboxed(dbus_addr)\n"
        "        if self._input is not None:\n"
        '            result += "\\nInput backend: " + type(self._input).__name__\n'
        "        else:\n"
        '            if shutil.which("ydotool"):\n',
    ),
    # Accurate backend label in session_start (was hard-coded "KWin EIS").
    (
        '        input_status = "Input backend: KWin EIS" if self._input '
        'else "No input backend available"\n',
        '        input_status = ("Input backend: " + type(self._input).__name__) '
        'if self._input else "No input backend available"\n',
    ),
    # Propagate the server's resolved import path to child processes. The Nix
    # wrapper injects module paths via site.addsitedir in the entry script, not
    # PYTHONPATH, so the AT-SPI query subprocess (python -m kwin_mcp.accessibility)
    # otherwise can't import kwin_mcp.
    (
        '        env["QT_QPA_PLATFORM"] = "wayland"\n'
        '        env.pop("DISPLAY", None)\n'
        "        return env\n",
        '        env["QT_QPA_PLATFORM"] = "wayland"\n'
        '        env.pop("DISPLAY", None)\n'
        '        env["PYTHONPATH"] = os.pathsep.join(p for p in sys.path if p)\n'
        "        return env\n",
    ),
]

for old, new in EDITS:
    if old not in src:
        sys.exit(f"kwin-mcp core.py fixup: anchor not found: {old[:70]!r}")
    src = src.replace(old, new, 1)

with open(path, "w") as fh:
    fh.write(src)
print("kwin-mcp core.py fixups applied")
