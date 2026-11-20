// End-to-end test: real browsers, real WebRTC, the dev server.
//
//   node test/e2e.mjs
//
// Needs Playwright (`npm install --no-save playwright`, or a global
// install on NODE_PATH). Three tabs join the same room: one simulates
// a Folk machine, one is a phone using the scratchpad, and one is a
// second person to share media with.

import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

import { startServer } from '../server/dev-server.js';

const { chromium } = createRequire(import.meta.url)('playwright');

const server = await startServer(0);
const base = `http://localhost:${server.port}`;
const browser = await chromium.launch({
  args: [
    '--use-fake-device-for-media-stream',
    '--use-fake-ui-for-media-stream',
    // Tabs in one headless browser cannot resolve each other's mDNS
    // candidate names, so let them see plain local addresses.
    '--disable-features=WebRtcHideLocalIpsWithMdns',
  ],
});

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

const open = async (path, name) => {
  const context = await browser.newContext({ permissions: ['camera', 'microphone'] });
  await context.addInitScript((n) => localStorage.setItem('connect-name', n), name);
  const page = await context.newPage();
  page.on('pageerror', (err) => { failed = true; console.log(`page error (${name}): ${err.message}`); });
  await page.goto(base + path);
  return page;
};

try {
  const machine = await open('/?sim', 'table');
  const phone = await open('/', 'phone');
  const friend = await open('/', 'friend');

  await step('everyone on the same network lands in the same room', async () => {
    await phone.locator('#machines .card', { hasText: 'table-sim' }).waitFor();
    await phone.locator('#people .card', { hasText: 'friend' }).waitFor();
    await friend.locator('#people .card', { hasText: 'phone' }).waitFor();
    assert.equal(await phone.locator('#status-text').textContent(), 'this network');
  });

  await step('the scratchpad connects to the machine over a data channel', async () => {
    await phone.locator('#machines .card', { hasText: 'table-sim' })
      .getByRole('button', { name: 'Open scratchpad' }).click();
    await phone.locator('#pad-status[data-state="connected"]').waitFor();
  });

  await step('running a program holds its code and placement on the machine', async () => {
    await phone.locator('#code').fill('Wish $this is labelled "hi there"\nWish $this is outlined red');
    await phone.getByRole('button', { name: 'Run on the table' }).click();
    await machine.waitForFunction(() => {
      const client = [...window.connect.sim.clients.values()][0];
      return client?.holds.get('code')?.code?.includes('hi there') &&
        client.holds.get('quad')?.place?.width === 0.3;
    });
    const canvas = await machine.locator('#sim-statements').textContent();
    assert.match(canvas, /Wish web-program-connect-phone-\w+ has a canvas/);
  });

  await step('touches arrive as statements, and go away when the finger lifts', async () => {
    const box = await phone.locator('#surface').boundingBox();
    await phone.mouse.move(box.x + box.width * 0.1, box.y + box.height * 0.8);
    await phone.mouse.down();
    await machine.waitForFunction(() =>
      /Claim phone has touch \d+ at \{0\.1\d* 0\.8\d*\}/.test(
        document.querySelector('#sim-statements').textContent));
    await phone.mouse.up();
    await machine.waitForFunction(() =>
      !document.querySelector('#sim-statements').textContent.includes('has touch'));
  });

  await step('dragging the program moves it on the machine', async () => {
    const box = await phone.locator('#program').boundingBox();
    await phone.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await phone.mouse.down();
    await phone.mouse.move(box.x + box.width / 2 + 60, box.y + box.height / 2 + 30, { steps: 4 });
    await phone.mouse.up();
    await machine.waitForFunction(() => {
      const place = [...window.connect.sim.clients.values()][0]?.holds.get('quad')?.place;
      return place && place.x > 0.36 && place.y > 0.31;
    });
    assert.ok(!(await machine.locator('#sim-statements').textContent()).includes('has touch'));
  });

  await step('mic level is sent while its toggle is on', async () => {
    await phone.locator('#send-mic').check();
    await machine.waitForFunction(() =>
      /Claim phone has audio level [\d.]+/.test(document.querySelector('#sim-statements').textContent));
    await phone.locator('#send-mic').uncheck();
    await machine.waitForFunction(() =>
      !document.querySelector('#sim-statements').textContent.includes('audio level'));
  });

  await step('leaving the scratchpad releases everything it held', async () => {
    await phone.getByRole('button', { name: 'Back' }).click();
    await machine.waitForFunction(() => window.connect.sim.clients.size === 0);
    await phone.locator('#home').waitFor();
  });

  const playing = (page, selector) => page.waitForFunction((sel) => {
    const video = document.querySelector(sel);
    return video && video.videoWidth > 0 && !video.paused;
  }, selector);

  await step('one browser can share its camera with another', async () => {
    await phone.locator('#people .card', { hasText: 'friend' })
      .getByRole('button', { name: 'Share camera' }).click();
    await playing(friend, '#people .card video');
    await phone.locator('#people .card button[data-action="camera"][aria-pressed="true"]').waitFor();
  });

  await step('the other side can share back over the same link', async () => {
    await friend.locator('#people .card', { hasText: 'phone' })
      .getByRole('button', { name: 'Share camera' }).click();
    await playing(phone, '#people .card video');
    assert.equal(await phone.evaluate(() => window.connect.state.links.size), 1);
  });

  await step('stopping a share removes the video on the other side', async () => {
    await phone.locator('#people .card button[data-action="camera"]').click();
    await friend.waitForFunction(() => !document.querySelector('#people .card video'));
  });

  await step('media can be shared to a simulated machine', async () => {
    await friend.locator('#machines .card', { hasText: 'table-sim' })
      .getByRole('button', { name: 'Share camera' }).click();
    await playing(machine, '#sim-media video');
  });

  await step('a named room is separate from the network room', async () => {
    const elsewhere = await open('/#attic', 'visitor');
    await elsewhere.locator('#status[data-state="up"]').waitFor();
    assert.equal(await elsewhere.locator('#status-text').textContent(), 'attic');
    assert.equal(await elsewhere.locator('.card').count(), 0);
  });

  await step('a peer that leaves disappears from the room', async () => {
    await friend.close();
    await phone.waitForFunction(() =>
      ![...document.querySelectorAll('#people .card')].some((c) => c.textContent.includes('friend')));
  });
} finally {
  await browser.close();
  await server.close();
}

process.exit(failed ? 1 : 0);
