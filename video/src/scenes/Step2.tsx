import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import ui from '../data/ui.json';
import {Background} from '../components/Background';
import {Browser} from '../components/Browser';
import {Code} from '../components/Code';
import {StepBar} from '../components/StepBar';
import {Pill} from '../components/Brand';
import {enter} from '../components/anim';
import {cue} from '../timeline';
import {C, FPS} from '../theme';

const SQL = `-- from any query, trigger or job
SELECT flagsmith.track_event('search_result_clicked', 'user-2024');
SELECT flagsmith.track_event('add_to_cart', 'user-2024');
SELECT flagsmith.track_event('search_latency_ms', 'user-2024', '3.2');`;

export const Step2: React.FC = () => {
  const f = useCurrentFrame();
  const ev = ui.metrics.events as Record<string, number>;
  const at = (k: string) => Math.round(ev[k] * FPS);
  return (
    <AbsoluteFill>
      <Background />
      <StepBar active={1} />
      <div style={{position: 'absolute', left: 70, top: 150, ...enter(f, 0, 30)}}>
        <Browser take="metrics" width={960} cams={[{f: 0, scale: 1.25, x: 0.42, y: 0.5}]} />
      </div>
      <div style={{position: 'absolute', right: 60, top: 150, ...enter(f, 8, 30)}}>
        <Code code={SQL} width={830} fontSize={17} title="recorded in SQL" start={8}
          highlight={[{lines: [1], from: at('Search result clicked') - 8}, {lines: [2], from: at('Add to cart') - 8},
                      {lines: [3], from: at('Search latency (ms)') - 8, color: 'rgba(251,191,36,.18)'}]} />
        <div style={{marginTop: 26, display: 'flex', gap: 14, ...enter(f, cue('step2', 'guardrail') - 4)}}>
          <Pill color={C.green} size={22}>↑ clicks</Pill><Pill color={C.green} size={22}>↑ add to cart</Pill>
          <Pill color={C.amber} size={22}>guardrail: latency</Pill>
        </div>
      </div>
    </AbsoluteFill>
  );
};
