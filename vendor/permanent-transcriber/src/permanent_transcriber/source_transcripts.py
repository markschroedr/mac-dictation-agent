"""Incremental source transcripts owned by the permanent worker."""
from __future__ import annotations

import csv
import logging
import json
import re
import time
import unicodedata
from difflib import SequenceMatcher
from itertools import groupby
from pathlib import Path
from typing import Callable

from .asr_backends import AsrBackend
from .config import AppPaths
from .manifest import load_json, write_json


def words(text: str) -> list[tuple[str, int, int]]:
    return [(unicodedata.normalize('NFKD', m.group()).encode('ascii', 'ignore').decode().lower(),
             m.start(), m.end()) for m in re.finditer(r"\w+(?:['’]\w+)?", text)]


def reconcile(turns: list[dict]) -> tuple[list[dict], list[dict]]:
    remote = sorted((t for t in turns if t['speaker'] == 'Remote'), key=lambda t: t['start'])
    output = list(remote)
    decisions = []
    active = []
    next_remote = 0
    for mic in sorted((t for t in turns if t['speaker'] == 'Microphone'), key=lambda t: t['start']):
        tokens = words(mic['text'])
        while next_remote < len(remote) and remote[next_remote]['start'] <= mic['end'] + 2:
            active.append(remote[next_remote])
            next_remote += 1
        active = [r for r in active if r['end'] >= mic['start'] - 2]
        candidates = [r for r in active if r['start'] <= mic['end'] + 2]
        reference = [w[0] for r in candidates for w in words(r['text'])]
        matched = set()
        alignment = SequenceMatcher(None, [w[0] for w in tokens], reference, autojunk=False)
        for tag, a, b, c, d in alignment.get_opcodes():
            if tag == 'equal':
                matched.update(range(a, b))
            elif tag == 'replace' and b - a == d - c:
                # Recognize minor spelling/ASR differences without semantic guesses.
                for i, j in zip(range(a, b), range(c, d)):
                    if SequenceMatcher(None, tokens[i][0], reference[j]).ratio() >= 0.72:
                        matched.add(i)
        coverage = len(matched) / max(1, len(tokens))
        # ASR can split one word into several ("wahrscheinlich" / "was man sich").
        # Compare whole normalized phrases as well as word alignment.
        phrase = ' '.join(w[0] for w in tokens)
        phrase_duplicate = False
        for r in candidates:
            candidate_words = [w[0] for w in words(r['text'])]
            for size in range(max(1, len(tokens) - 3), min(len(candidate_words), len(tokens) + 3) + 1):
                for start in range(len(candidate_words) - size + 1):
                    if SequenceMatcher(None, phrase, ' '.join(candidate_words[start:start + size])).ratio() >= 0.82:
                        phrase_duplicate = True
                        break
                if phrase_duplicate:
                    break
            if phrase_duplicate:
                break
        # A brief acknowledgment may be a separate local reply. Only suppress
        # it when the complete text AND onset nearly coincide with remote audio.
        short_duplicate = len(tokens) <= 3 and any(
            abs(r['start'] - mic['start']) <= 0.35
            and [w for w, _ in groupby(t[0] for t in words(r['text']))] == [w for w, _ in groupby(t[0] for t in tokens)]
            for r in candidates
        )
        action = 'keep'
        retained = [mic]
        if short_duplicate:
            action, retained = 'duplicate', []
        elif len(tokens) > 3 and (coverage >= 0.68 or phrase_duplicate):
            # Preserve substantial unmatched spans in mixed local/echo segments.
            runs = []
            start = None
            for i in range(len(tokens) + 1):
                if i < len(tokens) and i not in matched:
                    if start is None:
                        start = i
                elif start is not None:
                    runs.append((start, i))
                    start = None
            local_runs = [(a, b) for a, b in runs if b - a >= 3 and not phrase_duplicate]
            if local_runs:
                action = 'partial'
                retained = []
                for a, b in local_runs:
                    text = mic['text'][tokens[a][1]:tokens[b-1][2]]
                    retained.append({**mic, 'text': text, 'speaker': 'Microphone (uncertain)'})
            else:
                action, retained = 'duplicate', []
        output.extend(retained)
        decisions.append({'start': mic['start'], 'end': mic['end'], 'action': action,
                          'matched_fraction': round(coverage, 3),
                          'retained_text': [t['text'] for t in retained]})
    return sorted(output, key=lambda t: t['start']), decisions


def completed_chunks(folder: Path) -> list[tuple[str, float, float]]:
    listing = folder / 'chunks.csv'
    if not listing.exists():
        return []
    # ffmpeg flushes a CSV line only after closing that Opus file. Never glob
    # audio files: the newest one can still be open. Ignore a partial CSV line.
    text = listing.read_text()
    text = text[:text.rfind('\n') + 1]
    return [(name, float(start), float(end)) for name, start, end in csv.reader(text.splitlines())]


def source_sessions(paths: AppPaths) -> list[Path]:
    root = paths.root / 'storage' / 'source_tracks'
    if not root.exists():
        return []
    # Old completed recordings remain readable. They have no live chunk lists
    # and must not become a new ASR backlog just because this worker starts.
    return sorted(session for session in root.iterdir() if (session / 'session.json').exists())


def processing_status(paths: AppPaths) -> tuple[bool, str | None]:
    pending = False
    latest_error = None
    for session in source_sessions(paths):
        error = session / 'participants-error.txt'
        capture_error = session / 'capture-error.txt'
        latest_error = (capture_error.read_text() if capture_error.exists()
                        else error.read_text() if error.exists() else None)
        if not (session / 'transcribed').exists() and not error.exists() and not capture_error.exists():
            pending = True
    return pending, latest_error


def process_sessions(paths: AppPaths, backend: Callable[[], AsrBackend], failed: set[Path]) -> int:
    processed = 0
    for session in source_sessions(paths):
        if session in failed or (session / 'capture-error.txt').exists():
            continue
        if (session / 'transcribed').exists():
            continue
        try:
            processed += process_session(paths, session, backend)
        except Exception as exc:
            logging.getLogger(__name__).exception('source transcription failed: %s', session)
            (session / 'participants-error.txt').write_text(str(exc) + '\n')
            # Retry from the persisted caches on the next worker start, not in
            # an infinite shutdown loop. A bad session must not kill the worker.
            failed.add(session)
    return processed


def process_session(paths: AppPaths, session: Path, backend: Callable[[], AsrBackend]) -> int:
    # Read closed BEFORE the lists. If true, both encoder lists are final.
    # Reading it afterwards could finalize using a snapshot without the tail.
    closed = (session / 'closed.json').exists()
    sources = [('microphone', 'Microphone'), ('system', 'Remote')]
    chunks = {source: completed_chunks(session / source) for source, _ in sources}
    metadata = {source: load_json(session / source / 'capture.json') for source, _ in sources}
    if not metadata['microphone']:
        if closed:
            raise RuntimeError('Microphone never produced audio')
        return 0
    # A healthy system helper can have no audio to deliver. Capture records
    # helper failures separately; absent system PCM is not a failed recording.
    origin = min(float(meta['first_received_monotonic']) for meta in metadata.values() if meta)
    turns = []
    ends = []
    processed = 0
    cached = 0
    info = load_json(session / 'participants.json')
    asr_seconds = float(info.get('asr_seconds', 0))
    for source, label in sources:
        if not metadata[source]:
            # No system samples arrived before the microphone coverage. If
            # system audio starts later, its own first-received clock supplies
            # that later origin instead of moving previously published speech.
            ends.append(ends[0])
            continue
        offset = float(metadata[source]['first_received_monotonic']) - origin
        covered = 0.0
        source_turns = []
        for name, start, end in chunks[source]:
            audio = session / source / name
            cache = audio.with_name(audio.stem + '-asr.json')
            if not cache.exists():
                began = time.monotonic()
                result = backend().transcribe_files([audio])
                asr_seconds += time.monotonic() - began
                if not result.get('segments') and str(result.get('text', '')).strip():
                    raise RuntimeError('ASR returned text without timestamps')
                write_json(cache, result)
                processed += 1
                new_chunk = True
            else:
                result = json.loads(cache.read_text())
                new_chunk = False
            cached += 1
            covered = end
            for seg in result.get('segments', []):
                text = str(seg.get('text', '')).strip()
                if not text:
                    continue
                turn = {'speaker': label, 'start': offset + start + float(seg['start']),
                        'end': offset + start + float(seg['end']), 'text': text, 'chunk': name}
                # Rejoin phrases split by an encoder boundary, not unrelated
                # short acknowledgments elsewhere in the conversation.
                if (source_turns and source_turns[-1]['chunk'] != name
                        and 0 <= turn['start'] - source_turns[-1]['end'] < 0.5):
                    previous = source_turns[-1]
                    previous.update(end=turn['end'], text=previous['text'] + ' ' + text, chunk=name)
                else:
                    source_turns.append(turn)
            # One new chunk per source per pass keeps the two sides advancing
            # together. Further chunks are drained on the next worker pass.
            if new_chunk:
                break
        ends.append(offset + covered)
        turns.extend(source_turns)
    complete = closed and cached == sum(len(rows) for rows in chunks.values())
    if not processed and info.get('cached_chunks') == cached and info.get('complete') == complete:
        if complete:
            (session / 'transcribed').touch()
        return 0
    began = time.monotonic()
    turns, decisions = reconcile(turns)
    watermark = min(ends) - 2
    if not complete:
        turns = [turn for turn in turns if turn['end'] <= watermark]
    output = paths.transcripts_root / 'participants' / (session.name + '.txt')
    output.parent.mkdir(parents=True, exist_ok=True)
    lines = []
    for turn in turns:
        sec = max(0, int(turn['start']))
        lines.append(f"[{sec//3600:02d}:{sec//60%60:02d}:{sec%60:02d}] {turn['speaker']}: {turn['text']}\n")
    temporary = output.with_suffix('.tmp')
    temporary.write_text(''.join(lines))
    temporary.replace(output)
    write_json(session / 'participants.json', {
        'output': str(output), 'method': 'timed-fuzzy-text-v1', 'turn_count': len(turns),
        'microphone_decisions': decisions, 'complete': complete, 'cached_chunks': cached,
        'asr_seconds': round(asr_seconds, 3), 'matching_seconds': round(time.monotonic() - began, 3),
    })
    if complete:
        (session / 'transcribed').touch()
    (session / 'participants-error.txt').unlink(missing_ok=True)
    logging.getLogger(__name__).info('source transcript session=%s new_chunks=%s cached=%s complete=%s',
                                     session.name, processed, cached, complete)
    return processed
