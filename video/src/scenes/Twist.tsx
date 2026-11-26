import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import dots from '../data/dots.json';
import {Background} from '../components/Background';
import {StepBar} from '../components/StepBar';
import {Pill} from '../components/Brand';
import {enter, pop, t01} from '../components/anim';
import {cue} from '../timeline';
import {C, mono, sans} from '../theme';

const COLS = 80, ROWS = 30, S = 14, G = 6;

export const Twist: React.FC = () => {
  const f = useCurrentFrame();
  const sAt = cue('twist', 'rollout in staging') - 4;
  const pAt = cue('twist', 'production picks') - 2;
  const oAt = cue('twist', 'Only a quarter') - 4;
  const kAt = cue('twist', 'Flag Shift re-keys') - 4;
  const stg = dots.staging, prd = dots.production;
  const nS = [...stg].filter(c => c === '1').length, nP = [...prd].filter(c => c === '1').length;
  const nB = [...stg].filter((c, i) => c === '1' && prd[i] === '1').length;
  const focus = t01(f, oAt, 12);
  return (
    <AbsoluteFill>
      <Background />
      <StepBar active={3} />
      <div style={{position: 'absolute', top: 120, left: 0, right: 0, textAlign: 'center', fontFamily: sans, fontSize: 50, fontWeight: 900, color: C.text, ...enter(f, 0)}}>
        Same rule. <span style={{color: C.amber}}>Different people.</span>
      </div>
      <div style={{position: 'absolute', top: 196, left: 0, right: 0, textAlign: 'center', fontFamily: mono, fontSize: 24, color: C.muted, ...enter(f, 6)}}>
        segment quarter_rollout: $.identity.key PERCENTAGE_SPLIT 25 · in both environments
      </div>
      <div style={{position: 'absolute', left: (1920 - (COLS * (S + G) - G)) / 2, top: 262, display: 'grid',
        gridTemplateColumns: `repeat(${COLS}, ${S}px)`, gap: G}}>
        {Array.from({length: COLS * ROWS}, (_, i) => {
          const s = stg[i] === '1' && f >= sAt + (i % COLS) * 0.2;
          const p = prd[i] === '1' && f >= pAt + (i % COLS) * 0.2;
          const both = s && p;
          let bg = '#232838', glow: string | undefined;
          if (both) { bg = '#fff'; glow = '0 0 12px rgba(255,255,255,.9)'; }
          else if (s) bg = C.purple;
          else if (p) bg = C.amber;
          const dim = both ? 1 : 1 - focus * 0.75;
          return <div key={i} style={{width: S, height: S, borderRadius: S / 2, background: bg, boxShadow: glow, opacity: dim}} />;
        })}
      </div>
      <div style={{position: 'absolute', bottom: 172, left: 0, right: 0, display: 'flex', justifyContent: 'center', gap: 22}}>
        <div style={{transform: `scale(${pop(f, sAt)})`}}><Pill color={C.purple2} size={26}>● staging's 25% ({nS.toLocaleString()} of 2,400)</Pill></div>
        <div style={{transform: `scale(${pop(f, pAt)})`}}><Pill color={C.amber} size={26}>● production's 25% ({nP.toLocaleString()})</Pill></div>
        <div style={{transform: `scale(${pop(f, oAt)})`}}><Pill color="#ffffff" size={26}>● in both: {nB} · 25.0% across all 100,000 users</Pill></div>
      </div>
      {f >= kAt && (
        <div style={{position: 'absolute', bottom: 122, left: 0, right: 0, textAlign: 'center', fontFamily: sans, fontSize: 23, color: C.green, ...enter(f, kAt)}}>
          splits hash each environment's own key · FlagShift re-keys the candidate into production's keys, so the plan is exact
        </div>
      )}
    </AbsoluteFill>
  );
};
