import React from 'react';
import {useCurrentFrame} from 'remotion';
import {C, sans} from '../theme';

/** The pgsmith mark (flag on an anvil), redrawn so the flag can wave. */
export const Mark: React.FC<{size: number; wave?: boolean}> = ({size, wave = true}) => {
  const f = useCurrentFrame();
  const w = wave ? Math.sin(f / 7) * 1.8 : 0;
  const flag = `M25.5 9 C 33 ${5.5 + w}, 39 ${12.5 - w}, 47 ${9 + w * 0.5} C 51 7.3, 54 7.6, 56 8.4 L 56 29 C 54 28.2, 51 27.9, 47 ${29.6 + w * 0.5} C 39 ${33 - w}, 33 ${26 + w}, 25.5 29.5 Z`;
  return (
    <svg width={size} height={size} viewBox="0 0 64 64">
      <defs>
        <linearGradient id="mflag" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stopColor="#8B5CF6" /><stop offset="1" stopColor="#4F46E5" /></linearGradient>
        <linearGradient id="manvil" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stopColor="#64748B" /><stop offset="1" stopColor="#334155" /></linearGradient>
      </defs>
      <rect x="21" y="7" width="4.5" height="40" rx="2.25" fill="#94A3B8" />
      <path d={flag} fill="url(#mflag)" />
      <g fill="#fff" opacity={0.92}><rect x="31" y="14.2" width="17" height="3.2" rx="1.6" /><rect x="31" y="19.4" width="12" height="3.2" rx="1.6" /></g>
      <path d="M6 46 H 50 C 50 49.5, 46.5 51, 42 51 H 37 L 39.5 57 H 44 V 60 H 16 V 57 H 20.5 L 23 51 H 16 C 10 51, 6 49, 6 46 Z" fill="url(#manvil)" />
      <path d="M50 46 C 55 46, 58.5 44.5, 60 42 C 58 47.5, 54.5 49.5, 50 49.6 Z" fill="#475569" />
    </svg>
  );
};

export const Wordmark: React.FC<{size: number; style?: React.CSSProperties}> = ({size, style}) => (
  <span style={{fontFamily: sans, fontWeight: 800, fontSize: size, letterSpacing: -size * 0.03, ...style}}>
    <span style={{color: C.purple2}}>pg</span><span style={{color: C.text}}>smith</span>
  </span>
);

export const Pill: React.FC<{children: React.ReactNode; color?: string; style?: React.CSSProperties; size?: number}> = ({children, color = C.purple2, style, size = 22}) => (
  <div style={{display: 'inline-flex', alignItems: 'center', gap: 10, fontFamily: sans, fontWeight: 600, fontSize: size, color,
    padding: `${size * 0.35}px ${size * 0.8}px`, borderRadius: 999, background: `${color}1f`, border: `1px solid ${color}55`, ...style}}>{children}</div>
);

export const Kicker: React.FC<{children: React.ReactNode; style?: React.CSSProperties}> = ({children, style}) => (
  <div style={{fontFamily: sans, fontWeight: 700, fontSize: 22, letterSpacing: 4, textTransform: 'uppercase', color: C.purple2, ...style}}>{children}</div>
);
