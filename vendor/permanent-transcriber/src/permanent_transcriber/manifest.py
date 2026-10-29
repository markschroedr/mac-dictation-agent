from __future__ import annotations

import json
import os
from collections.abc import Iterator
from pathlib import Path
from typing import Any


def append_jsonl(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, ensure_ascii=True))
        handle.write("\n")


def iter_jsonl(path: Path) -> Iterator[dict[str, Any]]:
    if not path.exists():
        return
    with path.open("rb") as handle:
        for line in handle:
            # Writers can still be appending the last record.
            if not line.endswith(b"\n"):
                break
            if line.strip():
                yield json.loads(line)


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    return list(iter_jsonl(path))


def read_jsonl_from_offset(
    path: Path, offset: int, *, max_rows: int
) -> tuple[list[dict[str, Any]], list[int]]:
    if offset < 0:
        raise RuntimeError("negative manifest offset")
    if not path.exists():
        if offset:
            raise RuntimeError("manifest disappeared after checkpoint")
        return [], []
    rows: list[dict[str, Any]] = []
    offsets: list[int] = []
    with path.open("rb") as handle:
        if offset > os.fstat(handle.fileno()).st_size:
            raise RuntimeError("manifest is shorter than its checkpoint")
        if offset:
            handle.seek(offset - 1)
            if handle.read(1) != b"\n":
                raise RuntimeError("manifest checkpoint is not a record boundary")
        handle.seek(offset)
        while len(rows) < max_rows:
            line = handle.readline()
            if not line or not line.endswith(b"\n"):
                break
            if line.strip():
                rows.append(json.loads(line))
                offsets.append(handle.tell())
    return rows, offsets


def jsonl_position(path: Path, line_count: int | None = None) -> tuple[int, int]:
    """Find a legacy row cursor, or the complete-record EOF, without decoding history."""
    if line_count is not None and line_count < 0:
        raise RuntimeError("negative manifest row cursor")
    if not path.exists():
        return 0, 0
    count = 0
    with path.open("rb") as handle:
        while line_count is None or count < line_count:
            offset = handle.tell()
            line = handle.readline()
            if not line or not line.endswith(b"\n"):
                return offset, count
            if line.strip():
                count += 1
        return handle.tell(), count


def load_json(path: Path, default: dict[str, Any] | None = None) -> dict[str, Any]:
    if default is None:
        default = {}
    if not path.exists():
        return dict(default)
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return dict(default)


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    tmp_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    tmp_path.replace(path)


def append_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(text)
