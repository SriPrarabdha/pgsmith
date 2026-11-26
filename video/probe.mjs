// Render every Nth frame with the overlap probe on and report text collisions per scene.
import {bundle} from '@remotion/bundler';
import {renderFrames, selectComposition} from '@remotion/renderer';
import fs from 'node:fs';
import path from 'node:path';
const every = Number(process.argv[2] || 6);
const scenes = JSON.parse(fs.readFileSync('music/scenes.json'));
const serveUrl = await bundle({entryPoint: path.resolve('src/index.ts')});
const inputProps = {probe: true, music: null};
const composition = await selectComposition({serveUrl, id: 'Launch', inputProps, browserExecutable: '/usr/bin/google-chrome'});
const hits = [];
fs.rmSync('out/probe', {recursive: true, force: true});
await renderFrames({composition, serveUrl, inputProps, outputDir: 'out/probe', imageFormat: 'jpeg', jpegQuality: 30, scale: 0.25,
  everyNthFrame: every, concurrency: 16, browserExecutable: '/usr/bin/google-chrome', muted: true,
  onStart: () => {}, onFrameUpdate: () => {},
  onBrowserLog: ({text}) => { if (text.startsWith('OVERLAP ')) hits.push(JSON.parse(text.slice(8))); }});
const byScene = {};
for (const h of hits.sort((a, b) => a.frame - b.frame)) {
  const s = scenes.findLast(s => s.start * 30 <= h.frame) || scenes[0];
  for (const x of h.hits) {
    const k = `${s.id}: ${x}`;
    (byScene[k] ||= []).push(h.frame);
  }
}
const lines = Object.entries(byScene).map(([k, fr]) => `${k}   frames ${fr[0]}–${fr.at(-1)} (${fr.length}×, t=${(fr[0] / 30).toFixed(1)}s)`);
fs.writeFileSync('out/overlaps.txt', lines.join('\n') + '\n');
console.log(lines.length ? lines.join('\n') : 'no overlaps');
