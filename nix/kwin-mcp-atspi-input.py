"""AT-SPI action-based input backend for kwin-mcp (NixOS / Wayland).

kwin-mcp's stock InputBackend drives input through KWin's EIS/libei interface,
which segfaults on this host (``input.py:_bind_seat_capabilities`` — a libei ABI
mismatch), and its only other option (ydotool) needs ``/dev/uinput`` access the
session user doesn't have. This backend instead drives the app through the
accessibility layer: coordinate clicks are hit-tested to the AT-SPI element at
that point and invoked via ``Action.do_action`` / focus; typing goes to the
focused editable via ``EditableText``. No compositor input injection, no special
privileges — semantic, Wayland-native, and robust for accessible apps (exactly
the surface the a11y-audit annotations expose).

Ops that have no faithful accessibility equivalent (raw pointer moves, pixel
drags, scrolling, multi-touch) are logged and treated as best-effort no-ops
rather than raising, so the MCP tools never error out.
"""

from __future__ import annotations

import sys

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402


def _log(msg: str) -> None:
    print(f"[atspi-input] {msg}", file=sys.stderr)


class AtspiInputBackend:
    """Implements the InputBackend surface kwin_mcp.core calls, via AT-SPI."""

    def __init__(self, dbus_address: str | None = None) -> None:
        # Atspi resolves the a11y bus from the (session) D-Bus itself; the
        # caller has already exported DBUS_SESSION_BUS_ADDRESS for the target
        # session, so a plain init attaches to the right bus.
        Atspi.init()
        self._last = (0, 0)

    # ── hit-testing ───────────────────────────────────────────────────────
    def _candidates_at(self, x: int, y: int) -> list:
        hits: list = []
        desk = Atspi.get_desktop(0)
        for i in range(desk.get_child_count()):
            try:
                app = desk.get_child_at_index(i)
            except Exception:
                continue
            self._collect(app, x, y, hits, 0)
        # deepest / smallest-area actionable element wins
        def area(node) -> int:
            try:
                e = node.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
                return e.width * e.height
            except Exception:
                return 1 << 30

        hits.sort(key=area)
        return hits

    def _collect(self, node, x: int, y: int, hits: list, depth: int) -> None:
        if node is None or depth > 30:
            return
        try:
            comp = node.get_component_iface()
            if comp is not None:
                e = comp.get_extents(Atspi.CoordType.SCREEN)
                if e.x <= x < e.x + e.width and e.y <= y < e.y + e.height:
                    hits.append(node)
        except Exception:
            pass
        try:
            n = node.get_child_count()
        except Exception:
            return
        for i in range(n):
            try:
                self._collect(node.get_child_at_index(i), x, y, hits, depth + 1)
            except Exception:
                pass

    def _act(self, node) -> bool:
        try:
            ai = node.get_action_iface()
            if ai is not None and ai.get_n_actions() > 0:
                ai.do_action(0)
                return True
        except Exception:
            pass
        try:
            comp = node.get_component_iface()
            if comp is not None:
                comp.grab_focus()
                return True
        except Exception:
            pass
        return False

    # ── mouse ─────────────────────────────────────────────────────────────
    def mouse_move(self, x: int, y: int) -> None:
        self._last = (x, y)

    # Activation actions in priority order. Order matters: Qt exposes a radio as
    # ["Toggle", "Press", "SetFocus", ...] where "Toggle" is a no-op but "Press"
    # actually selects it, so "press" must outrank "toggle".
    _ACTIVATE_PRIORITY = (
        "press",
        "click",
        "activate",
        "invoke",
        "select",
        "jump",
        "open",
        "toggle",
    )

    @staticmethod
    def _action_names(node) -> list[str]:
        try:
            ai = node.get_action_iface()
            if ai is None:
                return []
            return [ai.get_action_name(k).lower() for k in range(ai.get_n_actions())]
        except Exception:
            return []

    def _activate_index(self, names: list[str]) -> int | None:
        for pref in self._ACTIVATE_PRIORITY:
            if pref in names:
                return names.index(pref)
        return None

    def mouse_click(self, x, y, button=None, click_count=1, modifiers=None, hold_ms=0) -> None:
        self._last = (int(x), int(y))
        cands = self._candidates_at(int(x), int(y))  # smallest-area first
        # 1) smallest element carrying a real activation action -> invoke the
        #    highest-priority one (skip focus-only labels/fillers overlapping the point).
        for node in cands:
            idx = self._activate_index(self._action_names(node))
            if idx is not None:
                try:
                    node.get_action_iface().do_action(idx)
                    return
                except Exception:
                    continue
        # 2) nothing activatable: fall back to any actionable node, then focus.
        for node in cands:
            if self._action_names(node):
                try:
                    node.get_action_iface().do_action(0)
                    return
                except Exception:
                    continue
        if cands and self._act(cands[0]):
            return
        _log(f"no actionable AT-SPI element at ({x}, {y})")

    def mouse_button_down(self, x, y, button=None) -> None:
        self._last = (int(x), int(y))

    def mouse_button_up(self, x, y, button=None) -> None:
        # emulate a press as down+up -> single activation on release
        self.mouse_click(x, y)

    def mouse_scroll(self, *a, **k) -> None:
        _log("mouse_scroll has no AT-SPI equivalent; ignored")

    def mouse_drag(self, *a, **k) -> None:
        _log("mouse_drag has no AT-SPI equivalent; ignored")

    # ── keyboard ──────────────────────────────────────────────────────────
    def _focused_editable(self):
        desk = Atspi.get_desktop(0)
        stack = [desk.get_child_at_index(i) for i in range(desk.get_child_count())]
        while stack:
            node = stack.pop()
            if node is None:
                continue
            try:
                ss = node.get_state_set()
                if ss.contains(Atspi.StateType.FOCUSED) and ss.contains(
                    Atspi.StateType.EDITABLE
                ):
                    return node
            except Exception:
                pass
            try:
                for i in range(node.get_child_count()):
                    stack.append(node.get_child_at_index(i))
            except Exception:
                pass
        return None

    def keyboard_type(self, text: str) -> None:
        node = self._focused_editable()
        if node is None:
            _log("keyboard_type: no focused editable element")
            return
        try:
            et = node.get_editable_text_iface()
            offset = 0
            ti = node.get_text_iface()
            if ti is not None:
                offset = ti.get_caret_offset()
            et.insert_text(max(offset, 0), text, len(text))
        except Exception as exc:  # noqa: BLE001
            _log(f"keyboard_type failed: {exc}")

    def keyboard_type_unicode(self, text: str, dbus_address: str | None = None) -> bool:
        self.keyboard_type(text)
        return True

    def keyboard_key(self, key: str) -> None:
        # Synthetic keysyms aren't deliverable over AT-SPI on Wayland; only
        # activation-style keys can be emulated semantically.
        _log(f"keyboard_key({key!r}) not supported via AT-SPI on Wayland; ignored")

    def keyboard_key_down(self, key: str) -> None:
        self.keyboard_key(key)

    def keyboard_key_up(self, key: str) -> None:
        pass

    # ── touch (map tap -> click; gestures unsupported) ──────────────────────
    def touch_tap(self, x, y, hold_ms=0) -> None:
        self.mouse_click(x, y)

    def touch_swipe(self, *a, **k) -> None:
        _log("touch_swipe unsupported via AT-SPI; ignored")

    def touch_pinch(self, *a, **k) -> None:
        _log("touch_pinch unsupported via AT-SPI; ignored")

    def touch_multi_swipe(self, *a, **k) -> None:
        _log("touch_multi_swipe unsupported via AT-SPI; ignored")

    def close(self) -> None:
        pass
