"""Experimental source attribution using timestamp-bounded fuzzy text alignment."""
from __future__ import annotations

import argparse
import json
import re
import unicodedata
from difflib import SequenceMatcher
from itertools import groupby
from pathlib import Path

from .asr_backends import create_backend
from .config import default_paths


def words(text: str) -> list[tuple[str, int, int]]:
    return [(unicodedata.normalize('NFKD', m.group()).encode('ascii', 'ignore').decode().lower(),
             m.start(), m.end()) for m in re.finditer(r"\w+(?:['’]\w+)?", text)]


def reconcile(turns: list[dict]) -> tuple[list[dict], list[dict]]:
    remote = [t for t in turns if t['speaker'] == 'Remote']
    output = list(remote)
    decisions = []
    for mic in (t for t in turns if t['speaker'] == 'Microphone'):
        tokens = words(mic['text'])
        candidates = [r for r in remote if r['start'] <= mic['end'] + 2 and r['end'] >= mic['start'] - 2]
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


def transcribe(session: Path, *, force: bool = False) -> None:
    paths = default_paths()
    output = paths.transcripts_root / 'participants' / (session.name + '.txt')
    if output.exists() and not force:
        return
    backend = create_backend(paths=paths)
    mm = json.loads((session / 'microphone/capture.json').read_text())
    sm = json.loads((session / 'system/capture.json').read_text())
    offset = float(sm['first_received_monotonic']) - float(mm['first_received_monotonic'])
    turns = []
    for source, label, origin in [('microphone', 'Microphone', 0.0), ('system', 'Remote', offset)]:
        files = sorted((session / source).glob('*.opus'))
        if not files:
            raise RuntimeError(f'No {source} audio in {session}')
        elapsed = origin
        for index, audio in enumerate(files):
            cache = session / source / f'{index:06d}-asr.json'
            if cache.exists():
                result = json.loads(cache.read_text())
            else:
                result = backend.transcribe_files([audio])
                temp = cache.with_suffix('.tmp')
                temp.write_text(json.dumps(result, ensure_ascii=False))
                temp.replace(cache)
            segments = result.get('segments', [])
            if not segments and str(result.get('text', '')).strip():
                raise RuntimeError('ASR returned text without timestamps')
            for seg in segments:
                text = str(seg.get('text', '')).strip()
                if text:
                    turns.append({'speaker': label, 'start': max(0, elapsed + float(seg['start'])),
                                  'end': max(0, elapsed + float(seg['end'])), 'text': text})
            # SourceTracks uses fixed 60-second Opus segments. Opus container
            # duration includes encoder padding; do not accumulate that as drift.
            elapsed = origin + (index + 1) * 60
    turns, decisions = reconcile(turns)
    output.parent.mkdir(parents=True, exist_ok=True)
    content = 'EXPERIMENTAL — Microphone = local input; Remote = system input.\nTimestamp-bounded fuzzy text deduplication; no echo cancellation or additional language model.\nRemote may contain multiple people. Uncertain mixed passages are marked.\n\n'
    for turn in turns:
        sec = int(turn['start'])
        content += f"[{sec//3600:02d}:{sec//60%60:02d}:{sec%60:02d}] {turn['speaker']}: {turn['text']}\n"
    temporary = output.with_suffix('.tmp')
    temporary.write_text(content)
    temporary.replace(output)
    (session / 'participants.json').write_text(json.dumps({
        'output': str(output), 'method': 'timed-fuzzy-text-v1', 'turn_count': len(turns),
        'microphone_decisions': decisions,
    }, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('session', type=Path)
    parser.add_argument('--force', action='store_true')
    args = parser.parse_args()
    try:
        transcribe(args.session, force=args.force)
    except Exception as exc:
        (args.session / 'participants-error.txt').write_text(str(exc) + '\n')
        raise
