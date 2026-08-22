import withSerwistInit from '@serwist/next';
import type { NextConfig } from 'next';

const nextConfig: NextConfig = {
  reactStrictMode: true,
};

/**
 * Compiles `app/sw.ts` into `public/sw.js` and registers it on the client.
 *
 * Disabled outside production on purpose: every real test in this story runs
 * against the deployed HTTPS build (the phone cannot reach `localhost`), and a
 * service worker caching locally mostly serves stale code back during local work.
 *
 * The build runs `--webpack` because this plugin is a webpack plugin and Next 16
 * defaults to Turbopack. Serwist's Turbopack support is experimental, and this
 * story is trying to get a clean yes or no about Apple's push delivery — an
 * experimental bundler in the path would make a failure ambiguous.
 */
const withSerwist = withSerwistInit({
  swSrc: 'app/sw.ts',
  swDest: 'public/sw.js',
  disable: process.env.NODE_ENV !== 'production',
});

export default withSerwist(nextConfig);
