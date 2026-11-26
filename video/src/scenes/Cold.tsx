import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import cold from '../data/term/cold.json';
import {Background} from '../components/Background';
import {Terminal} from '../components/Terminal';
import {Pill} from '../components/Brand';
import {enter, pop} from '../components/anim';
import {cue} from '../timeline';
import {C} from '../theme';

// the second run of the query (warm), as psql printed it
const out = cold[0].output;
const second = out.slice(out.indexOf('Time:') + out.slice(out.indexOf('Time:')).indexOf('\n') + 1);
const item = {prompt: 'postgres=#', command: "SELECT feature, enabled, value, reason\nFROM flagsmith.flags('user-42', '{\"plan\": \"pro\", \"country\": \"IN\"}');", output: second, ms: 1};

export const Cold: React.FC = () => {
  const f = useCurrentFrame();
  const chips: [string, string, string][] = [['No SDK', '✕', C.red], ['No network call', '✕', C.red], ['Just SQL', '✓', C.green]];
  return (
    <AbsoluteFill>
      <Background intensity={0.5} />
      <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', flexDirection: 'column', gap: 44}}>
        <Terminal items={[item]} start={12} width={1480} height={590} fontSize={27} opts={{cps: 2.4, lpf: 0.5}}
          rules={[{match: /Time: [\d.]+ ms/, bg: `${C.green}30`, color: C.green, weight: 700, from: cue('cold', 'No network') - 12},
                  {match: /^ search_ranking.*$/, lineBg: 'rgba(139,92,246,.18)', from: cue('cold', 'evaluated')}]} />
        <div style={{display: 'flex', gap: 22, height: 64}}>
          {chips.map(([t, icon, col]) => {
            const at = cue('cold', t === 'Just SQL' ? 'Just SQL' : t === 'No SDK' ? 'No SDK' : 'No network');
            const s = pop(f, at);
            return <div key={t} style={{transform: `scale(${s})`, opacity: Math.min(1, s * 1.5)}}>
              <Pill color={col} size={30}><b>{icon}</b> {t}</Pill></div>;
          })}
        </div>
      </AbsoluteFill>
      <div style={{position: 'absolute', top: 60, left: 0, right: 0, textAlign: 'center', ...enter(f, 4, 10)}}>
        <span style={{fontFamily: 'inherit', color: C.muted, fontSize: 22, letterSpacing: 3}}>SUPABASE POSTGRES · 127.0.0.1:55433</span>
      </div>
    </AbsoluteFill>
  );
};
