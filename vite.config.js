import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'
import path from 'path'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

function cspConnectSrcPlugin() {
  let resolvedEnv = {}

  return {
    name: 'inject-csp-connect-src',
    configResolved(config) {
      resolvedEnv = loadEnv(config.mode, config.root, 'VITE_N8N')
    },
    transformIndexHtml: {
      order: 'post',
      handler(html) {
        const extraDomains = new Set()

        for (const [, val] of Object.entries(resolvedEnv)) {
          if (val) {
            try {
              extraDomains.add(new URL(val).origin)
            } catch {
              // Ignore invalid URLs
            }
          }
        }

        if (extraDomains.size === 0) return html

        const domainsStr = [...extraDomains].join(' ')
        return html.replace(
          /connect-src 'self'/,
          `connect-src 'self' ${domainsStr}`
        )
      }
    }
  }
}

export default defineConfig({
  plugins: [
    cspConnectSrcPlugin(),
    react(),
    VitePWA({
      registerType: 'prompt',
      includeAssets: ['favicon.ico', 'apple-touch-icon.png', 'icon.svg'],
      manifest: {
        name: 'Distribuidora App',
        short_name: 'Distribuidora',
        description: 'Sistema de gestion para distribuidora de alimentos',
        theme_color: '#2563eb',
        background_color: '#f3f4f6',
        display: 'standalone',
        orientation: 'portrait-primary',
        scope: '/',
        start_url: '/',
        categories: ['business', 'productivity'],
        icons: [
          {
            src: 'pwa-64x64.png',
            sizes: '64x64',
            type: 'image/png'
          },
          {
            src: 'pwa-192x192.png',
            sizes: '192x192',
            type: 'image/png'
          },
          {
            src: 'pwa-512x512.png',
            sizes: '512x512',
            type: 'image/png',
            purpose: 'any'
          },
          {
            src: 'maskable-icon-512x512.png',
            sizes: '512x512',
            type: 'image/png',
            purpose: 'maskable'
          }
        ],
        screenshots: [
          {
            src: 'screenshot-wide.png',
            sizes: '1280x720',
            type: 'image/png',
            form_factor: 'wide',
            label: 'Dashboard de Distribuidora'
          },
          {
            src: 'screenshot-narrow.png',
            sizes: '640x1136',
            type: 'image/png',
            form_factor: 'narrow',
            label: 'Vista movil de pedidos'
          }
        ],
        shortcuts: [
          {
            name: 'Nuevo Pedido',
            short_name: 'Pedido',
            description: 'Crear un nuevo pedido',
            url: '/?action=nuevo-pedido',
            icons: [{ src: 'shortcut-pedido.png', sizes: '96x96' }]
          },
          {
            name: 'Ver Clientes',
            short_name: 'Clientes',
            description: 'Lista de clientes',
            url: '/?vista=clientes',
            icons: [{ src: 'shortcut-clientes.png', sizes: '96x96' }]
          }
        ]
      },
      workbox: {
        runtimeCaching: [
          {
            urlPattern: /\.(?:png|jpg|jpeg|svg|gif|webp)$/i,
            handler: 'CacheFirst',
            options: {
              cacheName: 'images-cache',
              expiration: {
                maxEntries: 60,
                maxAgeSeconds: 60 * 60 * 24 * 30
              }
            }
          },
          {
            urlPattern: /\.(?:woff|woff2|ttf|eot)$/i,
            handler: 'CacheFirst',
            options: {
              cacheName: 'fonts-cache',
              expiration: {
                maxEntries: 20,
                maxAgeSeconds: 60 * 60 * 24 * 365
              }
            }
          },
          {
            urlPattern: /\.(?:js|css)$/i,
            handler: 'StaleWhileRevalidate',
            options: {
              cacheName: 'static-resources',
              expiration: {
                maxEntries: 100,
                maxAgeSeconds: 60 * 60 * 24 * 7
              }
            }
          }
        ],
        globPatterns: ['**/*.{js,css,html,ico,png,svg,woff2}'],
        globIgnores: ['**/*.map'],
        cleanupOutdatedCaches: true,
        skipWaiting: false,
        clientsClaim: false
      },
      devOptions: {
        enabled: false,
        type: 'module'
      }
    })
  ],

  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
      '@components': path.resolve(__dirname, './src/components'),
      '@hooks': path.resolve(__dirname, './src/hooks'),
      '@services': path.resolve(__dirname, './src/services'),
      '@utils': path.resolve(__dirname, './src/utils'),
      '@lib': path.resolve(__dirname, './src/lib')
    }
  },

  build: {
    chunkSizeWarningLimit: 500,
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (id.includes('node_modules/react/') ||
              id.includes('node_modules/react-dom/')) {
            return 'vendor-react'
          }

          if (id.includes('node_modules/@radix-ui/') ||
              id.includes('node_modules/lucide-react/')) {
            return 'vendor-ui'
          }

          if (id.includes('node_modules/@supabase/')) {
            return 'vendor-supabase'
          }

          if (id.includes('node_modules/@sentry/')) {
            return 'vendor-sentry'
          }

          if (id.includes('node_modules/jspdf/')) {
            return 'lib-pdf'
          }

          if (id.includes('node_modules/exceljs/')) {
            return 'lib-excel'
          }

          if (id.includes('node_modules/zod/') ||
              id.includes('node_modules/dompurify/')) {
            return 'lib-validation'
          }

          if (id.includes('node_modules/react-window/')) {
            return 'lib-virtual'
          }
        },

        chunkFileNames: (chunkInfo) => {
          const facadeModuleId = chunkInfo.facadeModuleId
            ? chunkInfo.facadeModuleId.split('/').pop()
            : 'chunk'
          return `assets/${chunkInfo.name || facadeModuleId}-[hash].js`
        }
      }
    },
    minify: 'esbuild',
    sourcemap: false,
    target: 'es2020'
  },

  optimizeDeps: {
    include: [
      'react',
      'react-dom',
      '@supabase/supabase-js',
      'lucide-react',
      'zod',
      'dompurify'
    ],
    exclude: [
      'jspdf',
      'exceljs'
    ]
  },

  test: {
    globals: true,
    environment: 'jsdom',
    setupFiles: './src/test/setup.js',
    include: ['src/**/*.{test,spec}.{js,jsx,ts,tsx}'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'json', 'html', 'lcov'],
      exclude: [
        'node_modules/',
        'src/test/',
        'src/**/*.d.ts',
        'src/vite-env.d.ts',
        'src/main.jsx'
      ],
      thresholds: {
        statements: 50,
        branches: 40,
        functions: 45,
        lines: 50
      }
    }
  }
})
