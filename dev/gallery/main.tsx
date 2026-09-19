/**
 * Entry de la galería de UI. Lo carga `ui.html` como módulo externo.
 *
 * La primera línea es el preámbulo de React Refresh importado como MÓDULO, no
 * inyectado inline: el server de desarrollo manda `script-src 'self' … blob:` sin
 * `'unsafe-inline'` (securityHeadersDevPlugin, vite.config.js) y el `<script>`
 * inline que agrega `@vitejs/plugin-react` queda bloqueado — con eso, todo módulo
 * con componentes tira "can't detect preamble". Tiene que ir ANTES que cualquier
 * otro import: `injectIntoGlobalHook` parchea el hook de DevTools y react-dom lo
 * lee al evaluarse.
 *
 * `vite.gallery.config.js` además reemplaza el script inline por su versión
 * externa; este import es el cinturón además de los tiradores.
 */
import '@vitejs/plugin-react/preamble'

// Antes de que se evalúe nada que pueda pedir datos: bloquea toda petición fuera
// del propio origen. Ver el comentario del módulo.
import './sinRed'

import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'

// Los mismos dos CSS que carga `src/main.tsx`. Nada más: ni service worker, ni
// Sentry, ni web-vitals — la galería no reporta nada ni se registra en ningún lado.
import '../../src/index.css'
import '../../src/styles/high-contrast.css'

import GalleryApp from './GalleryApp'

const contenedor = document.getElementById('root')

if (contenedor) {
  createRoot(contenedor).render(
    <StrictMode>
      <GalleryApp />
    </StrictMode>,
  )
}
