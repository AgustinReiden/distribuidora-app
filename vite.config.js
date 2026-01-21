import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'path'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],

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
    include: ['src/**/*.{test,spec}.{js,jsx}'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'json', 'html'],
      exclude: ['node_modules/', 'src/test/']
    }
  }
})
