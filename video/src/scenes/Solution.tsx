import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import ui from '../data/ui.json';
import {Background} from '../components/Background';
import {Browser} from '../components/Browser';
import {Window} from '../components/Window';
import {Kicker, Pill} from '../components/Brand';
import {enter, pop, t01} from '../components/anim';
import {cue} from '../timeline';
import {C, FPS, mono, sans} from '../theme';

const NODES = [
  {t: 'Flagsmith', s: 'self-hosted or cloud'},
  {t: 'sync', s: 'pg_cron + http, inside Postgres'},
  {t: 'snapshots', s: 'one transaction per change'},
  {t: 'compiled SQL', s: 'inlined by the planner'},
  {t: 'flagsmith.flags()', s: 'in queries, policies, jobs'},
];

const flip = ui.flip;
const START_AT = 4.6; // seconds into the take: mid-typing "black_friday"

export const Solution: React.FC = () => {
  const f = useCurrentFrame();
  const split = cue('solution', 'Flip a flag') - 6;
  const pipeOut = t01(f, split - 8, 12);
  // the take starts at `split`; its save click happens (save - START_AT) s later
  const saveF = split + Math.round((flip.events.save - START_AT) * FPS);
  const changeF = split + Math.round((flip.changeT - START_AT) * FPS);
  return (
    <AbsoluteFill>
      <Background />
      <Kicker style={{position: 'absolute', top: 70, left: 120, ...enter(f, 0)}}>pgsmith</Kicker>
      {/* the pipeline */}
      <AbsoluteFill style={{opacity: 1 - pipeOut, alignItems: 'center', justifyContent: 'center'}}>
        <div style={{display: 'flex', alignItems: 'center', gap: 0}}>
          {NODES.map((n, i) => {
            const at = 8 + i * 9;
            const p = pop(f, at);
            return (
              <React.Fragment key={n.t}>
                {i > 0 && <Arrow f={f} at={at - 4} />}
                <div style={{width: 270, padding: '26px 18px', borderRadius: 20, textAlign: 'center', transform: `scale(${p})`,
                  background: i === 0 ? `linear-gradient(135deg, ${C.purple}, ${C.indigo})` : C.panel,
                  border: `1px solid ${i === 0 ? 'transparent' : C.line}`, boxShadow: '0 20px 60px rgba(0,0,0,.45)'}}>
                  <div style={{fontFamily: i >= 3 ? mono : sans, fontSize: i >= 3 ? 26 : 30, fontWeight: 800, color: '#fff'}}>{n.t}</div>
                  <div style={{fontFamily: sans, fontSize: 19, color: i === 0 ? '#e9e3ff' : C.muted, marginTop: 8}}>{n.s}</div>
                </div>
              </React.Fragment>
            );
          })}
        </div>
        <div style={{position: 'absolute', bottom: 210, ...enter(f, cue('solution', 'compiled into'), 16)}}>
          <Pill size={28}>a read-only replica of your environments · evaluated in plain SQL</Pill>
        </div>
      </AbsoluteFill>
      {/* flip in the UI, watch Postgres */}
      {f >= split - 2 && (
        <AbsoluteFill style={{...enter(f, split, 30, 14)}}>
          <div style={{position: 'absolute', left: 70, top: 150}}>
            <Browser take="flip" width={1180} from={split} startAt={START_AT}
              cams={[{f: 0, scale: 1.35, x: 0.78, y: 0.38}, {f: Math.round(2.2 * FPS), scale: 1.35, x: 0.82, y: 0.62}]} />
          </div>
          <div style={{position: 'absolute', right: 70, top: 150}}>
            <Watch f={f} split={split} />
          </div>
          <Stopwatch f={f} saveF={saveF} changeF={changeF} />
          {f > cue('solution', 'No extra') - 4 && (
            <div style={{position: 'absolute', left: 0, right: 0, bottom: 120, display: 'flex', justifyContent: 'center', ...enter(f, cue('solution', 'No extra'), 16)}}>
              <Pill color={C.green} size={28}>pg_cron · <span style={{fontFamily: mono}}>CALL flagsmith.sync_run()</span> every second · no sync service</Pill>
            </div>
          )}
        </AbsoluteFill>
      )}
    </AbsoluteFill>
  );
};

const Arrow: React.FC<{f: number; at: number}> = ({f, at}) => {
  const p = t01(f, at, 10);
  return (
    <svg width={64} height={30} style={{opacity: p}}>
      <line x1={4} y1={15} x2={50} y2={15} stroke={C.purple2} strokeWidth={3} strokeDasharray="6 6" strokeDashoffset={-f * 0.8} />
      <path d="M48 7 L60 15 L48 23 Z" fill={C.purple2} />
    </svg>
  );
};

// Postgres polled while the take was recorded (capture/watch.py): real clock, real values
const Watch: React.FC<{f: number; split: number}> = ({f, split}) => {
  const takeT = START_AT + (f - split) / FPS;
  const polls = flip.polls.filter(p => p.t <= takeT);
  // one row per ~0.25 s of the take
  const rows: typeof polls = [];
  let last = -1;
  for (const p of polls) if (p.t - last >= 0.25 || p.value !== rows.at(-1)?.value) { rows.push(p); last = p.t; }
  const shown = rows.slice(-11);
  return (
    <Window title="psql · Postgres, polled every 50 ms" width={560} height={656}>
      <div style={{padding: 22, fontFamily: mono, fontSize: 21, lineHeight: '34px'}}>
        <div style={{color: C.muted, whiteSpace: 'pre-wrap', marginBottom: 10}}>
          <span style={{color: C.purple2, fontWeight: 700}}>postgres=#</span> SELECT value FROM{'\n'}flagsmith.flag('pricing_banner',{'\n'}  'user-42');
        </div>
        <div style={{color: C.purple2, fontWeight: 700, whiteSpace: 'pre'}}>{'   polled at    | value'}</div>
        <div style={{color: C.dim, whiteSpace: 'pre'}}>{'----------------+----------------'}</div>
        {shown.map((r, i) => {
          const changed = r.value !== flip.before;
          return (
            <div key={i} style={{whiteSpace: 'pre', color: changed ? '#fff' : C.text, background: changed ? 'rgba(52,211,153,.22)' : undefined,
              borderRadius: 4, fontWeight: changed ? 700 : 400}}>
              {` ${r.clock} | ${r.value}`}
            </div>
          );
        })}
      </div>
    </Window>
  );
};

const Stopwatch: React.FC<{f: number; saveF: number; changeF: number}> = ({f, saveF, changeF}) => {
  if (f < saveF) return null;
  const done = f >= changeF;
  const ms = done ? flip.latencyMs : Math.round(((f - saveF) / FPS) * 1000);
  const p = pop(f, saveF, 12);
  const big = done ? pop(f, changeF, 9) : 0;
  return (
    <div style={{position: 'absolute', left: 1000, top: 108, transform: `scale(${p * (1 + 0.08 * big)})`, transformOrigin: 'center'}}>
      <div style={{display: 'flex', alignItems: 'center', gap: 14, padding: '14px 26px', borderRadius: 18,
        background: done ? `linear-gradient(135deg, ${C.green}, #059669)` : C.panel2, border: `1px solid ${done ? 'transparent' : C.line}`,
        boxShadow: done ? '0 12px 50px rgba(52,211,153,.5)' : '0 12px 40px rgba(0,0,0,.5)'}}>
        <span style={{fontSize: 34}}>⏱</span>
        <div>
          <div style={{fontFamily: mono, fontSize: 40, fontWeight: 800, color: '#fff'}}>{(ms / 1000).toFixed(2)} s</div>
          <div style={{fontFamily: sans, fontSize: 17, color: done ? '#ecfdf5' : C.muted}}>{done ? 'Flagsmith click → served by Postgres' : 'saved in Flagsmith…'}</div>
        </div>
      </div>
    </div>
  );
};
