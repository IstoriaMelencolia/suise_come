from __future__ import annotations

import argparse
import sys
from typing import Any

import requests

from config import BASE_URL


TIMEOUT_SECONDS = 1.5


def main() -> int:
    parser = argparse.ArgumentParser(description="Manual CLI for the suisen desktop pet.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    show_parser = subparsers.add_parser("show", help="Show the pet with a voice line.")
    show_parser.add_argument("kind", choices=("ask", "finish", "test"), help="Voice group or test mode to use.")
    show_parser.add_argument(
        "edge",
        nargs="?",
        choices=("top", "bottom", "left", "right"),
        help="Optional edge for ask/finish. Omit it to choose a random edge.",
    )

    subparsers.add_parser("hide", help="Hide the pet.")
    subparsers.add_parser("status", help="Check whether pet.py is running.")
    subparsers.add_parser("shutdown", help="Ask pet.py to exit.")

    args = parser.parse_args()

    if args.command == "status":
        response = _request("GET", "/status")
        if response is None:
            return 1
        _print_status(response)
        return 0

    if args.command == "show":
        if args.kind == "test" and args.edge is not None:
            print("show test does not accept an edge.")
            return 2
        path = f"/show/{args.kind}"
        if args.edge is not None:
            path = f"{path}/{args.edge}"
        response = _request("POST", path)
        if response is None:
            return 1
        print(response.get("message", f"show {args.kind} requested."))
        return 0 if response.get("ok", True) else 1

    if args.command == "hide":
        response = _request("POST", "/hide")
        if response is None:
            return 1
        print(response.get("message", "hide requested."))
        return 0 if response.get("ok", True) else 1

    if args.command == "shutdown":
        response = _request("POST", "/shutdown")
        if response is None:
            return 1
        print(response.get("message", "shutdown requested."))
        return 0 if response.get("ok", True) else 1

    parser.print_help()
    return 2


def _request(method: str, path: str) -> dict[str, Any] | None:
    url = f"{BASE_URL}{path}"
    try:
        response = requests.request(method, url, timeout=TIMEOUT_SECONDS)
    except requests.exceptions.ConnectionError:
        print("pet.py is not running. Please start it first.")
        return None
    except requests.exceptions.Timeout:
        print("pet.py did not respond in time. Please check whether it is busy.")
        return None
    except requests.exceptions.RequestException as exc:
        print(f"Could not contact pet.py: {exc}")
        return None

    try:
        payload = response.json()
    except ValueError:
        payload = {"ok": False, "message": response.text.strip() or "pet.py returned a non-JSON response."}

    if response.status_code >= 400:
        print(payload.get("message", f"pet.py returned HTTP {response.status_code}."))
        return {"ok": False, **payload}

    return payload


def _print_status(payload: dict[str, Any]) -> None:
    print("pet.py is running.")
    print(f"visible: {payload.get('visible')}")
    print(f"animating: {payload.get('animating')}")
    print(f"edge: {payload.get('edge')}")
    print(f"last_mode: {payload.get('last_mode')}")
    print(f"input_enabled: {payload.get('input_enabled')}")
    print(f"ask_voice_count: {payload.get('ask_voice_count')}")
    print(f"finish_voice_count: {payload.get('finish_voice_count')}")
    print(f"idle_seconds: {payload.get('idle_seconds')}")
    print(f"auto_exit_idle_seconds: {payload.get('auto_exit_idle_seconds')}")

    audio_error = payload.get("audio_error")
    if audio_error:
        print(f"audio_error: {audio_error}")

    listeners_error = payload.get("listeners_error")
    if listeners_error:
        print(f"listeners_error: {listeners_error}")


if __name__ == "__main__":
    raise SystemExit(main())
