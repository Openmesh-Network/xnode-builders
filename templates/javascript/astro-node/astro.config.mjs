// @ts-check
import { defineConfig } from 'astro/config';

import node from '@astrojs/node';

// https://astro.build/config
export default defineConfig({
  // Recommended to reduce final package size
  // vite: {
  //   ssr: {
  //     noExternal: true
  //   },
  // },
  adapter: node({
    mode: 'standalone'
  })
});