import React from 'react';
import {AbsoluteFill} from 'remotion';
import {Background} from './components/Background';
import {Mark, Pill, Wordmark} from './components/Brand';
import {C, mono, sans} from './theme';
import {Window} from './components/Window';

export const Thumbnail: React.FC = () => (
  <AbsoluteFill>
    <Background intensity={1.8} />
    <AbsoluteFill style={{padding: 110, justifyContent: 'center', gap: 34}}>
      <div style={{display: 'flex', alignItems: 'center', gap: 22}}><Mark size={130} wave={false} /><Wordmark size={110} /></div>
      <div style={{fontFamily: sans, fontSize: 96, fontWeight: 900, color: C.text, lineHeight: 1.02, letterSpacing: -2}}>
        Flagsmith flags,<br /><span style={{background: `linear-gradient(90deg, ${C.purple2}, ${C.blue})`, WebkitBackgroundClip: 'text', color: 'transparent'}}>inside Postgres.</span>
      </div>
      <div style={{fontFamily: mono, fontSize: 34, color: C.muted}}>SELECT * FROM flagsmith.flags('user-42');</div>
      <div style={{display: 'flex', gap: 18}}>
        <Pill color={C.green} size={30}>0.76 s sync</Pill><Pill color={C.red} size={30}>4,426 caught by FlagShift</Pill><Pill size={30}>230/230 engine tests</Pill>
      </div>
    </AbsoluteFill>
    <div style={{position: 'absolute', right: 90, top: 250, transform: 'rotate(-3deg)'}}>
      <Window title="flagshift plan · Staging → Production" width={720} height={420}>
        <div style={{padding: 30, fontFamily: mono, fontSize: 25, lineHeight: '44px', color: C.text, whiteSpace: 'pre'}}>
          <div style={{color: C.amber, fontWeight: 700}}>~ new_checkout   12,922 users</div>
          <div>  "v1" → "v2"           8,496 users</div>
          <div style={{background: 'rgba(248,113,113,.3)', borderRadius: 6, color: '#fff', fontWeight: 700}}>  "v2-enterprise" → "v2" 4,426 users</div>
          <div style={{color: '#FCD34D', fontStyle: 'italic'}}>! same rules, different people:</div>
          <div style={{color: '#FCD34D', fontStyle: 'italic'}}>  only 25.0% overlap</div>
          <div style={{color: C.purple2, marginTop: 8}}>evaluated in 4.95s inside Postgres</div>
        </div>
      </Window>
    </div>
  </AbsoluteFill>
);
