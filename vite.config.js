import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'
import path from 'path'
import os from 'os'
import process from 'node:process'
import { execSync } from 'node:child_process'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

const cpuCount = os.availableParallelism?.() ?? os.cpus().length

// Identidad del build. Una pestaña abierta se queda con el bundle que cargó
// el día que se abrió: es lo que dejó a la usuaria cancelando pedidos con el
// modal de julio en agosto. Con esto la app se da cuenta de que hay un deploy
// nuevo aunque el navegador todavía no haya revisado el service worker
// (ver useActualizacionDisponible.ts).
function resolverBuildId() {
  const desdeCI = process.env.VITE_BUILD_ID
    || process.env.VERCEL_GIT_COMMIT_SHA
    || process.env.CF_PAGES_COMMIT_SHA
    || process.env.GITHUB_SHA
  if (desdeCI) return desdeCI.slice(0, 12)

  try {
    return execSync('git rev-parse --short=12 HEAD', {
      stdio: ['ignore', 'pipe', 'ignore'],
    }).toString().trim()
  } catch {
    // Build fuera de un repo (tarball, contenedor sin .git): la marca de
    // tiempo alcanza, solo tiene que cambiar cuando cambia el bundle.
    return `t${Date.now().toString(36)}`
  }
}

const BUILD_ID = resolverBuildId()

// Se sirve desde la raíz y lo consulta useActualizacionDisponible.
function versionJsonPlugin() {
  return {
    name: 'emit-version-json',
    apply: 'build',
    generateBundle() {
      this.emitFile({
        type: 'asset',
        fileName: 'version.json',
        source: JSON.stringify({ buildId: BUILD_ID }),
      })
    },
  }
}

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
  define: {
    __APP_BUILD_ID__: JSON.stringify(BUILD_ID),
  },

  plugins: [
    cspConnectSrcPlugin(),
    versionJsonPlugin(),
    react(),
    VitePWA({
      // El registro lo hace la app a mano, en `src/utils/serviceWorker.ts`:
      // el modo inline del plugin inyecta un <script> inline y el CSP de
      // index.html no permite scripts inline.
      injectRegister: false,
      // 'prompt', NO 'autoUpdate': la recarga la decide la usuaria con el
      // cartel (BannerActualizacion). Un reload sorpresa mientras carga un
      // pedido le borra lo tipeado.
      registerType: 'prompt',
      // selfDestroying debe estar en false para que el SW persista y la PWA
      // funcione offline (Workbox precache + Dexie). El deploy previo con
      // selfDestroying:true ya desregistró SW corruptos; ahora los usuarios
      // registran un SW válido que habilita el modo offline real.
      selfDestroying: false,
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
        // Cualquier ruta se resuelve con el index.html precacheado: es lo que
        // hace que la app abra sin señal en vez de quedar en blanco. El proxy
        // de n8n queda afuera, va siempre a la red.
        navigateFallback: 'index.html',
        navigateFallbackDenylist: [/^\/api\//],
        // Los dos en false a propósito, y es el corazón del arreglo de marzo:
        // el SW nuevo se queda ESPERANDO en vez de tomar control de la pestaña
        // abierta. Así la sesión en curso sigue sirviéndose del precache viejo
        // —completo y consistente— y los import() lazy del bundle viejo no se
        // van a 404. El salto al build nuevo lo dispara el botón "Actualizar"
        // del cartel, vía aplicarActualizacionSW().
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
    // `virtual:pwa-register` lo genera el plugin durante el build; bajo vitest
    // el id virtual no resuelve y rompe la carga del archivo que lo importe.
    alias: {
      'virtual:pwa-register': path.resolve(__dirname, 'src/test/stubs/pwaRegister.ts')
    },
    include: ['src/**/*.{test,spec}.{js,jsx,ts,tsx}'],
    // El default (5s) produce timeouts aleatorios en tests jsdom pesados
    // cuando la máquina está cargada (p. ej. la suite completa en el hook
    // de pre-commit): fallaba un test distinto en cada corrida.
    testTimeout: 15000,
    // Sin tope, vitest levanta un fork jsdom por core lógico; en máquinas
    // con muchos cores (20+) se autosaturan y vuelven los timeouts.
    maxWorkers: Number(process.env.VITEST_MAX_WORKERS)
      || Math.min(6, Math.max(2, Math.floor(cpuCount / 2))),
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
