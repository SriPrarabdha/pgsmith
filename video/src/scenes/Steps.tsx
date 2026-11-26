import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {Background} from '../components/Background';
import {STEPS} from '../components/StepBar';
import {Kicker} from '../components/Brand';
import {enter, pop} from '../components/anim';
import {cue} from '../timeline';
import {C, sans} from '../theme';

const SUB = ['create it in Flagsmith', 'what "better" means', 'who sees which arm', 'roll it out'];

export const Steps: React.FC = () => {
  const f = useCurrentFrame();
  const stamp = cue('steps', 'from SQL') - 2;
  return (
    <AbsoluteFill>
      <Background intensity={1.3} />
      <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', flexDirection: 'column', gap: 60}}>
        <Kicker style={{...enter(f, 0)}}>Flagsmith Experimentation</Kicker>
        <div style={{display: 'flex', gap: 28}}>
          {STEPS.map((s, i) => {
            const p = pop(f, 8 + i * 6);
            return (
              <div key={s} style={{width: 360, height: 250, borderRadius: 26, padding: 30, background: C.panel, border: `1px solid ${C.line}`,
                transform: `translateY(${(1 - p) * 60}px) scale(${0.9 + 0.1 * p})`, opacity: p, boxShadow: '0 30px 80px rgba(0,0,0,.5)'}}>
                <div style={{width: 64, height: 64, borderRadius: 32, display: 'grid', placeItems: 'center', fontFamily: sans, fontSize: 32,
                  fontWeight: 900, color: '#fff', background: `linear-gradient(135deg, ${C.purple}, ${C.indigo})`}}>{i + 1}</div>
                <div style={{fontFamily: sans, fontSize: 36, fontWeight: 800, color: C.text, marginTop: 26, lineHeight: 1.1}}>{s}</div>
                <div style={{fontFamily: sans, fontSize: 22, color: C.muted, marginTop: 10}}>{SUB[i]}</div>
              </div>
            );
          })}
        </div>
        <div style={{fontFamily: sans, fontSize: 58, fontWeight: 900, color: C.text, transform: `scale(${pop(f, stamp, 10)})`}}>
          all four, <span style={{background: `linear-gradient(90deg, ${C.purple2}, ${C.blue})`, WebkitBackgroundClip: 'text', color: 'transparent'}}>from SQL.</span>
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
