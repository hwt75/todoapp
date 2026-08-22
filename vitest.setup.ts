/**
 * Test setup, loaded before every file.
 *
 * `@testing-library/jest-dom` is here for its matchers — `toBeInTheDocument`, `toHaveAttribute`
 * and the accessibility-shaped ones — which turn a failure from "expected null" into a sentence
 * naming what was not on the screen. The cleanup after each test is what keeps two renders of the
 * same component from finding each other's DOM.
 */

import '@testing-library/jest-dom/vitest';
import { cleanup } from '@testing-library/react';
import { afterEach } from 'vitest';

afterEach(() => {
  cleanup();
});
