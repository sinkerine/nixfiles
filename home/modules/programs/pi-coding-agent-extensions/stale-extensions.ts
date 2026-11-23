import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

function agentDir(env: NodeJS.ProcessEnv = process.env): string {
  return env.PI_CODING_AGENT_DIR || path.join(os.homedir(), ".pi/agent");
}

function safeRealpath(target: string): string | undefined {
  try {
    return fs.realpathSync(target);
  } catch {
    return undefined;
  }
}

export function readExtensionFingerprint(dir: string): string | undefined {
  const settingsPath = path.join(dir, "settings.json");
  let packages: unknown = undefined;
  try {
    const parsed = JSON.parse(fs.readFileSync(settingsPath, "utf8")) as { packages?: unknown };
    if (Array.isArray(parsed.packages)) {
      packages = parsed.packages;
    }
  } catch {
    return undefined;
  }

  const extDir = path.join(dir, "extensions");
  let extensions: [string, string | undefined][] = [];
  try {
    extensions = fs
      .readdirSync(extDir)
      .sort()
      .map((name) => [name, safeRealpath(path.join(extDir, name))]);
  } catch {
    extensions = [];
  }

  return JSON.stringify({ packages, extensions });
}

export default function staleExtensions(pi: ExtensionAPI) {
  if (process.env.PI_SUBAGENT_CHILD === "1") return;

  let loadedFingerprint: string | undefined;
  let warnedFingerprint: string | undefined;

  const check = (ctx: ExtensionContext) => {
    if (!ctx.hasUI) return;
    const dir = agentDir();
    if (loadedFingerprint === undefined) {
      loadedFingerprint = readExtensionFingerprint(dir);
      return;
    }
    const current = readExtensionFingerprint(dir);
    if (!current) return;
    if (current === loadedFingerprint) {
      if (warnedFingerprint !== undefined) {
        warnedFingerprint = undefined;
        ctx.ui.setStatus("stale-extensions", undefined);
      }
      return;
    }
    ctx.ui.setStatus("stale-extensions", "⚠ Extensions updated — run /reload");
    if (warnedFingerprint !== current) {
      warnedFingerprint = current;
      ctx.ui.notify(
        "Pi extensions or packages changed on disk since this session loaded. Run /reload to pick up the new versions.",
        "warning",
      );
    }
  };

  pi.on("session_start", (_event, ctx) => {
    if (loadedFingerprint === undefined) {
      loadedFingerprint = readExtensionFingerprint(agentDir());
    }
    check(ctx);
  });

  pi.on("before_agent_start", (_event, ctx) => {
    check(ctx);
  });

  pi.on("turn_end", (_event, ctx) => {
    check(ctx);
  });
}
