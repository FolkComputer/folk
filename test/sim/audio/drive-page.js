#!/usr/bin/env node
// Drives tone-page.html in a Chromium launched through Playwright and prints one JSON object:
//   { browser, args, url, steps: [{step, t (ms epoch), ...}], log: window.__audioLog }
//
//   node drive-page.js [--browser shell|chrome|<path>] [--headed] [--url URL] [--query 'f1=440&..']
//                      [--no-click] [--js-click] [--only tones|audio] [--repeat N]
//                      [--settle MS] [--hold MS] [--flag=--chromium-flag ...]
//
// Clicks are raw CDP Input.dispatchMouseEvent (mouseMoved, mousePressed, mouseReleased), the
// events browser.folk sends for a USB mouse. The page is only ever read with CDP
// Runtime.evaluate WITHOUT userGesture: Playwright's own page.evaluate() passes
// userGesture=true, which is a user activation by itself and would hide what the autoplay
// policy does. --js-click calls element.click() from script instead (no activation: a control).
// Playwright adds --mute-audio to every headless launch; it is removed here.
"use strict";
const fs = require("fs");
const path = require("path");

function loadPlaywright() {
  const candidates = ["playwright", "playwright-core", "/opt/node22/lib/node_modules/playwright",
                      "/usr/lib/node_modules/playwright", "/usr/local/lib/node_modules/playwright"];
  for (const c of candidates) { try { return require(c); } catch (e) { /* next */ } }
  console.error("drive-page.js: cannot find the playwright module (set NODE_PATH)");
  process.exit(2);
}

function findBrowser(which) {
  const newest = (dir, re, tail) => {
    try {
      return fs.readdirSync(dir).filter(n => re.test(n)).sort().reverse()
               .map(n => path.join(dir, n, tail)).find(p => fs.existsSync(p));
    } catch (e) { return undefined; }
  };
  const root = process.env.PLAYWRIGHT_BROWSERS_PATH || "/opt/pw-browsers";
  const shell = newest(root, /^chromium_headless_shell-\d+$/, "chrome-headless-shell-linux64/chrome-headless-shell");
  const chrome = newest(root, /^chromium-\d+$/, "chrome-linux64/chrome");
  if (which === "shell") return shell;
  if (which === "chrome") return chrome;
  if (which) return which;
  return process.env.FOLK_BROWSER || shell || chrome;
}

const opt = { browser: null, headed: false, url: null, query: "", click: true, jsClick: false,
              only: null, repeat: 1, settle: 300, hold: 0, flags: [] };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--browser") opt.browser = argv[++i];
  else if (a === "--headed") opt.headed = true;
  else if (a === "--url") opt.url = argv[++i];
  else if (a === "--query") opt.query = argv[++i];
  else if (a === "--no-click") opt.click = false;
  else if (a === "--js-click") opt.jsClick = true;
  else if (a === "--only") opt.only = argv[++i];
  else if (a === "--repeat") opt.repeat = parseInt(argv[++i]);
  else if (a === "--settle") opt.settle = parseInt(argv[++i]);
  else if (a === "--hold") opt.hold = parseInt(argv[++i]);
  else if (a.startsWith("--flag=")) opt.flags.push(a.slice(7));
  else { console.error("drive-page.js: unknown argument " + a); process.exit(2); }
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

(async () => {
  const { chromium } = loadPlaywright();
  const exe = findBrowser(opt.browser);
  if (!exe || !fs.existsSync(exe)) { console.error("drive-page.js: no Chromium at " + exe); process.exit(2); }
  const url = opt.url || ("file://" + path.join(__dirname, "tone-page.html") + (opt.query ? "?" + opt.query : ""));
  const args = (process.getuid && process.getuid() === 0 ? ["--no-sandbox"] : []).concat(opt.flags);
  const steps = [];
  const step = (name, extra) => steps.push(Object.assign({ step: name, t: Date.now() }, extra || {}));

  const browser = await chromium.launch({ executablePath: exe, headless: !opt.headed, args: args,
                                          ignoreDefaultArgs: ["--mute-audio"] });
  let code = 0;
  try {
    const page = await browser.newPage({ viewport: { width: 800, height: 600 } });
    page.on("pageerror", e => step("pageerror", { text: String(e) }));
    const cdp = await page.context().newCDPSession(page);
    const evalJs = async expression => {
      const r = await cdp.send("Runtime.evaluate", { expression: expression, returnByValue: true });
      if (r.exceptionDetails) throw new Error("evaluate failed: " + JSON.stringify(r.exceptionDetails));
      return r.result.value;
    };
    await page.goto(url);
    const logLen = () => evalJs("window.__audioLog.length");
    const waitEvent = async (names, from, timeout) => {      // first of `names` logged at index >= from
      const end = Date.now() + timeout;
      while (Date.now() < end) {
        const hit = await evalJs("(window.__audioLog.slice(" + from + ").find(e => " +
                                 JSON.stringify(names) + ".includes(e.event)) || {}).event || null");
        if (hit) return hit;
        await sleep(20);
      }
      return null;
    };
    const click = async id => {
      const el = "document.getElementById(" + JSON.stringify(id) + ")";
      const p = await evalJs("(() => { const r = " + el + ".getBoundingClientRect();" +
                             " return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()");
      step("click", { id: id, x: p.x, y: p.y, how: opt.jsClick ? "js" : "cdp" });   // t = just before
      if (opt.jsClick) {
        await evalJs(el + ".click()");
      } else {
        await cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: p.x, y: p.y, buttons: 0 });
        await cdp.send("Input.dispatchMouseEvent", { type: "mousePressed", x: p.x, y: p.y, button: "left", buttons: 1, clickCount: 1 });
        await cdp.send("Input.dispatchMouseEvent", { type: "mouseReleased", x: p.x, y: p.y, button: "left", buttons: 0, clickCount: 1 });
      }
      step("clicked", { id: id });
    };
    await sleep(opt.settle);
    step("ready", { logLen: await logLen() });
    if (opt.click) {
      for (let round = 0; round < opt.repeat; round++) {
        if (opt.only !== "audio") {
          const from = await logLen();
          await click("play");
          step("tones", { result: await waitEvent(["tones-ended", "tones-blocked"], from, 15000) });
          await sleep(300);                            // a gap of silence between the parts
        }
        if (opt.only !== "tones") {
          const from = await logLen();
          await click("play-audio");
          step("audio", { result: await waitEvent(["audio-ended", "audio-blocked", "audio-error"], from, 15000) });
          if (round + 1 < opt.repeat) await sleep(300);
        }
      }
    } else {
      await sleep(2500);
    }
    if (opt.hold) await sleep(opt.hold);
    step("done", await evalJs("({ ctxState: window.__audioCtx.state, ctxTime: window.__audioCtx.currentTime," +
                              " elementTime: window.__audioElement.currentTime })"));
    console.log(JSON.stringify({ browser: exe, args: args, url: url, steps: steps,
                                 log: await evalJs("window.__audioLog") }));
  } catch (e) {
    console.error("drive-page.js: " + (e && e.stack || e));
    code = 1;
  } finally {
    await browser.close().catch(() => {});
  }
  process.exit(code);
})();
