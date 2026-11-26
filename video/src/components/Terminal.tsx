// A terminal that replays commands and the output they really printed (src/data/term/*.json,
// captured by capture/term.py against the demo stack).
import React from 'react';
import {useCurrentFrame} from 'remotion';
import {C, mono} from '../theme';
import {Window} from './Window';

export type TermItem = {prompt: string; command: string; output: string; ms?: number};
export type Rule = {
  match: string | RegExp;
  color?: string;
  bg?: string;          // background on the matched text
  lineBg?: string;      // background on the whole line
  weight?: number;
  from?: number;        // frame (in the terminal's clock) when the rule switches on
};
export type Timing = {typeStart: number; typeEnd: number; outStart: number; outEnd: number; lines: number};
type Opts = {cps?: number; lpf?: number; gap?: number; execMax?: number};

const DROP = /^(Timing is on\.|Time: 0\.\d+ ms|SET)$/;
export const outLines = (o: string) => o.split('\n').filter(l => !DROP.test(l.trim()));

export function schedule(items: TermItem[], {cps = 2.2, lpf = 0.6, gap = 14, execMax = 18}: Opts = {}): Timing[] {
  let t = 0;
  return items.map(it => {
    const typeStart = t;
    const typeEnd = typeStart + Math.ceil(it.command.length / cps);
    const exec = Math.min(execMax, Math.max(5, Math.round((it.ms ?? 100) / 33)));
    const lines = outLines(it.output).length;
    const outStart = typeEnd + exec;
    const outEnd = outStart + Math.ceil(lines / lpf);
    t = outEnd + gap;
    return {typeStart, typeEnd, outStart, outEnd, lines};
  });
}

function baseStyle(line: string, isHeaderOfTable: boolean): React.CSSProperties {
  const s = line.trim();
  if (isHeaderOfTable) return {color: C.purple2, fontWeight: 700};
  if (/^-+(\+-+)*$/.test(s)) return {color: C.dim};
  if (/^\(\d+ rows?\)$/.test(s)) return {color: C.dim};
  if (/^Time: /.test(s)) return {color: C.green};
  if (/^~ /.test(s)) return {color: C.amber, fontWeight: 700};
  if (/^= /.test(s)) return {color: C.muted};
  if (/^! /.test(s)) return {color: '#FCD34D', fontStyle: 'italic'};
  if (/^e\.g\. /.test(s)) return {color: C.dim};
  if (/^Verified/.test(s)) return {color: C.green, fontWeight: 700};
  if (/^applied /.test(s)) return {color: C.blue};
  if (/^Plan: /.test(s)) return {color: C.text, fontWeight: 700};
  if (/^flagshift plan/.test(s)) return {color: C.purple2, fontWeight: 700};
  if (/^parity OK/.test(s)) return {color: C.green, fontWeight: 700};
  if (/Container .* (Stopped|Stopping)/.test(s)) return {color: C.red};
  return {color: C.text};
}

function renderLine(line: string, rules: Rule[], f: number, key: string, header: boolean) {
  const active = rules.filter(r => (r.from ?? -1) <= f && (typeof r.match === 'string' ? line.includes(r.match) : r.match.test(line)));
  const lineBg = active.find(r => r.lineBg)?.lineBg;
  let parts: (string | React.ReactElement)[] = [line || ' '];
  for (const r of active) {
    if (!r.color && !r.bg && !r.weight) continue;
    const re = typeof r.match === 'string' ? new RegExp(r.match.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')) : r.match;
    parts = parts.flatMap((p, i): (string | React.ReactElement)[] => {
      if (typeof p !== 'string') return [p];
      const m = p.match(re);
      if (!m || m.index === undefined) return [p];
      return [p.slice(0, m.index),
        <span key={`${key}-${i}`} style={{color: r.color, background: r.bg, fontWeight: r.weight, borderRadius: 4, padding: r.bg ? '0 3px' : 0, margin: r.bg ? '0 -3px' : 0}}>{m[0]}</span>,
        p.slice(m.index + m[0].length)];
    });
  }
  return (
    <div key={key} style={{whiteSpace: 'pre', ...baseStyle(line, header), background: lineBg, borderRadius: 6,
      boxShadow: lineBg ? `0 0 0 4px ${lineBg}` : undefined}}>{parts}</div>
  );
}

export const Terminal: React.FC<{
  items: TermItem[]; start?: number; opts?: Opts; rules?: Rule[]; fontSize?: number;
  width: number | string; height: number | string; title?: string; maxLines?: number; style?: React.CSSProperties;
  promptColor?: string; finalPrompt?: boolean; padding?: number;
}> = ({items, start = 0, opts, rules = [], fontSize = 22, width, height, title = 'psql · postgres@supabase', maxLines, style, finalPrompt = true, padding = 26}) => {
  const f = useCurrentFrame() - start;
  const tm = schedule(items, opts);
  const rows: React.ReactNode[] = [];
  items.forEach((it, i) => {
    const t = tm[i];
    if (f < t.typeStart) return;
    const typed = it.command.slice(0, Math.max(0, Math.floor((f - t.typeStart) * (opts?.cps ?? 2.2))));
    const typing = f < t.typeEnd;
    const cmdLines = typed.split('\n');
    cmdLines.forEach((cl, j) => {
      const pr = j === 0 ? it.prompt : it.prompt === '$' ? ' ' : 'postgres-#';
      rows.push(
        <div key={`c${i}-${j}`} style={{whiteSpace: 'pre', color: C.text}}>
          <span style={{color: it.prompt === '$' ? C.green : C.purple2, fontWeight: 700}}>{pr}</span>{' '}{cl}
          {typing && j === cmdLines.length - 1 && <Cursor f={f} />}
        </div>);
    });
    if (f >= t.outStart) {
      const ls = outLines(it.output);
      const n = Math.min(ls.length, Math.floor((f - t.outStart) * (opts?.lpf ?? 0.6)) + 1);
      const tableHeaderIdx = ls.findIndex((l, k) => k + 1 < ls.length && /^-+(\+-+)+$/.test(ls[k + 1].trim()));
      ls.slice(0, n).forEach((l, k) => rows.push(renderLine(l, rules, f, `o${i}-${k}`, k === tableHeaderIdx)));
      if (i < items.length - 1 || f >= t.outEnd) rows.push(<div key={`sp${i}`} style={{height: fontSize * 0.6}} />);
    }
  });
  const last = tm[tm.length - 1];
  if (finalPrompt && last && f >= last.outEnd + 4) {
    rows.push(<div key="final" style={{whiteSpace: 'pre'}}><span style={{color: items.at(-1)!.prompt === '$' ? C.green : C.purple2, fontWeight: 700}}>{items.at(-1)!.prompt}</span> <Cursor f={f} /></div>);
  }
  const lineH = fontSize * 1.42;
  const visible = maxLines ?? Infinity;
  const shown = rows.length > visible ? rows.slice(rows.length - visible) : rows;
  return (
    <Window title={title} width={width} height={height} style={style}>
      <div style={{padding, fontFamily: mono, fontSize, lineHeight: `${lineH}px`, color: C.text}}>{shown}</div>
    </Window>
  );
};

const Cursor: React.FC<{f: number}> = ({f}) => (
  <span style={{display: 'inline-block', width: '0.6em', height: '1.1em', verticalAlign: 'text-bottom', marginLeft: 2,
    background: C.purple2, opacity: Math.floor(f / 15) % 2 === 0 ? 0.9 : 0.15}} />
);
