import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {Background} from '../components/Background';
import {Kicker, Pill} from '../components/Brand';
import {clamp, enter, pop, t01} from '../components/anim';
import {cue} from '../timeline';
import {C, mono, sans} from '../theme';

const card: React.CSSProperties = {background: C.panel, border: `1px solid ${C.line}`, borderRadius: 22, padding: 28,
  boxShadow: '0 30px 80px rgba(0,0,0,.45)'};

const SQL_THINGS: [string, string, string][] = [
  ['search ranking', 'ORDER BY relevance …', 'search ranking'],
  ['row-level security', 'CREATE POLICY …', 'row-level security'],
  ['nightly jobs', 'pg_cron · batch UPDATE …', 'nightly jobs'],
  ['reports', 'SELECT … GROUP BY plan', 'reports'],
];

export const Problem: React.FC = () => {
  const f = useCurrentFrame();
  const blind = cue('problem', 'None of it');
  const phase2 = cue('problem', 'And every flip');
  const out1 = t01(f, phase2 - 6, 14);
  return (
    <AbsoluteFill>
      <Background />
      <Kicker style={{position: 'absolute', top: 70, left: 120, ...enter(f, 0)}}>The problem</Kicker>
      {/* phase 1: the app can see flags, the database can't */}
      <AbsoluteFill style={{opacity: 1 - out1, transform: `translateY(${-out1 * 40}px)`}}>
        <div style={{position: 'absolute', left: 110, top: 300, width: 620, display: 'flex', flexDirection: 'column', gap: 30}}>
          <div style={{...card, ...enter(f, 6)}}>
            <div style={{fontFamily: sans, fontSize: 30, color: C.muted, fontWeight: 700}}>Your app</div>
            <div style={{fontFamily: mono, fontSize: 28, color: C.text, marginTop: 14}}>flagsmith.get_identity_flags(…)</div>
            <div style={{marginTop: 20}}><Pill color={C.green} size={26}>✓ Flagsmith SDK</Pill></div>
          </div>
          <div style={{...card, textAlign: 'center', ...enter(f, 14)}}>
            <div style={{fontFamily: sans, fontSize: 40, fontWeight: 800, color: C.text}}>Flagsmith</div>
            <div style={{fontFamily: sans, fontSize: 26, color: C.muted, marginTop: 6}}>your flags, segments, experiments</div>
          </div>
        </div>
        {/* link from Flagsmith to the database: cut */}
        <svg style={{position: 'absolute', left: 745, top: 530, overflow: 'visible'}} width={220} height={60}>
          <line x1={0} y1={30} x2={200 * t01(f, 30, 30)} y2={30} stroke={f > blind ? C.red : C.dim} strokeWidth={4} strokeDasharray="10 10" />
          {f > blind && <text x={86} y={44} fontSize={46} fontWeight={900} fill={C.red} fontFamily={sans}
            style={{transform: `scale(${pop(f, blind)})`, transformOrigin: '125px 30px'}}>✕</text>}
        </svg>
        <div style={{position: 'absolute', left: 975, top: 250, width: 840, ...card, padding: 34, ...enter(f, 10)}}>
          <div style={{display: 'flex', alignItems: 'center', gap: 16}}>
            <DbIcon />
            <div>
              <div style={{fontFamily: sans, fontSize: 34, fontWeight: 800, color: C.text}}>Your database</div>
              <div style={{fontFamily: sans, fontSize: 22, color: C.muted}}>where much of the product actually runs</div>
            </div>
          </div>
          <div style={{display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 18, marginTop: 28}}>
            {SQL_THINGS.map(([label, code, phrase]) => {
              const at = cue('problem', phrase) - 4;
              const p = pop(f, at);
              const dead = t01(f, blind + 2, 10);
              return (
                <div key={label} style={{position: 'relative', borderRadius: 16, padding: '20px 22px', background: C.panel2,
                  border: `1px solid ${dead > 0.5 ? `${C.red}66` : C.line}`, transform: `scale(${0.85 + 0.15 * p})`, opacity: p}}>
                  <div style={{fontFamily: sans, fontSize: 29, fontWeight: 700, color: C.text, textTransform: 'capitalize'}}>{label}</div>
                  <div style={{fontFamily: mono, fontSize: 20, color: C.muted, marginTop: 8}}>{code}</div>
                  <div style={{marginTop: 12, opacity: dead}}><Pill color={C.red} size={17}>✕ can't see flags</Pill></div>
                </div>
              );
            })}
          </div>
        </div>
      </AbsoluteFill>
      {/* phase 2: a flip hits everyone at once, unreviewed */}
      <Phase2 at={phase2} />
    </AbsoluteFill>
  );
};

const Phase2: React.FC<{at: number}> = ({at}) => {
  const f = useCurrentFrame();
  if (f < at - 4) return null;
  const flip = at + 14;
  const on = t01(f, flip, 6);
  const N = 22 * 8;
  return (
    <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', flexDirection: 'column', gap: 40, ...enter(f, at, 30)}}>
      <div style={{display: 'flex', alignItems: 'center', gap: 60}}>
        <div style={{display: 'flex', alignItems: 'center', gap: 22}}>
          <div style={{width: 150, height: 80, borderRadius: 40, background: on > 0.5 ? C.purple : '#3a3f4d', position: 'relative',
            boxShadow: on > 0.5 ? '0 0 40px rgba(139,92,246,.7)' : undefined}}>
            <div style={{position: 'absolute', top: 8, left: 8 + on * 70, width: 64, height: 64, borderRadius: 32, background: '#fff'}} />
          </div>
          <div style={{fontFamily: mono, fontSize: 34, color: C.text}}>new_checkout</div>
        </div>
        <div style={{display: 'grid', gridTemplateColumns: 'repeat(22, 22px)', gap: 8}}>
          {Array.from({length: N}, (_, i) => {
            const lit = f > flip + 2 + (i % 22) * 0.25;
            return <div key={i} style={{width: 22, height: 22, borderRadius: 11, background: lit ? C.purple2 : '#2a2f3c',
              boxShadow: lit ? '0 0 10px rgba(167,139,250,.6)' : undefined}} />;
          })}
        </div>
      </div>
      <div style={{display: 'flex', gap: 22}}>
        <div style={{opacity: t01(f, flip + 10, 8)}}><Pill color={C.amber} size={30}>⚡ 100% of matching users · instantly</Pill></div>
        <div style={{opacity: t01(f, cue('problem', 'with no review') - 4, 8)}}><Pill color={C.red} size={30}>no review step on open-source Flagsmith</Pill></div>
      </div>
      <div style={{fontFamily: sans, fontSize: 22, color: C.dim, opacity: interpolate(f, [cue('problem', 'with no review') + 10, cue('problem', 'with no review') + 20], [0, 1], clamp)}}>
        Change Requests are a paid feature (Scale-Up and Enterprise)
      </div>
    </AbsoluteFill>
  );
};

const DbIcon: React.FC = () => (
  <svg width={64} height={70} viewBox="0 0 64 70">
    <ellipse cx={32} cy={12} rx={28} ry={10} fill={C.pg} />
    <path d="M4 12 V56 C4 62 16 66 32 66 C48 66 60 62 60 56 V12 C60 18 48 22 32 22 C16 22 4 18 4 12Z" fill="#2a5579" />
    <path d="M4 34 C4 40 16 44 32 44 C48 44 60 40 60 34" stroke="#7fb0d8" strokeWidth={2} fill="none" opacity={0.6} />
  </svg>
);
