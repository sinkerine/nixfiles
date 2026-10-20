// Minimal Chrome DevTools Protocol client for the Electron app in this VM.
// The app is launched with --remote-debugging-port, which Chromium binds to
// the guest's loopback only; the host reaches this script over SSH.
import { readdirSync, writeFileSync } from "node:fs";

const PORT = process.env.CDP_PORT || "9222";
const STEPS_DIR = "/job/out/steps";

const USAGE = `vm-test-cdp [--target N|TEXT] COMMAND

  targets                    List debuggable targets (pages are numbered from 0)
  snapshot                   Visible interactive elements with selectors and bounds
  text [SELECTOR]            innerText of the page or an element
  eval JS                    Evaluate JS in the page (promises awaited), print JSON
  wait JS [--timeout SEC]    Poll JS until it is truthy (default 10s)
  click SELECTOR [--double|--right]
  type SELECTOR TEXT [--clear]
  key COMBO...               e.g. Enter Escape Tab ctrl+a shift+Tab
  screenshot [LABEL]         Capture the page into ${STEPS_DIR}`;

function die(message) {
  console.error(`vm-test-cdp: ${message}`);
  process.exit(1);
}

function takeFlag(args, name) {
  const i = args.indexOf(name);
  if (i === -1) return false;
  args.splice(i, 1);
  return true;
}

function takeOption(args, name) {
  const i = args.indexOf(name);
  if (i === -1) return undefined;
  const value = args[i + 1];
  if (value === undefined) die(`${name} needs a value`);
  args.splice(i, 2);
  return value;
}

async function listTargets() {
  let res;
  try {
    res = await fetch(`http://127.0.0.1:${PORT}/json/list`);
  } catch {
    die(`no CDP endpoint on port ${PORT}; is the app running with --remote-debugging-port?`);
  }
  return res.json();
}

function pickTarget(targets, selector) {
  const pages = targets.filter((t) => t.type === "page");
  if (pages.length === 0) die("no page targets");
  if (selector === undefined) return pages[0];
  if (/^\d+$/.test(selector)) {
    return pages[Number(selector)] ?? die(`no page target #${selector}`);
  }
  const needle = selector.toLowerCase();
  return (
    pages.find((t) => `${t.title} ${t.url}`.toLowerCase().includes(needle)) ??
    die(`no page target matching "${selector}"`)
  );
}

async function connect(target) {
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  const pending = new Map();
  let nextId = 1;
  await new Promise((resolve, reject) => {
    ws.onopen = resolve;
    ws.onerror = () => reject(new Error(`cannot connect to ${target.webSocketDebuggerUrl}`));
  });
  ws.onmessage = (event) => {
    const msg = JSON.parse(event.data);
    const handler = pending.get(msg.id);
    if (!handler) return;
    pending.delete(msg.id);
    if (msg.error) handler.reject(new Error(`${msg.error.message} (${msg.error.code})`));
    else handler.resolve(msg.result);
  };
  const send = (method, params = {}) =>
    new Promise((resolve, reject) => {
      const id = nextId++;
      pending.set(id, { resolve, reject });
      ws.send(JSON.stringify({ id, method, params }));
    });
  const evaluate = async (expression) => {
    const r = await send("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
      userGesture: true,
    });
    if (r.exceptionDetails) {
      const d = r.exceptionDetails;
      throw new Error(d.exception?.description ?? d.text);
    }
    return r.result.value;
  };
  return { send, evaluate, close: () => ws.close() };
}

// Runs in the page: describe visible interactive elements with a usable selector.
const SNAPSHOT_JS = `(() => {
  const q = 'a,button,input,select,textarea,summary,[role],[onclick],[tabindex],[contenteditable=""],[contenteditable=true]';
  const sel = (el) => {
    if (el.id && document.querySelectorAll('#' + CSS.escape(el.id)).length === 1) return '#' + CSS.escape(el.id);
    for (const a of ['data-testid', 'data-test', 'name', 'aria-label']) {
      const v = el.getAttribute(a);
      if (v) {
        const s = el.tagName.toLowerCase() + '[' + a + '="' + CSS.escape(v) + '"]';
        if (document.querySelectorAll(s).length === 1) return s;
      }
    }
    const parts = [];
    for (let e = el; e && e.nodeType === 1 && e !== document.documentElement; e = e.parentElement) {
      if (e.id && document.querySelectorAll('#' + CSS.escape(e.id)).length === 1) { parts.unshift('#' + CSS.escape(e.id)); break; }
      const same = [...(e.parentElement?.children ?? [])].filter((c) => c.tagName === e.tagName);
      parts.unshift(e.tagName.toLowerCase() + (same.length > 1 ? ':nth-of-type(' + (same.indexOf(e) + 1) + ')' : ''));
    }
    return parts.join(' > ');
  };
  const out = [];
  for (const el of document.querySelectorAll(q)) {
    const r = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    if (r.width === 0 || r.height === 0 || style.visibility === 'hidden' || style.display === 'none') continue;
    const label = (el.getAttribute('aria-label') || el.innerText || el.value || el.placeholder || el.title || '').trim().replace(/\\s+/g, ' ').slice(0, 80);
    out.push({
      tag: el.tagName.toLowerCase(),
      role: el.getAttribute('role') || undefined,
      type: el.getAttribute('type') || undefined,
      label,
      disabled: el.disabled || el.getAttribute('aria-disabled') === 'true' || undefined,
      selector: sel(el),
      rect: [Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height)],
    });
  }
  return { title: document.title, url: location.href, focused: document.activeElement ? sel(document.activeElement) : null, elements: out };
})()`;

const KEYS = {
  enter: ["Enter", "Enter", 13, "\r"],
  return: ["Enter", "Enter", 13, "\r"],
  escape: ["Escape", "Escape", 27],
  esc: ["Escape", "Escape", 27],
  tab: ["Tab", "Tab", 9],
  backspace: ["Backspace", "Backspace", 8],
  delete: ["Delete", "Delete", 46],
  space: [" ", "Space", 32, " "],
  arrowup: ["ArrowUp", "ArrowUp", 38],
  up: ["ArrowUp", "ArrowUp", 38],
  arrowdown: ["ArrowDown", "ArrowDown", 40],
  down: ["ArrowDown", "ArrowDown", 40],
  arrowleft: ["ArrowLeft", "ArrowLeft", 37],
  left: ["ArrowLeft", "ArrowLeft", 37],
  arrowright: ["ArrowRight", "ArrowRight", 39],
  right: ["ArrowRight", "ArrowRight", 39],
  home: ["Home", "Home", 36],
  end: ["End", "End", 35],
  pageup: ["PageUp", "PageUp", 33],
  pagedown: ["PageDown", "PageDown", 34],
};
const MODIFIERS = { alt: 1, ctrl: 2, control: 2, meta: 4, super: 4, cmd: 4, shift: 8 };

function parseCombo(combo) {
  const parts = combo.split("+");
  const name = parts.pop();
  let modifiers = 0;
  for (const m of parts) {
    const bit = MODIFIERS[m.toLowerCase()];
    if (!bit) die(`unknown modifier "${m}" in ${combo}`);
    modifiers |= bit;
  }
  let key, code, keyCode, text;
  const named = KEYS[name.toLowerCase()];
  if (named) {
    [key, code, keyCode, text] = named;
  } else if (/^f([1-9]|1[0-2])$/i.test(name)) {
    key = code = name.toUpperCase();
    keyCode = 111 + Number(name.slice(1));
  } else if (name.length === 1) {
    const upper = name.toUpperCase();
    key = modifiers & 8 ? upper : name;
    code = /[a-z]/i.test(name) ? `Key${upper}` : /\d/.test(name) ? `Digit${name}` : undefined;
    keyCode = upper.charCodeAt(0);
    text = key;
  } else {
    die(`unknown key "${name}"`);
  }
  // Shortcuts must not insert text.
  if (modifiers & (1 | 2 | 4)) text = undefined;
  return { key, code, keyCode, text, modifiers };
}

async function elementCenter(cdp, selector) {
  const info = await cdp.evaluate(`(() => {
    const el = document.querySelector(${JSON.stringify(selector)});
    if (!el) return null;
    el.scrollIntoView({ block: 'center', inline: 'center' });
    const r = el.getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2, w: r.width, h: r.height,
             label: (el.getAttribute('aria-label') || el.innerText || el.value || '').trim().slice(0, 60) };
  })()`);
  if (!info) die(`no element matches ${selector}`);
  if (info.w === 0 || info.h === 0) die(`element ${selector} has no size (hidden?)`);
  return info;
}

function nextStepPath(label) {
  const n = readdirSync(STEPS_DIR).filter((f) => /\.(png|jpg)$/.test(f)).length + 1;
  const safe = label.replace(/[^A-Za-z0-9_-]/g, "-");
  return `${STEPS_DIR}/${String(n).padStart(3, "0")}-cdp-${safe}.png`;
}

async function main() {
  const args = process.argv.slice(2);
  const targetSelector = takeOption(args, "--target");
  const cmd = args.shift();
  if (!cmd || cmd === "help" || cmd === "--help" || cmd === "-h") {
    console.log(USAGE);
    return;
  }

  const targets = await listTargets();
  if (cmd === "targets") {
    targets
      .filter((t) => t.type === "page")
      .forEach((t, i) => console.log(`${i}\t${t.title}\t${t.url}`));
    const others = targets.filter((t) => t.type !== "page");
    for (const t of others) console.log(`-\t[${t.type}] ${t.title}\t${t.url}`);
    return;
  }

  const target = pickTarget(targets, targetSelector);
  const cdp = await connect(target);
  try {
    switch (cmd) {
      case "snapshot": {
        const s = await cdp.evaluate(SNAPSHOT_JS);
        console.log(`title: ${s.title}\nurl: ${s.url}\nfocused: ${s.focused ?? "-"}`);
        s.elements.forEach((e, i) => {
          const kind = [e.tag, e.type && `type=${e.type}`, e.role && `role=${e.role}`].filter(Boolean).join(" ");
          const flags = e.disabled ? " (disabled)" : "";
          console.log(`[${i}] ${kind} "${e.label}"${flags}  sel=${e.selector}  @${e.rect.join(",")}`);
        });
        break;
      }
      case "text": {
        const selector = args[0];
        const text = await cdp.evaluate(
          selector
            ? `document.querySelector(${JSON.stringify(selector)})?.innerText ?? null`
            : "document.body.innerText",
        );
        if (text === null) die(`no element matches ${selector}`);
        console.log(text);
        break;
      }
      case "eval": {
        if (args.length === 0) die("usage: eval JS");
        const value = await cdp.evaluate(args.join(" "));
        console.log(typeof value === "string" ? value : JSON.stringify(value, null, 2));
        break;
      }
      case "wait": {
        const timeout = Number(takeOption(args, "--timeout") ?? 10) * 1000;
        if (args.length === 0) die("usage: wait JS [--timeout SEC]");
        const expression = args.join(" ");
        const deadline = Date.now() + timeout;
        let last;
        while (Date.now() < deadline) {
          try {
            last = await cdp.evaluate(expression);
            if (last) {
              console.log(typeof last === "string" ? last : JSON.stringify(last));
              return;
            }
          } catch (e) {
            last = e.message;
          }
          await new Promise((r) => setTimeout(r, 250));
        }
        die(`timed out after ${timeout / 1000}s; last value: ${JSON.stringify(last)}`);
        break;
      }
      case "click": {
        const double = takeFlag(args, "--double");
        const right = takeFlag(args, "--right");
        const selector = args[0] ?? die("usage: click SELECTOR [--double|--right]");
        const { x, y, label } = await elementCenter(cdp, selector);
        const button = right ? "right" : "left";
        await cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", x, y });
        for (let clickCount = 1; clickCount <= (double ? 2 : 1); clickCount++) {
          await cdp.send("Input.dispatchMouseEvent", { type: "mousePressed", x, y, button, clickCount });
          await cdp.send("Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button, clickCount });
        }
        console.log(`clicked ${selector} "${label}" at ${Math.round(x)},${Math.round(y)} (page coordinates)`);
        break;
      }
      case "type": {
        const clear = takeFlag(args, "--clear");
        const [selector, ...rest] = args;
        if (!selector || rest.length === 0) die("usage: type SELECTOR TEXT [--clear]");
        const found = await cdp.evaluate(`(() => {
          const el = document.querySelector(${JSON.stringify(selector)});
          if (!el) return false;
          el.focus();
          if (${clear}) {
            if (typeof el.select === 'function') el.select();
            else document.execCommand('selectAll');
          }
          return true;
        })()`);
        if (!found) die(`no element matches ${selector}`);
        await cdp.send("Input.insertText", { text: rest.join(" ") });
        console.log(`typed into ${selector}`);
        break;
      }
      case "key": {
        if (args.length === 0) die("usage: key COMBO...");
        for (const combo of args) {
          const { key, code, keyCode, text, modifiers } = parseCombo(combo);
          const base = { key, code, modifiers, windowsVirtualKeyCode: keyCode, nativeVirtualKeyCode: keyCode };
          await cdp.send("Input.dispatchKeyEvent", { type: text ? "keyDown" : "rawKeyDown", text, ...base });
          await cdp.send("Input.dispatchKeyEvent", { type: "keyUp", ...base });
        }
        console.log(`pressed ${args.join(" ")}`);
        break;
      }
      case "screenshot": {
        const { data } = await cdp.send("Page.captureScreenshot", { format: "png" });
        const path = nextStepPath(args[0] ?? "page");
        writeFileSync(path, Buffer.from(data, "base64"));
        console.log(path);
        break;
      }
      default:
        die(`unknown command "${cmd}"\n\n${USAGE}`);
    }
  } finally {
    cdp.close();
  }
}

main().catch((e) => die(e.message));
