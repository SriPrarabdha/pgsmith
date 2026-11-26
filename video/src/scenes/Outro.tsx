import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {Background} from '../components/Background';
import {Mark, Pill, Wordmark} from '../components/Brand';
import {clamp, enter, pop} from '../components/anim';
import {cue, scene} from '../timeline';
import {C, mono, sans} from '../theme';

export const Outro: React.FC = () => {
  const f = useCurrentFrame();
  const end = scene('outro').frames;
  const fade = interpolate(f, [end - 24, end], [0, 1], clamp);
  return (
    <AbsoluteFill>
      <Background intensity={1.5} />
      <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', flexDirection: 'column', gap: 30}}>
        <div style={{display: 'flex', alignItems: 'center', gap: 24, transform: `scale(${pop(f, 0, 12)})`}}>
          <Mark size={150} /><Wordmark size={130} />
        </div>
        <div style={{display: 'flex', gap: 16, ...enter(f, cue('outro', 'Pure SQL'))}}>
          {['pure SQL', 'Supabase', 'Amazon RDS', 'PostgreSQL 14–18', 'BSD-3-Clause'].map(t => <Pill key={t} size={24}>{t}</Pill>)}
        </div>
        <div style={{fontFamily: sans, fontSize: 60, fontWeight: 900, color: C.text, marginTop: 20, ...enter(f, cue('outro', 'Flagsmith flags'))}}>
          Flagsmith flags, <span style={{background: `linear-gradient(90deg, ${C.purple2}, ${C.blue})`, WebkitBackgroundClip: 'text', color: 'transparent'}}>where your data lives.</span>
        </div>
        <div style={{display: 'flex', gap: 40, marginTop: 24, fontFamily: mono, fontSize: 28, color: C.muted, ...enter(f, cue('outro', 'Flagsmith flags') + 12)}}>
          <span><span style={{color: C.purple2}}>github.com/</span>SriPrarabdha/pgsmith</span>
          <span><span style={{color: C.green}}>$</span> make quickstart</span>
        </div>
        <div style={{fontFamily: sans, fontSize: 22, color: C.dim, marginTop: 30, ...enter(f, cue('outro', 'Flagsmith flags') + 24)}}>
          Toggle Wars · Track 3: Build on Open Source Flagsmith
        </div>
      </AbsoluteFill>
      <AbsoluteFill style={{background: '#000', opacity: fade}} />
    </AbsoluteFill>
  );
};
