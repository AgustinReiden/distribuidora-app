/* eslint-disable no-undef */
/**
 * Playwright Configuration
 *
 * Configuración para tests E2E incluyendo:
 * - Tests de caos (offline/online)
 * - Tests de sincronización
 * - Tests de integridad de datos
 */

import { defineConfig, devices } from '@playwright/test'

export default defineConfig({
  testDir: './e2e',
  testMatch: '**/*.spec.{ts,js}',

  /* Timeout para tests de caos que pueden ser lentos */
  timeout: 60000,

  /* Reintentar tests fallidos 1 vez */
  retries: process.env.CI ? 2 : 1,

  /* Correr tests en paralelo */
  workers: process.env.CI ? 1 : undefined,

  /* Reporter para CI y local */
  reporter: [
    ['html', { open: 'never' }],
    ['list']
  ],

  /* Configuración global */
  use: {
    /* URL base de la app */
    baseURL: 'http://localhost:5173',

    /* Capturar trace en primer reintento */
    trace: 'on-first-retry',

    /* Screenshot en fallo */
    screenshot: 'only-on-failure',

    /* Video en fallo */
    video: 'on-first-retry'
  },

  /* Proyectos de test */
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] }
    },
    {
      name: 'mobile',
      use: { ...devices['Pixel 5'] }
    }
  ],

  /* Servidor de desarrollo */
  webServer: {
    command: 'npm run dev',
    url: 'http://localhost:5173',
    reuseExistingServer: !process.env.CI,
    timeout: 120000
  }
})
