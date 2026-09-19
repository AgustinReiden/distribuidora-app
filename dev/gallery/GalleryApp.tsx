/**
 * Galería de UI (issue #694). SÓLO desarrollo: `npm run gallery` → http://localhost:5174/ui.html
 *
 * Para qué: ver los componentes REALES de `src/` con datos de fixture, en claro /
 * oscuro / alto contraste y en los cinco roles, sin backend y sin login. No hay
 * Storybook ni modo demo, y los e2e corren sin sesión.
 *
 * Reglas que sostienen esto (ver `vite.gallery.config.js`):
 *  - Nada de la galería vive bajo `src/`: si viviera, sus clases entrarían al CSS
 *    de producción por el `content` de `tailwind.config.js`.
 *  - Los componentes se IMPORTAN, no se copian. Una copia se desactualiza sola y
 *    deja de valer como referencia.
 *
 * El ancho del contenido es `max-w-7xl mx-auto px-4`, el mismo que usa `src/App.tsx`
 * para el `<main>`, para que lo que se ve acá sea representativo.
 */
import { useState } from 'react'
import { Contrast, Moon, Sun } from 'lucide-react'
import { useTheme } from '../../src/contexts/ThemeContext'
import type { RolUsuario } from '../../src/types'
import GalleryProviders from './GalleryProviders'
import { ETIQUETA_ROL, ROLES_GALERIA } from './fixtures/auth'
import SeccionPaleta from './sections/SeccionPaleta'
import SeccionPrimitivos from './sections/SeccionPrimitivos'
import SeccionPedidos from './sections/SeccionPedidos'
import SeccionHeaders from './sections/SeccionHeaders'
import SeccionCompartidos from './sections/SeccionCompartidos'
import SeccionAvisos from './sections/SeccionAvisos'
import SeccionNavegacion from './sections/SeccionNavegacion'

const INDICE = [
  { id: 'paleta', titulo: 'Paleta' },
  { id: 'primitivos', titulo: 'Primitivos' },
  { id: 'pedidos', titulo: 'Pedidos' },
  { id: 'headers', titulo: 'Headers' },
  { id: 'compartidos', titulo: 'Compartidos' },
  { id: 'avisos', titulo: 'Avisos' },
  { id: 'navegacion', titulo: 'Navegación' },
]

const CONTROL =
  'inline-flex items-center gap-2 h-9 px-3 rounded-lg border border-stone-300 dark:border-gray-700 bg-white dark:bg-gray-800 text-sm text-stone-700 dark:text-gray-200 hover:bg-stone-50 dark:hover:bg-gray-700/60 transition-colors'

const CONTROL_ACTIVO =
  'inline-flex items-center gap-2 h-9 px-3 rounded-lg border border-blue-400 dark:border-blue-600 bg-blue-50 dark:bg-blue-900/30 text-sm text-blue-800 dark:text-blue-200 transition-colors'

function BarraGaleria({
  rol,
  onRol,
  avisosFijos,
  onAvisosFijos,
}: {
  rol: RolUsuario
  onRol: (rol: RolUsuario) => void
  avisosFijos: boolean
  onAvisosFijos: (valor: boolean) => void
}) {
  const { darkMode, toggleDarkMode, highContrast, toggleHighContrast } = useTheme()

  return (
    <header className="sticky top-0 z-[60] border-b border-stone-200 dark:border-gray-800 bg-white/95 dark:bg-gray-950/95 backdrop-blur supports-[backdrop-filter]:bg-white/80 dark:supports-[backdrop-filter]:bg-gray-950/80">
      <div className="max-w-7xl mx-auto px-4 py-2.5 flex flex-wrap items-center gap-x-3 gap-y-2">
        <p className="font-semibold text-sm text-stone-900 dark:text-white mr-1">
          Galería de UI
          <span className="ml-2 font-normal text-xs text-stone-500 dark:text-stone-400">
            datos de fixture · sin backend
          </span>
        </p>

        <label htmlFor="galeria-rol" className="sr-only">
          Rol
        </label>
        <select
          id="galeria-rol"
          value={rol}
          onChange={(e) => onRol(e.target.value as RolUsuario)}
          className={CONTROL}
          title="Rol con el que se renderizan los componentes"
        >
          {ROLES_GALERIA.map((r) => (
            <option key={r} value={r}>
              {ETIQUETA_ROL[r]}
            </option>
          ))}
        </select>

        <button
          type="button"
          onClick={toggleDarkMode}
          className={darkMode ? CONTROL_ACTIVO : CONTROL}
          aria-pressed={darkMode}
          title="Clase `dark` en <html> (API real de ThemeContext)"
        >
          {darkMode ? <Moon className="w-4 h-4" /> : <Sun className="w-4 h-4" />}
          {darkMode ? 'Oscuro' : 'Claro'}
        </button>

        <button
          type="button"
          onClick={toggleHighContrast}
          className={highContrast ? CONTROL_ACTIVO : CONTROL}
          aria-pressed={highContrast}
          title="Clase `high-contrast` en <html> (API real de ThemeContext)"
        >
          <Contrast className="w-4 h-4" />
          Alto contraste
        </button>

        <label
          className={`cursor-pointer select-none ${avisosFijos ? CONTROL_ACTIVO : CONTROL}`}
          title="Los avisos son position:fixed y tapan el resto de la galería"
        >
          <input
            type="checkbox"
            checked={avisosFijos}
            onChange={(e) => onAvisosFijos(e.target.checked)}
            className="w-4 h-4 rounded text-blue-600 focus:ring-blue-500"
          />
          Avisos fijos
        </label>

        <nav aria-label="Secciones" className="flex flex-wrap items-center gap-1 ml-auto">
          {INDICE.map((s) => (
            <a
              key={s.id}
              href={`#${s.id}`}
              className="px-2.5 py-1 rounded-md text-xs font-medium text-stone-600 dark:text-stone-400 hover:bg-stone-100 dark:hover:bg-gray-800 hover:text-stone-900 dark:hover:text-white transition-colors"
            >
              {s.titulo}
            </a>
          ))}
        </nav>
      </div>
    </header>
  )
}

function Contenido({
  rol,
  onRol,
  avisosFijos,
  onAvisosFijos,
}: {
  rol: RolUsuario
  onRol: (rol: RolUsuario) => void
  avisosFijos: boolean
  onAvisosFijos: (valor: boolean) => void
}) {
  return (
    // El mismo fondo que el `body` de la app (src/index.css).
    <div className="min-h-screen bg-stone-50 dark:bg-gray-900">
      <BarraGaleria
        rol={rol}
        onRol={onRol}
        avisosFijos={avisosFijos}
        onAvisosFijos={onAvisosFijos}
      />
      <main className="max-w-7xl mx-auto px-4 pb-24">
        <SeccionPaleta />
        <SeccionPrimitivos />
        <SeccionPedidos />
        <SeccionHeaders />
        <SeccionCompartidos />
        <SeccionAvisos mostrarFijos={avisosFijos} />
        <SeccionNavegacion />
      </main>
    </div>
  )
}

export default function GalleryApp() {
  const [rol, setRol] = useState<RolUsuario>('admin')
  const [avisosFijos, setAvisosFijos] = useState(false)

  return (
    <GalleryProviders rol={rol}>
      <Contenido
        rol={rol}
        onRol={setRol}
        avisosFijos={avisosFijos}
        onAvisosFijos={setAvisosFijos}
      />
    </GalleryProviders>
  )
}
