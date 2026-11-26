// dump scene timings (seconds) for the music generator: mirrors src/timeline.ts
import fs from 'node:fs';
const vo = JSON.parse(fs.readFileSync('src/data/vo.json'));
const src = fs.readFileSync('src/timeline.ts', 'utf8');
const defs = [...src.matchAll(/\{id: '(\w+)', vo: '(\w+)', lead: ([\d.]+), tail: ([\d.]+)\}/g)].map(m => ({id: m[1], vo: m[2], lead: +m[3], tail: +m[4]}));
let at = 0; const out = [];
for (const d of defs) { const fr = Math.round((d.lead + vo[d.vo].seconds + d.tail) * 30); out.push({id: d.id, start: at / 30, end: (at + fr) / 30, voStart: (at + Math.round(d.lead * 30)) / 30, voEnd: (at + Math.round(d.lead * 30) + Math.round(vo[d.vo].seconds * 30)) / 30}); at += fr; }
fs.writeFileSync('music/scenes.json', JSON.stringify(out, null, 1));
console.log(out.map(o => `${o.id}@${o.start.toFixed(1)}`).join(' '), 'total', (at / 30).toFixed(1));
