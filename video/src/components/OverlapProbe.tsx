// Debug only (inputProps.probe): after each frame renders, find visible text that collides with other
// text or with a UI recording, and log it for probe.mjs. Nothing is drawn.
import {useLayoutEffect} from 'react';
import {useCurrentFrame} from 'remotion';

type Box = {x0: number; y0: number; x1: number; y1: number; label: string; el: Element; kind: 'text' | 'media'};

function visible(el: Element): number {
  let op = 1;
  for (let e: Element | null = el; e && e !== document.body; e = e.parentElement) {
    const cs = getComputedStyle(e);
    if (cs.display === 'none' || cs.visibility === 'hidden') return 0;
    op *= parseFloat(cs.opacity || '1');
  }
  return op;
}

function clip(r: {x0: number; y0: number; x1: number; y1: number}, el: Element) {
  let {x0, y0, x1, y1} = r;
  for (let e: Element | null = el.parentElement; e && e !== document.body; e = e.parentElement) {
    const cs = getComputedStyle(e);
    if (cs.overflow !== 'visible' || cs.overflowX !== 'visible' || cs.overflowY !== 'visible') {
      const c = e.getBoundingClientRect();
      x0 = Math.max(x0, c.left); y0 = Math.max(y0, c.top); x1 = Math.min(x1, c.right); y1 = Math.min(y1, c.bottom);
    }
  }
  x0 = Math.max(x0, 0); y0 = Math.max(y0, 0); x1 = Math.min(x1, 1920); y1 = Math.min(y1, 1080);
  return x1 > x0 && y1 > y0 ? {x0, y0, x1, y1} : null;
}

export const OverlapProbe: React.FC = () => {
  const frame = useCurrentFrame();
  useLayoutEffect(() => {
    const boxes: Box[] = [];
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      const t = (n.textContent || '').trim();
      if (!t || !n.parentElement || visible(n.parentElement) < 0.2) continue;
      const range = document.createRange();
      range.selectNodeContents(n);
      for (const r of Array.from(range.getClientRects())) {
        if (r.width < 2 || r.height < 2) continue;
        // glyph box: shrink to the middle 70% of the line height so neighbouring lines do not count
        const pad = r.height * 0.15;
        const c = clip({x0: r.left, y0: r.top + pad, x1: r.right, y1: r.bottom - pad}, n.parentElement);
        if (c) boxes.push({...c, label: t.slice(0, 60), el: n.parentElement, kind: 'text'});
      }
    }
    document.querySelectorAll('[data-ov]').forEach(el => {
      if (visible(el) < 0.2) return;
      const r = el.getBoundingClientRect();
      const c = clip({x0: r.left, y0: r.top, x1: r.right, y1: r.bottom}, el);
      if (c) boxes.push({...c, label: `[${el.getAttribute('data-ov')}]`, el, kind: 'media'});
    });
    const hits: string[] = [];
    for (let i = 0; i < boxes.length; i++) {
      for (let j = i + 1; j < boxes.length; j++) {
        const a = boxes[i], b = boxes[j];
        if (a.el === b.el || a.el.contains(b.el) || b.el.contains(a.el)) continue;
        if (a.kind === 'media' && b.kind === 'media') continue;
        const w = Math.min(a.x1, b.x1) - Math.max(a.x0, b.x0), h = Math.min(a.y1, b.y1) - Math.max(a.y0, b.y0);
        if (w > 3 && h > 3 && w * h > 60) hits.push(`${a.label} <> ${b.label}`);
      }
    }
    if (hits.length) console.log('OVERLAP ' + JSON.stringify({frame, hits: [...new Set(hits)].slice(0, 40)}));
  });
  return null;
};
