import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  resolve: {
    // Mirrors the `@/*` path alias in tsconfig.json. Vitest does not read tsconfig
    // paths on its own, so without this the first test that imports the way
    // app/page.tsx does fails on resolution rather than on logic.
    alias: {
      '@': fileURLToPath(new URL('.', import.meta.url)),
    },
  },
});
