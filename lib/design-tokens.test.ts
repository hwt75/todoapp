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

// Four now, not three. `neutral` was a borrowed surface tone until the 2026-09-08
// redesign declared it a family in its own right — which means it gets held to the same
// contrast floor as the other three rather than being assumed fine because it is grey.
const STATE_FAMILIES = ['held', 'urgent', 'failed', 'neutral'] as const;

// Every light-mode colour token not already covered by a state family (tint/ink, tested on
// its own below) is expected to carry its own dark counterpart — derived rather than a
// hand-maintained list, so a token added later is covered without anyone remembering to add
// it here.
//
// Nothing is exempt from this any more. The action fill used to be, on the grounds that a
// fill carrying its own background is mode-stable by construction; on a cream page and a
// warm near-black that stopped being true, so the fill is declared twice and measured twice.
const DARK_COUNTERPART_TOKENS = Object.keys(light).filter(
  (name) =>
    light[name].startsWith('#') &&
    !STATE_FAMILIES.some((family) => name === `${family}-tint` || name === `${family}-ink`),
);

/** The one fill and its ink, held to the text floor in both modes. */
const FILL_INK_PAIRS = [['action-ink', 'action-fill']] as const;

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

  // There is one fill, and it is the only thing in the product that inverts rather than
  // merely re-tinting: dark ink on a dark-mode fill, light ink on a light-mode one. Stating
  // it here is what stops a future edit from "simplifying" the pair back to a single value
  // and quietly losing contrast in whichever mode it was not chosen for.
  it('the action fill is declared in both modes, not shared', () => {
    expect(dark['action-fill'], 'action-fill has no dark counterpart').toBeDefined();
    expect(dark['action-ink'], 'action-ink has no dark counterpart').toBeDefined();
    expect(dark['action-fill']).not.toBe(light['action-fill']);
    expect(dark['action-ink']).not.toBe(light['action-ink']);
  });

  it('has no destructive fill at all', () => {
    // Deleting a commitment is an outlined control in the failed family. A fill here would
    // be a second primary action wearing red, which is the thing the outline exists to
    // prevent — see DESIGN.md's `button-destructive`.
    expect(light['destructive-fill'], 'the destructive fill was reintroduced').toBeUndefined();
    expect(light['destructive-ink'], 'the destructive ink was reintroduced').toBeUndefined();
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

  it.each(
    FILL_INK_PAIRS.flatMap(([ink, fill]) => [
      [ink, fill, 'light' as const],
      [ink, fill, 'dark' as const],
    ]),
  )('%s on %s in %s mode', (ink, fill, mode) => {
    const tokens = mode === 'dark' ? dark : light;
    const ratio = contrastRatio(tokens[ink], tokens[fill]);
    expect(ratio, `${ink}/${fill} (${mode}) is ${ratio.toFixed(2)}:1`).toBeGreaterThanOrEqual(
      TEXT_AA,
    );
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
  it('spends its one shadow exactly twice', () => {
    // Elevation is hairlines and one tonal step, plus a single shadow that marks a layer
    // above the page — the tab bar, and the blocking morning declaration. Both are literally
    // on a layer above the page. A third would be depth used for importance, which is
    // decoration, and decoration is a cost on a screen the user is already reluctant to open.
    expect(CSS).not.toMatch(/box-shadow/);

    const declared = CSS.match(/--shadow-[\w-]+\s*:/g) ?? [];
    expect(declared, 'there is one shadow token, not a set').toHaveLength(1);

    const uses = GLOBALS.match(/box-shadow\s*:/g) ?? [];
    expect(
      uses.length,
      'the shadow belongs to the tab bar and the blocking declaration. A third claimant is ' +
        'depth spent on importance rather than on layering; a missing one means one of those ' +
        'two lost its lift and now sits flat on the page it is supposed to be above.',
    ).toBe(2);

    // Named rather than counted alone, so a shadow that moved to some other element still fails.
    expect(GLOBALS).toMatch(/\.tabbar\s*\{[^}]*box-shadow/);
    expect(GLOBALS).toMatch(/\.declaration\s*\{[^}]*box-shadow/);
  });

  it('reserves the pill radius — nothing pressable uses it', () => {
    // The pill silhouette is what separates a state label from a control at a glance.
    expect(light['radius-pill']).toBe('9999px');
    const buttonBlock = /button\s*\{[^}]*\}/.exec(GLOBALS)?.[0] ?? '';
    expect(buttonBlock).not.toMatch(/radius-pill/);
  });

  it('gives the urgent label its own silhouette', () => {
    // Urgent and failed must be separable before the words are read, and hue alone was not
    // doing it. The urgent label is the one label that is not a pill: outlined, 6px corners.
    // If this ever collapses back to `--radius-pill`, the second half of that separation is
    // gone and only the hue difference is left carrying it.
    expect(light['radius-urgent']).toBe('6px');
    const urgent = /\.pill-urgent\s*\{[^}]*\}/.exec(GLOBALS)?.[0] ?? '';
    expect(urgent, '.pill-urgent is missing').not.toBe('');
    expect(urgent).toMatch(/radius-urgent/);
    expect(urgent).not.toMatch(/radius-pill/);
    expect(urgent, 'urgent is outlined, not filled').toMatch(/background:\s*transparent/);
  });

  it('uses hairlines at 1px in the warm border tone, not 0.5px', () => {
    // Same lightness against the page as the old 0.5px black (1.25:1), but a list of rows
    // stops reading as a spreadsheet — and 0.5px in this colour was not reliably drawn.
    expect(light.hairline).toBe('1px');
  });

  it('spends the rationed type roles no faster than the budget allows', () => {
    // `figure` may be claimed by exactly two elements in the finished product — the debt
    // total and Epic 3's focus timer — and `quote` by exactly one string, in the referee's
    // collection message. The rule is a budget, not a ban, and this is what stops the third
    // claimant arriving unnoticed.
    expect(light['type-figure'], 'the figure role must be defined').toBeDefined();
    expect(light['font-quote'], 'the quoted role must be defined').toBeDefined();

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

    // The display face is rationed the same way and to the same two elements, and it is the
    // separate assertion because a size and a face can drift apart: `--type-figure` on a body
    // face is not the debt block, and Caprasimo at label size is not a figure. Both claims
    // must be both things.
    const displayUses = GLOBALS.match(/var\(\s*--font-display\s*[,)]/g) ?? [];
    expect(
      displayUses.length,
      'Caprasimo is the display voice and belongs to three things: the wordmark on the ' +
        "referee's brand bar, the debt total, and the running timer. A fourth claimant would " +
        'make the app loud; a missing one means one of those three lost its face.',
    ).toBe(3);

    // The serif is rationed hardest of the three, and to exactly one thing: the referee's
    // pre-written collection message (Story 7.2, `.collection-message`). It marks that string
    // as something a person says out loud rather than interface chrome, and a second serif
    // string deletes the signal the first one carries.
    //
    // Asserted in both directions, like the two budgets above. Zero is the state this test
    // held until 7.2 — the screen was drawn in the handoff and not built — and going back to
    // zero now would mean the one thing that earned the face has silently lost it.
    const quoteUses = GLOBALS.match(/var\(\s*--font-quote\s*[,)]/g) ?? [];
    expect(
      quoteUses.length,
      "Lora italic belongs to one string in the entire product: the referee's collection " +
        'message. A second claimant deletes what the first one signals; none at all means ' +
        'the sentence he is meant to say out loud is dressed as interface chrome again.',
    ).toBe(1);

    // And its size, separately, for the reason the figure budget gives above: a size and a
    // face can drift apart. `--type-quote` on the body face would be a sentence dressed up
    // without the voice; Lora at label size would be the voice without the room to speak.
    const quoteSizeUses = GLOBALS.match(/var\(\s*--type-quote\s*[,)]/g) ?? [];
    expect(
      quoteSizeUses.length,
      "The quote size belongs to the same one string as the quote face: the referee's " +
        'collection message. A second claimant, or none, means the two have come apart.',
    ).toBe(1);
  });

  it('keeps literal colours out of the base stylesheet', () => {
    // Every colour resolves to a token. tokens.css is the one place a hex may appear.
    expect(GLOBALS).not.toMatch(/#[0-9a-fA-F]{3,8}\b/);
  });
});
