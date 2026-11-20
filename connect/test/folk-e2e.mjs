// End-to-end test against a real Folk process.
//
//   node test/folk-e2e.mjs
//
// Starts the dev server and a headless Folk system running
// builtin-programs/connect.folk (see harness.folk), then drives the
// scratchpad in a browser and checks that statements really arrive
// in Folk, and that Folk's replies make it back.
//
// Needs Playwright, a built ./folk, and libdatachannel (connect.folk
// builds it on first run, which takes a few minutes).

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { startServer } from '../server/dev-server.js';

const { chromium } = createRequire(import.meta.url)('playwright');
const repo = fileURLToPath(new URL('../..', import.meta.url));

let failed = false;
const step = async (name, fn) => {
  try {
    await fn();
    console.log(`ok - ${name}`);
  } catch (err) {
    failed = true;
    console.log(`not ok - ${name}\n${String(err.stack ?? err).replace(/^/gm, '    ')}`);
  }
};

async function until(what, check, timeoutMs = 20000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const value = check();
    if (value) return value;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`timed out waiting for ${what}`);
}

function startFolk(server, { pairing = false } = {}) {
  const log = join(mkdtempSync(join(tmpdir(), 'folk-connect-')), 'log');
  const child = spawn('./folk', ['connect/test/harness.folk'], {
    cwd: repo,
    stdio: 'ignore',
    env: {
      ...process.env,
      CONNECT_SERVER: `ws://127.0.0.1:${server.port}/ws`,
      CONNECT_LOG: log,
      ...(pairing ? { CONNECT_PAIRING: '1' } : {}),
    },
  });
  return {
    lines: () => (existsSync(log) ? readFileSync(log, 'utf8').split('\n') : []),
    stop: () => new Promise((resolve) => {
      child.once('exit', resolve);
      child.kill('SIGKILL');
    }),
  };
}

const server = await startServer(0);
const browser = await chromium.launch({
  args: [
    '--use-fake-device-for-media-stream',
    '--use-fake-ui-for-media-stream',
    '--disable-features=WebRtcHideLocalIpsWithMdns',
  ],
});

const openPhone = async (name) => {
  const context = await browser.newContext();
  await context.addInitScript((n) => localStorage.setItem('connect-name', n), name);
  const page = await context.newPage();
  page.on('pageerror', (err) => { failed = true; console.log(`page error: ${err.message}`); });
  await page.goto(`http://localhost:${server.port}/`);
  return page;
};
const openPad = async (page) => {
  // The first boot may have to build wslay (and libdatachannel).
  const card = page.locator('#machines .card', { hasText: 'harness' });
  await card.waitFor({ timeout: 600000 });
  await card.getByRole('button', { name: 'Open scratchpad' }).click();
};

let folk = startFolk(server);
try {
  const phone = await openPhone('phone');

  await step('the Folk machine shows up in the room', async () => {
    await openPad(phone);
    assert.equal(await phone.locator('#machines .card .kind').textContent(), 'Folk');
  });

  await step('the scratchpad reaches Folk over WebRTC', async () => {
    await phone.locator('#pad-status[data-state="connected"]').waitFor({ timeout: 30000 });
  });

  await step('a touch on the phone becomes a statement in Folk', async () => {
    const box = await phone.locator('#surface').boundingBox();
    await phone.mouse.move(box.x + box.width * 0.2, box.y + box.height * 0.7);
    await phone.mouse.down();
    await until('the touch', () => folk.lines().some((l) => /^touch phone \d+$/.test(l)));
    await phone.mouse.up();
    await until('the touch to end', () => folk.lines().some((l) => /^untouch phone \d+$/.test(l)));
  });

  await step('running a program gives Folk its code', async () => {
    await phone.locator('#code').fill('Wish $this is labelled "from the phone"\n# a \\\n  continued line');
    await phone.getByRole('button', { name: 'Run on the table' }).click();
    const line = await until('the code', () =>
      folk.lines().find((l) => l.startsWith('code web-program-connect-phone-')));
    assert.match(line, /Wish \$this is labelled "from the phone"/);
  });

  await step("Folk's replies come back to the browser", async () => {
    // watch() has Folk push matches down the channel. (The harness
    // does not load collect.folk, so not watchCollected.)
    await phone.evaluate(() => {
      window.seen = [];
      window.connect.state.pad.pad.folk.watch(
        '/program/ has program code /code/', { add: (match) => window.seen.push(match) });
    });
    await phone.waitForFunction(() => window.seen.some((m) => m.code.includes('from the phone')));
  });

  await step('leaving the scratchpad retracts what it held', async () => {
    await phone.getByRole('button', { name: 'Back' }).click();
    await until('the code to go away', () =>
      folk.lines().some((l) => l.startsWith('uncode web-program-connect-phone-')));
  });

  await step('the scratchpad can be opened again', async () => {
    await openPad(phone);
    await phone.locator('#pad-status[data-state="connected"]').waitFor({ timeout: 30000 });
    await phone.getByRole('button', { name: 'Back' }).click();
  });

  await folk.stop();
  await step('a machine that goes away leaves the room', async () => {
    await phone.waitForFunction(() => document.querySelectorAll('#machines .card').length === 0);
  });

  // --- Pairing ---

  folk = startFolk(server, { pairing: true });
  const stranger = await openPhone('stranger');
  let code;

  await step('a machine that requires pairing claims a code', async () => {
    code = (await until('the pairing code', () =>
      folk.lines().find((l) => l.startsWith('pairing-code ')), 60000)).split(' ')[1];
    assert.match(code, /^\d{4}$/);
  });

  await step('the wrong code is refused, and nothing reaches Folk', async () => {
    const wrong = code === '0000' ? '1111' : '0000';
    let asked = 0;
    stranger.on('dialog', (dialog) => (asked++ === 0 ? dialog.accept(wrong) : dialog.dismiss()));
    await openPad(stranger);
    await stranger.locator('#pad-status[data-state="failed"]').waitFor({ timeout: 30000 });
    assert.match(await stranger.locator('#pad-problem').textContent(), /pairing code/);
    // Going around the page and opening a "folk" channel directly
    // does not work either: Folk closes it.
    const state = await stranger.evaluate(async () => {
      const { state, linkTo } = window.connect;
      const peer = [...state.peers.values()].find((p) => p.kind === 'folk');
      const channel = linkTo(peer.id).channel('folk');
      await new Promise((resolve) => {
        channel.addEventListener('close', resolve);
        setTimeout(resolve, 5000);
      });
      return channel.readyState;
    });
    assert.equal(state, 'closed');
    await stranger.getByRole('button', { name: 'Back' }).click();
    stranger.removeAllListeners('dialog');
  });

  await step('the right code is accepted, and remembered as a token', async () => {
    stranger.once('dialog', (dialog) => dialog.accept(code));
    await openPad(stranger);
    await stranger.locator('#pad-status[data-state="connected"]').waitFor({ timeout: 30000 });
    await stranger.getByRole('button', { name: 'Back' }).click();

    // Second time: no prompt (a dialog here would hang the test).
    await openPad(stranger);
    await stranger.locator('#pad-status[data-state="connected"]').waitFor({ timeout: 30000 });
    assert.ok(await stranger.evaluate(() => localStorage.getItem('connect-token:harness')));
  });
} finally {
  await folk.stop();
  await browser.close();
  await server.close();
}

process.exit(failed ? 1 : 0);
