import {loadFont as loadInter} from '@remotion/google-fonts/Inter';
import {loadFont as loadMono} from '@remotion/google-fonts/JetBrainsMono';

export const sans = loadInter('normal', {weights: ['400', '500', '600', '700', '800', '900'], subsets: ['latin']}).fontFamily;
export const mono = loadMono('normal', {weights: ['400', '500', '700'], subsets: ['latin']}).fontFamily;

export const C = {
  bg: '#07060D',
  bg2: '#0D0B18',
  panel: '#100E1C',
  panel2: '#171428',
  line: 'rgba(167,139,250,0.18)',
  text: '#E6EDF3',
  muted: '#8B93A7',
  dim: '#5B6275',
  purple: '#8B5CF6',
  purple2: '#A78BFA',
  indigo: '#4F46E5',
  green: '#34D399',
  red: '#F87171',
  amber: '#FBBF24',
  blue: '#60A5FA',
  pg: '#336791',
};
export const FPS = 30;
