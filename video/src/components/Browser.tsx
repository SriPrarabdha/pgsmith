// A real Flagsmith UI take (public/ui/*.mp4, recorded by capture/shoot-ui.mjs) in a browser frame,
// with optional camera moves. Holds the last frame once the take ends.
import React from 'react';
import {Freeze, interpolate, OffthreadVideo, Sequence, staticFile, useCurrentFrame} from 'remotion';
import ui from '../data/ui.json';
import {FPS} from '../theme';
import {Window} from './Window';
import {clamp, ease} from './anim';

export type Take = keyof typeof ui;
export type Cam = {f: number; scale: number; x: number; y: number}; // focus point x,y in 0..1 of the take

export const Browser: React.FC<{
  take: Take; width: number; from?: number; startAt?: number; rate?: number; cams?: Cam[];
  style?: React.CSSProperties; url?: string; endAt?: number;
}> = ({take, width, from = 0, startAt = 0, rate = 1, cams = [], style, url, endAt}) => {
  const f = useCurrentFrame() - from;
  const t = ui[take];
  const height = Math.round(width * 9 / 16) + 44;
  const vidEnd = Math.floor(((endAt ?? t.seconds) - startAt) * FPS / rate) - 2;
  const k = cams.length ? camAt(cams, f) : {scale: 1, x: 0.5, y: 0.5};
  const W = width, H = width * 9 / 16;
  // translate so the focus point stays centred while zoomed (clamped to the edges)
  const tx = Math.min(0, Math.max(W - W * k.scale, W / 2 - k.x * W * k.scale));
  const ty = Math.min(0, Math.max(H - H * k.scale, H / 2 - k.y * H * k.scale));
  const video = <OffthreadVideo src={staticFile(t.file)} startFrom={Math.round(startAt * FPS)} playbackRate={rate} muted
    style={{width: W, height: H, display: 'block'}} />;
  return (
    <Window url={url ?? `localhost:8000  ·  Flagsmith 2.295.2 (self-hosted)`} width={width} height={height} light style={style}>
      <div data-ov="Flagsmith UI" style={{width: W, height: H, transform: `translate(${tx}px, ${ty}px) scale(${k.scale})`, transformOrigin: '0 0'}}>
        {f < vidEnd ? <Sequence from={from} layout="none">{video}</Sequence>
          : <Freeze frame={vidEnd}>{video}</Freeze>}
      </div>
    </Window>
  );
};

function camAt(cams: Cam[], f: number) {
  if (f <= cams[0].f) return cams[0];
  for (let i = 1; i < cams.length; i++) {
    const a = cams[i - 1], b = cams[i];
    if (f <= b.f) {
      const p = interpolate(f, [a.f, b.f], [0, 1], {...clamp, easing: ease});
      return {f, scale: a.scale + (b.scale - a.scale) * p, x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p};
    }
  }
  return cams[cams.length - 1];
}
