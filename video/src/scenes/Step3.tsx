import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import traffic from '../data/term/traffic.json';
import parity from '../data/term/parity.json';
import {Background} from '../components/Background';
import {Browser} from '../components/Browser';
import {StepBar} from '../components/StepBar';
import {Terminal} from '../components/Terminal';
import {Pill} from '../components/Brand';
import {clamp, enter, fmt, pop, t01} from '../components/anim';
import {cue} from '../timeline';
import {C, FPS, mono, sans} from '../theme';

// numbers from the captured run
const delivered = 16798, batches = 17, secs = 3.8;

export const Step3: React.FC = () => {
  const f = useCurrentFrame();
  const parityAt = cue('step3', 'Bucketing') - 8;
  const resultsAt = cue('step3', 'Simulated traffic') - 8;
  const qItems = [
    {...traffic[0], command: 'python demos/search_ab/simulate.py --users 3000 --via-queue', output: traffic[0].output.split('\n').slice(-3).join('\n')},
    {...traffic[2], command: 'SELECT * FROM flagsmith.events_tick();'},
    {...traffic[3]},
  ];
  return (
    <AbsoluteFill>
      <Background />
      <StepBar active={2} />
      {/* A: exposures queue in Postgres, the database delivers them */}
      {f < parityAt + 6 && (
        <AbsoluteFill style={{opacity: 1 - t01(f, parityAt - 4, 10)}}>
          <div style={{position: 'absolute', left: 70, top: 150, ...enter(f, 0, 30)}}>
            <Terminal items={qItems} width={1080} height={820} fontSize={19} maxLines={24} opts={{cps: 3.5, lpf: 2.2, gap: 8, execMax: 10}}
              rules={[{match: /delivered/, color: C.green}, {match: /16819|16798/, color: C.green, weight: 800}]} />
          </div>
          <div style={{position: 'absolute', right: 70, top: 200, width: 660, display: 'flex', flexDirection: 'column', gap: 26}}>
            <Flow f={f} />
            {([['events delivered', delivered, ''], ['batches', batches, ''], ['seconds', secs, '']] as [string, number, string][]).map(([l, v], i) => {
              const at = 70 + i * 10;
              const p = t01(f, at, 40);
              return (
                <div key={l} style={{display: 'flex', alignItems: 'baseline', gap: 18, ...enter(f, at)}}>
                  <span style={{fontFamily: mono, fontSize: 64, fontWeight: 800, color: C.text}}>{l === 'seconds' ? (v * p).toFixed(1) : fmt(v * p)}</span>
                  <span style={{fontFamily: sans, fontSize: 28, color: C.muted}}>{l}</span>
                </div>
              );
            })}
            <div style={{...enter(f, 110)}}><Pill color={C.green} size={22}>in the SDK's event format · retried · never sent twice</Pill></div>
          </div>
        </AbsoluteFill>
      )}
      {/* B: parity */}
      {f >= parityAt - 2 && f < resultsAt + 6 && (
        <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', flexDirection: 'column', gap: 40, paddingTop: 60,
          ...enter(f, parityAt, 30), opacity: Math.min(t01(f, parityAt, 10), 1 - t01(f, resultsAt - 4, 10))}}>
          <Terminal items={[{...parity[0], command: 'pgsmith parity --population "SELECT identifier, traits FROM app.users" --sample 10000'}]}
            start={parityAt} width={1600} height={220} fontSize={23} opts={{cps: 5, lpf: 1}} title="pgsmith vs the official Flagsmith SDK"
            rules={[{match: /parity OK/, bg: `${C.green}33`}]} />
          <div style={{display: 'flex', gap: 80, alignItems: 'center'}}>
            {[['10,000', 'live identities'], ['100,000', 'flag comparisons'], ['0', 'mismatches']].map(([v, l], i) => (
              <div key={l} style={{textAlign: 'center', transform: `scale(${pop(f, parityAt + 40 + i * 8)})`}}>
                <div style={{fontFamily: sans, fontSize: i === 2 ? 130 : 96, fontWeight: 900, color: i === 2 ? C.green : C.text, lineHeight: 1}}>{v}</div>
                <div style={{fontFamily: sans, fontSize: 28, color: C.muted, marginTop: 8}}>{l}</div>
              </div>
            ))}
          </div>
        </AbsoluteFill>
      )}
      {/* C: Flagsmith's read-out */}
      {f >= resultsAt - 2 && (
        <AbsoluteFill style={{...enter(f, resultsAt, 30)}}>
          <div style={{position: 'absolute', left: 70, top: 150}}>
            <Browser take="results" width={1240} from={resultsAt}
              cams={[{f: 0, scale: 1.3, x: 0.45, y: 0.33}, {f: Math.round(2.6 * FPS), scale: 1.3, x: 0.45, y: 0.4},
                     {f: Math.round(4.6 * FPS), scale: 1.3, x: 0.62, y: 0.8}]} />
          </div>
          <div style={{position: 'absolute', right: 70, top: 170, width: 500, display: 'flex', flexDirection: 'column', gap: 20}}>
            <Lift f={f} at={cue('step3', 'boosted lifts') - 4} label="Search result clicked" v="+22.6%" ci="95% CI 19.4% – 25.8%" color={C.green} />
            <Lift f={f} at={cue('step3', 'add to cart') - 4} label="Add to cart" v="+64.3%" ci="95% CI 50.0% – 78.6%" color={C.green} />
            <Lift f={f} at={cue('step3', 'Latency stays') - 4} label="Search latency (guardrail)" v="±0.0%" ci="95% CI −1.0% – +1.0%" color={C.amber} />
            <div style={{...enter(f, resultsAt + 20), alignSelf: 'flex-start'}}><Pill color={C.amber} size={20}>SIMULATED TRAFFIC · 5,929 users</Pill></div>
          </div>
        </AbsoluteFill>
      )}
    </AbsoluteFill>
  );
};

const Lift: React.FC<{f: number; at: number; label: string; v: string; ci: string; color: string}> = ({f, at, label, v, ci, color}) => {
  const p = pop(f, at);
  return (
    <div style={{padding: '18px 24px', borderRadius: 18, background: C.panel, border: `1px solid ${color}55`, transform: `scale(${p})`, opacity: Math.min(1, p * 1.4),
      boxShadow: `0 16px 50px rgba(0,0,0,.45)`}}>
      <div style={{fontFamily: sans, fontSize: 21, color: C.muted, fontWeight: 600}}>{label}</div>
      <div style={{display: 'flex', alignItems: 'baseline', gap: 16}}>
        <span style={{fontFamily: sans, fontSize: 62, fontWeight: 900, color}}>{v}</span>
        <span style={{fontFamily: mono, fontSize: 18, color: C.muted}}>{ci}</span>
      </div>
    </div>
  );
};

// exposure packets flowing from Postgres to Flagsmith
const Flow: React.FC<{f: number}> = ({f}) => {
  const p = t01(f, 10, 20);
  return (
    <div style={{position: 'relative', height: 150, opacity: p}}>
      <Box x={0} label="Postgres" sub="flagsmith.event queue" color={C.pg} />
      <Box x={420} label="Flagsmith" sub="/api/v1/events" color={C.purple} />
      {Array.from({length: 7}, (_, i) => {
        const t = ((f - 30 + i * 9) % 60) / 60;
        if (f < 30 + 0) return null;
        const x = interpolate(t, [0, 1], [230, 410], clamp);
        return <div key={i} style={{position: 'absolute', left: x, top: 62, width: 26, height: 18, borderRadius: 5, background: C.purple2,
          opacity: t < 0.1 ? t * 10 : t > 0.9 ? (1 - t) * 10 : 1, boxShadow: '0 0 12px rgba(167,139,250,.8)'}} />;
      })}
    </div>
  );
};
const Box: React.FC<{x: number; label: string; sub: string; color: string}> = ({x, label, sub, color}) => (
  <div style={{position: 'absolute', left: x, top: 20, width: 230, height: 110, borderRadius: 18, background: `${color}26`, border: `1px solid ${color}88`,
    display: 'flex', flexDirection: 'column', justifyContent: 'center', alignItems: 'center'}}>
    <div style={{fontFamily: sans, fontSize: 28, fontWeight: 800, color: C.text}}>{label}</div>
    <div style={{fontFamily: mono, fontSize: 16, color: C.muted, marginTop: 4}}>{sub}</div>
  </div>
);
