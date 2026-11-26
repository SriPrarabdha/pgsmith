import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {C} from '../theme';

export const Background: React.FC<{glow?: string; intensity?: number}> = ({glow = C.purple, intensity = 1}) => {
  const f = useCurrentFrame();
  const dx = Math.sin(f / 240) * 60, dy = Math.cos(f / 300) * 40;
  return (
    <AbsoluteFill style={{background: C.bg, overflow: 'hidden'}}>
      <AbsoluteFill style={{
        background: `radial-gradient(900px 600px at ${30 + dx / 30}% ${20 + dy / 30}%, ${glow}${hex(0.22 * intensity)}, transparent 70%),
                     radial-gradient(800px 600px at ${80 - dx / 40}% ${85 - dy / 40}%, ${C.indigo}${hex(0.18 * intensity)}, transparent 70%)`,
      }} />
      <AbsoluteFill style={{
        backgroundImage: `linear-gradient(${C.line} 1px, transparent 1px), linear-gradient(90deg, ${C.line} 1px, transparent 1px)`,
        backgroundSize: '64px 64px', backgroundPosition: `${dx * 0.3}px ${f * 0.25}px`, opacity: 0.22,
        maskImage: 'radial-gradient(ellipse at center, black 30%, transparent 80%)',
        WebkitMaskImage: 'radial-gradient(ellipse at center, black 30%, transparent 80%)',
      }} />
    </AbsoluteFill>
  );
};
const hex = (a: number) => Math.round(Math.max(0, Math.min(1, a)) * 255).toString(16).padStart(2, '0');
