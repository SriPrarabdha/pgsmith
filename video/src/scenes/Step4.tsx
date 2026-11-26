import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import ui from '../data/ui.json';
import after from '../data/term/after_ship.json';
import {Background} from '../components/Background';
import {Browser} from '../components/Browser';
import {StepBar} from '../components/StepBar';
import {Terminal} from '../components/Terminal';
import {Pill} from '../components/Brand';
import {clamp, ease, enter, pop, t01} from '../components/anim';
import {cue} from '../timeline';
import {C, FPS} from '../theme';

const RATE = 1.35, START = 0.5;
// layout: the ship take large and centred, then (after "Complete experiment") the completed page on the left
// and the same SQL on the right; nothing is stacked on top of anything else
export const Step4: React.FC = () => {
  const f = useCurrentFrame();
  const clickF = Math.round((ui.ship.events.complete - START) * FPS / RATE);
  const doneAt = clickF + 10;
  const sqlAt = Math.max(doneAt + 16, cue('step4', 'and the SQL') - 12);
  const move = interpolate(f, [doneAt, doneAt + 18], [0, 1], {...clamp, easing: ease});
  return (
    <AbsoluteFill>
      <Background />
      <StepBar active={3} />
      {f < doneAt + 2 ? (
        <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', paddingTop: 110, paddingBottom: 30, opacity: 1 - t01(f, doneAt - 4, 6)}}>
          <Browser take="ship" width={1340} startAt={START} rate={RATE}
            cams={[{f: 0, scale: 1.0, x: 0.5, y: 0.5}, {f: Math.round(1.4 * FPS), scale: 1.35, x: 0.5, y: 0.52}, {f: clickF, scale: 1.45, x: 0.56, y: 0.72}]} />
        </AbsoluteFill>
      ) : (
        <>
          <div style={{position: 'absolute', left: 60, top: 150, opacity: t01(f, doneAt, 8), transform: `translateX(${(1 - move) * 120}px)`}}>
            <Browser take="shipped" width={1060} from={doneAt} cams={[{f: 0, scale: 1.3, x: 0.5, y: 0.32}]} />
          </div>
          {f >= sqlAt - 2 && (
            <div style={{position: 'absolute', right: 60, top: 150, width: 720, display: 'flex', flexDirection: 'column', gap: 26, ...enter(f, sqlAt, 40)}}>
              <Terminal items={[{...after[0], command: "SELECT s.title, p.sales_30d, s.arm … 'user-42' …;"}]} start={sqlAt}
                width={720} height={360} fontSize={18} opts={{cps: 8, lpf: 1}} finalPrompt={false} title="same query · same user-42"
                rules={[{match: 'boosted', color: C.purple2, weight: 800}]} />
              <div style={{alignSelf: 'flex-start', transform: `scale(${pop(f, sqlAt + 24, 10)})`, transformOrigin: 'left center'}}>
                <Pill color={C.green} size={30} style={{background: C.green, color: '#052e1b', border: 'none', fontWeight: 800, boxShadow: '0 8px 30px rgba(52,211,153,.45)'}}>✓ SQL unchanged</Pill>
              </div>
              <div style={{alignSelf: 'flex-start', ...enter(f, sqlAt + 34)}}>
                <Pill color={C.purple2} size={24}>user-42 was in control · now boosted</Pill>
              </div>
            </div>
          )}
        </>
      )}
    </AbsoluteFill>
  );
};
