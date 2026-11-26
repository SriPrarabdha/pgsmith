import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {Background} from '../components/Background';
import {Mark, Wordmark} from '../components/Brand';
import {clamp, enter, pop} from '../components/anim';
import {C, sans} from '../theme';

export const Title: React.FC = () => {
  const f = useCurrentFrame();
  const s = pop(f, 2, 11);
  const flash = interpolate(f, [0, 3, 14], [0, 0.55, 0], clamp);
  return (
    <AbsoluteFill>
      <Background intensity={1.6} />
      <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', flexDirection: 'column'}}>
        <div style={{display: 'flex', alignItems: 'center', gap: 28, transform: `scale(${0.6 + 0.4 * s})`}}>
          <div style={{filter: 'drop-shadow(0 0 40px rgba(139,92,246,.6))'}}><Mark size={190} /></div>
          <Wordmark size={170} style={{...enter(f, 6, 30, 14)}} />
        </div>
        <div style={{fontFamily: sans, fontSize: 44, fontWeight: 500, color: C.muted, marginTop: 26, ...enter(f, 16, 20)}}>
          Flagsmith feature flags, <span style={{color: C.text, fontWeight: 700}}>evaluated inside Postgres.</span>
        </div>
      </AbsoluteFill>
      <AbsoluteFill style={{background: '#fff', opacity: flash}} />
    </AbsoluteFill>
  );
};
