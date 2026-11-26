import React from 'react';
import {C, mono, sans} from '../theme';

/** Dark window chrome used by terminals and the browser. */
export const Window: React.FC<{title?: string; url?: string; width: number | string; height?: number | string;
  style?: React.CSSProperties; children: React.ReactNode; light?: boolean}> = ({title, url, width, height, style, children, light}) => (
  <div style={{width, height, borderRadius: 18, overflow: 'hidden', background: light ? '#fff' : C.panel,
    border: `1px solid ${light ? 'rgba(255,255,255,.25)' : C.line}`,
    boxShadow: '0 40px 120px rgba(0,0,0,.55), 0 0 0 1px rgba(0,0,0,.4), 0 0 80px rgba(139,92,246,.10)', display: 'flex', flexDirection: 'column', ...style}}>
    <div style={{height: 44, flex: '0 0 44px', display: 'flex', alignItems: 'center', gap: 9, padding: '0 18px',
      background: light ? '#EEF0F4' : C.panel2, borderBottom: `1px solid ${light ? '#dde0e6' : C.line}`}}>
      {['#FF5F57', '#FEBC2E', '#28C840'].map(c => <div key={c} style={{width: 13, height: 13, borderRadius: 7, background: c}} />)}
      {url ? (
        <div style={{marginLeft: 18, flex: 1, height: 28, borderRadius: 8, background: light ? '#fff' : C.bg2, display: 'flex', alignItems: 'center',
          padding: '0 14px', fontFamily: sans, fontSize: 15, color: light ? '#4b5563' : C.muted, border: `1px solid ${light ? '#dde0e6' : C.line}`}}>
          <span style={{color: '#16a34a', marginRight: 8}}>●</span>{url}
        </div>
      ) : (
        <div style={{flex: 1, textAlign: 'center', fontFamily: mono, fontSize: 15, color: C.muted, marginRight: 60}}>{title}</div>
      )}
    </div>
    <div style={{flex: 1, position: 'relative', overflow: 'hidden'}}>{children}</div>
  </div>
);
