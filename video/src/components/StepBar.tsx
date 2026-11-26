import React from 'react';
import {useCurrentFrame} from 'remotion';
import {C, sans} from '../theme';
import {t01} from './anim';

export const STEPS = ['Multivariate flag', 'Pick the metrics', 'Split the traffic', 'Ship the winner'];

/** The hackathon's four experiment steps, with the current one lit. */
export const StepBar: React.FC<{active: number; appear?: number; big?: boolean}> = ({active, appear = -30}) => {
  const f = useCurrentFrame();
  const p = t01(f, appear, 14);
  return (
    <div style={{position: 'absolute', top: 34, left: 0, right: 0, display: 'flex', justifyContent: 'center', gap: 14, opacity: p,
      transform: `translateY(${(1 - p) * -20}px)`}}>
      {STEPS.map((s, i) => {
        const on = i === active, done = i < active;
        return (
          <div key={s} style={{display: 'flex', alignItems: 'center', gap: 12, padding: '10px 20px 10px 12px', borderRadius: 999,
            fontFamily: sans, fontSize: 21, fontWeight: 650, color: on ? '#fff' : done ? C.purple2 : C.muted,
            background: on ? `linear-gradient(135deg, ${C.purple}, ${C.indigo})` : 'rgba(255,255,255,.04)',
            border: `1px solid ${on ? 'transparent' : C.line}`, boxShadow: on ? '0 8px 30px rgba(139,92,246,.45)' : undefined}}>
            <div style={{width: 30, height: 30, borderRadius: 15, display: 'grid', placeItems: 'center', fontSize: 17, fontWeight: 800,
              background: on ? 'rgba(255,255,255,.22)' : done ? `${C.purple}33` : 'rgba(255,255,255,.06)'}}>{done ? '✓' : i + 1}</div>
            {s}
          </div>
        );
      })}
    </div>
  );
};
