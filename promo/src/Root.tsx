import React from 'react';
import {CalculateMetadataFunction, Composition} from 'remotion';
import {FPS, Promo, PromoProps, timing} from './Promo';

const base: PromoProps = {
  bg: '#FFFFFF', ink: '#0A0A0A', accent: '#2F5BFF',
  demoSrc: 'demo.mp4', demoDurationSec: 30, demoStartSec: 0, demoAspect: 16 / 9, muteDemo: false,
  hook: ['Your demo *looks* like a screen recording.', 'It shouldn’t.', 'Meet *Lumen*.'],
  beatSec: 1.15,
  headline: 'Press record. Ship the demo.',
  chapters: [],
  outro: ['Record once.', '*Ship* everywhere.'],
  cta: '',
};

const base9x16: PromoProps = {...base, demoAspect: 9 / 16};

// The render duration is always derived from the incoming props. The static
// durationInFrames on each Composition is just the derivation of its own defaults
// (Remotion requires a literal at the call site when width/height are explicit).
const calc: CalculateMetadataFunction<PromoProps> = ({props}) => ({durationInFrames: timing(props).total});

export const Root: React.FC = () => (
  <>
    <Composition id="Promo-16x9" component={Promo} width={1920} height={1080} fps={FPS}
      durationInFrames={timing(base).total} defaultProps={base} calculateMetadata={calc} />
    <Composition id="Promo-9x16" component={Promo} width={1080} height={1920} fps={FPS}
      durationInFrames={timing(base9x16).total} defaultProps={base9x16} calculateMetadata={calc} />
  </>
);
