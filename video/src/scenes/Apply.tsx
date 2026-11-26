import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import apply from '../data/term/apply.json';
import down from '../data/term/down.json';
import {Background} from '../components/Background';
import {StepBar} from '../components/StepBar';
import {Terminal} from '../components/Terminal';
import {Pill} from '../components/Brand';
import {enter, pop, t01} from '../components/anim';
import {cue} from '../timeline';
import {C} from '../theme';

// keep the tail of apply's output: the changes, the writes and the verification
const applyOut = apply[0].output.split('\n');
const keep = applyOut.slice(applyOut.findIndex(l => l.startsWith('~ new_checkout')));
const applyItem = {...apply[0], command: 'flagshift apply --env production --promote-from staging --population app.users --yes', output: keep.join('\n')};
const downItems = [
  {...down[0], command: 'docker compose stop flagsmith'},
  {...down[1], command: 'SELECT name, last_outcome, consecutive_failures, last_error FROM flagsmith.sync_status();'},
  {...down[2]},
];

export const Apply: React.FC = () => {
  const f = useCurrentFrame();
  const downAt = cue('apply', 'And if Flagsmith') - 8;
  return (
    <AbsoluteFill>
      <Background glow={f > downAt ? C.red : C.green} intensity={0.9} />
      <StepBar active={3} />
      {f < downAt + 6 && (
        <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', paddingTop: 70, opacity: 1 - t01(f, downAt - 4, 10)}}>
          <Terminal items={[applyItem]} start={4} width={1780} height={760} fontSize={21} opts={{cps: 5, lpf: 1.2, execMax: 12}} title="FlagShift · apply"
            rules={[{match: /8,496 users change/, color: C.green, weight: 800},
                    {match: /^Verified.*/, lineBg: 'rgba(52,211,153,.22)'},
                    {match: /4,426/, color: C.red}]} />
          <div style={{position: 'absolute', right: 90, top: 190, transform: `rotate(4deg) scale(${pop(f, cue('apply', 're-plan proves'))})`}}>
            <Pill color={C.green} size={30}>✓ re-plan: no changes</Pill>
          </div>
        </AbsoluteFill>
      )}
      {f >= downAt - 2 && (
        <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', paddingTop: 70, ...enter(f, downAt, 30)}}>
          <Terminal items={downItems} start={downAt} width={1780} height={760} fontSize={21} opts={{cps: 5, lpf: 1.2, gap: 8}}
            rules={[{match: /error.*$/, color: C.red}, {match: /Could not resolve host: flagsmith/, color: C.red, weight: 700},
                    {match: /^ search_ranking.*boosted.*$/, lineBg: 'rgba(52,211,153,.18)'}]} />
          <div style={{position: 'absolute', right: 90, bottom: 150, display: 'flex', gap: 16, ...enter(f, downAt + 120)}}>
            <Pill color={C.red} size={26}>Flagsmith: down</Pill><Pill color={C.green} size={26}>Postgres: still serving the last good config</Pill>
          </div>
        </AbsoluteFill>
      )}
    </AbsoluteFill>
  );
};
