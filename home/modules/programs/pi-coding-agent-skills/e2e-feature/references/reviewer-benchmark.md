# Reviewer latency comparison

Run this only for an explicitly requested performance experiment. It is not a new stage in every feature workflow.

The Nix-installed `e2e-review-benchmark` replays immutable Git snapshots through the configured model variants with the same contract and code packet. It disables tools, MCP, extensions, skills, context-file discovery and persistent sessions. Ground-truth expectations are retained for evaluation and are never sent in the review prompt. It records per-request wall time, resolved model, token/cache/reasoning usage, raw events, text reports and provisional finding matches.

```sh
e2e-review-benchmark \
  --repository element-web=/home/sinkerine/dev/element-web \
  --output /tmp/reviewer-comparison-new \
  --repeats 1 --timeout 300
```

The bundled manifest has one archived gallery defect and its fixed control. It compares the Gemini high benchmark baseline with Gemini medium, Gemini low and Sol medium. Supply `--manifest <file>` for a broader corpus (up to eight cases, four variants and three repeats). Packet paths are read with `git show`; no checkout or product files are edited. The benchmark rotates model order between cases. Each process has a deadline, reports partial failures, and stops the experiment on a failed or malformed model result rather than switching providers as recovery.

A packet contains a contract and explicitly selected files/context. Missing context is a limitation to record, not permission to invent repository behavior. The benchmark caps packet size and keeps raw events outside the source tree. Existing model credentials are used without printing or copying them.

`summary.json` is deliberately marked `needs-adjudication` after successful requests. Its keyword matches are only candidates, and unmatched findings are not automatically false positives. Compare every finding with the immutable code and the original adjudicated issue, normalize severity, and save an `adjudication.json` beside the summary. Account for timeouts, cache hits and provider variability. No result changes the default reviewer automatically.

The initial pilot is documented in `/nixfiles/docs/e2e-review-benchmark.md`: all variants found the known issue and returned no findings on its fixed control, but two related cases are insufficient to establish broad finding quality. The user-selected feature-workflow default is Opus high; the initial pilot did not measure high reasoning. Before proposing a change, add independent task categories and repeats, including subtle integration failures and clean controls, and adjudicate confirmed Critical/Important findings, false positives and latency together.
