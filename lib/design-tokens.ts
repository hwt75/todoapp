/**
 * Reads the token layer so it can be asserted about.
 *
 * `app/tokens.css` is the implementation and `DESIGN.md` is the source of truth, and
 * nothing mechanical keeps two files in agreement. These parsers exist so a test can:
 * a value that drifts should fail a suite, not wait to be noticed on a screen.
 *
 * Deliberately dependency-free — the frontmatter shapes read here are flat maps of
 * scalars, and this project already prefers thirty lines of parsing to a package.
 */

export type TokenMap = Record<string, string>;

export interface CssTokens {
  /** Declared on `:root` — the light set, and the only place non-colour tokens live. */
  light: TokenMap;
  /** Declared under `prefers-color-scheme: dark`. Intentionally a partial override. */
  dark: TokenMap;
}

/** Every `--name: value;` in a block of CSS, values trimmed, names without the dashes. */
function readDeclarations(block: string): TokenMap {
  // Stripped first so a commented-out declaration (e.g. a value left behind after an
  // edit) can never be matched and overwrite the real one below it.
  const withoutComments = block.replace(/\/\*[\s\S]*?\*\//g, '');
  const out: TokenMap = {};
  for (const [, name, value] of withoutComments.matchAll(/--([\w-]+)\s*:\s*([^;]+);/g)) {
    out[name] = value.trim().replace(/\s+/g, ' ');
  }
  return out;
}

/**
 * Splits the stylesheet into its light and dark declarations.
 *
 * The dark block is found by locating the `prefers-color-scheme: dark` media query and
 * reading to the end of the file, which holds because that query is last and nothing
 * follows it. A future stylesheet that adds a rule after it would need this revisited —
 * the parity tests would start failing rather than passing silently, which is the right
 * way round.
 */
export function parseCssTokens(css: string): CssTokens {
  const darkStart = css.search(/@media\s*\(prefers-color-scheme:\s*dark\)/);
  const lightSource = darkStart === -1 ? css : css.slice(0, darkStart);
  const darkSource = darkStart === -1 ? '' : css.slice(darkStart);

  return { light: readDeclarations(lightSource), dark: readDeclarations(darkSource) };
}

/**
 * Pulls one flat mapping block out of DESIGN.md's YAML frontmatter.
 *
 * Reads only the two-space-indented `key: value` lines directly under `section`, so a
 * nested block (`typography`, `components`) contributes nothing rather than flattening
 * into nonsense. Quotes are stripped; keys are kept verbatim.
 */
export function parseDesignSection(markdown: string, section: string): TokenMap {
  const start = markdown.search(new RegExp(`^${section}:\\s*$`, 'm'));
  if (start === -1) return {};

  const rest = markdown.slice(start).split('\n').slice(1);
  const out: TokenMap = {};

  for (const line of rest) {
    // A non-indented, non-empty line ends the section.
    if (line.trim() !== '' && !/^\s/.test(line)) break;
    const match = /^ {2}'?([\w-]+)'?:\s*'?([^'\n]+?)'?\s*$/.exec(line);
    if (match) out[match[1]] = match[2].trim();
  }

  return out;
}

/** WCAG relative luminance. Throws on anything that is not a six-digit hex. */
export function relativeLuminance(hex: string): number {
  // String(hex ?? '') rather than hex.trim() directly: a missing token (undefined,
  // e.g. one dropped from a dark-mode block) must fail this function's own named
  // check below, not crash on .trim() with a bare TypeError a reader can't place.
  const match = /^#?([0-9a-f]{6})$/i.exec(String(hex ?? '').trim());
  if (!match) throw new Error(`Not a six-digit hex colour: ${hex}`);

  const channels = [0, 2, 4].map((offset) => {
    const value = parseInt(match[1].slice(offset, offset + 2), 16) / 255;
    return value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
  });

  return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2];
}

/**
 * WCAG contrast ratio, 1 to 21. Order-independent.
 *
 * The accessibility review's `medium` finding was that no ratio was ever named — the
 * risk being the next pair added, not today's values. This is what names it: AA is
 * 4.5:1 for text and 3:1 for non-text state indicators.
 */
export function contrastRatio(foreground: string, background: string): number {
  const a = relativeLuminance(foreground);
  const b = relativeLuminance(background);
  const [lighter, darker] = a > b ? [a, b] : [b, a];
  return (lighter + 0.05) / (darker + 0.05);
}

/**
 * The two values that non-CSS consumers need.
 *
 * `app/manifest.ts` and the viewport's `themeColor` are metadata, not stylesheets: they
 * are serialised into JSON and `<meta>` tags where a custom property has nothing to
 * resolve against. Rather than let a literal hex sit in a component — the one thing this
 * layer exists to prevent — the values are named here and held to the stylesheet by a
 * test, the same way the stylesheet is held to DESIGN.md.
 *
 * Keep this list as short as it is. Anything a stylesheet can reach belongs in the
 * stylesheet.
 */
export const METADATA_COLORS = {
  surfaceBase: '#FFFFFF',
  surfaceBaseDark: '#1C1C1E',
} as const;
