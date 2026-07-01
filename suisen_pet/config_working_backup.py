from __future__ import annotations

from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]

IMAGE_DIR = PROJECT_ROOT / "suisen_picture"
ASK_VOICE_DIR = PROJECT_ROOT / "suisen_voice"
FINISH_VOICE_DIR = PROJECT_ROOT / "finish_voice"
SUPPORTED_IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp", ".bmp", ".gif"}
SUPPORTED_AUDIO_EXTENSIONS = {".ogg", ".wav", ".mp3", ".flac"}

HOST = "127.0.0.1"
PORT = 8765
BASE_URL = f"http://{HOST}:{PORT}"

IMAGE_CROP_RATIO = 0.45
EDGE_VISIBLE_RATIO = 0.70
TOP_BOTTOM_VISIBLE_RATIO = 0.70
LEFT_RIGHT_VISIBLE_RATIO = 0.70
TOP_BOTTOM_SCALE = 0.40
LEFT_RIGHT_SCALE = 0.40
MAX_SCREEN_FILL_RATIO = 0.88
SCREEN_SAFE_MARGIN = 16

INPUT_GRACE_MS = 800
ANIMATION_MS = 420
TEST_DISPLAY_MS = 3000

# Disabled by default while debugging image visibility. Re-enable after the window path is verified.
ENABLE_MOUSE_PASSTHROUGH = False
