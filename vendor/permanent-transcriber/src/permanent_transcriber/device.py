from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import sounddevice as sd

from .config import AppPaths


def config_path(paths: AppPaths) -> Path:
    return paths.state_root / "config.json"


def load_app_config(paths: AppPaths) -> dict[str, Any]:
    path = config_path(paths)
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}


def save_app_config(paths: AppPaths, payload: dict[str, Any]) -> None:
    path = config_path(paths)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def list_input_devices() -> list[dict[str, Any]]:
    devices = sd.query_devices()
    default_input, _default_output = sd.default.device
    rows: list[dict[str, Any]] = []
    for index, device in enumerate(devices):
        if device["max_input_channels"] <= 0:
            continue
        rows.append(
            {
                "index": index,
                "name": device["name"],
                "default_samplerate": device["default_samplerate"],
                "max_input_channels": device["max_input_channels"],
                "is_default_input": index == default_input,
            }
        )
    return rows


def resolve_input_device(paths: AppPaths, requested: str | None = None) -> tuple[int | str, dict[str, Any]]:
    devices = list_input_devices()
    if not devices:
        raise RuntimeError("no input devices available")

    if requested is not None:
        resolved, row = _resolve_explicit_device(requested, devices)
        return resolved, {"strategy": "explicit", "device": row}

    app_config = load_app_config(paths)
    preferred = app_config.get("preferred_input_device")
    if preferred is not None:
        try:
            resolved, row = _resolve_explicit_device(str(preferred), devices)
            return resolved, {"strategy": "preferred", "device": row}
        except RuntimeError:
            pass

    default_row = next((row for row in devices if row["is_default_input"]), None)
    if default_row is not None:
        return default_row["index"], {"strategy": "system_default", "device": default_row}

    if len(devices) == 1:
        return devices[0]["index"], {"strategy": "sole_input", "device": devices[0]}

    ranked = sorted(
        devices,
        key=lambda row: (
            row["max_input_channels"],
            row["default_samplerate"],
            -row["index"],
        ),
        reverse=True,
    )
    return ranked[0]["index"], {"strategy": "fallback_best_input", "device": ranked[0]}


def set_preferred_input_device(paths: AppPaths, requested: str) -> dict[str, Any]:
    resolved, details = resolve_input_device(paths, requested=requested)
    app_config = load_app_config(paths)
    app_config["preferred_input_device"] = str(resolved)
    save_app_config(paths, app_config)
    return details


def clear_preferred_input_device(paths: AppPaths) -> None:
    app_config = load_app_config(paths)
    if "preferred_input_device" in app_config:
        del app_config["preferred_input_device"]
        save_app_config(paths, app_config)


def _resolve_explicit_device(requested: str, devices: list[dict[str, Any]]) -> tuple[int | str, dict[str, Any]]:
    if requested.isdigit():
        index = int(requested)
        row = next((row for row in devices if row["index"] == index), None)
        if row is None:
            raise RuntimeError(f"input device index not found: {requested}")
        return index, row

    lowered = requested.casefold()
    exact = next((row for row in devices if row["name"].casefold() == lowered), None)
    if exact is not None:
        return exact["index"], exact

    partial_matches = [row for row in devices if lowered in row["name"].casefold()]
    if len(partial_matches) == 1:
        row = partial_matches[0]
        return row["index"], row
    if len(partial_matches) > 1:
        names = ", ".join(str(row["index"]) + ":" + row["name"] for row in partial_matches)
        raise RuntimeError(f"device name is ambiguous: {requested} -> {names}")

    raise RuntimeError(f"input device not found: {requested}")
