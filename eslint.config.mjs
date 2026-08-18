import nextCoreWebVitals from 'eslint-config-next/core-web-vitals';
import nextTypeScript from 'eslint-config-next/typescript';
import prettier from 'eslint-config-prettier';

const config = [
  { ignores: ['.next/**', 'public/sw.js', 'public/sw.js.map'] },
  ...nextCoreWebVitals,
  ...nextTypeScript,
  // Last, so it wins: turns off every rule Prettier owns. Formatting is settled
  // by the formatter, never argued about a second time by the linter.
  prettier,
];

export default config;
