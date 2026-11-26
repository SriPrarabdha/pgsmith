// A small SQL code card with syntax colouring, typed reveal and highlighted lines.
import React from 'react';
import {useCurrentFrame} from 'remotion';
import {C, mono} from '../theme';
import {Window} from './Window';

const KW = /\b(SELECT|FROM|WHERE|WITH|AS|MATERIALIZED|ORDER|BY|CASE|WHEN|THEN|ELSE|END|DESC|LIMIT|LANGUAGE|STABLE|RETURNS|TABLE|CREATE|FUNCTION|OR|REPLACE|AND|GROUP|INSERT|INTO|VALUES|JOIN|ON|LATERAL)\b/g;
function colour(line: string): React.ReactNode[] {
  const out: React.ReactNode[] = [];
  const re = /(--.*$)|('[^']*')|\b(flagsmith\.[a-z_]+|shop\.[a-z_]+|coalesce|ts_rank|ln|websearch_to_tsquery)\b|\b(SELECT|FROM|WHERE|WITH|AS|MATERIALIZED|ORDER|BY|CASE|WHEN|THEN|ELSE|END|DESC|LIMIT|LANGUAGE|STABLE|RETURNS|TABLE|CREATE|FUNCTION|AND|GROUP|JOIN|ON)\b|(\b\d+(\.\d+)?\b)/g;
  let i = 0, m: RegExpExecArray | null, k = 0;
  while ((m = re.exec(line))) {
    if (m.index > i) out.push(line.slice(i, m.index));
    const [s] = m;
    const color = m[1] ? C.dim : m[2] ? C.green : m[3] ? C.blue : m[4] ? C.purple2 : C.amber;
    out.push(<span key={k++} style={{color, fontStyle: m[1] ? 'italic' : undefined, fontWeight: m[4] ? 600 : undefined}}>{s}</span>);
    i = m.index + s.length;
  }
  if (i < line.length) out.push(line.slice(i));
  void KW;
  return out;
}

export const Code: React.FC<{code: string; width: number | string; height?: number | string; title?: string; fontSize?: number;
  start?: number; cps?: number; highlight?: {lines: number[]; from: number; color?: string}[]; style?: React.CSSProperties}> =
  ({code, width, height, title = 'sql', fontSize = 24, start = 0, cps = 0, highlight = [], style}) => {
  const f = useCurrentFrame() - start;
  const shown = cps > 0 ? code.slice(0, Math.max(0, Math.floor(f * cps))) : code;
  const lines = shown.split('\n');
  return (
    <Window title={title} width={width} height={height} style={style}>
      <div style={{padding: '22px 26px', fontFamily: mono, fontSize, lineHeight: `${fontSize * 1.5}px`, color: C.text}}>
        {lines.map((l, i) => {
          const h = highlight.find(h => h.lines.includes(i) && f >= h.from);
          return (
            <div key={i} style={{whiteSpace: 'pre', borderRadius: 6, background: h ? (h.color ?? 'rgba(139,92,246,.22)') : undefined,
              boxShadow: h ? `0 0 0 5px ${h.color ?? 'rgba(139,92,246,.22)'}` : undefined}}>{colour(l)}{l === '' ? ' ' : ''}</div>
          );
        })}
      </div>
    </Window>
  );
};
