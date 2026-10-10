#!/usr/bin/env python3
"""Measure single-request Qwen decode and total HTTP throughput on Strata's API."""

import argparse
import json
import time
import urllib.request
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8081")
    parser.add_argument("--model", default="huihui-qwen3.5-9b-abliterated-q5_k_m")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--long-context", action="store_true", help="Include a 130K-token prompt and retrieval check")
    args = parser.parse_args()

    def post(path, payload):
        req = urllib.request.Request(
            args.url.rstrip("/") + path,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json", "Authorization": "Bearer lan-only"},
        )
        with urllib.request.urlopen(req, timeout=600) as response:
            return json.load(response)

    def reference_prompt(target):
        # Count the real model's rendered chat template, including role tokens.
        def build(repeats):
            text = "Reference: memory caching improves repeated data access.\n"
            return ("Checkpoint alpha code is 731946.\n" + text * (repeats // 2)
                    + "Checkpoint beta code is 582173.\n" + text * (repeats - repeats // 2)
                    + "\nFirst report both checkpoint codes exactly. Then explain memory caching "
                    "in at least 1000 words, with examples and engineering tradeoffs.")

        def count(prompt):
            rendered = post("/apply-template", {"messages": [{"role": "user", "content": prompt}]})
            return len(post("/tokenize", {"content": rendered["prompt"], "add_special": True})["tokens"])

        low, high = 0, target
        while low < high:
            mid = (low + high + 1) // 2
            if count(build(mid)) <= target:
                low = mid
            else:
                high = mid - 1
        prompt = build(low)
        print(json.dumps({"prepared_target": target, "prepared_tokens": count(prompt)}), flush=True)
        return prompt

    prompts = [
        "Explain how Linux virtual memory, page faults, page cache and swap work. "
        "Give a detailed tutorial of at least 1000 words with practical examples.",
        "Write a complete Python implementation of a bounded LRU cache with TTL, "
        "thread safety, usage examples and a detailed explanation of design decisions.",
        "Describe the history, science and practical engineering of solar power in "
        "at least 1000 words, discussing storage, grid stability and efficiency.",
    ]
    results = []
    # Run a small warmup before timed requests.
    post("/v1/chat/completions", {
        "model": args.model, "messages": [{"role": "user", "content": "What is 2+2?"}],
        "max_tokens": 16, "temperature": 0, "cache_prompt": False,
    })
    cases = [("short", p) for p in prompts]
    cases.extend((label, reference_prompt(target)) for label, target in [("4k", 4096), ("28k", 28000)])
    if args.long_context:
        cases.append(("130k", reference_prompt(130000)))
    for label, prompt in cases:
        started = time.monotonic()
        response = post("/v1/chat/completions", {
            "model": args.model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": 512, "temperature": 0, "cache_prompt": False,
        })
        elapsed = time.monotonic() - started
        usage = response["usage"]
        timings = response["timings"]
        text = response["choices"][0]["message"].get("content", "")
        row = {
            "case": label, "model": response["model"],
            "prompt_tokens": usage["prompt_tokens"],
            "completion_tokens": usage["completion_tokens"],
            "decode_tps": timings["predicted_per_second"],
            "prefill_tps": timings["prompt_per_second"],
            "http_seconds": elapsed,
            "http_tps": usage["completion_tokens"] / elapsed,
            "finish_reason": response["choices"][0]["finish_reason"],
            "sample": text[:180],
        }
        if label != "short":
            row["retrieved_both_codes"] = "731946" in text and "582173" in text
        results.append(row)
        print(json.dumps(row), flush=True)
    if args.output:
        args.output.write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
