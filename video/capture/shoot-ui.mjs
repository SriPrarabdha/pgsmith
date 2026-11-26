// Real Flagsmith UI takes for the launch video:  node capture/shoot-ui.mjs <shot> [<shot> ...]
import {open, go, glide, glideClick, findText, smoothScroll, record, sleep, P, CURSOR_JS} from './ui.mjs';
import {spawn} from 'node:child_process';
const OUT = 'public/ui';
const shots = {
  // A: change a flag in Flagsmith while Postgres is watched
  async flip(page) {
    await go(page, P + '/features');
    const w = spawn('../.venv/bin/python', ['capture/watch.py', `${OUT}/flip.watch.json`, 'pricing_banner', 'user-42'], {stdio: 'inherit'});
    await sleep(1500);
    const rec = await record(page, `${OUT}/flip.mp4`);
    await glide(page, 700, 600, 500); await sleep(400);
    await glideClick(page, 'pricing_banner', {exact: true, wait: 1400});
    const v = await findText(page, 'summer', {exact: true, within: '.modal, [role=dialog], body'});
    rec.mark('edit');
    await glide(page, v.x + 60, v.y, 600); await page.mouse.down(); await sleep(60); await page.mouse.up(); await sleep(250);
    await page.keyboard.down('Control'); await page.keyboard.press('a'); await page.keyboard.up('Control');
    await page.keyboard.type('black_friday', {delay: 75}); await sleep(500);
    const b = await findText(page, 'Update Feature Value', {exact: true});
    await glide(page, b.x, b.y, 650); await sleep(300);
    rec.mark('save'); const tSave = Date.now();
    await page.mouse.down(); await sleep(70); await page.mouse.up();
    await sleep(4000);
    const r = await rec.stop();
    w.kill('SIGTERM'); await sleep(600);
    console.log('flip', r, 'save wall', tSave);
  },
  // B: the multivariate flag and its 50/50 split
  async mv(page) {
    await go(page, P + '/features');
    const rec = await record(page, `${OUT}/mv.mp4`);
    await glide(page, 600, 500, 400); await sleep(300);
    rec.mark('open');
    await glideClick(page, 'search_ranking', {exact: true, wait: 1500});
    await glide(page, 1040, 560, 600);
    rec.mark('scroll');
    await smoothScroll(page, 330, 1300);
    await sleep(500);
    const w = await findText(page, 'Environment Weight %', {exact: true});
    if (w) await glide(page, w.x + 560, w.y, 700);
    await sleep(2200);
    console.log('mv', await rec.stop());
  },
  // C: the metrics the experiment reads
  async metrics(page) {
    await go(page, P + '/metrics');
    const rec = await record(page, `${OUT}/metrics.mp4`);
    await glide(page, 900, 300, 300);
    for (const t of ['Search result clicked', 'Add to cart', 'Search latency (ms)']) {
      const p = await findText(page, t, {exact: true}); await glide(page, p.x + 40, p.y + 8, 650); rec.mark(t); await sleep(650);
    }
    await sleep(800);
    console.log('metrics', await rec.stop());
  },
  // D: the experiment's results
  async results(page) {
    await go(page, P + '/experiments/1'); await sleep(1200);
    const rec = await record(page, `${OUT}/results.mp4`);
    await glide(page, 900, 450, 300); await sleep(600);
    const lift = await findText(page, '+22.6%', {exact: true});
    rec.mark('banner');
    const ban = await findText(page, 'Winner Probability Confirmed');
    if (ban) await glide(page, ban.x + 120, ban.y + 4, 700);
    await sleep(1400);
    rec.mark('scroll');
    await glide(page, 900, 600, 400);
    await smoothScroll(page, 560, 1500);
    await sleep(500);
    rec.mark('table');
    const t = await findText(page, '[19.4%, 25.8%]') || await findText(page, 'boosted', {exact: true});
    if (t) await glide(page, t.x, t.y, 800);
    await sleep(2500);
    console.log('results', await rec.stop());
  },
  // E: ship the winner (irreversible: completes the experiment)
  async ship(page) {
    await go(page, P + '/experiments/1'); await sleep(1200);
    const rec = await record(page, `${OUT}/ship.mp4`);
    await glide(page, 900, 300, 300); await sleep(500);
    rec.mark('end');
    await glideClick(page, 'End Experiment', {exact: true, tag: 'button', wait: 1300});
    const opt = await findText(page, '> 99% chance to win');
    if (opt) { await glide(page, opt.x, opt.y, 700); await sleep(700); }
    const sum = await findText(page, '100% of users');
    if (sum) { await glide(page, sum.x, sum.y, 600); await sleep(900); }
    rec.mark('complete');
    await glideClick(page, 'Complete experiment', {exact: true, tag: 'button', wait: 2500});
    await sleep(1500);
    console.log('ship', await rec.stop());
  },
  // F: after shipping: the completed experiment
  async shipped(page) {
    await go(page, P + '/experiments/1'); await sleep(1500);
    const rec = await record(page, `${OUT}/shipped.mp4`);
    await glide(page, 700, 300, 300); await sleep(400);
    const st = await findText(page, 'Completed', {exact: true});
    if (st) await glide(page, st.x, st.y + 6, 800);
    await sleep(2500);
    console.log('shipped', await rec.stop());
  },
};
const {browser, page} = await open({width: 1440, height: 810, scale: 2});
await page.evaluateOnNewDocument(CURSOR_JS);
for (const s of process.argv.slice(2)) { await shots[s](page); }
await browser.close();
