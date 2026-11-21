#!/usr/bin/env node
// apps_reference.mjs -- the reference oracle for the sim test apps.
//
// Runs every scenario of scenarios.json against test/sim/apps (served by ../appserver.py) with
// Playwright driving a headless Chromium directly, checks the scenario's oracles (`expect`
// ops, final `expect`, `expectLog` against the POSTed log) plus generic ones (every record
// reached the server, posted state == page state, the status strip decoded from the screenshot
// == page state), and writes screenshots and reference.json (final __state() per scenario) to
// --out. The same scenarios are meant to be replayed through Folk + emulated USB devices and
// compared with reference.json.
//
//   node test/sim/tests/apps_reference.mjs [--out DIR] [--only NAME[,NAME]] [--keep-going]
//
// Needs node >= 18 and playwright (global install is found through `npm root -g`); the browser
// is $FOLK_BROWSER or the Playwright Chromium headless shell under /opt/pw-browsers.
import { spawn, execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const simDir = path.resolve(here, '..');
const require = createRequire(import.meta.url);

function loadPlaywright() {
  const candidates = ['playwright', 'playwright-core'];
  try { candidates.push(path.join(execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim(), 'playwright')); } catch (e) {}
  candidates.push(path.resolve(path.dirname(process.execPath), '..', 'lib', 'node_modules', 'playwright'));
  for (const c of candidates) { try { return require(c); } catch (e) {} }
  throw new Error('playwright not found (tried ' + candidates.join(', ') + ')');
}
function findBrowser() {
  if (process.env.FOLK_BROWSER) return process.env.FOLK_BROWSER;
  const root = '/opt/pw-browsers';
  const dirs = fs.existsSync(root) ? fs.readdirSync(root).sort() : [];
  for (const d of dirs) {
    const p = path.join(root, d, 'chrome-headless-shell-linux64', 'chrome-headless-shell');
    if (d.startsWith('chromium_headless_shell-') && fs.existsSync(p)) return p;
  }
  for (const d of dirs) {
    const p = path.join(root, d, 'chrome-linux64', 'chrome');
    if (d.startsWith('chromium-') && fs.existsSync(p)) return p;
  }
  return undefined;   // let Playwright look for its own
}

// ---- abstract actions -> Playwright
const KEYS = {
  CTRL: 'Control', CONTROL: 'Control', SHIFT: 'Shift', ALT: 'Alt', META: 'Meta', ENTER: 'Enter', RETURN: 'Enter',
  ESC: 'Escape', ESCAPE: 'Escape', TAB: 'Tab', SPACE: 'Space', BACKSPACE: 'Backspace', DELETE: 'Delete', DEL: 'Delete',
  HOME: 'Home', END: 'End', PAGEUP: 'PageUp', PAGEDOWN: 'PageDown', LEFT: 'ArrowLeft', RIGHT: 'ArrowRight',
  UP: 'ArrowUp', DOWN: 'ArrowDown', INSERT: 'Insert',
};
// US layout, as in hidemu.c: unshifted and shifted characters of the same physical keys.
const US_PLAIN = "`1234567890-=qwertyuiop[]\\asdfghjkl;'zxcvbnm,./ ";
const US_SHIFT = '~!@#$%^&*()_+QWERTYUIOP{}|ASDFGHJKL:"ZXCVBNM<>? ';
const US_CODES = ['Backquote', 'Digit1', 'Digit2', 'Digit3', 'Digit4', 'Digit5', 'Digit6', 'Digit7', 'Digit8', 'Digit9', 'Digit0',
  'Minus', 'Equal', 'KeyQ', 'KeyW', 'KeyE', 'KeyR', 'KeyT', 'KeyY', 'KeyU', 'KeyI', 'KeyO', 'KeyP', 'BracketLeft', 'BracketRight',
  'Backslash', 'KeyA', 'KeyS', 'KeyD', 'KeyF', 'KeyG', 'KeyH', 'KeyJ', 'KeyK', 'KeyL', 'Semicolon', 'Quote', 'KeyZ', 'KeyX',
  'KeyC', 'KeyV', 'KeyB', 'KeyN', 'KeyM', 'Comma', 'Period', 'Slash', 'Space'];
function charKey(ch) {
  if (ch === '\n') return { code: 'Enter', shift: false };
  if (ch === '\t') return { code: 'Tab', shift: false };
  let i = US_PLAIN.indexOf(ch);
  if (i >= 0) return { code: US_CODES[i], shift: false };
  i = US_SHIFT.indexOf(ch);
  if (i >= 0) return { code: US_CODES[i], shift: true };
  throw new Error('cannot type character ' + JSON.stringify(ch));
}
function keyName(name) {
  if (KEYS[name.toUpperCase()]) return KEYS[name.toUpperCase()];
  if (name.length === 1) return charKey(name).code;
  return name;   // already a DOM key/code name
}
function pointOf(layout, spec) {
  // a target may also be a literal viewport point {x, y} (what the fuzzer records)
  const lit = spec && typeof spec === 'object' && spec.target && typeof spec.target === 'object' ? spec.target : spec;
  if (lit && typeof lit === 'object' && typeof lit.x === 'number') return { x: lit.x, y: lit.y };
  const target = typeof spec === 'string' ? spec : spec.target;
  const at = (typeof spec === 'object' && spec.at) || [0.5, 0.5];
  const r = layout[target];
  if (!r) throw new Error('no such target in the layout: ' + target + ' (have: ' + Object.keys(layout).join(' ') + ')');
  return { x: r.x + Math.floor(r.w * at[0]), y: r.y + Math.floor(r.h * at[1]) };
}
function matches(actual, expected, where = '') {
  // subset match; returns a description of the first mismatch or null
  if (expected === null || typeof expected !== 'object') {
    return Object.is(actual, expected) ? null : `${where || 'value'}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`;
  }
  if (Array.isArray(expected)) {
    if (!Array.isArray(actual) || actual.length !== expected.length) return `${where}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`;
    for (let i = 0; i < expected.length; i++) { const m = matches(actual[i], expected[i], `${where}[${i}]`); if (m) return m; }
    return null;
  }
  if (actual === null || typeof actual !== 'object') return `${where}: expected an object, got ${JSON.stringify(actual)}`;
  for (const k of Object.keys(expected)) { const m = matches(actual[k], expected[k], where ? `${where}.${k}` : k); if (m) return m; }
  return null;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function runAction(page, a) {
  const layout = () => page.evaluate(() => window.__layout());
  const button = a.button || 'left';
  switch (a.op) {
    case 'click': case 'rightclick': case 'dblclick': {
      const p = pointOf(await layout(), a);
      const b = a.op === 'rightclick' ? 'right' : button;
      await page.mouse.move(p.x, p.y);
      await page.mouse.down({ button: b, clickCount: 1 }); await page.mouse.up({ button: b, clickCount: 1 });
      if (a.op === 'dblclick') { await page.mouse.down({ button: b, clickCount: 2 }); await page.mouse.up({ button: b, clickCount: 2 }); }
      break;
    }
    case 'move': { const p = pointOf(await layout(), a); await page.mouse.move(p.x, p.y, { steps: a.steps || 4 }); break; }
    case 'mousedown': { const p = pointOf(await layout(), a); await page.mouse.move(p.x, p.y); await page.mouse.down({ button }); break; }
    case 'mouseup': {
      if (a.target) { const p = pointOf(await layout(), a); await page.mouse.move(p.x, p.y); }
      await page.mouse.up({ button }); break;
    }
    case 'drag': {
      const l = await layout(), from = pointOf(l, a.from), to = pointOf(l, a.to);
      await page.mouse.move(from.x, from.y);
      await page.mouse.down({ button });
      await page.mouse.move(to.x, to.y, { steps: a.steps || 8 });
      await page.mouse.up({ button });
      break;
    }
    case 'type':
      for (const ch of a.text) {
        const k = charKey(ch);
        if (k.shift) await page.keyboard.down('Shift');
        await page.keyboard.press(k.code);
        if (k.shift) await page.keyboard.up('Shift');
      }
      break;
    case 'key':
      for (let i = 0; i < (a.count || 1); i++) await page.keyboard.press(keyName(a.key));
      break;
    case 'chord': {
      const keys = a.keys.split('+').map(keyName);
      for (let i = 0; i < (a.count || 1); i++) {
        for (const k of keys) await page.keyboard.down(k);
        for (const k of keys.slice().reverse()) await page.keyboard.up(k);
      }
      break;
    }
    case 'keydown': await page.keyboard.down(keyName(a.key)); break;
    case 'keyup': await page.keyboard.up(keyName(a.key)); break;
    case 'wheel': {
      const p = pointOf(await layout(), a);
      await page.mouse.move(p.x, p.y);
      for (let i = 0; i < Math.abs(a.dy || 0); i++) { await page.mouse.wheel(0, 100 * Math.sign(a.dy)); await sleep(20); }
      for (let i = 0; i < Math.abs(a.dx || 0); i++) { await page.mouse.wheel(100 * Math.sign(a.dx), 0); await sleep(20); }
      break;
    }
    case 'wait': await sleep(a.ms); break;
    case 'expect': {
      // poll briefly: state may follow the input asynchronously (focus, scrolling, timers)
      let m = null;
      for (let i = 0; i < 20; i++) {
        m = matches(await page.evaluate(() => window.__state()), a.state);
        if (!m) return;
        await sleep(50);
      }
      throw new Error('expect: ' + m);
    }
    default: throw new Error('unknown op ' + a.op);
  }
  await sleep(30);
}

async function runScenario(browser, base, sc, out) {
  const session = sc.name + '-' + Date.now().toString(36);
  const context = await browser.newContext({ viewport: { width: 1024, height: 640 }, deviceScaleFactor: 1 });
  // The pages see what they see in Folk's browser: the same page shim (lib/browser-page-shim.js).
  await context.addInitScript({ content: fs.readFileSync(path.join(simDir, '..', '..', 'lib', 'browser-page-shim.js'), 'utf8') });
  const page = await context.newPage();
  const problems = [], consoleLines = [], dialogs = [];
  page.on('console', (m) => { if (m.type() === 'error' || m.type() === 'warning') consoleLines.push(m.type() + ': ' + m.text()); });
  page.on('pageerror', (e) => problems.push('page error: ' + e.message));
  page.on('dialog', async (d) => { dialogs.push({ type: d.type(), message: d.message() }); if (sc.dialog === 'dismiss') await d.dismiss(); else await d.accept(); });
  const result = { name: sc.name, app: sc.app, session };
  try {
    await page.goto(`${base}/${sc.app}.html?session=${session}`);
    await page.waitForFunction(() => window.sim && window.sim.ready);
    result.initial = { state: await page.evaluate(() => window.__stableState()), hash: await page.evaluate(() => window.__hash()), layout: await page.evaluate(() => window.__layout()) };
    for (let i = 0; i < sc.actions.length; i++) {
      try { await runAction(page, sc.actions[i]); } catch (e) { problems.push(`action ${i} ${JSON.stringify(sc.actions[i])}: ${e.message}`); break; }
    }
    await sleep(450);   // let the last batch reach the server
    const state = await page.evaluate(() => window.__state());
    Object.assign(result, {
      state, stable: await page.evaluate(() => window.__stableState()), hash: await page.evaluate(() => window.__hash()),
      layout: await page.evaluate(() => window.__layout()), pointer: await page.evaluate(() => window.__pointer()), dialogs,
    });
    const pageEvents = await page.evaluate(() => window.__events());
    if (sc.expect) { const m = matches(state, sc.expect); if (m) problems.push('final state: ' + m); }
    const posted = await (await fetch(`${base}/log?session=${session}`)).json();
    result.events = posted.events;
    // generic oracles
    if (posted.events.length !== pageEvents.length) problems.push(`POSTed log has ${posted.events.length} records, the page logged ${pageEvents.length}`);
    posted.events.forEach((e, i) => { if (e.i !== i) problems.push(`POSTed log: record ${i} has i=${e.i}`); });
    if (posted.hash !== result.hash) problems.push(`posted hash ${posted.hash} != page hash ${result.hash}`);
    const mState = matches(posted.state, result.stable); if (mState) problems.push('posted state: ' + mState);
    const mLayout = matches(posted.layout, result.layout); if (mLayout) problems.push('posted layout: ' + mLayout);
    let from = 0;
    for (const pat of sc.expectLog || []) {
      let found = -1;
      for (let i = from; i < posted.events.length; i++) if (!matches(posted.events[i], pat)) { found = i; break; }
      if (found < 0) { problems.push('expectLog: no match (in order) for ' + JSON.stringify(pat)); break; }
      from = found + 1;
    }
    const shot = path.join(out, sc.name + '.png');
    await page.screenshot({ path: shot });
    try {
      const strip = JSON.parse(execFileSync('python3', [path.join(simDir, 'folksim.py'), '--decode-strip', shot], { encoding: 'utf8' }));
      result.strip = strip;
      const n = pageEvents.filter((e) => e.k !== 'app' && e.k !== 'load').length % 4096;
      if (strip.hash !== result.hash || strip.count !== n) problems.push(`strip decodes to ${JSON.stringify(strip)}, page has hash ${result.hash} count ${n}`);
    } catch (e) { problems.push('strip: ' + String(e.message).split('\n')[0]); }
  } catch (e) {
    problems.push(String(e.message).split('\n')[0]);
  }
  result.console = consoleLines;
  result.problems = problems;
  await context.close();
  return result;
}

async function main() {
  const args = process.argv.slice(2);
  const opt = (name, dflt) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : dflt; };
  const out = path.resolve(opt('--out', path.join(process.cwd(), 'apps-reference-out')));
  const only = opt('--only', '') ? opt('--only', '').split(',') : null;
  fs.mkdirSync(out, { recursive: true });
  const { scenarios } = JSON.parse(fs.readFileSync(opt('--scenarios', path.join(here, 'scenarios.json')), 'utf8'));

  const server = spawn('python3', [path.join(simDir, 'appserver.py'), '--port', '0'], { stdio: ['ignore', 'pipe', 'inherit'] });
  let failed = 0, browser = null;
  try {
    const base = await new Promise((resolve, reject) => {
      let buf = '';
      server.stdout.on('data', (d) => { buf += d; const m = buf.match(/listening on (http:\/\/[\d.]+:\d+)/); if (m) resolve(m[1]); });
      server.on('exit', (c) => reject(new Error('appserver exited with ' + c)));
      setTimeout(() => reject(new Error('appserver did not start')), 10000);
    });
    const { chromium } = loadPlaywright();
    browser = await chromium.launch({ executablePath: findBrowser(), args: ['--no-sandbox'] });
    const reference = { browser: browser.version(), scenarios: {} };
    for (const sc of scenarios) {
      if (only && !only.includes(sc.name)) continue;
      const t0 = Date.now();
      const r = await runScenario(browser, base, sc, out);
      reference.scenarios[sc.name] = r;
      const ok = r.problems.length === 0;
      if (!ok) failed++;
      console.log(`${ok ? 'ok  ' : 'FAIL'} ${sc.name}: ${sc.actions.length} actions, ${(r.events || []).length} log records, hash ${r.hash}, ${Date.now() - t0} ms`);
      for (const p of r.problems) console.log('     ' + p);
      for (const c of r.console) console.log('     console ' + c);
    }
    fs.writeFileSync(path.join(out, 'reference.json'), JSON.stringify(reference, null, 1));
    console.log(`${failed ? 'FAIL' : 'PASS'}: ${Object.keys(reference.scenarios).length - failed}/${Object.keys(reference.scenarios).length} scenarios; output in ${out}`);
  } finally {
    if (browser) await browser.close().catch(() => {});
    server.kill('SIGTERM');
  }
  process.exit(failed ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(2); });
