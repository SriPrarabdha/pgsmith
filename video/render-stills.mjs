// Render selected frames of the Launch composition to out/stills/ (one bundle, many stills).
import {bundle} from '@remotion/bundler';
import {renderStill, selectComposition} from '@remotion/renderer';
import path from 'node:path';
const frames = process.argv.slice(2).map(Number);
const serveUrl = await bundle({entryPoint: path.resolve('src/index.ts')});
const comp = await selectComposition({serveUrl, id: 'Launch', inputProps: {}, browserExecutable: '/usr/bin/google-chrome'});
for (const frame of frames) {
  const out = `out/stills/f${String(frame).padStart(5, '0')}.jpg`;
  await renderStill({composition: comp, serveUrl, output: out, frame, imageFormat: 'jpeg', jpegQuality: 85, browserExecutable: '/usr/bin/google-chrome', scale: 0.5});
  console.log(out);
}
