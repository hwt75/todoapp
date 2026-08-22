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

// Every light-mode colour token not already covered by a state family (tint/ink, tested
// on its own below) or a mode-stable fill (deliberately absent from dark, tested on its
// own below) is expected to carry its own dark counterpart — derived rather than a
// hand-maintained list, so a token added later is covered without anyone remembering to
// add it here.
const DARK_COUNTERPART_TOKENS = Object.keys(light).filter(
  (name) =>
    light[name].startsWith('#') &&
    !STATE_FAMILIES.some((family) => name === `${family}-tint` || name === `${family}-ink`) &&
    !MODE_STABLE_FILLS.includes(name),
);

const FILL_INK_PAIRS = MODE_STABLE_FILLS.filter((name) => name.endsWith('-ink')).map(
  (ink) => [ink, ink.replace(/-ink$/, '-fill')] as const,
);

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

  it('every rounded value is implemented', () => {
    const design = parseDesignSection(DESIGN, 'rounded');
    for (const [key, value] of Object.entries(design)) {
      // DESIGN.md's Tailwind-style `DEFAULT` key names the un-suffixed token.
      const tokenName = `radius-${key.toLowerCase()}`;
      expect(light[tokenName], `${tokenName} missing or drifted`).toBe(value);
    }
  });

  it('every spacing value is implemented', () => {
    const design = parseDesignSection(DESIGN, 'spacing');
    for (const [key, value] of Object.entries(design)) {
      const tokenName = `space-${key}`;
      expect(light[tokenName], `${tokenName} missing or drifted`).toBe(value);
    }
  });

  it('every colour in DESIGN.md is implemented in tokens.css', () => {
    // The reverse of "every colour token matches DESIGN.md" above: a colour declared in
    // DESIGN.md but never implemented in the stylesheet would otherwise go unnoticed.
    for (const [designKey, value] of Object.entries(designColors)) {
      const isDark = designKey.endsWith('-dark');
      const tokenName = isDark ? designKey.slice(0, -'-dark'.length) : designKey;
      const tokens = isDark ? dark : light;
      expect(
        tokens[tokenName]?.toLowerCase(),
        `${designKey} declared in DESIGN.md but missing from tokens.css`,
      ).toBe(value.toLowerCase());
    }
  });
});

describe('dark mode is a declared set, not an inversion', () => {
  it.each(STATE_FAMILIES)('%s carries a dark tint and ink', (family) => {
    expect(dark[`${family}-tint`], `${family}-tint has no dark counterpart`).toBeDefined();
    expect(dark[`${family}-ink`], `${family}-ink has no dark counterpart`).toBeDefined();
  });

  it.each(DARK_COUNTERPART_TOKENS)('%s carries a dark counterpart', (name) => {
    expect(dark[name], `${name} has no dark counterpart`).toBeDefined();
  });

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

  it.each(
    STATE_FAMILIES.flatMap((family) => [
      [family, 'light' as const],
      [family, 'dark' as const],
    ]),
  )('%s ink on %s tint', (family, mode) => {
    const tokens = mode === 'dark' ? dark : light;
    const ratio = contrastRatio(tokens[`${family}-ink`], tokens[`${family}-tint`]);
    expect(ratio, `${family} (${mode}) is ${ratio.toFixed(2)}:1`).toBeGreaterThanOrEqual(TEXT_AA);
  });

  it.each(FILL_INK_PAIRS)('%s on %s', (ink, fill) => {
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

  it('spends the rationed type roles no faster than the budget allows', () => {
    // `figure` may be claimed by exactly two elements in the finished product — the debt
    // total and Epic 3's focus timer — and `quoted` by exactly one string, in the referee's
    // collection message. The rule is a budget, not a ban, and this is what stops the third
    // claimant arriving unnoticed.
    expect(light['type-figure'], 'the figure role must be defined').toBeDefined();
    expect(light['font-quoted'], 'the quoted role must be defined').toBeDefined();

    // The pattern used to carry a stray literal backspace where a `\b` was meant, so it matched
    // nothing and the budget it exists to police was never counted at all. It now matches the
    // token as a `var()` argument however it is written — `var(--type-figure)` and
    // `var(--type-figure, 2rem)` alike — so a claim wearing a fallback cannot slip past the way
    // the backspace did. The tracking token beside each claim is part of that claim, not a
    // second one, which is why the closing `)` or `,` is required.
    const figureUses = GLOBALS.match(/var\(\s*--type-figure\s*[,)]/g) ?? [];
    expect(
      figureUses.length,
      'the figure role is spent by the debt block (2.6) and the focus timer (3.1). Exactly two, ' +
        'and asserted in both directions: a third claimant takes the size from "this is the ' +
        'number" to "this is a number", and a missing one means a claimant was deleted or ' +
        'renamed and the budget is being counted against something that is no longer there.',
    ).toBe(2);

    // Nothing has earned the serif yet. A second serif string deletes the signal the first
    // one carries.
    expect(GLOBALS).not.toMatch(/font-quoted/);
  });

  it('keeps literal colours out of the base stylesheet', () => {
    // Every colour resolves to a token. tokens.css is the one place a hex may appear.
    expect(GLOBALS).not.toMatch(/#[0-9a-fA-F]{3,8}\b/);
  });
});
