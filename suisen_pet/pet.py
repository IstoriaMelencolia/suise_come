from __future__ import annotations

import json
import math
import random
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import pygame
from PIL import Image
from pynput import keyboard, mouse
from PySide6.QtCore import QEasingCurve, QObject, QPoint, QPropertyAnimation, QThread, QTimer, Signal, Slot, Qt
from PySide6.QtGui import QImage, QPixmap
from PySide6.QtWidgets import QApplication, QLabel, QWidget
from screeninfo import get_monitors

from config import (
    ANIMATION_MS,
    AUTO_EXIT_IDLE_SECONDS,
    ASK_VOICE_DIR,
    DEFAULT_ALLOWED_EDGES,
    DEFAULT_EDGE_OFFSETS,
    EDGE_VISIBLE_RATIO,
    ENABLE_MOUSE_PASSTHROUGH,
    FINISH_VOICE_DIR,
    HOST,
    IMAGE_DIR,
    IMAGE_CROP_RATIO,
    INPUT_GRACE_MS,
    LEFT_RIGHT_VISIBLE_RATIO,
    LEFT_RIGHT_SCALE,
    MAX_SCREEN_FILL_RATIO,
    PORT,
    SCREEN_SAFE_MARGIN,
    SUPPORTED_AUDIO_EXTENSIONS,
    SUPPORTED_IMAGE_EXTENSIONS,
    TEST_DISPLAY_MS,
    TOP_BOTTOM_VISIBLE_RATIO,
    TOP_BOTTOM_SCALE,
)

try:
    import win32con
    import win32gui
except ImportError:  # pragma: no cover - pywin32 is expected on the target machine.
    win32con = None
    win32gui = None


EDGES = tuple(DEFAULT_ALLOWED_EDGES)
SHOW_MODES = ("ask", "finish", "test")


def _log(message: str) -> None:
    print(f"[suisen_pet] {message}", flush=True)


def _thread_info() -> str:
    thread = threading.current_thread()
    return (
        f"python_thread={thread.name} ident={thread.ident} "
        f"qt_thread_id={id(QThread.currentThread())}"
    )


class PetController(QObject):
    show_requested = Signal(str, object)
    hide_requested = Signal()
    shutdown_requested = Signal(str)

    def __init__(self) -> None:
        super().__init__()
        self.window: PetWindow | None = None
        self._lock = threading.RLock()
        self._input_enabled = False
        self._visible = False
        self._animating = False
        self._edge: str | None = None
        self._last_mode: str | None = None
        self._last_voice: str | None = None
        self._audio_ready = False
        self._audio_error: str | None = None
        self._listeners_ready = False
        self._listeners_error: str | None = None
        self._keyboard_listener: keyboard.Listener | None = None
        self._mouse_listener: mouse.Listener | None = None
        self._last_activity_time = time.monotonic()
        self._shutdown_started = False
        self._idle_timer = QTimer(self)
        self._idle_timer.setInterval(30_000)
        self._idle_timer.timeout.connect(self._check_idle_timeout)

        self.show_requested.connect(self._handle_show, Qt.ConnectionType.QueuedConnection)
        self.hide_requested.connect(self._handle_hide, Qt.ConnectionType.QueuedConnection)
        self.shutdown_requested.connect(self._handle_shutdown, Qt.ConnectionType.QueuedConnection)

    def attach_window(self, window: "PetWindow") -> None:
        self.window = window

    def record_activity(self, source: str) -> None:
        with self._lock:
            self._last_activity_time = time.monotonic()
        _log(f"activity recorded from {source}")

    def start_idle_timer(self) -> None:
        self._idle_timer.start()
        _log(f"idle auto-exit enabled: {AUTO_EXIT_IDLE_SECONDS} seconds")

    def request_show(self, voice_kind: str, edge: str | None = None) -> None:
        _log(f"HTTP requested show mode={voice_kind} edge={edge}; emitting Qt signal; {_thread_info()}")
        self.show_requested.emit(voice_kind, edge)

    def request_hide(self) -> None:
        _log(f"HTTP requested hide; emitting Qt signal; {_thread_info()}")
        self.hide_requested.emit()

    def request_shutdown(self, reason: str) -> None:
        _log(f"HTTP requested shutdown reason={reason}; emitting Qt signal; {_thread_info()}")
        self.shutdown_requested.emit(reason)

    def status(self) -> dict[str, Any]:
        with self._lock:
            idle_seconds = int(time.monotonic() - self._last_activity_time)
            return {
                "running": True,
                "visible": self._visible,
                "animating": self._animating,
                "edge": self._edge,
                "last_mode": self._last_mode,
                "input_enabled": self._input_enabled,
                "audio_ready": self._audio_ready,
                "audio_error": self._audio_error,
                "listeners_ready": self._listeners_ready,
                "listeners_error": self._listeners_error,
                "last_voice": self._last_voice,
                "image_count": len(_image_files()),
                "ask_voice_count": _voice_file_count("ask"),
                "finish_voice_count": _voice_file_count("finish"),
                "idle_seconds": idle_seconds,
                "auto_exit_idle_seconds": AUTO_EXIT_IDLE_SECONDS,
            }

    def set_window_state(
        self,
        *,
        visible: bool,
        animating: bool,
        edge: str | None,
        mode: str | None = None,
    ) -> None:
        with self._lock:
            self._visible = visible
            self._animating = animating
            self._edge = edge
            if mode is not None:
                self._last_mode = mode

    def enable_input_hiding(self) -> None:
        with self._lock:
            if self._visible and not self._animating:
                self._input_enabled = True

    def disable_input_hiding(self) -> None:
        with self._lock:
            self._input_enabled = False

    def start_input_listeners(self) -> None:
        try:
            self._keyboard_listener = keyboard.Listener(on_press=self._on_keyboard_press)
            self._mouse_listener = mouse.Listener(
                on_move=self._on_mouse_move,
                on_click=self._on_mouse_click,
                on_scroll=self._on_mouse_scroll,
            )
            self._keyboard_listener.start()
            self._mouse_listener.start()
        except Exception as exc:  # noqa: BLE001 - listener failures should not crash the pet.
            with self._lock:
                self._listeners_ready = False
                self._listeners_error = str(exc)
            print(f"Input listeners could not start: {exc}", flush=True)
            return

        with self._lock:
            self._listeners_ready = True
            self._listeners_error = None

    def play_voice(self, voice_kind: str, character_key: str) -> None:
        voice_folder, voice_path = _random_voice(voice_kind, character_key)
        _log(f"selected voice folder: {voice_folder}")
        if voice_path is None:
            with self._lock:
                self._audio_ready = False
                self._audio_error = None
                self._last_voice = None
            _log_missing_audio(voice_kind, character_key, voice_folder)
            _log("selected voice path: no matched voice")
            _log(
                f"No matched audio selected for mode='{voice_kind}' "
                f"character_key='{character_key}'. Showing pet without sound."
            )
            return

        _log(f"selected voice path: {voice_path}")
        try:
            if not pygame.mixer.get_init():
                pygame.mixer.init()
            pygame.mixer.music.stop()
            pygame.mixer.music.load(str(voice_path))
            pygame.mixer.music.play(loops=0)
        except Exception as exc:  # noqa: BLE001 - audio failures should not crash the pet.
            with self._lock:
                self._audio_ready = False
                self._audio_error = str(exc)
            print(f"Could not play voice file '{voice_path.name}': {exc}", flush=True)
            return

        with self._lock:
            self._audio_ready = True
            self._audio_error = None
            self._last_voice = str(voice_path)

    @Slot(str, object)
    def _handle_show(self, voice_kind: str, edge: str | None) -> None:
        _log(f"Qt slot _handle_show received mode={voice_kind} edge={edge}; {_thread_info()}")
        if self.window is None:
            _log("No PetWindow is attached; cannot show.")
            return
        if voice_kind not in SHOW_MODES:
            _log(f"Unknown show mode: {voice_kind}")
            return
        if edge is not None and edge not in EDGES:
            _log(f"Unknown edge: {edge}")
            return
        if voice_kind == "test":
            self.window.show_test()
            return
        self.window.show_pet(voice_kind, edge)

    @Slot()
    def _handle_hide(self) -> None:
        _log(f"Qt slot _handle_hide received; {_thread_info()}")
        if self.window is None:
            return
        self.window.hide_pet()

    @Slot(str)
    def _handle_shutdown(self, reason: str) -> None:
        if self._shutdown_started:
            return
        self._shutdown_started = True
        _log(f"Qt slot _handle_shutdown received reason={reason}; {_thread_info()}")
        self._idle_timer.stop()
        self.disable_input_hiding()

        try:
            pygame.mixer.music.stop()
        except Exception as exc:  # noqa: BLE001 - shutdown should not be blocked by audio errors.
            _log(f"audio stop during shutdown failed: {exc}")

        if self.window is not None:
            self.window.stop_and_close()

        app = QApplication.instance()
        if app is not None:
            QTimer.singleShot(50, app.quit)

    @Slot()
    def _check_idle_timeout(self) -> None:
        with self._lock:
            idle_seconds = time.monotonic() - self._last_activity_time

        if idle_seconds > AUTO_EXIT_IDLE_SECONDS:
            _log(
                "auto-exit idle timeout reached: "
                f"idle_seconds={int(idle_seconds)} limit={AUTO_EXIT_IDLE_SECONDS}"
            )
            self._handle_shutdown("idle timeout")

    def _on_keyboard_press(self, _key: keyboard.Key | keyboard.KeyCode | None) -> None:
        self._hide_from_input()

    def _on_mouse_move(self, _x: int, _y: int) -> None:
        self._hide_from_input()

    def _on_mouse_click(self, _x: int, _y: int, _button: mouse.Button, _pressed: bool) -> None:
        self._hide_from_input()

    def _on_mouse_scroll(self, _x: int, _y: int, _dx: int, _dy: int) -> None:
        self._hide_from_input()

    def _hide_from_input(self) -> None:
        should_hide = False
        with self._lock:
            if self._input_enabled and self._visible:
                self._input_enabled = False
                should_hide = True
        if should_hide:
            self.hide_requested.emit()


class PetWindow(QWidget):
    def __init__(self, controller: PetController) -> None:
        super().__init__()
        self.controller = controller
        self.current_edge: str | None = None
        self.hidden_pos: QPoint | None = None
        self.visible_pos: QPoint | None = None
        self.animation = QPropertyAnimation(self, b"pos", self)
        self.animation.setDuration(ANIMATION_MS)

        self.label = QLabel(self)
        self.label.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents, ENABLE_MOUSE_PASSTHROUGH)

        flags = (
            Qt.WindowType.FramelessWindowHint
            | Qt.WindowType.Tool
            | Qt.WindowType.WindowStaysOnTopHint
        )
        self.setWindowFlags(flags)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground, True)
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents, ENABLE_MOUSE_PASSTHROUGH)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating, True)

    def show_pet(self, voice_kind: str, requested_edge: str | None = None) -> None:
        _log(f"show_pet mode={voice_kind} requested_edge={requested_edge}; {_thread_info()}")
        if self.isVisible():
            _log("Window is already visible; reusing it for the newly selected character.")

        monitor = _primary_monitor()
        try:
            selected_image = _random_image()
            if selected_image is None:
                raise FileNotFoundError("No supported image files were found.")
            image_path, character_key = selected_image
            profile = _load_image_profile(image_path, character_key)
            edge = requested_edge or random.choice(profile["allowed_edges"])
            pixmap, image_info = _build_pet_pixmap(edge, monitor, image_path, character_key, profile)
        except Exception as exc:  # noqa: BLE001 - missing/bad assets should not crash the pet.
            _log(f"Could not build pet image for show mode={voice_kind}: {exc}")
            _log_missing_images()
            self.controller.set_window_state(visible=False, animating=False, edge=None, mode=voice_kind)
            return
        _log_image_info(voice_kind, edge, image_info, monitor)
        self.label.setPixmap(pixmap)
        self.label.resize(pixmap.size())
        self.setFixedSize(pixmap.size())

        geometry_info = _positions_for_edge(edge, pixmap.width(), pixmap.height(), monitor, profile)
        hidden_pos = geometry_info["start_pos"]
        visible_pos = geometry_info["end_pos"]
        _log_geometry_info(geometry_info, pixmap.width(), pixmap.height())
        self.current_edge = edge
        self.hidden_pos = hidden_pos
        self.visible_pos = visible_pos

        self.controller.disable_input_hiding()
        self.controller.set_window_state(visible=True, animating=True, edge=edge, mode=voice_kind)

        self.animation.stop()
        self.setGeometry(hidden_pos.x(), hidden_pos.y(), pixmap.width(), pixmap.height())
        self.show()
        _log("window.show() called")
        _apply_windows_window_styles(self)
        self.raise_()
        self.activateWindow()
        self.controller.play_voice(voice_kind, image_info["voice_key"])

        self.animation.setEasingCurve(QEasingCurve.Type.OutCubic)
        self.animation.setStartValue(hidden_pos)
        self.animation.setEndValue(visible_pos)
        self._disconnect_animation_finished()
        self.animation.finished.connect(self._show_animation_finished)
        self.animation.start()
        _log("animation.start() called")

        QTimer.singleShot(INPUT_GRACE_MS, self.controller.enable_input_hiding)

    def show_test(self) -> None:
        mode = "test"
        edge = "bottom"
        _log(f"show_test mode={mode}; {_thread_info()}")

        monitor = _primary_monitor()
        try:
            selected_image = _random_image()
            if selected_image is None:
                raise FileNotFoundError("No supported image files were found.")
            image_path, character_key = selected_image
            profile = _load_image_profile(image_path, character_key)
            pixmap, image_info = _build_pet_pixmap(edge, monitor, image_path, character_key, profile)
        except Exception as exc:  # noqa: BLE001 - missing/bad assets should not crash the pet.
            _log(f"Could not build pet image for show test: {exc}")
            _log_missing_images()
            self.controller.set_window_state(visible=False, animating=False, edge=None, mode=mode)
            return
        _log_image_info(mode, "center", image_info, monitor)
        self.label.setPixmap(pixmap)
        self.label.resize(pixmap.size())
        self.setFixedSize(pixmap.size())

        center_pos = _center_position(pixmap.width(), pixmap.height(), monitor)
        _log(f"test geometry start_geometry={_geometry_text(center_pos, pixmap.width(), pixmap.height())}")

        self.current_edge = None
        self.hidden_pos = None
        self.visible_pos = center_pos

        self.controller.disable_input_hiding()
        self.controller.set_window_state(visible=True, animating=False, edge=None, mode=mode)

        self.animation.stop()
        self.setGeometry(center_pos.x(), center_pos.y(), pixmap.width(), pixmap.height())
        self.show()
        _log("window.show() called")
        _apply_windows_window_styles(self)
        self.raise_()
        self.activateWindow()
        self.controller.play_voice(mode, image_info["voice_key"])
        _log("animation.start() skipped for show test")

        QTimer.singleShot(TEST_DISPLAY_MS, self._hide_test_window)

    def hide_pet(self) -> None:
        self.controller.disable_input_hiding()
        if not self.isVisible():
            self.controller.set_window_state(visible=False, animating=False, edge=None)
            return

        if self.hidden_pos is None:
            self.hide()
            self.controller.set_window_state(visible=False, animating=False, edge=None)
            return

        self.controller.set_window_state(visible=True, animating=True, edge=self.current_edge)
        self.animation.stop()
        self.animation.setEasingCurve(QEasingCurve.Type.InCubic)
        self.animation.setStartValue(self.pos())
        self.animation.setEndValue(self.hidden_pos)
        self._disconnect_animation_finished()
        self.animation.finished.connect(self._hide_animation_finished)
        self.animation.start()

    def stop_and_close(self) -> None:
        _log("stopping animation and closing pet window")
        self.animation.stop()
        self.controller.disable_input_hiding()
        self.hide()
        self.close()
        self.controller.set_window_state(visible=False, animating=False, edge=None)

    def _hide_test_window(self) -> None:
        if self.isVisible() and self.current_edge is None and self.hidden_pos is None:
            _log("show test display time elapsed; hiding window")
            self.hide()
            self.controller.set_window_state(visible=False, animating=False, edge=None)

    def _disconnect_animation_finished(self) -> None:
        try:
            self.animation.finished.disconnect()
        except (RuntimeError, TypeError):
            pass

    def _show_animation_finished(self) -> None:
        self.controller.set_window_state(visible=True, animating=False, edge=self.current_edge)

    def _hide_animation_finished(self) -> None:
        self.controller.disable_input_hiding()
        self.hide()
        self.controller.set_window_state(visible=False, animating=False, edge=None)


class PetRequestHandler(BaseHTTPRequestHandler):
    server: "PetHTTPServer"

    def do_GET(self) -> None:  # noqa: N802 - stdlib handler API.
        self._handle_request()

    def do_POST(self) -> None:  # noqa: N802 - stdlib handler API.
        self._handle_request()

    def log_message(self, _format: str, *_args: Any) -> None:
        return

    def _handle_request(self) -> None:
        parsed = urlparse(self.path)
        parts = [part for part in parsed.path.split("/") if part]
        self.server.controller.record_activity(parsed.path or "/")

        if parts == ["status"]:
            self._send_json(200, self.server.controller.status())
            return

        if len(parts) in {2, 3} and parts[0] == "show":
            mode = parts[1]
            if mode not in SHOW_MODES:
                self._send_json(400, {"ok": False, "message": "show kind must be 'ask', 'finish', or 'test'."})
                return
            edge = parts[2] if len(parts) == 3 else None
            if edge is not None and edge not in EDGES:
                self._send_json(400, {"ok": False, "message": "edge must be top, bottom, left, or right."})
                return
            if mode == "test" and edge is not None:
                self._send_json(400, {"ok": False, "message": "show test does not accept an edge."})
                return
            self.server.controller.request_show(mode, edge)
            edge_text = f" {edge}" if edge is not None else ""
            self._send_json(200, {"ok": True, "message": f"show {mode}{edge_text} requested."})
            return

        if parts == ["hide"]:
            self.server.controller.request_hide()
            self._send_json(200, {"ok": True, "message": "hide requested."})
            return

        if parts == ["shutdown"]:
            self.server.controller.request_shutdown("http /shutdown")
            self._send_json(200, {"ok": True, "message": "shutdown requested."})
            return

        self._send_json(404, {"ok": False, "message": "unknown endpoint."})

    def _send_json(self, status_code: int, payload: dict[str, Any]) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class PetHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, server_address: tuple[str, int], controller: PetController) -> None:
        self.controller = controller
        super().__init__(server_address, PetRequestHandler)


def _voice_root(voice_kind: str) -> Path | None:
    if voice_kind in {"ask", "test"}:
        return ASK_VOICE_DIR
    if voice_kind == "finish":
        return FINISH_VOICE_DIR
    return None


def _voice_folder(voice_kind: str, character_key: str) -> Path | None:
    root = _voice_root(voice_kind)
    return root / character_key if root is not None else None


def _voice_files(voice_kind: str, character_key: str) -> list[Path]:
    folder = _voice_folder(voice_kind, character_key)
    if folder is None:
        return []
    return _supported_files_in_dir(folder, SUPPORTED_AUDIO_EXTENSIONS)


def _random_voice(voice_kind: str, character_key: str) -> tuple[Path | None, Path | None]:
    folder = _voice_folder(voice_kind, character_key)
    files = _voice_files(voice_kind, character_key)
    return folder, random.choice(files) if files else None


def _voice_file_count(voice_kind: str) -> int:
    root = _voice_root(voice_kind)
    if root is None or not root.is_dir():
        return 0
    return sum(
        len(_supported_files_in_dir(folder, SUPPORTED_AUDIO_EXTENSIONS))
        for folder in root.iterdir()
        if folder.is_dir()
    )


def _image_files() -> list[Path]:
    return _supported_files_in_dir(IMAGE_DIR, SUPPORTED_IMAGE_EXTENSIONS)


def _random_image() -> tuple[Path, str] | None:
    files = _image_files()
    if not files:
        return None
    image_path = random.choice(files)
    return image_path, image_path.stem


def _default_image_profile(image_path: Path, character_key: str) -> dict[str, Any]:
    return {
        "profile_path": image_path.with_suffix(".json"),
        "voice_key": character_key,
        "crop_ratio": IMAGE_CROP_RATIO,
        "top_bottom_scale": TOP_BOTTOM_SCALE,
        "left_right_scale": LEFT_RIGHT_SCALE,
        "top_bottom_visible_ratio": TOP_BOTTOM_VISIBLE_RATIO,
        "left_right_visible_ratio": LEFT_RIGHT_VISIBLE_RATIO,
        "allowed_edges": list(EDGES),
        "offset": dict(DEFAULT_EDGE_OFFSETS),
    }


def _valid_profile_number(value: Any, *, minimum: float, maximum: float | None = None) -> bool:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    numeric_value = float(value)
    if not math.isfinite(numeric_value):
        return False
    if numeric_value < minimum:
        return False
    return maximum is None or numeric_value <= maximum


def _load_image_profile(image_path: Path, character_key: str) -> dict[str, Any]:
    profile = _default_image_profile(image_path, character_key)
    profile_path = profile["profile_path"]
    if not profile_path.is_file():
        return profile

    try:
        raw_profile = json.loads(profile_path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        _log(f"profile JSON could not be loaded: path={profile_path} error={exc}; using defaults")
        return profile

    if not isinstance(raw_profile, dict):
        _log(f"profile JSON must contain an object: path={profile_path}; using defaults")
        return profile

    voice_key = raw_profile.get("voice_key")
    if voice_key is not None:
        if (
            isinstance(voice_key, str)
            and voice_key.strip()
            and voice_key not in {".", ".."}
            and "/" not in voice_key
            and "\\" not in voice_key
        ):
            profile["voice_key"] = voice_key.strip()
        else:
            _log(f"ignored invalid profile field voice_key: path={profile_path} value={voice_key!r}")

    number_fields = {
        "crop_ratio": (0.0, 1.0),
        "top_bottom_scale": (0.0, None),
        "left_right_scale": (0.0, None),
        "top_bottom_visible_ratio": (0.0, 1.0),
        "left_right_visible_ratio": (0.0, 1.0),
    }
    for field, (minimum, maximum) in number_fields.items():
        if field not in raw_profile:
            continue
        value = raw_profile[field]
        if _valid_profile_number(value, minimum=minimum, maximum=maximum) and float(value) > 0:
            profile[field] = float(value)
        else:
            _log(f"ignored invalid profile field {field}: path={profile_path} value={value!r}")

    if "allowed_edges" in raw_profile:
        raw_edges = raw_profile["allowed_edges"]
        if isinstance(raw_edges, list):
            allowed_edges = list(dict.fromkeys(edge for edge in raw_edges if edge in EDGES))
            if allowed_edges:
                profile["allowed_edges"] = allowed_edges
            else:
                _log(f"ignored invalid profile field allowed_edges: path={profile_path} value={raw_edges!r}")
        else:
            _log(f"ignored invalid profile field allowed_edges: path={profile_path} value={raw_edges!r}")

    if "offset" in raw_profile:
        raw_offset = raw_profile["offset"]
        if isinstance(raw_offset, dict):
            offset = dict(DEFAULT_EDGE_OFFSETS)
            for edge in EDGES:
                if edge not in raw_offset:
                    continue
                value = raw_offset[edge]
                if (
                    isinstance(value, bool)
                    or not isinstance(value, (int, float))
                    or not math.isfinite(float(value))
                ):
                    _log(f"ignored invalid profile offset {edge}: path={profile_path} value={value!r}")
                    continue
                offset[edge] = int(value)
            profile["offset"] = offset
        else:
            _log(f"ignored invalid profile field offset: path={profile_path} value={raw_offset!r}")

    return profile


def _supported_files_in_dir(directory: Path, extensions: set[str]) -> list[Path]:
    if not directory.exists() or not directory.is_dir():
        return []
    return sorted(
        path
        for path in directory.iterdir()
        if path.is_file() and path.suffix.lower() in extensions
    )


def _format_paths(paths: list[Path]) -> str:
    return ", ".join(str(path) for path in paths)


def _format_extensions(extensions: set[str]) -> str:
    return ", ".join(sorted(extensions))


def _log_missing_images() -> None:
    _log(
        "No supported image files found. "
        f"directory={IMAGE_DIR} "
        f"extensions=[{_format_extensions(SUPPORTED_IMAGE_EXTENSIONS)}]"
    )


def _log_missing_audio(voice_kind: str, character_key: str, voice_folder: Path | None) -> None:
    if voice_folder is None:
        _log(f"no matched voice: unsupported mode='{voice_kind}' character_key='{character_key}'")
        return

    if not voice_folder.is_dir():
        _log(f"matched voice folder not found: {voice_folder}")
        return

    _log(
        "no matched voice files: "
        f"folder={voice_folder} "
        f"extensions=[{_format_extensions(SUPPORTED_AUDIO_EXTENSIONS)}]"
    )


def _display_scale_for_edge(edge: str, profile: dict[str, Any]) -> float:
    if edge in {"top", "bottom"}:
        return float(profile["top_bottom_scale"])
    return float(profile["left_right_scale"])


def _visible_ratio_for_edge(edge: str, profile: dict[str, Any]) -> float:
    if edge in {"top", "bottom"}:
        return float(profile["top_bottom_visible_ratio"])
    return float(profile["left_right_visible_ratio"])


def _trim_transparent_padding(image: Image.Image) -> tuple[Image.Image, tuple[int, int, int, int] | None]:
    bbox = image.getchannel("A").getbbox()
    if bbox is None:
        return image, None
    return image.crop(bbox), bbox


def _build_pet_pixmap(
    edge: str,
    monitor: dict[str, int],
    image_path: Path,
    character_key: str,
    profile: dict[str, Any],
) -> tuple[QPixmap, dict[str, Any]]:
    image_info: dict[str, Any] = {
        "path": str(image_path),
        "character_key": character_key,
        "profile_path": str(profile["profile_path"]),
        "voice_key": profile["voice_key"],
        "effective_crop_ratio": profile["crop_ratio"],
        "effective_top_bottom_scale": profile["top_bottom_scale"],
        "effective_left_right_scale": profile["left_right_scale"],
        "effective_top_bottom_visible_ratio": profile["top_bottom_visible_ratio"],
        "effective_left_right_visible_ratio": profile["left_right_visible_ratio"],
        "effective_allowed_edges": list(profile["allowed_edges"]),
        "effective_offset": dict(profile["offset"]),
        "exists": image_path.exists(),
        "image_dir": str(IMAGE_DIR),
        "supported_image_extensions": sorted(SUPPORTED_IMAGE_EXTENSIONS),
        "max_screen_fill_ratio": MAX_SCREEN_FILL_RATIO,
    }

    with Image.open(image_path) as source:
        try:
            source.seek(0)
        except EOFError:
            pass
        image = source.convert("RGBA")
    image_info["original_size"] = image.size
    crop_height = max(1, int(image.height * float(profile["crop_ratio"])))
    image = image.crop((0, 0, image.width, crop_height))
    image_info["cropped_size"] = image.size

    if edge == "top":
        image = image.rotate(180, expand=True)
    elif edge == "left":
        image = image.rotate(-90, expand=True)
    elif edge == "right":
        image = image.rotate(90, expand=True)
    image_info["rotated_size"] = image.size

    image, trim_bbox = _trim_transparent_padding(image)
    image_info["transparent_trim_bbox"] = trim_bbox
    image_info["trimmed_size"] = image.size

    display_scale = _display_scale_for_edge(edge, profile)
    image_info["display_scale"] = display_scale
    scaled_size = (
        max(1, int(image.width * display_scale)),
        max(1, int(image.height * display_scale)),
    )
    image_info["pre_limit_scaled_size"] = scaled_size

    safe_width = max(1, int(monitor["width"]) - (SCREEN_SAFE_MARGIN * 2))
    safe_height = max(1, int(monitor["height"]) - (SCREEN_SAFE_MARGIN * 2))
    max_width = max(1, int(safe_width * MAX_SCREEN_FILL_RATIO))
    max_height = max(1, int(safe_height * MAX_SCREEN_FILL_RATIO))
    image_info["max_allowed_size"] = (max_width, max_height)
    limit_scale = min(max_width / scaled_size[0], max_height / scaled_size[1], 1.0)
    final_size = (
        max(1, int(scaled_size[0] * limit_scale)),
        max(1, int(scaled_size[1] * limit_scale)),
    )
    image_info["screen_limited_scale"] = limit_scale
    image_info["final_scale_from_trimmed"] = display_scale * limit_scale
    image_info["final_size"] = final_size

    if image.size != final_size:
        image = image.resize(final_size, Image.Resampling.LANCZOS)

    image_data = image.tobytes("raw", "RGBA")
    qimage = QImage(
        image_data,
        image.width,
        image.height,
        image.width * 4,
        QImage.Format.Format_RGBA8888,
    ).copy()
    return QPixmap.fromImage(qimage), image_info


def _log_image_info(mode: str, edge: str, image_info: dict[str, Any], monitor: dict[str, int]) -> None:
    _log(f"received mode={mode}")
    _log(f"current thread info: {_thread_info()}")
    _log(f"IMAGE_CROP_RATIO={IMAGE_CROP_RATIO}")
    _log(f"TOP_BOTTOM_SCALE={TOP_BOTTOM_SCALE}")
    _log(f"LEFT_RIGHT_SCALE={LEFT_RIGHT_SCALE}")
    _log(f"MAX_SCREEN_FILL_RATIO={MAX_SCREEN_FILL_RATIO}")
    _log(f"selected image: {image_info['path']}")
    _log(f"character key: {image_info.get('character_key')}")
    _log(f"profile json path: {image_info.get('profile_path')}")
    _log(f"voice_key: {image_info.get('voice_key')}")
    _log(f"effective crop_ratio: {image_info.get('effective_crop_ratio')}")
    _log(
        "effective scale: "
        f"top_bottom={image_info.get('effective_top_bottom_scale')} "
        f"left_right={image_info.get('effective_left_right_scale')}"
    )
    _log(
        "effective visible ratio: "
        f"top_bottom={image_info.get('effective_top_bottom_visible_ratio')} "
        f"left_right={image_info.get('effective_left_right_visible_ratio')}"
    )
    _log(f"effective allowed_edges: {image_info.get('effective_allowed_edges')}")
    _log(f"effective offset: {image_info.get('effective_offset')}")
    _log(f"image exists: {image_info['exists']}")
    _log(f"image dir: {image_info.get('image_dir')}")
    _log(f"supported image extensions: {image_info.get('supported_image_extensions')}")
    _log(f"original size: {image_info.get('original_size')}")
    _log(f"cropped size: {image_info.get('cropped_size')}")
    _log(f"rotated size: {image_info.get('rotated_size')}")
    _log(f"transparent trim bbox: {image_info.get('transparent_trim_bbox')}")
    _log(f"trimmed size: {image_info.get('trimmed_size')}")
    _log(f"display scale for edge: {image_info.get('display_scale')}")
    _log(f"pre-limit scaled size: {image_info.get('pre_limit_scaled_size')}")
    _log(
        "post-limit scaled size: "
        f"{image_info.get('final_size')} "
        f"screen_limited_scale={image_info.get('screen_limited_scale')} "
        f"final_scale_from_trimmed={image_info.get('final_scale_from_trimmed')} "
        f"max_allowed_size={image_info.get('max_allowed_size')}"
    )
    _log(f"screen available area: {_monitor_text(monitor)}")
    _log(f"selected edge: {edge}")


def _positions_for_edge(
    edge: str,
    width: int,
    height: int,
    monitor: dict[str, int],
    profile: dict[str, Any],
) -> dict[str, Any]:
    left = int(monitor["x"])
    top = int(monitor["y"])
    right = left + int(monitor["width"])
    bottom = top + int(monitor["height"])

    if edge in {"top", "bottom"}:
        min_x = left + SCREEN_SAFE_MARGIN
        max_x = right - width - SCREEN_SAFE_MARGIN
        raw_x = _random_int(left, max(left, right - width))
        x = _clamp(raw_x, min_x, max_x)
        visible_ratio = _visible_ratio_for_edge(edge, profile)
        edge_offset = int(profile["offset"].get(edge, 0))
        base_visible_depth = max(1, int(height * visible_ratio))
        visible_depth = _clamp(base_visible_depth + edge_offset, 1, height)
        if edge == "top":
            start_pos = QPoint(x, top - height - 2)
            end_pos = QPoint(x, top - (height - visible_depth))
        else:
            start_pos = QPoint(x, bottom + 2)
            end_pos = QPoint(x, bottom - visible_depth)
        actual_visible_depth = _actual_visible_depth(edge, end_pos, width, height, monitor)
        return {
            "edge": edge,
            "axis": "x",
            "raw_position": raw_x,
            "clamped_position": x,
            "min_position": min_x,
            "max_position": max_x,
            "visible_ratio": visible_ratio,
            "edge_offset": edge_offset,
            "base_visible_depth": base_visible_depth,
            "visible_depth": visible_depth,
            "actual_visible_depth": actual_visible_depth,
            "start_pos": start_pos,
            "end_pos": end_pos,
        }

    min_y = top + SCREEN_SAFE_MARGIN
    max_y = bottom - height - SCREEN_SAFE_MARGIN
    raw_y = _random_int(top, max(top, bottom - height))
    y = _clamp(raw_y, min_y, max_y)
    visible_ratio = _visible_ratio_for_edge(edge, profile)
    edge_offset = int(profile["offset"].get(edge, 0))
    base_visible_depth = max(1, int(width * visible_ratio))
    visible_depth = _clamp(base_visible_depth + edge_offset, 1, width)
    if edge == "left":
        start_pos = QPoint(left - width - 2, y)
        end_pos = QPoint(left - (width - visible_depth), y)
    else:
        start_pos = QPoint(right + 2, y)
        end_pos = QPoint(right - visible_depth, y)
    actual_visible_depth = _actual_visible_depth(edge, end_pos, width, height, monitor)
    return {
        "edge": edge,
        "axis": "y",
        "raw_position": raw_y,
        "clamped_position": y,
        "min_position": min_y,
        "max_position": max_y,
        "visible_ratio": visible_ratio,
        "edge_offset": edge_offset,
        "base_visible_depth": base_visible_depth,
        "visible_depth": visible_depth,
        "actual_visible_depth": actual_visible_depth,
        "start_pos": start_pos,
        "end_pos": end_pos,
    }


def _center_position(width: int, height: int, monitor: dict[str, int]) -> QPoint:
    x = int(monitor["x"]) + max(0, (int(monitor["width"]) - width) // 2)
    y = int(monitor["y"]) + max(0, (int(monitor["height"]) - height) // 2)
    return QPoint(x, y)


def _geometry_text(position: QPoint, width: int, height: int) -> str:
    return f"({position.x()}, {position.y()}, {width}, {height})"


def _actual_visible_depth(edge: str, position: QPoint, width: int, height: int, monitor: dict[str, int]) -> int:
    screen_left = int(monitor["x"])
    screen_top = int(monitor["y"])
    screen_right = screen_left + int(monitor["width"])
    screen_bottom = screen_top + int(monitor["height"])

    if edge in {"top", "bottom"}:
        visible_top = max(position.y(), screen_top)
        visible_bottom = min(position.y() + height, screen_bottom)
        return max(0, visible_bottom - visible_top)

    visible_left = max(position.x(), screen_left)
    visible_right = min(position.x() + width, screen_right)
    return max(0, visible_right - visible_left)


def _log_geometry_info(geometry_info: dict[str, Any], width: int, height: int) -> None:
    _log(f"edge: {geometry_info['edge']}")
    _log(f"img_w={width} img_h={height}")
    _log(f"TOP_BOTTOM_VISIBLE_RATIO={TOP_BOTTOM_VISIBLE_RATIO}")
    _log(f"LEFT_RIGHT_VISIBLE_RATIO={LEFT_RIGHT_VISIBLE_RATIO}")
    _log(f"EDGE_VISIBLE_RATIO compatibility value={EDGE_VISIBLE_RATIO}")
    _log(f"visible_ratio used this time: {geometry_info['visible_ratio']}")
    _log(
        f"edge offset used this time: {geometry_info['edge_offset']} "
        f"base_visible_depth={geometry_info['base_visible_depth']}"
    )
    _log(f"clamp axis: {geometry_info['axis']}")
    _log(
        "clamp before random position: "
        f"{geometry_info['raw_position']} "
        f"allowed=[{geometry_info['min_position']}, {geometry_info['max_position']}]"
    )
    _log(f"clamp after final position: {geometry_info['clamped_position']}")
    _log(f"visible_depth={geometry_info['visible_depth']}")
    _log(f"actual visible pixels: {geometry_info['actual_visible_depth']}")
    _log(
        "animation geometry "
        f"start_geometry={_geometry_text(geometry_info['start_pos'], width, height)} "
        f"end_geometry={_geometry_text(geometry_info['end_pos'], width, height)}"
    )


def _clamp(value: int, minimum: int, maximum: int) -> int:
    if maximum < minimum:
        return minimum
    return max(minimum, min(value, maximum))


def _monitor_text(monitor: dict[str, int]) -> str:
    return (
        f"(x={monitor['x']}, y={monitor['y']}, "
        f"width={monitor['width']}, height={monitor['height']}, "
        f"margin={SCREEN_SAFE_MARGIN})"
    )


def _primary_monitor() -> dict[str, int]:
    screen = QApplication.primaryScreen()
    geometry = screen.availableGeometry() if screen is not None else None
    if geometry is not None:
        return {
            "x": geometry.x(),
            "y": geometry.y(),
            "width": geometry.width(),
            "height": geometry.height(),
        }

    try:
        monitors = get_monitors()
        if monitors:
            chosen = next((monitor for monitor in monitors if getattr(monitor, "is_primary", False)), monitors[0])
            return {
                "x": int(chosen.x),
                "y": int(chosen.y),
                "width": int(chosen.width),
                "height": int(chosen.height),
            }
    except Exception as exc:  # noqa: BLE001 - fall back to Qt screen geometry.
        print(f"screeninfo could not read monitors: {exc}", flush=True)

    return {"x": 0, "y": 0, "width": 1920, "height": 1080}


def _random_int(start: int, end: int) -> int:
    if end <= start:
        return start
    return random.randint(start, end)


def _apply_windows_window_styles(widget: QWidget) -> None:
    if win32gui is None or win32con is None:
        return

    try:
        hwnd = int(widget.winId())
        ex_style = win32gui.GetWindowLong(hwnd, win32con.GWL_EXSTYLE)
        ex_style |= win32con.WS_EX_LAYERED | win32con.WS_EX_TOOLWINDOW
        if ENABLE_MOUSE_PASSTHROUGH:
            ex_style |= win32con.WS_EX_TRANSPARENT
        else:
            ex_style &= ~win32con.WS_EX_TRANSPARENT
        win32gui.SetWindowLong(hwnd, win32con.GWL_EXSTYLE, ex_style)
        win32gui.SetWindowPos(
            hwnd,
            win32con.HWND_TOPMOST,
            0,
            0,
            0,
            0,
            win32con.SWP_NOMOVE
            | win32con.SWP_NOSIZE
            | win32con.SWP_NOACTIVATE
            | win32con.SWP_SHOWWINDOW,
        )
    except Exception as exc:  # noqa: BLE001 - style failure should not break the MVP.
        print(f"Could not apply click-through/topmost window style: {exc}", flush=True)


def _start_http_server(controller: PetController) -> PetHTTPServer:
    server = PetHTTPServer((HOST, PORT), controller)
    thread = threading.Thread(target=server.serve_forever, name="suisen-pet-http", daemon=True)
    thread.start()
    return server


def main() -> int:
    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)

    controller = PetController()
    window = PetWindow(controller)
    controller.attach_window(window)
    app.pet_controller = controller  # type: ignore[attr-defined]
    app.pet_window = window  # type: ignore[attr-defined]
    controller.start_input_listeners()
    controller.start_idle_timer()

    try:
        server = _start_http_server(controller)
    except OSError as exc:
        print(f"Could not start pet.py on {HOST}:{PORT}. Is port 8765 already in use? {exc}", flush=True)
        return 1

    app.aboutToQuit.connect(server.shutdown)
    print(f"suisen pet is running on http://{HOST}:{PORT}", flush=True)
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
