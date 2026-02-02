import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'
import path from 'path'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

// https://vite.dev/config/
export default defineConfig({
  plugins: [
    react(),
    VitePWA({
      registerType: 'autoUpdate',
      includeAssets: ['favicon.ico', 'apple-touch-icon.png', 'mask-icon.svg'],
      manifest: {
        name: 'Distribuidora App',
        short_name: 'Distribuidora',
        description: 'Sistema de gestión para distribuidora de alimentos',
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
            label: 'Vista móvil de pedidos'
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
        // Estrategias de caché
        runtimeCaching: [
          {
            // API de Supabase - Network First
            urlPattern: /^https:\/\/.*\.supabase\.co\/.*/i,
            handler: 'NetworkFirst',
            options: {
              cacheName: 'supabase-api-cache',
              expiration: {
                maxEntries: 100,
                maxAgeSeconds: 60 * 60 // 1 hora
              },
              cacheableResponse: {
                statuses: [0, 200]
              },
              networkTimeoutSeconds: 10
            }
          },
          {
            // Imágenes - Cache First
            urlPattern: /\.(?:png|jpg|jpeg|svg|gif|webp)$/i,
            handler: 'CacheFirst',
            options: {
              cacheName: 'images-cache',
              expiration: {
                maxEntries: 60,
                maxAgeSeconds: 60 * 60 * 24 * 30 // 30 días
              }
            }
          },
          {
            // Fuentes - Cache First
            urlPattern: /\.(?:woff|woff2|ttf|eot)$/i,
            handler: 'CacheFirst',
            options: {
              cacheName: 'fonts-cache',
              expiration: {
                maxEntries: 20,
                maxAgeSeconds: 60 * 60 * 24 * 365 // 1 año
              }
            }
          },
          {
            // JS/CSS - Stale While Revalidate
            urlPattern: /\.(?:js|css)$/i,
            handler: 'StaleWhileRevalidate',
            options: {
              cacheName: 'static-resources',
              expiration: {
                maxEntries: 100,
                maxAgeSeconds: 60 * 60 * 24 * 7 // 7 días
              }
            }
          }
        ],
        // Precache de recursos estáticos
        globPatterns: ['**/*.{js,css,html,ico,png,svg,woff2}'],
        // No incluir source maps
        globIgnores: ['**/*.map'],
        // Limpiar caches obsoletos
        cleanupOutdatedCaches: true,
        // Skip waiting para actualizaciones inmediatas
        skipWaiting: true,
        clientsClaim: true
      },
      devOptions: {
        enabled: false, // Deshabilitado en desarrollo
        type: 'module'
      }
    })
  ],

  // Alias para imports más limpios
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

  // Configuración de build optimizada
  build: {
    // Límite de advertencia de chunk (500KB)
    chunkSizeWarningLimit: 500,

    // Opciones de Rollup para code splitting
    rollupOptions: {
      output: {
        // Estrategia de chunks manuales (función para mayor control)
        manualChunks(id) {
          // Vendor: React core
          if (id.includes('node_modules/react/') ||
              id.includes('node_modules/react-dom/')) {
            return 'vendor-react';
          }

          // UI Libraries (Radix + Lucide)
          if (id.includes('node_modules/@radix-ui/') ||
              id.includes('node_modules/lucide-react/')) {
            return 'vendor-ui';
          }

          // Supabase client
          if (id.includes('node_modules/@supabase/')) {
            return 'vendor-supabase';
          }

          // Sentry (monitoring)
          if (id.includes('node_modules/@sentry/')) {
            return 'vendor-sentry';
          }

          // PDF generation (lazy loaded)
          if (id.includes('node_modules/jspdf/')) {
            return 'lib-pdf';
          }

          // Excel processing (lazy loaded)
          if (id.includes('node_modules/exceljs/')) {
            return 'lib-excel';
          }

          // Data validation & sanitization
          if (id.includes('node_modules/zod/') ||
              id.includes('node_modules/dompurify/')) {
            return 'lib-validation';
          }

          // Virtualization (for large lists)
          if (id.includes('node_modules/react-window/')) {
            return 'lib-virtual';
          }
        },

        // Naming pattern for chunks
        chunkFileNames: (chunkInfo) => {
          const facadeModuleId = chunkInfo.facadeModuleId
            ? chunkInfo.facadeModuleId.split('/').pop()
            : 'chunk'
          return `assets/${chunkInfo.name || facadeModuleId}-[hash].js`
        }
      }
    },

    // Minificación
    minify: 'esbuild',

    // Source maps en producción (solo para debugging)
    sourcemap: false,

    // Target browsers
    target: 'es2020'
  },

  // Optimización de dependencias en desarrollo
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
      'jspdf', // Lazy loaded
      'exceljs' // Lazy loaded
    ]
  },

  // Configuración de tests
  test: {
    globals: true,
    environment: 'jsdom',
    setupFiles: './src/test/setup.js',
    include: ['src/**/*.{test,spec}.{js,jsx,ts,tsx}'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'json', 'html'],
      exclude: ['node_modules/', 'src/test/']
    }
  }
})
