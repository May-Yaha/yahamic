#!/usr/bin/env python3
"""Character error rate of a Qwen3-ASR checkpoint on a training-set split (test.jsonl / dev.jsonl).

Run from inside the copied Training folder (audio paths in the JSONL are relative to it):
    python asr_cer.py Qwen/Qwen3-ASR-0.6B test.jsonl
    python asr_cer.py out/checkpoint-200 test.jsonl
Punctuation and spaces are ignored, letter case counts, the same as TrainingSet.normalized in the Mac app.
"""
import json
import sys
import unicodedata

import torch
from qwen_asr import Qwen3ASRModel


def normalized(text):
    return "".join(c for c in text if unicodedata.category(c)[0] not in "PSZ" and not c.isspace())


def distance(a, b):
    previous = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        current = [i]
        for j, y in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x != y)))
        previous = current
    return previous[-1]


def main(model_path, split):
    device = "cuda:0" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"
    model = Qwen3ASRModel.from_pretrained(model_path, dtype=torch.bfloat16 if device != "cpu" else torch.float32,
                                          device_map=device)
    rows = [json.loads(line) for line in open(split, encoding="utf-8") if line.strip()]
    errors = chars = 0
    for row in rows:
        reference = normalized(row["text"].split("<asr_text>", 1)[-1])
        hypothesis = normalized(model.transcribe(audio=row["audio"], language="Chinese")[0].text)
        errors += distance(hypothesis, reference)
        chars += len(reference)
    print(f"{model_path}: CER {errors / max(chars, 1):.2%} over {len(rows)} takes, {chars} chars")


if __name__ == "__main__":
    assert normalized("跑一下 swift test。") == normalized("跑一下swift test") and distance("abc", "abd") == 1
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(*sys.argv[1:])
