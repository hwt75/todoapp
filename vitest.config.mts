import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

const alias = {
  // Mirrors the `@/*` path alias in tsconfig.json. Vitest does not read tsconfig
  // paths on its own, so without this the first test that imports the way
  // app/page.tsx does fails on resolution rather than on logic.
  '@': fileURLToPath(new URL('.', import.meta.url)),
};

export default defineConfig({
  resolve: { alias },
  test: {
    // Two projects rather than one environment, because the two halves of this suite want
    // different things. Everything under `lib/` and `app/` is pure and runs in Node, which is
    // faster and keeps a DOM out of reach of modules that must never need one — `lib/summary.ts`
    // building a sentence, `lib/chain.ts` writing a number. Components need jsdom.
    //
    // Split by path rather than by a per-file docblock, so a new component test cannot forget to
    // ask for a DOM and fail on `document is not defined` for a reason that has nothing to do
    // with what it was checking.
    projects: [
      {
        resolve: { alias },
        test: {
          name: 'lib',
          environment: 'node',
          include: ['lib/**/*.test.ts', 'app/**/*.test.ts'],
        },
      },
      {
        resolve: { alias },
        test: {
          name: 'components',
          environment: 'jsdom',
          include: ['components/**/*.test.tsx'],
          setupFiles: ['./vitest.setup.ts'],
        },
      },
    ],
  },
});
