import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: '.',
  testMatch: /.*\.spec\.ts/,
  timeout: 60000,
  retries: 0,
  workers: 1,
  fullyParallel: false,
  use: {
    baseURL: process.env.PVE_BASE_URL || 'https://localhost:8006',
    ignoreHTTPSErrors: true,
    screenshot: 'only-on-failure',
    trace: 'on-first-retry',
  },
});
