import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { COMMITMENT_CADENCES } from './commitment';
import {
  COMMITMENT_STATES,
  STATE_PRESENTATION,
  type StateFamily,
  rowLabel,
  stateToday,
} from './commitment-state';

const PROJECT_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const GLOBALS = readFileSync(join(PROJECT_ROOT, 'app', 'globals.css'), 'utf8');

const FAMILIES: StateFamily[] = ['neutral', 'held', 'urgent', 'failed'];

describe('every state has a presentation', () => {
  it.each(COMMITMENT_STATES.map((state) => [state]))('%s', (state) => {
    const presentation = STATE_PRESENTATION[state];
    expect(presentation, `${state} has no presentation`).toBeDefined();
    expect(FAMILIES, `${state} uses a family that is not one of the four`).toContain(
      presentation.family,
    );
  });

  it.each(COMMITMENT_STATES.map((state) => [state]))(
    '%s carries a word, not only a colour',
    (state) => {
      // The accessibility floor: a user who cannot distinguish the tints must lose nothing.
      expect(STATE_PRESENTATION[state].label.trim()).not.toBe('');
      expect(STATE_PRESENTATION[state].spoken.trim()).not.toBe('');
    },
  );

  it('leaves the four families distinguishable rather than collapsing two states into one meaning', () => {
    // `appealing` must not borrow `failed`: money on hold is money the author might keep.
    expect(STATE_PRESENTATION.appealing.family).toBe('urgent');
    expect(STATE_PRESENTATION.missed.family).toBe('failed');
    expect(STATE_PRESENTATION.not_yet.family).toBe('neutral');
  });
});

describe('today can only be honest', () => {
  // Settlement does not exist. Any state other than `not_yet` would be invented rather
  // than computed, and this test is what stops one appearing by accident.
  it.each(COMMITMENT_CADENCES.map((cadence) => [cadence]))(
    'a %s commitment is `not_yet` today',
    (cadence) => {
      expect(stateToday({ cadence })).toBe('not_yet');
    },
  );

  it('never reports a state settlement has not computed', () => {
    for (const cadence of COMMITMENT_CADENCES) {
      expect(['held', 'missed', 'appealing', 'waived']).not.toContain(stateToday({ cadence }));
    }
  });
});

describe('a row reads as one sentence', () => {
  it('joins name and state', () => {
    expect(rowLabel('Gym', 'not_yet', false)).toBe('Gym, not yet done today');
  });

  it('says the money part in words rather than leaving it to colour', () => {
    expect(rowLabel('No fap', 'not_yet', true)).toContain('costs money');
  });

  it.each(COMMITMENT_STATES.map((state) => [state]))('is non-empty for %s', (state) => {
    expect(rowLabel('Gym', state, false).length).toBeGreaterThan('Gym'.length);
  });
});

describe('the stylesheet keeps pills out of the button fills', () => {
  // A pill that borrowed a button fill would read as pressable, and the pill silhouette
  // is the one thing separating a state label from a control before either is read.
  const pillBlocks = [...GLOBALS.matchAll(/\.pill[\w-]*\s*\{[^}]*\}/g)].map((m) => m[0]);

  it('finds the pill rules', () => {
    expect(pillBlocks.length).toBeGreaterThan(1);
  });

  it.each([['--action-fill'], ['--destructive-fill']])('no pill uses %s', (token) => {
    for (const block of pillBlocks) {
      expect(block, `a pill rule reaches for ${token}`).not.toContain(token);
    }
  });

  it('every family has a pill class', () => {
    for (const family of FAMILIES) {
      expect(GLOBALS, `no .pill-${family} rule`).toMatch(new RegExp(`\\.pill-${family}\\b`));
    }
  });

  it('no pill rule is interactive', () => {
    for (const block of pillBlocks) {
      expect(block).not.toMatch(/cursor:\s*pointer/);
    }
  });
});

describe('rows grow with the type rather than clipping it', () => {
  // Dynamic Type is honoured throughout, and a fixed-height row is how that promise gets
  // broken at the largest sizes.
  const rowBlock = /\.row\s*\{[^}]*\}/.exec(GLOBALS)?.[0] ?? '';

  it('finds the row rule', () => {
    expect(rowBlock).not.toBe('');
  });

  it.each([['height'], ['max-height'], ['overflow: hidden'], ['white-space: nowrap']])(
    'does not pin %s',
    (property) => {
      expect(rowBlock).not.toContain(property);
    },
  );

  it('does not tint the row itself', () => {
    // Colour lives in the pill. Nine tinted rectangles stacked vertically read as an
    // alert panel, which is the exact artifact the product exists to avoid.
    expect(rowBlock).not.toMatch(/background/);
  });
});
