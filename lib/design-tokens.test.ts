import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  METADATA_COLORS,
  contrastRatio,
  parseCssTokens,
  parseDesignSection,
} from './design-tokens';

const PROJECT_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const CSS = readFileSync(join(PROJECT_ROOT, 'app', 'tokens.css'), 'utf8');
const GLOBALS = readFileSync(join(PROJECT_ROOT, 'app', 'globals.css'), 'utf8');
const DESIGN = readFileSync(
  join(
    PROJECT_ROOT,
    '_bmad-output',
    'planning-artifacts',
    'ux-designs',
    'ux-todoapp-2026-08-11',
    'DESIGN.md',
  ),
  'utf8',
);

const { light, dark } = parseCssTokens(CSS);
const designColors = parseDesignSection(DESIGN, 'colors');

/** DESIGN.md writes `held-tint` / `held-tint-dark`; the CSS splits those across blocks. */
function designValue(name: string, mode: 'light' | 'dark'): string | undefined {
  return designColors[mode === 'dark' ? `${name}-dark` : name];
}

const STATE_FAMILIES = ['held', 'urgent', 'failed'] as const;
const MODE_STABLE_FILLS = ['action-fill', 'action-ink', 'destructive-fill', 'destructive-ink'];

describe('token parity with DESIGN.md', () => {
  // DESIGN.md is the source of truth and a human-owned artifact. Nothing mechanical keeps
  // the stylesheet in step with it, so this is the thing that does.
  const colorTokens = Object.keys(light).filter((name) => light[name].startsWith('#'));

  it('finds the colours to compare', () => {
    expect(colorTokens.length).toBeGreaterThan(15);
  });

  it.each([
    ['light' as const, () => light],
    ['dark' as const, () => dark],
  ])('every %s colour token matches DESIGN.md', (mode, getTokens) => {
    const tokens = getTokens();
    for (const [name, value] of Object.entries(tokens)) {
      if (!value.startsWith('#')) continue;
      const expected = designValue(name, mode);
      expect(expected, `${name} (${mode}) is not defined in DESIGN.md`).toBeDefined();
      expect(value.toLowerCase(), `${name} (${mode}) drifted from DESIGN.md`).toBe(
        expected!.toLowerCase(),
      );
    }
  });

  it.each([['rounded', 'radius', { DEFAULT: 'default', card: 'card', pill: 'pill' }]])(
    'every %s value is implemented',
    (section, prefix, mapping) => {
      const design = parseDesignSection(DESIGN, section);
      for (const [designKey, tokenKey] of Object.entries(mapping)) {
        expect(light[`${prefix}-${tokenKey}`], `${prefix}-${tokenKey} missing`).toBe(
          design[designKey],
        );
      }
    },
  );

  it('every spacing value is implemented', () => {
    const design = parseDesignSection(DESIGN, 'spacing');
    for (const [key, value] of Object.entries(design)) {
      const tokenName = /^\d+$/.test(key) ? `space-${key}` : `space-${key}`;
      expect(light[tokenName], `${tokenName} missing or drifted`).toBe(value);
    }
  });
});

describe('dark mode is a declared set, not an inversion', () => {
  it.each(STATE_FAMILIES)('%s carries a dark tint and ink', (family) => {
    expect(dark[`${family}-tint`], `${family}-tint has no dark counterpart`).toBeDefined();
    expect(dark[`${family}-ink`], `${family}-ink has no dark counterpart`).toBeDefined();
  });

  it.each(['surface-base', 'surface-card', 'surface-sunken', 'text-primary', 'border'])(
    '%s carries a dark counterpart',
    (name) => {
      expect(dark[name]).toBeDefined();
    },
  );

  // The fills carry their own background, which is what makes them mode-stable and lets
  // a coloured area read as pressable in either mode. A dark variant would break that,
  // so its absence is the requirement — not an omission to be tidied up later.
  it.each(MODE_STABLE_FILLS)('%s has no dark variant', (name) => {
    expect(dark[name], `${name} must not be redefined in dark mode`).toBeUndefined();
  });
});

describe('contrast clears WCAG AA', () => {
  // The accessibility review found no ratio was ever named, and said the risk is the next
  // pair added rather than today's values. This is where the floor lives.
  const TEXT_AA = 4.5;

  it.each([
    ['held', 'light' as const],
    ['held', 'dark' as const],
    ['urgent', 'light' as const],
    ['urgent', 'dark' as const],
    ['failed', 'light' as const],
    ['failed', 'dark' as const],
  ])('%s ink on %s tint', (family, mode) => {
    const tokens = mode === 'dark' ? dark : light;
    const ratio = contrastRatio(tokens[`${family}-ink`], tokens[`${family}-tint`]);
    expect(ratio, `${family} (${mode}) is ${ratio.toFixed(2)}:1`).toBeGreaterThanOrEqual(TEXT_AA);
  });

  it.each([
    ['action-ink', 'action-fill'],
    ['destructive-ink', 'destructive-fill'],
  ])('%s on %s', (ink, fill) => {
    const ratio = contrastRatio(light[ink], light[fill]);
    expect(ratio, `${ink}/${fill} is ${ratio.toFixed(2)}:1`).toBeGreaterThanOrEqual(TEXT_AA);
  });

  it.each([
    ['light' as const, () => light],
    ['dark' as const, () => dark],
  ])('body text on the base surface in %s mode', (mode, getTokens) => {
    const tokens = getTokens();
    const ratio = contrastRatio(tokens['text-primary'], tokens['surface-base']);
    expect(
      ratio,
      `text-primary on surface-base (${mode}) is ${ratio.toFixed(2)}:1`,
    ).toBeGreaterThanOrEqual(TEXT_AA);
  });

  it('secondary text still clears AA, in both modes', () => {
    for (const [mode, tokens] of [
      ['light', light],
      ['dark', dark],
    ] as const) {
      const ratio = contrastRatio(tokens['text-secondary'], tokens['surface-base']);
      expect(ratio, `text-secondary (${mode}) is ${ratio.toFixed(2)}:1`).toBeGreaterThanOrEqual(
        TEXT_AA,
      );
    }
  });
});

describe('the metadata escape hatch stays honest', () => {
  // These two exist only because manifest JSON and <meta> tags cannot resolve a custom
  // property. Untested they would just be literal hexes with a nicer name, which is the
  // exact thing this layer forbids.
  it('surfaceBase matches the stylesheet', () => {
    expect(METADATA_COLORS.surfaceBase.toLowerCase()).toBe(light['surface-base'].toLowerCase());
  });

  it('surfaceBaseDark matches the dark stylesheet', () => {
    expect(METADATA_COLORS.surfaceBaseDark.toLowerCase()).toBe(dark['surface-base'].toLowerCase());
  });

  it('stays as small as it claims to be', () => {
    // A growing list means values are leaking out of CSS into TypeScript.
    expect(Object.keys(METADATA_COLORS)).toHaveLength(2);
  });
});

describe('structural rules the stylesheet cannot state about itself', () => {
  it('declares no shadow anywhere', () => {
    // Elevation is hairlines and one tonal step. Depth would be decoration, and
    // decoration is a cost on a screen the user is already reluctant to open.
    expect(CSS).not.toMatch(/box-shadow/);
    expect(GLOBALS).not.toMatch(/box-shadow/);
  });

  it('reserves the pill radius — nothing pressable uses it', () => {
    // The pill silhouette is what separates a state label from a control at a glance.
    expect(light['radius-pill']).toBe('9999px');
    const buttonBlock = /button\s*\{[^}]*\}/.exec(GLOBALS)?.[0] ?? '';
    expect(buttonBlock).not.toMatch(/radius-pill/);
  });

  it('uses hairlines at 0.5px, not 1px borders', () => {
    expect(light.hairline).toBe('0.5px');
  });

  it('spends neither rationed type role', () => {
    // `figure` may be claimed by exactly two elements in the finished product and
    // `quoted` by exactly one string. Neither is on this shell.
    expect(light['type-figure'], 'the figure role must be defined').toBeDefined();
    expect(light['font-quoted'], 'the quoted role must be defined').toBeDefined();
    expect(GLOBALS).not.toMatch(/type-figure|font-quoted/);
  });

  it('keeps literal colours out of the base stylesheet', () => {
    // Every colour resolves to a token. tokens.css is the one place a hex may appear.
    expect(GLOBALS).not.toMatch(/#[0-9a-fA-F]{3,8}\b/);
  });
});
