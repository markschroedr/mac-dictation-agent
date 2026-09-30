"""Experimental source-based participant transcript after capture stops."""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from scipy import signal, linalg

from .asr_backends import create_backend
from .config import default_paths

RATE = 16000


def decode(path: Path) -> np.ndarray:
    pcm = subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(path),
        '-f', 'f32le', '-ar', str(RATE), '-ac', '1', 'pipe:1'])
    return np.frombuffer(pcm, dtype='<f4')


def remove_echo(mic: np.ndarray, remote: np.ndarray) -> tuple[np.ndarray, dict]:
    # Estimate acoustic delay from waveform correlation, not transcript wording.
    n = min(len(mic), len(remote))
    scores = []
    for start in range(0, n, RATE * 30):
        m, s = mic[start:start + RATE * 30:4], remote[start:start + RATE * 30:4]
        if len(m) < 4000 or np.linalg.norm(s) < 0.01:
            continue
        c = signal.correlate(m, s, mode='full', method='fft')
        lags = signal.correlation_lags(len(m), len(s))
        valid = np.abs(lags) <= 4000
        i = np.argmax(np.abs(c[valid]))
        score = abs(c[valid][i]) / (np.linalg.norm(m) * np.linalg.norm(s) + 1e-12)
        scores.append((float(score), int(lags[valid][i]) * 4))
    if not scores or max(scores)[0] < 0.08:
        return mic.copy(), {'echo_detected': False}
    score, lag = max(scores)
    aligned = np.zeros(len(mic), dtype=np.float32)
    if lag >= 0:
        count = min(len(remote), len(mic) - lag)
        aligned[lag:lag + count] = remote[:count]
    else:
        count = min(len(mic), len(remote) + lag)
        aligned[:count] = remote[-lag:-lag + count]
    clean = mic.copy()
    # Fit a short room-response filter per window. Uncorrelated local speech
    # remains; changing delays, nonlinear speakers and double-talk are limitations.
    taps = 256
    for start in range(0, len(mic), RATE * 30):
        s = aligned[start:start + RATE * 30].astype(np.float64)
        m = mic[start:start + len(s)].astype(np.float64)
        if len(s) <= taps or np.dot(s, s) < 1e-8:
            continue
        auto = signal.correlate(s, s, mode='full', method='fft')[len(s)-1:len(s)-1+taps]
        cross = signal.correlate(m, s, mode='full', method='fft')[len(s)-1:len(s)-1+taps]
        auto[0] += auto[0] * 0.01
        h = linalg.solve_toeplitz((auto, auto), cross)
        clean[start:start + len(s)] -= signal.lfilter(h, [1.0], s).astype(np.float32)
    # ASR can amplify tiny residual echo back into readable remote speech.
    # Suppress frames only when the fitted echo explains >95% of mic energy.
    # Double-talk with a very quiet local speaker can still be lost; experiment
    # explicitly includes loudspeaker calls to measure this limitation.
    for start in range(0, len(clean), 320):
        end = start + 320
        original_energy = float(np.dot(mic[start:end], mic[start:end]))
        residual_energy = float(np.dot(clean[start:end], clean[start:end]))
        if original_energy > 1e-10 and residual_energy < original_energy * 0.05:
            clean[start:end] = 0
    return clean, {'echo_detected': True, 'lag_seconds': lag / RATE, 'correlation': score}


def transcribe(session: Path) -> None:
    paths = default_paths()
    output = paths.transcripts_root / 'participants' / (session.name + '.txt')
    if output.exists():
        return
    microphones = sorted((session / 'microphone').glob('*.opus'))
    systems = sorted((session / 'system').glob('*.opus'))
    if not microphones or not systems:
        raise RuntimeError('Both source tracks are required')
    mm = json.loads((session / 'microphone/capture.json').read_text())
    sm = json.loads((session / 'system/capture.json').read_text())
    offset = float(sm['first_received_monotonic']) - float(mm['first_received_monotonic'])
    # Arrival timestamps provide an initial timeline; waveform matching estimates
    # loudspeaker delay independently. Neither establishes hardware-clock sync.
    backend = create_backend(paths=paths)
    turns = []
    diagnostics = []
    paths.tmp_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='participants-', dir=paths.tmp_root) as temp:
        for index in range(max(len(microphones), len(systems))):
            mic = decode(microphones[index]) if index < len(microphones) else np.zeros(0, dtype=np.float32)
            remote = decode(systems[index]) if index < len(systems) else np.zeros(0, dtype=np.float32)
            clean, detail = remove_echo(mic, remote)
            diagnostics.append(detail)
            for label, chunk, origin in [('Microphone', clean, 0.0), ('Remote', remote, offset)]:
                start = index * RATE * 60
                if not len(chunk) or np.max(np.abs(chunk), initial=0) < 1e-5:
                    continue
                wav = Path(temp) / 'input.wav'
                import wave
                with wave.open(str(wav), 'wb') as f:
                    f.setparams((1, 2, RATE, 0, 'NONE', 'not compressed'))
                    f.writeframes((np.clip(chunk, -1, 1) * 32767).astype('<i2').tobytes())
                result = backend.transcribe_files([wav])
                segments = result.get('segments', [])
                if not segments and str(result.get('text', '')).strip():
                    raise RuntimeError('ASR returned text without timestamps; cannot order participant turns')
                for seg in segments:
                    text = str(seg.get('text', '')).strip()
                    if text:
                        turns.append({'speaker': label, 'start': max(0, origin + start / RATE + float(seg['start'])), 'text': text})
    turns.sort(key=lambda t: t['start'])
    output.parent.mkdir(parents=True, exist_ok=True)
    content = 'EXPERIMENTAL — Microphone = local input; Remote = system input.\nRemote can contain multiple people; labels are sources, not identified people.\nLoudspeaker echo removal is approximate; duplicates or missing speech remain possible.\n\n'
    for turn in turns:
        sec = int(turn['start'])
        content += f"[{sec//3600:02d}:{sec//60%60:02d}:{sec%60:02d}] {turn['speaker']}: {turn['text']}\n"
    temporary = output.with_suffix('.tmp')
    temporary.write_text(content)
    temporary.replace(output)
    (session / 'participants.json').write_text(json.dumps({'output': str(output), 'echo': diagnostics, 'turn_count': len(turns)}, indent=2))


if __name__ == '__main__':
    session = Path(sys.argv[1])
    try:
        transcribe(session)
    except Exception as exc:
        (session / 'participants-error.txt').write_text(str(exc) + '\n')
        raise
