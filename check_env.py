import sys
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent
IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp", ".bmp", ".gif"}
AUDIO_EXTENSIONS = {".ogg", ".wav", ".mp3", ".flac"}

results = []


def supported_files(candidates: list[Path], extensions: set[str]) -> list[Path]:
    for directory in candidates:
        if not directory.is_dir():
            continue
        files = sorted(
            path
            for path in directory.iterdir()
            if path.is_file() and path.suffix.lower() in extensions
        )
        if files:
            return files
    return []

# Python version
py_ver = sys.version
results.append(("Python version", py_ver, "3.12" in py_ver))

libs = [
    ("PySide6", "PySide6"),
    ("pygame", "pygame"),
    ("pynput", "pynput"),
    ("win32gui", "win32gui"),
    ("PIL", "PIL"),
    ("screeninfo", "screeninfo"),
    ("requests", "requests"),
]

for display_name, import_name in libs:
    try:
        __import__(import_name)
        results.append((f"import {display_name}", "OK", True))
    except ImportError as e:
        results.append((f"import {display_name}", f"FAIL: {e}", False))

image_files = supported_files(
    [PROJECT_DIR / "suisen_picture"],
    IMAGE_EXTENSIONS,
)
results.append(("images", f"{len(image_files)} supported files", len(image_files) > 0))

voice_files = supported_files(
    [PROJECT_DIR / "suisen_voice"],
    AUDIO_EXTENSIONS,
)
results.append(("ask voices", f"{len(voice_files)} supported files", len(voice_files) > 0))

# finish_voice
finish_dir = PROJECT_DIR / "finish_voice"
finish_files = supported_files([finish_dir], AUDIO_EXTENSIONS)
results.append(("finish voices", f"{len(finish_files)} supported files", len(finish_files) > 0))

# Print
print("=" * 50)
print("Environment Check Report")
print("=" * 50)
all_ok = True
for name, detail, ok in results:
    status = "PASS" if ok else "FAIL"
    if not ok:
        all_ok = False
    print(f"[{status}] {name}: {detail}")

print("=" * 50)
if all_ok:
    print("All checks passed.")
else:
    print("Some checks failed. See above.")
