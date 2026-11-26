import {Config} from '@remotion/cli/config';
Config.setVideoImageFormat('jpeg');
Config.setJpegQuality(95);
Config.setConcurrency(16);
Config.setBrowserExecutable('/usr/bin/google-chrome');
Config.setChromiumOpenGlRenderer('angle');
