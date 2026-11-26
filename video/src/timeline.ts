// Scene order and timing. Each scene's length follows its voice-over line (src/data/vo.json,
// written by tts/gen.py), so regenerating the voice re-times the whole video.
import voRaw from './data/vo.json';
import {FPS} from './theme';

export type VO = {file: string; seconds: number; text: string};
export const vo = voRaw as unknown as Record<string, VO>;

type SceneDef = {id: string; vo?: string; lead: number; tail: number; min?: number};
// lead/tail in seconds: silence before the line starts and after it ends
export const SCENES: SceneDef[] = [
  {id: 'cold', vo: 'cold', lead: 2.2, tail: 0.5},
  {id: 'title', vo: 'title', lead: 0.4, tail: 1.2},
  {id: 'problem', vo: 'problem', lead: 0.4, tail: 0.6},
  {id: 'solution', vo: 'solution', lead: 0.3, tail: 0.8},
  {id: 'steps', vo: 'steps', lead: 0.3, tail: 0.4},
  {id: 'step1', vo: 'step1', lead: 0.3, tail: 1.0},
  {id: 'step2', vo: 'step2', lead: 0.3, tail: 0.4},
  {id: 'step3', vo: 'step3', lead: 0.3, tail: 0.6},
  {id: 'step4', vo: 'step4', lead: 0.3, tail: 1.1},
  {id: 'release', vo: 'release', lead: 0.3, tail: 1.0},
  {id: 'twist', vo: 'twist', lead: 0.3, tail: 0.6},
  {id: 'apply', vo: 'apply', lead: 0.3, tail: 1.1},
  {id: 'proof', vo: 'proof', lead: 0.3, tail: 0.8},
  {id: 'outro', vo: 'outro', lead: 0.3, tail: 2.3},
];

export type Scene = SceneDef & {from: number; frames: number; leadF: number; voF: number};
export const scenes: Scene[] = (() => {
  let at = 0;
  return SCENES.map(s => {
    const voS = s.vo ? vo[s.vo]?.seconds ?? 3 : 0;
    const frames = Math.max(Math.round((s.min ?? 0) * FPS), Math.round((s.lead + voS + s.tail) * FPS));
    const sc = {...s, from: at, frames, leadF: Math.round(s.lead * FPS), voF: Math.round(voS * FPS)};
    at += frames;
    return sc;
  });
})();
export const TOTAL = scenes.reduce((a, s) => a + s.frames, 0);
export const scene = (id: string) => scenes.find(s => s.id === id)!;

// Frame (within a scene) at which a phrase of its voice-over is spoken, estimated from its position
// in the text (speech rate is close to uniform within a line).
export function cue(id: string, phrase: string, offset = 0): number {
  const s = scene(id);
  const text = vo[s.vo!].text;
  const i = text.indexOf(phrase);
  if (i < 0) throw new Error(`cue: "${phrase}" not in ${id}`);
  return Math.round(s.leadF + (i / text.length) * s.voF + offset * FPS);
}
