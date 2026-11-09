# Reviewer latency pilot — November 9, 2026

A bounded replay of two archived Element Web snapshots compared the then-default Gemini medium reviewer, Gemini low and Sol medium. Every model received byte-identical contract/code evidence within each case, with tools, MCP, extensions, skills, context discovery and persistent sessions disabled. Model order rotated between cases. One request per model/case was run; there were no timeouts or failed requests.

| Variant | Known-defect snapshot | Fixed control | Median request wall time | Confirmed defect found | Findings on fixed control |
| --- | ---: | ---: | ---: | --- | ---: |
| Gemini medium | 28.163s | 14.537s | 21.350s | 1/1 | 0 |
| Gemini low | 11.483s | 16.141s | 13.812s | 1/1 | 0 |
| Sol medium | 11.733s | 9.279s | 10.506s | 1/1 | 0 |

These times include CLI startup and provider execution. They are a small pilot, not a feature-workflow speedup estimate. Requests used different tokenizers and provider caches: both Sol requests reported 3,968 cached input tokens, while Gemini reported none. Provider dollar costs were zero, so no spending conclusion follows.

| Variant | Recorded uncached input | Cached input | Output | Reasoning reported |
| --- | ---: | ---: | ---: | ---: |
| Gemini medium | 16,116 | 0 | 2,368 | 1,894 |
| Gemini low | 16,116 | 0 | 442 | 0 |
| Sol medium | 12,712 | 7,936 | 370 | 126 |

## Adjudication

The pre-fix source tree is `50cca4668d377578b25f2456f38347dd93d7f653` in the maintained Element Web repository. Its `MediaEventHelper.isEligible` accepts gallery MatrixEvents, while its content getter returns the gallery wrapper rather than an item's media content. Existing callers construct a helper from the event, so source/filename/encryption metadata cannot resolve correctly. This was a confirmed Important issue in the original workflow's T1 findings.

All three variants identified this same content-unwrapping defect with the relevant getter, eligibility check and callers. Neither Gemini response was a distinct additional finding. Both labeled it Critical; adjudication normalizes it to Important, consistent with the original parent review. Sol labeled it Important.

The fixed snapshot is commit `5f3adc12c5090940ca02569d0d52d19ef5d7a851`, which resolves the event through `galleryItemToMediaContent(content.itemtypes[0])`. Every variant returned an empty findings array on that snapshot. This establishes the expected distinction for this packet, not the absence of defects elsewhere in the feature.

The runner's provisional keyword matcher did not reliably recognize the issue because the original expectation included “throw” while the reports described broken resolution without that exact word. Manual code-based adjudication overrides that provisional match. The matcher never selects a reviewer or declares unmatched findings false positives.

## Decision

The pilot retained Gemini medium at the time. The user subsequently selected Gemini high as the reviewer default, and future benchmark runs include that baseline. High reasoning was not measured in this pilot. The faster variants are promising for a broader experiment, but one defect and its repaired control do not establish equivalent finding quality. Add unrelated, adjudicated examples from SDK/API compatibility, Android dependency injection, lifecycle/cancellation and clean changes, with repeated requests, before changing the workflow default.

The implementation provides the reusable harness, immutable corpus manifest, usage/timing records and explicit adjudication boundary. It does not automatically run this experiment during feature work.

## Reproduction

```sh
e2e-review-benchmark \
  --repository element-web=/home/sinkerine/dev/element-web \
  --output /tmp/reviewer-comparison-fresh --repeats 1 --timeout 300
```

The manifest is [review-cases.json](/nixfiles/home/modules/programs/pi-coding-agent-skills/e2e-feature/benchmarks/review-cases.json), and the runner is [benchmark.py](/nixfiles/home/modules/programs/pi-coding-agent-skills/e2e-feature/scripts/benchmark.py).

This run's raw source packets, events and reports remain at [/tmp/e2e-review-benchmark-latency-20261109](/tmp/e2e-review-benchmark-latency-20261109). The benchmark summary retains the original model responses and provisional scores; [adjudication.json](/tmp/e2e-review-benchmark-latency-20261109/adjudication.json) records the final assessment separately.
