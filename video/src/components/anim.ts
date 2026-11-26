import {Easing, interpolate, spring} from 'remotion';
import {FPS} from '../theme';
export const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;
export const ease = Easing.bezier(0.22, 1, 0.36, 1);
/** 0→1 over `dur` frames starting at `at` (ease-out). */
export const t01 = (f: number, at: number, dur = 15, e = ease) => interpolate(f, [at, at + dur], [0, 1], {...clamp, easing: e});
export const pop = (f: number, at: number, damping = 14) => spring({frame: f - at, fps: FPS, config: {damping, stiffness: 160, mass: 0.7}});
/** entrance: fade + rise */
export const enter = (f: number, at: number, dist = 24, dur = 16) => {
  const p = t01(f, at, dur);
  return {opacity: p, transform: `translateY(${(1 - p) * dist}px)`};
};
export const fmt = (n: number) => Math.round(n).toLocaleString('en-US');
