import assert from "node:assert/strict";
import { existsSync, readFileSync, rmSync } from "node:fs";
import test from "node:test";
import { pathToFileURL } from "node:url";

const extPath = process.env.BASH_OUTPUT_COMPACT_EXTENSION
  ? pathToFileURL(process.env.BASH_OUTPUT_COMPACT_EXTENSION).href
  : new URL("./bash-output-compact.ts", import.meta.url).href;

const { default: bashOutputCompact, TAIL_LINES } = await import(extPath);

function setup() {
  let handler;
  bashOutputCompact({
    on(event, fn) {
      if (event === "tool_result") handler = fn;
    },
  });
  assert.ok(handler, "registers tool_result handler");
  return handler;
}

test("leaves small, non-bash, nested, and failing results untouched", () => {
  const handle = setup();
  const big = "warn: act(...)\n".repeat(2000);

  assert.equal(handle({ toolName: "read", isError: false, content: [{ type: "text", text: big }] }), undefined);
  assert.equal(handle({ toolName: "bash", isError: false, content: [{ type: "text", text: "ok\n" }] }), undefined);
  assert.equal(
    handle({ toolName: "bash", parentToolCallId: "cm-1", isError: false, content: [{ type: "text", text: big }] }),
    undefined,
  );
  assert.equal(
    handle({ toolName: "bash", isError: true, content: [{ type: "text", text: big }] }),
    undefined,
  );
  assert.equal(
    handle({
      toolName: "bash",
      isError: false,
      structuredContent: { exit_code: 1 },
      content: [{ type: "text", text: big }],
    }),
    undefined,
  );
});

test("compacts passing bash output over 16KB and reuses existing fullOutputPath", () => {
  const handle = setup();
  const warnings = Array.from({ length: 500 }, (_, i) => `warning ${i}: An update inside a test was not wrapped in act(...)`).join("\n");
  const summary = "Tests  31 passed (31)\nDuration  4.57s";
  const text = `${warnings}\n${summary}\n\n[Showing lines 216-1391 of 1391 (50.0KB limit). Full output: /tmp/pi-bash-existing.log]`;

  const result = handle({
    toolName: "bash",
    isError: false,
    structuredContent: { exit_code: 0 },
    details: { fullOutputPath: "/tmp/pi-bash-existing.log" },
    content: [{ type: "text", text }],
  });

  assert.ok(result);
  const out = result.content[0].text;
  assert.ok(Buffer.byteLength(out, "utf8") < 6000, `expected compact output, got ${out.length} chars`);
  assert.match(out, /Tests {2}31 passed \(31\)/);
  assert.match(out, /Full output: \/tmp\/pi-bash-existing\.log/);
  assert.doesNotMatch(out, /50\.0KB limit/);
  assert.equal(result.details.fullOutputPath, "/tmp/pi-bash-existing.log");
  const bodyLines = out.split("\n\n[Compacted successful bash output")[0].split("\n");
  assert.equal(bodyLines.length, TAIL_LINES);
});

test("persists full output to a temp file when bash did not already truncate", () => {
  const handle = setup();
  const text = Array.from({ length: 400 }, (_, i) => `line ${i}: ${"x".repeat(50)}`).join("\n");

  const result = handle({
    toolName: "bash",
    isError: false,
    content: [{ type: "text", text }],
  });

  assert.ok(result);
  const savedPath = result.details.fullOutputPath;
  assert.ok(typeof savedPath === "string" && existsSync(savedPath));
  try {
    assert.equal(readFileSync(savedPath, "utf8"), text);
    assert.match(result.content[0].text, /line 399:/);
    assert.match(result.content[0].text, new RegExp(savedPath.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  } finally {
    rmSync(savedPath, { force: true });
  }
});
