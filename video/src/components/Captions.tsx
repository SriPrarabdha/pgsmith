// Burned-in captions from the voice-over text, split into short phrases timed by length.
import React from 'react';
import {useCurrentFrame} from 'remotion';
import {C, sans} from '../theme';
import {t01} from './anim';

export function phrases(text: string, max = 56): {text: string; w: number}[] {
  const clean = text.replace(/\.\.\./g, '…').replace(/P G smith/g, 'pgsmith').replace(/Flag Shift/g, 'FlagShift').replace(/R D S/g, 'RDS');
  const words = clean.split(/\s+/);
  const out: string[] = [];
  let cur = '';
  for (const w of words) {
    const next = cur ? cur + ' ' + w : w;
    if (next.length > max && cur) { out.push(cur); cur = w; continue; }
    cur = next;
    if (/[.?!:…]$/.test(w) && cur.length > max * 0.45) { out.push(cur); cur = ''; }
  }
  if (cur) out.push(cur);
  // weight = characters + a pause for punctuation
  return out.map(p => ({text: p, w: p.length + (/[.?!…]$/.test(p) ? 10 : /[,:]$/.test(p) ? 5 : 0)}));
}

export const Captions: React.FC<{text: string; start: number; frames: number}> = ({text, start, frames}) => {
  const f = useCurrentFrame() - start;
  if (f < 0 || f > frames + 6) return null;
  const ps = phrases(text);
  const total = ps.reduce((a, p) => a + p.w, 0);
  let acc = 0, idx = ps.length - 1, at = 0;
  for (let i = 0; i < ps.length; i++) {
    const len = (ps[i].w / total) * frames;
    if (f < acc + len) { idx = i; at = acc; break; }
    acc += len;
  }
  const p = t01(f, at, 5);
  return (
    <div style={{position: 'absolute', left: 0, right: 0, bottom: 34, display: 'flex', justifyContent: 'center', pointerEvents: 'none'}}>
      <div style={{fontFamily: sans, fontSize: 34, fontWeight: 600, color: C.text, background: 'rgba(7,6,13,.78)',
        padding: '10px 22px', borderRadius: 14, border: `1px solid ${C.line}`, opacity: p, maxWidth: 1500, textAlign: 'center',
        letterSpacing: -0.2, backdropFilter: 'blur(6px)'}}>{ps[idx].text}</div>
    </div>
  );
};
