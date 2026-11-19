import React from 'react';
import {AbsoluteFill, Easing, OffthreadVideo, Sequence, interpolate, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';

export const FPS = 60;
const FONT = '"SF Pro Display", -apple-system, BlinkMacSystemFont, "Helvetica Neue", Inter, Arial, sans-serif';

export type PromoProps = {
  bg: string; ink: string; accent: string;
  demoSrc: string; demoDurationSec: number; demoStartSec: number; demoAspect: number; muteDemo: boolean;
  hook: string[]; beatSec: number;
  headline: string; chapters: {at: number; text: string}[];
  outro: string[]; cta: string;
};

const sec = (s: number) => Math.round(s * FPS);
const OVERLAP = 0.3;
const OUT = Easing.bezier(0.16, 1, 0.3, 1);   // fast out, long settle
const IN = Easing.bezier(0.7, 0, 0.84, 0);
const ramp = (f: number, a: number, b: number, e: (t: number) => number = OUT) =>
  b > a ? interpolate(f, [a, b], [0, 1], {easing: e, extrapolateLeft: 'clamp', extrapolateRight: 'clamp'}) : f >= b ? 1 : 0;

export const timing = (p: PromoProps) => {
  const beat = sec(p.beatSec);
  const hookF = Math.max(1, p.hook.length) * beat;
  const demoF = sec(p.demoDurationSec);
  const demoFrom = Math.max(0, hookF - sec(OVERLAP));
  const demoTo = demoFrom + demoF;
  const outroFrom = demoTo - sec(OVERLAP);
  const outroF = Math.max(1, p.outro.length) * beat + sec(0.7);
  return {hookF, demoF, demoFrom, demoTo, outroFrom, outroF, total: outroFrom + outroF};
};

// ---------- text layout ----------
type Tok = {w: string; accent: boolean};
const tokenize = (text: string): Tok[] => {
  let on = false;
  const out: Tok[] = [];
  for (const raw of text.split(/\s+/).filter(Boolean)) {
    if (raw.startsWith('*')) on = true;
    out.push({w: raw.replace(/\*/g, ''), accent: on});
    if (raw.endsWith('*') && raw.length > 1) on = false;
  }
  return out;
};

const greedy = (toks: Tok[], cap: number): Tok[][] => {
  const lines: Tok[][] = [];
  let cur: Tok[] = [];
  let len = 0;
  for (const t of toks) {
    const add = (cur.length ? 1 : 0) + t.w.length;
    if (cur.length && len + add > cap) { lines.push(cur); cur = [t]; len = t.w.length; }
    else { cur.push(t); len += add; }
  }
  if (cur.length) lines.push(cur);
  return lines;
};

// Approximate: 0.56em average glyph width for heavy sans. Largest size whose lines fit the box.
const layoutLines = (toks: Tok[], boxW: number, boxH: number, max: number, min = 48) => {
  const longest = Math.max(...toks.map((t) => t.w.length));
  const total = toks.reduce((a, t) => a + t.w.length, 0) + toks.length - 1;
  for (let size = max; size >= min; size -= 4) {
    const cap = boxW / (size * 0.56);
    if (longest > cap) continue;
    let lines = greedy(toks, cap);
    if (lines.length > 1) {                       // balance line lengths
      const bal = greedy(toks, Math.max(longest, Math.ceil((total / lines.length) * 1.12)));
      if (bal.length <= lines.length) lines = bal;
    }
    if (lines.length * size * 1.06 <= boxH) return {size, lines};
  }
  return {size: min, lines: [toks]};
};

const Caption: React.FC<{
  text: string; f: number; dur: number; boxW: number; boxH: number; max: number;
  ink: string; accent: string; exit?: boolean;
}> = ({text, f, dur, boxW, boxH, max, ink, accent, exit = true}) => {
  const {size, lines} = React.useMemo(() => layoutLines(tokenize(text), boxW, boxH, max), [text, boxW, boxH, max]);
  const inF = sec(0.55), outF = sec(0.32);
  const out = exit ? ramp(f, dur - outF, dur, IN) : 0;
  let idx = 0;
  return (
    <div style={{display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', width: boxW, height: boxH}}>
      {lines.map((line, li) => (
        <div key={li} style={{display: 'flex', gap: size * 0.24, lineHeight: 1.04, whiteSpace: 'nowrap'}}>
          {line.map((tok) => {
            const i = idx++;
            const a = ramp(f, i * 3, i * 3 + inF);
            return (
              <span key={i} style={{
                display: 'inline-block', fontSize: size, fontWeight: 800, letterSpacing: '-0.045em',
                color: tok.accent ? accent : ink, opacity: a * (1 - out),
                transform: `translateY(${(1 - a) * size * 0.34 - out * size * 0.16}px)`,
                filter: `blur(${(1 - a) * size * 0.1 + out * size * 0.05}px)`,
              }}>{tok.w}</span>
            );
          })}
        </div>
      ))}
    </div>
  );
};

// ---------- scenes ----------
const Beats: React.FC<{p: PromoProps; items: string[]; lastExtra: number; exitLast: boolean; max: number}> =
  ({p, items, lastExtra, exitLast, max}) => {
    const f = useCurrentFrame();
    const {width, height} = useVideoConfig();
    const beat = sec(p.beatSec);
    const boxW = width * 0.86, boxH = height * 0.6;
    return (
      <>
        {items.map((text, i) => {
          const last = i === items.length - 1;
          const local = f - i * beat;
          const dur = beat + (last ? lastExtra : sec(0.12));
          if (local < 0 || local > dur) return null;
          return (
            <AbsoluteFill key={i} style={{alignItems: 'center', justifyContent: 'center'}}>
              <Caption text={text} f={local} dur={dur} boxW={boxW} boxH={boxH} max={max}
                ink={p.ink} accent={p.accent} exit={last ? exitLast : true} />
            </AbsoluteFill>
          );
        })}
      </>
    );
  };

const Outro: React.FC<{p: PromoProps}> = ({p}) => {
  const f = useCurrentFrame();
  const {width, height} = useVideoConfig();
  const portrait = height > width;
  const t = f - (p.outro.length - 1) * sec(p.beatSec);
  const a = ramp(t, sec(0.35), sec(0.9));
  return (
    <>
      <Beats p={p} items={p.outro} lastExtra={sec(0.7)} exitLast={false} max={portrait ? 190 : 230} />
      {p.cta ? (
        <div style={{position: 'absolute', left: 0, right: 0, bottom: height * 0.12, textAlign: 'center',
          fontSize: width * (portrait ? 0.04 : 0.022), fontWeight: 600, letterSpacing: '0.02em',
          color: p.ink, opacity: a * 0.5, transform: `translateY(${(1 - a) * 16}px)`}}>{p.cta}</div>
      ) : null}
    </>
  );
};

const Demo: React.FC<{p: PromoProps; demoF: number}> = ({p, demoF}) => {
  const f = useCurrentFrame();
  const {width, height} = useVideoConfig();
  const portrait = height > width;
  const caps = [{at: 0.2, text: p.headline}, ...p.chapters].filter((c) => c.text);
  const top = height * 0.06;
  const capH = caps.length ? height * (portrait ? 0.22 : 0.2) : 0;
  const boxW = width * (portrait ? 0.9 : 0.86);
  const boxH = height - capH - top - height * 0.06;
  let fw = boxW, fh = fw / p.demoAspect;
  if (fh > boxH) { fh = boxH; fw = fh * p.demoAspect; }
  const fx = (width - fw) / 2, fy = top + capH + (boxH - fh) / 2;
  const rad = fw * 0.022;

  const e = ramp(f, 0, sec(1.1));
  const x = ramp(f, demoF - sec(0.5), demoF, IN);
  const scale = (0.82 + 0.18 * e) * (1 - 0.05 * x);
  const ty = (1 - e) * height * 0.07 - x * height * 0.02;
  const op = Math.min(1, e * 2.5) * (1 - x);
  const src = /^(https?:|data:)/.test(p.demoSrc) ? p.demoSrc : staticFile(p.demoSrc);
  const from = sec(p.demoStartSec);

  return (
    <>
      {caps.map((c, i) => {
        const a = sec(c.at);
        const b = i + 1 < caps.length ? sec(caps[i + 1].at) + sec(0.3) : demoF - sec(0.15);
        const local = f - a;
        if (local < 0 || local > b - a) return null;
        return (
          <div key={i} style={{position: 'absolute', left: (width - boxW) / 2, top, width: boxW, height: capH}}>
            <Caption text={c.text} f={local} dur={b - a} boxW={boxW} boxH={capH}
              max={portrait ? 112 : 124} ink={p.ink} accent={p.accent} />
          </div>
        );
      })}
      <div style={{
        position: 'absolute', left: fx, top: fy, width: fw, height: fh, borderRadius: rad, overflow: 'hidden',
        background: '#000', opacity: op, transform: `translateY(${ty}px) scale(${scale})`,
        boxShadow: '0 2px 4px rgba(0,0,0,.06), 0 14px 28px rgba(0,0,0,.09), 0 52px 104px rgba(0,0,0,.16)',
      }}>
        <OffthreadVideo src={src} trimBefore={from} durationInFrames={demoF} muted={p.muteDemo}
          volume={(vf) => Math.min(1, vf / sec(0.3)) * (1 - ramp(vf, demoF - sec(0.5), demoF, IN))}
          style={{width: '100%', height: '100%', objectFit: 'cover'}} />
        <div style={{position: 'absolute', inset: 0, borderRadius: rad, boxShadow: 'inset 0 0 0 1px rgba(0,0,0,.08)'}} />
      </div>
    </>
  );
};

export const Promo: React.FC<PromoProps> = (p) => {
  const t = timing(p);
  const {width, height} = useVideoConfig();
  const portrait = height > width;
  return (
    <AbsoluteFill style={{backgroundColor: p.bg, fontFamily: FONT}}>
      <Sequence from={0} durationInFrames={t.hookF + sec(OVERLAP)}>
        <Beats p={p} items={p.hook} lastExtra={sec(OVERLAP)} exitLast max={portrait ? 190 : 230} />
      </Sequence>
      <Sequence from={t.demoFrom} durationInFrames={t.demoF}><Demo p={p} demoF={t.demoF} /></Sequence>
      <Sequence from={t.outroFrom} durationInFrames={t.outroF}><Outro p={p} /></Sequence>
    </AbsoluteFill>
  );
};
