#!/usr/bin/env python3
"""Derive reproducible edge cases from the pinned, attributed FLEURS subset."""
import hashlib
import json
from pathlib import Path
import struct
import wave

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "target/fixtures/fleurs/manifest.json"
DEST = ROOT / "target/fixtures/edges"


def read_audio(path):
    data = Path(path).read_bytes()
    assert data[:4] == b"RIFF" and data[8:12] == b"WAVE"
    chunks, offset = {}, 12
    while offset + 8 <= len(data):
        tag, size = struct.unpack_from("<4sI", data, offset)
        chunks[tag] = data[offset + 8:offset + 8 + size]
        offset += 8 + size + size % 2
    kind, channels, rate, _, _, bits = struct.unpack_from("<HHIIHH", chunks[b"fmt "])
    assert channels == 1 and rate == 16000
    payload = chunks[b"data"]
    if kind == 3 and bits == 32:
        return list(struct.unpack(f"<{len(payload)//4}f", payload))
    if kind == 1 and bits == 16:
        return [x / 32768 for x in struct.unpack(f"<{len(payload)//2}h", payload)]
    raise ValueError("Unsupported fixture WAV encoding")


def main():
    manifest = json.loads(BASE.read_text())
    DEST.mkdir(parents=True, exist_ok=True)
    result = []
    def write(name, language, samples, reference, sources, purpose):
        path = DEST / f"{name}.wav"
        with wave.open(str(path), "wb") as wav:
            wav.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            wav.writeframes(struct.pack(f"<{len(samples)}h", *[max(-32768, min(32767, round(v * 32767))) for v in samples]))
        result.append(dict(id=name, language=language, path=str(path), reference=reference,
                           sha256=hashlib.sha256(path.read_bytes()).hexdigest(), sources=sources, purpose=purpose))
    write("silence", "silence", [0.] * 32000, "", [], "No recognized text")
    speech = {}
    for lang in ("en_us", "sv_se"):
        candidates = [s for s in manifest["samples"] if s["language"] == lang]
        shortest = min(candidates, key=lambda s: (len(read_audio(s["path"])), s["id"]))
        audio = read_audio(shortest["path"])
        speech[lang] = (audio, shortest)
        write(f"short-{lang}", lang, audio, shortest["reference"], [shortest["id"]], "Shortest complete utterance in the acceptance subset")
        write(f"pauses-{lang}", lang, [0.] * 16000 + audio + [0.] * 24000 + audio + [0.] * 8000,
              shortest["reference"] + " " + shortest["reference"], [shortest["id"]], "Leading, internal, and trailing silence")
        # A one-sample remainder exercises final partial model chunks for any normal metadata chunk size.
        write(f"boundary-{lang}", lang, audio + [0.] * ((8960 - len(audio) % 8960) % 8960 + 1),
              shortest["reference"], [shortest["id"]], "Legacy 8960-sample boundary plus one; runtime still uses model metadata")
    en, es = speech["en_us"]
    sv, ss = speech["sv_se"]
    write("meeting-alternating", "mixed", en + [0.] * 8000 + [v * .5 for v in sv],
          es["reference"] + " " + ss["reference"], [es["id"], ss["id"]], "English mic then attenuated Swedish system audio; automatic language detection")
    write("meeting-overlap", "mixed", [((en[i] if i < len(en) else 0) + (sv[i] * .5 if i < len(sv) else 0)) * .5 for i in range(max(len(en), len(sv)))],
          es["reference"] + " " + ss["reference"], [es["id"], ss["id"]], "Simultaneous sources: diagnostic only; no single-speaker WER gate")
    (DEST / "manifest.json").write_text(json.dumps(dict(dataset=manifest["dataset"], revision=manifest["revision"], license=manifest["license"], transformation="Deterministic concatenation, silence, scaling, and PCM16 conversion", samples=result), indent=2))
    print(f"Wrote {len(result)} edge fixtures")

if __name__ == "__main__":
    main()
