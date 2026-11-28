import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {Background} from '../components/Background';
import {Kicker} from '../components/Brand';
import {enter, fmt, pop, t01} from '../components/anim';
import {cue} from '../timeline';
import {C, sans} from '../theme';

type Tile = {v: number; fmt: (n: number) => string; label: string; sub: string; at: string; color?: string};
const TILES: Tile[] = [
  {v: 230, fmt: n => `${Math.round(n)}/230`, label: "Flagsmith's engine test suite", sub: 'engine-test-data v3.13.2', at: 'It passes', color: C.green},
  {v: 5000, fmt: n => fmt(n), label: 'random configurations, 0 differences', sub: 'vs the official engine (flag-engine 11.1.2)', at: 'five thousand', color: C.green},
  {v: 10000, fmt: n => fmt(n), label: 'live identities, 0 mismatches', sub: 'vs self-hosted Flagsmith, through the SDK', at: 'matches the official', color: C.green},
  {v: 5.95, fmt: n => `${n.toFixed(2)} s`, label: '1M users × 50 flags', sub: '8.4M flag evaluations per second', at: 'a million users'},
  {v: 47, fmt: n => `${Math.round(n)} µs`, label: 'one user, all 50 flags', sub: 'official Python engine: 204 µs', at: 'fifty flags'},
  {v: 18, fmt: n => `14–${Math.max(14, Math.round(n))}`, label: 'PostgreSQL versions in CI', sub: '+ Supabase and RDS via pg_tle', at: 'six seconds'},
];

export const Proof: React.FC = () => {
  const f = useCurrentFrame();
  return (
    <AbsoluteFill>
      <Background intensity={1.2} />
      <Kicker style={{position: 'absolute', top: 90, left: 0, right: 0, textAlign: 'center', ...enter(f, 0)}}>Same answers as Flagsmith. Fast.</Kicker>
      <div style={{position: 'absolute', left: 120, right: 120, top: 190, display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 30}}>
        {TILES.map(t => {
          const at = cue('proof', t.at) - 6;
          const p = pop(f, at);
          const n = t.v * t01(f, at, 34);
          return (
            <div key={t.label} style={{height: 330, borderRadius: 26, padding: 34, background: C.panel, border: `1px solid ${t.color ? `${t.color}44` : C.line}`,
              transform: `scale(${0.85 + 0.15 * p})`, opacity: Math.min(1, p * 1.3), boxShadow: '0 30px 80px rgba(0,0,0,.45)', display: 'flex', flexDirection: 'column', justifyContent: 'flex-end'}}>
              <div style={{fontFamily: sans, fontSize: 92, fontWeight: 900, color: t.color ?? C.text, letterSpacing: -2, lineHeight: 1}}>{t.fmt(n)}</div>
              <div style={{fontFamily: sans, fontSize: 30, fontWeight: 700, color: C.text, marginTop: 18}}>{t.label}</div>
              <div style={{fontFamily: sans, fontSize: 21, color: C.muted, marginTop: 8}}>{t.sub}</div>
            </div>
          );
        })}
      </div>
    </AbsoluteFill>
  );
};
