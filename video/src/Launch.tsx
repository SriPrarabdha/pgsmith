import React from 'react';
import {AbsoluteFill, Audio, Sequence, staticFile} from 'remotion';
import {Captions} from './components/Captions';
import {OverlapProbe} from './components/OverlapProbe';
import {scenes, vo} from './timeline';
import {Cold} from './scenes/Cold';
import {Title} from './scenes/Title';
import {Problem} from './scenes/Problem';
import {Solution} from './scenes/Solution';
import {Steps} from './scenes/Steps';
import {Step1} from './scenes/Step1';
import {Step2} from './scenes/Step2';
import {Step3} from './scenes/Step3';
import {Step4} from './scenes/Step4';
import {Release} from './scenes/Release';
import {Twist} from './scenes/Twist';
import {Apply} from './scenes/Apply';
import {Proof} from './scenes/Proof';
import {Outro} from './scenes/Outro';
import {C, sans} from './theme';

// the music sits at 0.26 between lines and ducks to 0.05 under the voice (0.3 s ramps)
const VO_SPANS = scenes.filter(s => s.vo).map(s => [s.from + s.leadF, s.from + s.leadF + s.voF] as const);
const musicVolume = (f: number) => {
  let duck = 0;
  for (const [a, b] of VO_SPANS) {
    const d = f < a ? (a - f) / 9 : f > b ? (f - b) / 12 : 0; // frames of ramp before / after
    duck = Math.max(duck, Math.max(0, 1 - d));
  }
  return 0.26 - (0.26 - 0.05) * duck;
};

const SCENE_COMPONENTS: Record<string, React.FC> = {
  cold: Cold, title: Title, problem: Problem, solution: Solution, steps: Steps, step1: Step1, step2: Step2,
  step3: Step3, step4: Step4, release: Release, twist: Twist, apply: Apply, proof: Proof, outro: Outro,
};

export const Launch: React.FC<{captions?: boolean; music?: string | null; probe?: boolean}> = ({captions = true, music = 'music/bed.wav', probe = false}) => (
  <AbsoluteFill style={{background: C.bg, fontFamily: sans}}>
    {scenes.map(s => {
      const Comp = SCENE_COMPONENTS[s.id];
      return (
        <Sequence key={s.id} from={s.from} durationInFrames={s.frames} name={s.id}>
          <Comp />
          {s.vo && <Sequence from={s.leadF} layout="none"><Audio src={staticFile(vo[s.vo].file)} /></Sequence>}
          {captions && s.vo && s.id !== 'title' && <Captions text={vo[s.vo].text} start={s.leadF} frames={s.voF} />}
        </Sequence>
      );
    })}
    {music && <Audio src={staticFile(music)} volume={musicVolume} />}
    {probe && <OverlapProbe />}
  </AbsoluteFill>
);
