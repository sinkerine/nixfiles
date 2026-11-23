import { randomBytes } from "node:crypto";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export const COMPACT_THRESHOLD_BYTES = 16 * 1024;
export const TAIL_LINES = 60;
export const MAX_TAIL_BYTES = 12 * 1024;

const PI_TRUNCATION_FOOTER_RE = /\n\n\[Showing [^\n]*Full output: [^\n]+\]$/;

function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes}B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)}KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)}MB`;
}

function tailText(body: string, maxLines: number, maxBytes: number): { text: string; lines: number } {
  const allLines = body.split("\n");
  const selected = allLines.slice(-maxLines);
  let joined = selected.join("\n");
  if (Buffer.byteLength(joined, "utf8") <= maxBytes) {
    return { text: joined, lines: selected.length };
  }
  const kept: string[] = [];
  let usedBytes = 0;
  for (let i = selected.length - 1; i >= 0; i--) {
    const line = selected[i]!;
    const sepBytes = kept.length > 0 ? 1 : 0;
    const lineBytes = Buffer.byteLength(line, "utf8");
    if (usedBytes + sepBytes + lineBytes > maxBytes) {
      if (kept.length === 0) {
        // Single line exceeds maxBytes: keep its UTF-8 tail.
        const buf = Buffer.from(line, "utf8");
        kept.push(buf.subarray(Math.max(0, buf.length - maxBytes)).toString("utf8"));
      }
      break;
    }
    kept.push(line);
    usedBytes += sepBytes + lineBytes;
  }
  kept.reverse();
  joined = kept.join("\n");
  return { text: joined, lines: kept.length };
}

function persistFullOutput(text: string): string {
  const filePath = path.join(os.tmpdir(), `pi-bash-compact-${randomBytes(8).toString("hex")}.log`);
  fs.writeFileSync(filePath, text, "utf8");
  return filePath;
}

export default function bashOutputCompact(pi: ExtensionAPI) {
  pi.on("tool_result", (event) => {
    if (event.toolName !== "bash") return;
    if (event.parentToolCallId) return;
    if (event.isError) return;

    const structured = event.structuredContent as { exit_code?: unknown } | undefined;
    if (structured && typeof structured.exit_code === "number" && structured.exit_code !== 0) {
      return;
    }

    if (!Array.isArray(event.content) || event.content.length === 0) return;
    if (!event.content.every((part) => part && part.type === "text" && typeof part.text === "string")) {
      return;
    }

    const originalText = event.content.map((part) => (part as { text: string }).text).join("\n");
    const originalBytes = Buffer.byteLength(originalText, "utf8");
    if (originalBytes <= COMPACT_THRESHOLD_BYTES) return;

    const details = (event.details && typeof event.details === "object" ? event.details : {}) as Record<string, unknown>;
    const existingPath = typeof details.fullOutputPath === "string" && details.fullOutputPath.length > 0
      ? details.fullOutputPath
      : undefined;

    const body = existingPath ? originalText.replace(PI_TRUNCATION_FOOTER_RE, "") : originalText;
    const fullOutputPath = existingPath ?? persistFullOutput(originalText);

    const { text: tail, lines: keptLines } = tailText(body, TAIL_LINES, MAX_TAIL_BYTES);
    const tailBytes = Buffer.byteLength(tail, "utf8");
    const notice =
      `[Compacted successful bash output (${formatSize(originalBytes)} -> ${formatSize(tailBytes)}): ` +
      `showing last ${keptLines} lines. Full output: ${fullOutputPath}]`;
    const compacted = tail ? `${tail}\n\n${notice}` : notice;

    return {
      content: [{ type: "text", text: compacted }],
      details: { ...details, fullOutputPath },
    };
  });
}
