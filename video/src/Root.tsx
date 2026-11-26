import React from 'react';
import {Composition, Still} from 'remotion';
import {Launch} from './Launch';
import {TOTAL} from './timeline';
import {FPS} from './theme';
import {Thumbnail} from './Thumbnail';

export const Root: React.FC = () => (
  <>
    <Composition id="Launch" component={Launch} durationInFrames={TOTAL} fps={FPS} width={1920} height={1080}
      defaultProps={{captions: true, music: 'music/bed.wav' as string | null}} />
    <Still id="Thumbnail" component={Thumbnail} width={1920} height={1080} />
  </>
);
