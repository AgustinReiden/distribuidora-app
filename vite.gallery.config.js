/**
 * Config de la GALERÍA DE UI (issue #694). Sólo desarrollo: `npm run gallery`.
 *
 * Por qué es un archivo aparte y no un flag dentro de `vite.config.js`:
 *
 *  - `tailwind.config.js` tiene `content: ["./index.html", "./src/**"]`. Cualquier
 *    clase que la galería usara desde `src/` entraría al CSS de producción. Por eso
 *    la galería vive fuera de `src/` (`ui.html` + `dev/gallery/**`) y el escaneo
 *    extra se declara ACÁ, en un postcss inline, sin tocar `tailwind.config.js`.
 *  - `npm run build` no sabe que esto existe: no hay `ui.html` en el build, ni
 *    chunks de galería, ni una clase más en `dist/assets/index-*.css`.
 *
 * La galería NUNCA habla con el Supabase real: los placeholders se fuerzan sobre
 * `process.env`, que en `loadEnv()` de Vite tiene prioridad sobre los archivos
 * `.env`. Se pisa con `=` (no `??=`) a propósito: si alguien exporta las credenciales
 * de producción en su shell, la galería igual arranca contra el placeholder.
 */
import process from 'node:process'

// Antes de que Vite resuelva el env (lo hace después de evaluar este módulo).
// `createClient()` de `src/lib/supabase.ts` corre a nivel de módulo y tira si
// faltan; construirlo no hace red, así que con el placeholder alcanza.
process.env.VITE_SUPABASE_URL = 'https://placeholder.supabase.co'
process.env.VITE_SUPABASE_ANON_KEY = 'placeholder-key'

import { mergeConfig } from 'vite'
import tailwindcss from 'tailwindcss'
import autoprefixer from 'autoprefixer'
import baseExport from './vite.config.js'
import tailwindConfigBase from './tailwind.config.js'

// `defineConfig` devuelve lo que recibe: hoy es un objeto, pero si mañana pasa a
// ser una función hay que resolverla o `mergeConfig` recibe algo que no es config.
const baseConfig = typeof baseExport === 'function'
  ? baseExport({ command: 'serve', mode: 'development', ssrBuild: false })
  : baseExport

/**
 * El preámbulo de React Refresh, servido como módulo externo en vez de inline.
 *
 * `securityHeadersDevPlugin` (vite.config.js) manda `script-src 'self' … blob:`
 * SIN `'unsafe-inline'`, y `@vitejs/plugin-react` inyecta su preámbulo como
 * `<script type="module">` inline: el navegador lo bloquea y **todo** módulo con
 * componentes tira "can't detect preamble" (le pasa hoy a `npm run dev`, ver el
 * informe del PR). El mismo plugin publica ese preámbulo como módulo virtual
 * (`@vitejs/plugin-react/preamble`), que sí pasa el CSP porque se sirve desde
 * el propio origen. `dev/gallery/main.tsx` además lo importa como primera línea:
 * si esta sustitución fallara con una versión futura del plugin, la galería
 * sigue arrancando.
 */
const PREAMBULO_INLINE_RE =
  /<script type="module">\s*import \{ injectIntoGlobalHook \}[\s\S]*?<\/script>/

function preambuloExternoPlugin() {
  return {
    name: 'gallery-preambulo-externo',
    apply: 'serve',
    transformIndexHtml: {
      order: 'post',
      handler(html) {
        return html.replace(
          PREAMBULO_INLINE_RE,
          '<script type="module" src="/@id/__x00__@vitejs/plugin-react/preamble"></script>',
        )
      },
    },
  }
}

/** `/` va a la galería: el server de la galería no es para abrir la app real. */
function raizALaGaleriaPlugin() {
  return {
    name: 'gallery-raiz-redirect',
    apply: 'serve',
    configureServer(server) {
      server.middlewares.use((req, res, next) => {
        if (req.url === '/' || req.url === '/index.html') {
          res.statusCode = 302
          res.setHeader('Location', '/ui.html')
          res.end()
          return
        }
        next()
      })
    },
  }
}

export default mergeConfig(baseConfig, {
  plugins: [preambuloExternoPlugin(), raizALaGaleriaPlugin()],

  // PostCSS inline: reemplaza a `postcss.config.js` SOLO para esta config, y le
  // agrega al `content` de Tailwind el HTML y los fuentes de la galería. Así el
  // chrome de la galería puede usar Tailwind sin que ninguna de sus clases toque
  // el CSS de producción.
  css: {
    postcss: {
      plugins: [
        tailwindcss({
          ...tailwindConfigBase,
          content: [
            ...tailwindConfigBase.content,
            './ui.html',
            './dev/gallery/**/*.{ts,tsx}',
          ],
        }),
        autoprefixer(),
      ],
    },
  },

  server: {
    port: 5174,
    strictPort: true,
    open: false,
  },
})
