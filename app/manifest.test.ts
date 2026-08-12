import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import manifest from './manifest';

const PROJECT_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

/** Reads width and height out of a PNG's IHDR chunk, which always leads the file. */
function readPngSize(buffer: Buffer): { width: number; height: number } {
  return { width: buffer.readUInt32BE(16), height: buffer.readUInt32BE(20) };
}

describe('web app manifest', () => {
  const m = manifest();

  it('declares standalone display', () => {
    // iOS offers "Add to Home Screen" as a real web app on the strength of this
    // value. Anything else and the icon opens a browser tab, which cannot receive
    // notifications — the product's only delivery channel.
    expect(m.display).toBe('standalone');
  });

  it('pins app identity independently of start_url', () => {
    // Without an explicit id, changing start_url later orphans the existing
    // install and the notification subscription attached to it.
    expect(m.id).toBe('/');
    expect(m.start_url).toBe('/');
    expect(m.scope).toBe('/');
  });

  it('declares the icon sizes iOS needs', () => {
    const sizes = (m.icons ?? []).map((icon) => icon.sizes);
    expect(sizes).toContain('180x180');
    expect(sizes).toContain('192x192');
    expect(sizes).toContain('512x512');
  });

  it('references icons that are real PNGs at their declared size', () => {
    // Existence alone is not enough. The encoder in scripts/generate-icons.mjs is
    // hand-written; a truncated or wrong-sized file passes an existsSync check and
    // then iOS silently declines to offer installation, with no error anywhere.
    for (const icon of m.icons ?? []) {
      const src = String(icon.src);
      expect(src.startsWith('/'), `icon src must be root-relative: ${src}`).toBe(true);

      const path = join(PROJECT_ROOT, 'public', src);
      expect(existsSync(path), `missing icon file: ${src}`).toBe(true);

      const buffer = readFileSync(path);
      expect(buffer.subarray(0, 8), `not a PNG: ${src}`).toEqual(PNG_MAGIC);

      const [declaredWidth, declaredHeight] = String(icon.sizes).split('x').map(Number);
      expect(readPngSize(buffer), `wrong dimensions: ${src}`).toEqual({
        width: declaredWidth,
        height: declaredHeight,
      });
    }
  });
});
