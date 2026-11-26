// Shared helpers for driving the local Flagsmith UI with headless Chrome.
import puppeteer from 'puppeteer-core';
import fs from 'node:fs';
export const env = Object.fromEntries(fs.readFileSync('../demos/.env', 'utf8').trim().split('\n').map(l => l.split(/=(.*)/s).slice(0, 2)));
export const BASE = 'http://localhost:8000';
export const P = `/project/${env.FLAGSMITH_PROJECT_ID}/environment/${env.PROD_CLIENT_KEY}`;
export const S = `/project/${env.FLAGSMITH_PROJECT_ID}/environment/${env.STAGING_CLIENT_KEY}`;
export const sleep = ms => new Promise(r => setTimeout(r, ms));

export async function open({width = 1440, height = 810, scale = 1} = {}) {
  const browser = await puppeteer.launch({executablePath: '/usr/bin/google-chrome', headless: 'new',
    args: ['--no-sandbox', `--window-size=${width},${height}`, '--hide-scrollbars', '--force-color-profile=srgb', `--force-device-scale-factor=${scale}`],
    defaultViewport: {width, height, deviceScaleFactor: scale}});
  const page = await browser.newPage();
  // the UI phones home (its own flags, analytics); keep it local so it loads fast and deterministic
  await page.setRequestInterception(true);
  page.on('request', r => {
    const u = r.url();
    if (/^(https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?\/|data:|blob:)/.test(u)) return r.continue();
    if (u.includes('api.flagsmith.com')) return r.respond({status: 200, contentType: 'application/json',
      headers: {'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*'}, body: u.includes('/identities') ? '{"flags":[],"traits":[]}' : '[]'});
    return r.abort();
  });
  await page.goto(BASE + '/', {waitUntil: 'networkidle2'});
  await page.waitForSelector('input[type="password"]', {timeout: 15000});
  await page.click('#email');
  await page.keyboard.type('admin@pgflagsmith.local');
  await page.click('input[type="password"]');
  await page.keyboard.type('Sup3r-Secret-Demo!');
  await page.keyboard.press('Enter');
  await page.waitForFunction(() => !document.querySelector('input[type="password"]'), {timeout: 20000});
  await page.waitForNetworkIdle({idleTime: 500}).catch(() => {});
  return {browser, page};
}

export async function go(page, path) {
  await page.goto(BASE + path, {waitUntil: 'networkidle2'});
  await sleep(800);
}

// Find the smallest visible element whose text matches, return its centre.
export async function findText(page, text, {exact = false, within = 'body', tag = '*'} = {}) {
  return page.evaluate((text, exact, within, tag) => {
    const root = document.querySelector(within) || document.body;
    const all = [...root.querySelectorAll(tag)].filter(e => {
      const t = (e.innerText || '').trim();
      if (!(exact ? t === text : t.includes(text))) return false;
      const r = e.getBoundingClientRect();
      return r.width > 0 && r.height > 0;
    });
    all.sort((a, b) => a.innerText.length - b.innerText.length || b.querySelectorAll('*').length - a.querySelectorAll('*').length);
    const e = all[0];
    if (!e) return null;
    const r = e.getBoundingClientRect();
    return {x: r.x + r.width / 2, y: r.y + r.height / 2, w: r.width, h: r.height, tag: e.tagName};
  }, text, exact, within, tag);
}

export async function clickText(page, text, opts = {}) {
  const p = await findText(page, text, opts);
  if (!p) throw new Error(`text not found: ${text}`);
  await page.mouse.click(p.x, p.y);
  await sleep(opts.wait ?? 900);
  return p;
}

// ---- recording helpers -------------------------------------------------------
// A visible cursor (headless Chrome draws none) and a click ripple, injected into every page.
export const CURSOR_JS = `
(() => {
  if (window.__cursor) return; window.__cursor = true;
  const add = () => {
    const c = document.createElement('div');
    c.id = '__cursor';
    c.innerHTML = '<svg width="28" height="28" viewBox="0 0 28 28"><path d="M5 3 L5 22 L10 17.5 L13.5 25 L16.8 23.6 L13.4 16.2 L20 16.2 Z" fill="#111" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg>';
    Object.assign(c.style, {position: 'fixed', left: '0px', top: '0px', zIndex: 2147483647, pointerEvents: 'none',
      transform: 'translate(-5px,-3px)', filter: 'drop-shadow(0 2px 3px rgba(0,0,0,.35))'});
    document.documentElement.appendChild(c);
    const st = document.createElement('style');
    st.textContent = '@keyframes __rip{from{transform:translate(-50%,-50%) scale(.2);opacity:.55}to{transform:translate(-50%,-50%) scale(1);opacity:0}}';
    document.documentElement.appendChild(st);
    addEventListener('mousemove', e => { c.style.left = e.clientX + 'px'; c.style.top = e.clientY + 'px'; }, true);
    addEventListener('mousedown', e => {
      const r = document.createElement('div');
      Object.assign(r.style, {position: 'fixed', left: e.clientX + 'px', top: e.clientY + 'px', width: '56px', height: '56px',
        borderRadius: '50%', background: 'rgba(124,58,237,.45)', zIndex: 2147483646, pointerEvents: 'none',
        animation: '__rip .5s ease-out forwards'});
      document.documentElement.appendChild(r); setTimeout(() => r.remove(), 600);
    }, true);
  };
  if (document.documentElement) add(); else addEventListener('DOMContentLoaded', add);
})();`;

let mouse = {x: 720, y: 405};
const ease = t => t < .5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
export async function glide(page, x, y, ms = 700) {
  const from = {...mouse}, steps = Math.max(8, Math.round(ms / 16));
  for (let i = 1; i <= steps; i++) {
    const t = ease(i / steps);
    await page.mouse.move(from.x + (x - from.x) * t, from.y + (y - from.y) * t);
    await sleep(ms / steps);
  }
  mouse = {x, y};
}
export async function glideClick(page, text, opts = {}) {
  const p = await findText(page, text, opts);
  if (!p) throw new Error(`text not found: ${text}`);
  const x = p.x + (opts.dx ?? 0), y = p.y + (opts.dy ?? 0);
  await glide(page, x, y, opts.ms ?? 700);
  await sleep(opts.hover ?? 250);
  await page.mouse.down(); await sleep(70); await page.mouse.up();
  await sleep(opts.wait ?? 900);
  return p;
}
export async function smoothScroll(page, dy, ms = 1200) {
  const steps = Math.round(ms / 16);
  let done = 0;
  for (let i = 1; i <= steps; i++) {
    const target = Math.round(dy * ease(i / steps));
    await page.mouse.wheel({deltaY: target - done}); done = target;
    await sleep(ms / steps);
  }
}

// Record the page with Chrome's screencast: every painted frame is saved with its timestamp, then
// assembled into a constant-30-fps H.264 file. Returns stop() -> {file, t0, events}; t0 = wall clock (ms)
// of the first frame, and mark(name) logs events relative to it (for syncing overlays in the edit).
import {execFileSync} from 'node:child_process';
import path from 'node:path';
export async function record(page, file, {quality = 92} = {}) {
  const dir = file.replace(/\.mp4$/, '.frames');
  fs.rmSync(dir, {recursive: true, force: true}); fs.mkdirSync(dir, {recursive: true});
  const cdp = await page.createCDPSession();
  const frames = [];
  cdp.on('Page.screencastFrame', async ({data, metadata, sessionId}) => {
    const n = frames.length, f = path.join(dir, `${String(n).padStart(6, '0')}.jpg`);
    fs.writeFileSync(f, Buffer.from(data, 'base64'));
    frames.push({f, t: metadata.timestamp * 1000});
    cdp.send('Page.screencastFrameAck', {sessionId}).catch(() => {});
  });
  const vp = page.viewport();
  await cdp.send('Page.startScreencast', {format: 'jpeg', quality, everyNthFrame: 1,
    maxWidth: Math.round(vp.width * (vp.deviceScaleFactor || 1)), maxHeight: Math.round(vp.height * (vp.deviceScaleFactor || 1))});
  const wall0 = Date.now();
  const events = [];
  const rec = {
    mark(name) { events.push({name, t: (Date.now() - wall0) / 1000}); },
    async stop() {
      await sleep(300);
      await cdp.send('Page.stopScreencast');
      await sleep(200);
      if (!frames.length) throw new Error('no frames');
      // frame i lasts until frame i+1 (last one: 0.5 s); timestamps relative to wall0
      const t0 = frames[0].t, lines = [];
      const lead = (t0 - wall0) / 1000;
      frames.forEach((fr, i) => {
        const next = i + 1 < frames.length ? frames[i + 1].t : fr.t + 500;
        lines.push(`file '${path.resolve(fr.f)}'`, `duration ${((next - fr.t) / 1000).toFixed(4)}`);
      });
      lines.push(`file '${path.resolve(frames.at(-1).f)}'`);
      fs.writeFileSync(dir + '/list.txt', lines.join('\n'));
      execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', dir + '/list.txt',
        '-vf', 'fps=30,scale=trunc(iw/2)*2:trunc(ih/2)*2', '-c:v', 'libx264', '-preset', 'slow', '-crf', '14',
        '-pix_fmt', 'yuv420p', file]);
      // events relative to the first frame
      const evs = events.map(e => ({name: e.name, t: +(e.t - lead).toFixed(3)}));
      fs.writeFileSync(file.replace(/\.mp4$/, '.json'), JSON.stringify({file, frames: frames.length, wall0: wall0 + lead * 1000, events: evs}, null, 1));
      fs.rmSync(dir, {recursive: true, force: true});
      return {file, frames: frames.length, events: evs, wall0: wall0 + lead * 1000};
    },
  };
  return rec;
}
