#!/usr/bin/env python3
"""Replay immutable review packets through a bounded, tool-free model comparison."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import statistics
import subprocess
import tempfile
import time

SYSTEM = """You are an independent code reviewer. Review only the supplied contract and immutable code packet.
Find concrete current defects and regressions, including interactions between the supplied files. Do not invent missing repository facts.
Return JSON only: {"findings":[{"path":"repo-relative path","symbol":"affected symbol","severity":"Critical|Important|Minor","summary":"defect","evidence":"specific code and trigger"}],"limitations":[]}.
Do not inventory correct code. If no concrete issue is found, return an empty findings array. No tools are available."""


def atomic_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def packet(root, revision, definition):
    require_sha = subprocess.check_output(["git", "-C", str(root), "rev-parse", "--verify", "--end-of-options", revision + "^{tree}"], text=True).strip()
    chunks = [definition["contract"], "\nImmutable source tree: " + require_sha]
    for item in definition["files"]:
        name = item["path"]
        if Path(name).is_absolute() or ".." in Path(name).parts:
            raise ValueError("Packet paths must stay inside the repository")
        source = subprocess.check_output(["git", "-C", str(root), "show", require_sha + ":" + name], text=True)
        lines = source.splitlines()
        if "match" in item:
            indexes = set()
            for index, line in enumerate(lines):
                if item["match"] in line:
                    indexes.update(range(max(0, index - 8), min(len(lines), index + 12)))
            if not indexes:
                raise ValueError(f"Packet context match disappeared: {name}")
        else:
            indexes = range(len(lines))
        chunks.append("\nFILE " + name + "\n" + "\n".join(f"{index + 1}: {lines[index]}" for index in sorted(indexes)))
    text = "\n".join(chunks)
    if len(text.encode()) > 160_000:
        raise ValueError("Review packet exceeds 160 KB; narrow the immutable evidence explicitly")
    return text


def parse_report(text):
    text = text.strip()
    if text.startswith("```") and text.endswith("```"):
        text = text[text.index("\n") + 1:-3]
    report = json.loads(text)
    if not isinstance(report, dict) or not isinstance(report.get("findings"), list) or not isinstance(report.get("limitations", []), list):
        raise ValueError("Reviewer did not return the required findings object")
    for finding in report["findings"]:
        if not isinstance(finding, dict) or not all(isinstance(finding.get(key), str) and finding[key] for key in ["path", "symbol", "severity", "summary", "evidence"]):
            raise ValueError("Malformed reviewer finding")
        if finding["severity"] not in ["Critical", "Important", "Minor"]:
            raise ValueError("Malformed reviewer severity")
    return report


def score(report, expected):
    # Candidate matches require parent adjudication; text matching never selects a model.
    matches = []
    matched_findings = set()
    for issue in expected:
        candidates = []
        for index, finding in enumerate(report["findings"]):
            text = (finding["summary"] + " " + finding["evidence"] + " " + finding["symbol"]).lower()
            if finding["path"] == issue["path"] and all(term.lower() in text for term in issue.get("terms", [])):
                candidates.append(index)
                matched_findings.add(index)
        matches.append({"issue": issue["id"], "candidate_findings": candidates})
    return {"expected": len(expected), "candidate_matches": matches,
            "unmatched_findings": [index for index in range(len(report["findings"])) if index not in matched_findings],
            "requires_adjudication": True}


def run_cell(pi, model, prompt, output, timeout):
    events, errors = output.with_suffix(".jsonl"), output.with_suffix(".stderr")
    started = time.monotonic()
    args = [pi, "--print", "--mode", "json", "--model", model, "--no-session", "--no-tools", "--no-extensions",
            "--no-mcp", "--no-skills", "--no-prompt-templates", "--no-context-files", "--system-prompt", SYSTEM]
    env = {key: value for key, value in os.environ.items() if key not in ["PASEO_AGENT_ID", "PI_SESSION_FILE", "PI_SUBAGENT_DEPTH"]}
    with tempfile.TemporaryDirectory(prefix="review-packet-") as cwd, events.open("w") as out, errors.open("w") as err:
        process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=out, stderr=err, text=True, cwd=cwd,
                                   env=env, start_new_session=True)
        timed_out = False
        try:
            process.communicate(prompt, timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
        except BaseException:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise
    result = {"requested_model": model, "wall_seconds": round(time.monotonic() - started, 3),
              "exit_code": process.returncode, "events": str(events), "stderr": str(errors), "timed_out": timed_out}
    messages, usage, tool_calls = [], {}, 0
    for line in events.read_text().split("\n"):
        if not line:
            continue
        event = json.loads(line)
        if event.get("type") == "tool_execution_start":
            tool_calls += 1
        if event.get("type") == "message_end" and event.get("message", {}).get("role") == "assistant":
            message = event["message"]
            messages.append(message)
            for key in ["input", "output", "cacheRead", "cacheWrite", "reasoning"]:
                usage[key] = usage.get(key, 0) + (message.get("usage", {}).get(key, 0) or 0)
    result.update(usage=usage, tool_calls=tool_calls)
    if timed_out or process.returncode or not messages:
        result["status"] = "timeout" if timed_out else "failed"
        return result
    result["resolved_model"] = messages[-1].get("model")
    if any(message.get("stopReason") in ("error", "aborted") for message in messages) or tool_calls:
        result["status"] = "failed"
        return result
    text = "\n".join(block.get("text", "") for message in messages for block in message.get("content", []) if block.get("type") == "text")
    output.with_suffix(".md").write_text(text)
    try:
        result["report"] = parse_report(text)
        result["status"] = "completed"
    except (ValueError, TypeError) as error:
        result.update(status="invalid-output", error=str(error))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--repository", action="append", default=[], help="name=/absolute/repository")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pi", default="pi")
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--timeout", type=int, default=300)
    args = parser.parse_args()
    if not 1 <= args.repeats <= 3 or not 1 <= args.timeout <= 900:
        parser.error("repeats must be 1..3 and timeout must be 1..900 seconds")
    manifest = json.loads(args.manifest.read_text())
    if manifest.get("version") != 1 or not 1 <= len(manifest["cases"]) <= 8 or not 1 <= len(manifest["variants"]) <= 4:
        parser.error("Expected version=1, up to eight cases and four variants")
    repositories = dict(item.split("=", 1) for item in args.repository)
    args.output.mkdir(parents=True, exist_ok=True)
    summary_path = args.output / "summary.json"
    if summary_path.exists():
        parser.error("Output already has a benchmark summary; choose a fresh directory")
    packets = {}
    for case in manifest["cases"]:
        for identifier in [case["id"], case["packet"]]:
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,79}", identifier):
                parser.error("Case and packet ids must be safe names")
        definition = manifest["packets"][case["packet"]]
        packets[case["id"]] = packet(Path(repositories[definition["repository"]]), case["revision"], definition)
        (args.output / (case["id"] + "-packet.md")).write_text(packets[case["id"]])
    results = []
    summary = {"version": 1, "status": "running", "tool_policy": "no tools; no extensions; identical evidence per case", "results": results, "default_changed": False}
    atomic_json(summary_path, summary)
    for repeat in range(args.repeats):
        for index, case in enumerate(manifest["cases"]):
            # Rotate order to avoid always giving one variant the first request.
            variants = manifest["variants"]
            offset = (index + repeat) % len(variants)
            for variant in variants[offset:] + variants[:offset]:
                if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,79}", variant["id"]):
                    parser.error("Variant ids must be safe names")
                name = f"{case['id']}-{variant['id']}-r{repeat + 1}"
                result = run_cell(args.pi, variant["model"], packets[case["id"]], args.output / name, args.timeout)
                result.update(case=case["id"], variant=variant["id"], repeat=repeat + 1,
                              packet_sha256=hashlib.sha256(packets[case["id"]].encode()).hexdigest())
                if result["status"] == "completed":
                    result["quality"] = score(result["report"], case.get("expected", []))
                results.append(result)
                atomic_json(summary_path, summary)
                print(json.dumps({"case": case["id"], "variant": variant["id"], "status": result["status"], "seconds": result["wall_seconds"]}), flush=True)
                if result["status"] != "completed":
                    summary["status"] = "incomplete"
                    atomic_json(summary_path, summary)
                    return 1
    summary["status"] = "needs-adjudication"
    summary["medians_seconds"] = {variant["id"]: statistics.median(result["wall_seconds"] for result in results if result["variant"] == variant["id"]) for variant in manifest["variants"]}
    atomic_json(summary_path, summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
