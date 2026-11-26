import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import plan from '../data/term/plan.json';
import {Background} from '../components/Background';
import {StepBar} from '../components/StepBar';
import {schedule, Terminal} from '../components/Terminal';
import {Kicker, Pill} from '../components/Brand';
import {clamp, ease, enter, pop} from '../components/anim';
import {cue} from '../timeline';
import {C, mono, sans} from '../theme';

const items = [{...plan[0], command: 'flagshift plan --env production --promote-from staging --population app.users'}];
const OPTS = {cps: 3.2, lpf: 0.9, execMax: 26};

export const Release: React.FC = () => {
  const f = useCurrentFrame();
  const start = cue('release', 'Flag Shift') - 24;
  const tm = schedule(items, OPTS)[0];
  const catchAt = Math.max(start + tm.outEnd + 6, cue('release', 'catches this') - 6);
  const zoom = interpolate(f, [catchAt, catchAt + 22], [0, 1], {...clamp, easing: ease});
  return (
    <AbsoluteFill>
      <Background glow={zoom > 0.5 ? C.red : C.purple} intensity={1 + zoom * 0.3} />
      <StepBar active={3} />
      {/* intro: a release is more than one flag */}
      {f < start + 6 && (
        <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', flexDirection: 'column', gap: 30, opacity: 1 - interpolate(f, [start - 6, start + 4], [0, 1], clamp)}}>
          <Kicker style={{...enter(f, 0)}}>the release: staging → production</Kicker>
          <div style={{display: 'flex', gap: 20}}>
            {[['search_ranking', 'boosted, 100%', C.green], ['new_checkout', 'quarter rollout', C.amber], ['pricing_banner', 'diwali for india_mobile', C.purple2], ['max_upload_mb', '250 for app_v3', C.purple2]].map(([n, d, col], i) => (
              <div key={n} style={{padding: '22px 26px', borderRadius: 20, background: C.panel, border: `1px solid ${C.line}`, transform: `scale(${pop(f, 6 + i * 6)})`}}>
                <div style={{fontFamily: mono, fontSize: 28, color: C.text, fontWeight: 700}}>{n}</div>
                <div style={{fontFamily: sans, fontSize: 22, color: col, marginTop: 6}}>{d}</div>
              </div>
            ))}
          </div>
        </AbsoluteFill>
      )}
      {f >= start - 2 && (
        <div style={{position: 'absolute', left: 70, top: 150, ...enter(f, start, 30)}}>
          {/* at the catch the plan narrows to the left (long lines clip) to make room for the call-out */}
          <Terminal items={items} start={start} width={1780 - zoom * 660} height={800} fontSize={20.5} opts={OPTS} title="FlagShift · terraform plan for flags"
            rules={[
              {match: /4,426 users/, color: '#fff', weight: 800, from: catchAt - start},
              {match: /value "v2-enterprise" → "v2".*/, lineBg: 'rgba(248,113,113,.30)', color: '#FECACA', from: catchAt - start},
              {match: /evaluated in [\d.]+s inside Postgres/, color: C.purple2, weight: 700},
              {match: /same rules, different people.*/, color: '#FDE68A', weight: 700, from: cue('release', 'and catches') - start},
            ]} />
        </div>
      )}
      {f >= catchAt + 6 && (
        <div style={{position: 'absolute', right: 60, top: 300, width: 590, transform: `translateX(${(1 - zoom) * 80}px)`, opacity: zoom}}>
          <div style={{padding: '30px 32px', borderRadius: 22, background: 'linear-gradient(135deg, #7f1d1d, #450a0a)', border: `1px solid ${C.red}`,
            boxShadow: '0 20px 70px rgba(248,113,113,.35)', transform: `scale(${pop(f, catchAt + 10, 11)})`, transformOrigin: 'left center'}}>
            <div style={{fontFamily: sans, fontSize: 22, fontWeight: 800, color: '#FECACA', letterSpacing: 2}}>CAUGHT BEFORE IT SHIPPED</div>
            <div style={{fontFamily: sans, fontSize: 96, fontWeight: 900, color: '#fff', lineHeight: 1.05, marginTop: 6}}>4,426</div>
            <div style={{fontFamily: sans, fontSize: 30, color: '#FEE2E2', fontWeight: 600, lineHeight: 1.25}}>enterprise accounts would lose <span style={{fontFamily: mono, whiteSpace: 'nowrap'}}>v2-enterprise</span></div>
            <div style={{fontFamily: sans, fontSize: 21, color: '#FCA5A5', marginTop: 14, lineHeight: 1.35}}>staging ranks quarter_rollout above enterprise for new_checkout</div>
          </div>
        </div>
      )}
    </AbsoluteFill>
  );
};
