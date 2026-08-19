import nextCoreWebVitals from 'eslint-config-next/core-web-vitals';
import nextTypeScript from 'eslint-config-next/typescript';
import prettier from 'eslint-config-prettier';

const config = [
  {
    ignores: [
      '.next/**',
      'public/sw.js',
      'public/sw.js.map',
      // Deno, not Node: `npm:` specifiers and Deno globals that this config's parser and
      // this project's tsconfig are both right to reject. It is type-checked by the
      // Supabase deploy, not here.
      'supabase/functions/**',
    ],
  },
  ...nextCoreWebVitals,
  ...nextTypeScript,
  // Last, so it wins: turns off every rule Prettier owns. Formatting is settled
  // by the formatter, never argued about a second time by the linter.
  prettier,
  {
    rules: {
      // A leading underscore is how this codebase says "required by the signature,
      // deliberately unused" — `stateToday(_commitment)` takes an argument it will need
      // the moment settlement exists, so the signature is stable before the body is.
      '@typescript-eslint/no-unused-vars': [
        'warn',
        { argsIgnorePattern: '^_', varsIgnorePattern: '^_', caughtErrorsIgnorePattern: '^_' },
      ],
    },
  },
];

export default config;
