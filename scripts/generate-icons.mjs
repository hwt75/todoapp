// Generates the app icons from the supplied mark.
//
// These used to be placeholders — solid fills of the text colour — because the UX phase
// had produced tokens but never a logo. The 2026-09-08 handoff supplies one, so this now
// downsamples that single 1254x1254 PNG to the raster sizes iOS and the manifest ask for.
// iOS refuses to offer "Add to Home Screen" without them, and without that install there
// are no notifications and no product.
//
// Dependency-free on purpose, and it stays that way: a PNG decoder is zlib plus five
// filter cases, a box filter is nine lines, and this project should not carry an image
// library to resize one square.
//
// Run by `prebuild`, so `npm run build` always ships icons that match the mark on disk.

import { deflateSync, inflateSync } from 'node:zlib';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const PROJECT_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');

// The mark, as delivered. It lives with the rest of the handoff rather than in `public/`
// because it is a design source: `public/icons/` holds what this script derives from it.
const SOURCE = join(PROJECT_ROOT, 'design_handoff_todoapp', 'design', 'assets', 'logo.png');
const OUT_DIR = join(PROJECT_ROOT, 'public', 'icons');

// 180 is the apple-touch-icon iOS actually reads; 192 and 512 are the manifest's.
const SIZES = [180, 192, 512];

const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

function crc32(buf) {
  let c = ~0;
  for (const byte of buf) {
    c ^= byte;
    for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1));
  }
  return ~c >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}

/**
 * Decodes a non-interlaced, 8-bit truecolour PNG (with or without alpha) to flat RGB.
 *
 * Deliberately narrow. It refuses anything it was not written to read rather than
 * producing a plausible-looking wrong image — a silently mangled app icon is the kind of
 * defect nobody notices until it is on somebody's home screen.
 */
function decodeRgb(file) {
  if (!file.subarray(0, 8).equals(PNG_SIGNATURE)) throw new Error(`${SOURCE} is not a PNG`);

  let offset = 8;
  let header = null;
  const idat = [];

  while (offset < file.length) {
    const length = file.readUInt32BE(offset);
    const type = file.toString('ascii', offset + 4, offset + 8);
    const data = file.subarray(offset + 8, offset + 8 + length);

    if (type === 'IHDR') {
      header = {
        width: data.readUInt32BE(0),
        height: data.readUInt32BE(4),
        depth: data[8],
        colorType: data[9],
        interlace: data[12],
      };
    } else if (type === 'IDAT') {
      idat.push(data);
    } else if (type === 'IEND') {
      break;
    }

    offset += 12 + length;
  }

  if (!header) throw new Error('no IHDR');
  if (header.depth !== 8) throw new Error(`unsupported bit depth ${header.depth}, expected 8`);
  if (header.interlace !== 0) throw new Error('interlaced PNGs are not supported');
  if (header.colorType !== 2 && header.colorType !== 6) {
    throw new Error(`unsupported colour type ${header.colorType}, expected 2 or 6`);
  }

  const { width, height } = header;
  const channels = header.colorType === 6 ? 4 : 3;
  const raw = inflateSync(Buffer.concat(idat));
  const stride = width * channels;
  const out = Buffer.alloc(width * height * 3);
  // The previous scanline, already un-filtered — what Up, Average and Paeth read.
  let previous = Buffer.alloc(stride);

  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    const line = Buffer.from(raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1)));

    for (let x = 0; x < stride; x++) {
      const left = x >= channels ? line[x - channels] : 0;
      const up = previous[x];
      const upLeft = x >= channels ? previous[x - channels] : 0;

      switch (filter) {
        case 0:
          break;
        case 1:
          line[x] = (line[x] + left) & 0xff;
          break;
        case 2:
          line[x] = (line[x] + up) & 0xff;
          break;
        case 3:
          line[x] = (line[x] + ((left + up) >> 1)) & 0xff;
          break;
        case 4: {
          const p = left + up - upLeft;
          const pa = Math.abs(p - left);
          const pb = Math.abs(p - up);
          const pc = Math.abs(p - upLeft);
          const predictor = pa <= pb && pa <= pc ? left : pb <= pc ? up : upLeft;
          line[x] = (line[x] + predictor) & 0xff;
          break;
        }
        default:
          throw new Error(`unknown filter type ${filter} on row ${y}`);
      }
    }

    // Alpha is dropped rather than composited: the supplied mark is opaque, and an icon
    // with transparency would show the home screen's wallpaper through it on Android.
    for (let x = 0; x < width; x++) {
      const from = x * channels;
      const to = (y * width + x) * 3;
      out[to] = line[from];
      out[to + 1] = line[from + 1];
      out[to + 2] = line[from + 2];
    }

    previous = line;
  }

  return { width, height, pixels: out };
}

/**
 * Box-filter downsample. Every source pixel contributes to exactly one target pixel, which
 * for a large square reduced to 512 or 180 is both correct and cheap — the artifacts a box
 * filter is criticised for need upsampling or a near-1:1 ratio to show up, and neither
 * happens here.
 */
function resize(source, size) {
  const out = Buffer.alloc(size * size * 3);

  for (let y = 0; y < size; y++) {
    const y0 = Math.floor((y * source.height) / size);
    const y1 = Math.max(y0 + 1, Math.floor(((y + 1) * source.height) / size));

    for (let x = 0; x < size; x++) {
      const x0 = Math.floor((x * source.width) / size);
      const x1 = Math.max(x0 + 1, Math.floor(((x + 1) * source.width) / size));

      let r = 0;
      let g = 0;
      let b = 0;
      let n = 0;

      for (let sy = y0; sy < y1; sy++) {
        for (let sx = x0; sx < x1; sx++) {
          const at = (sy * source.width + sx) * 3;
          r += source.pixels[at];
          g += source.pixels[at + 1];
          b += source.pixels[at + 2];
          n++;
        }
      }

      const to = (y * size + x) * 3;
      out[to] = Math.round(r / n);
      out[to + 1] = Math.round(g / n);
      out[to + 2] = Math.round(b / n);
    }
  }

  return out;
}

function encodePng(size, rgb) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 2; // colour type: truecolour
  // 10-12: compression, filter, interlace — all zero

  const stride = size * 3 + 1; // one filter byte per scanline
  const raw = Buffer.alloc(stride * size);
  for (let y = 0; y < size; y++) {
    raw[y * stride] = 0; // filter: none
    rgb.copy(raw, y * stride + 1, y * size * 3, (y + 1) * size * 3);
  }

  return Buffer.concat([
    PNG_SIGNATURE,
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

const source = decodeRgb(readFileSync(SOURCE));
console.log(`read ${SOURCE} (${source.width}x${source.height})`);

mkdirSync(OUT_DIR, { recursive: true });
for (const size of SIZES) {
  const file = join(OUT_DIR, `icon-${size}.png`);
  writeFileSync(file, encodePng(size, resize(source, size)));
  console.log(`wrote ${file}`);
}
