/**
 * Primitivas de la galería: sección con ancla y marco con etiqueta.
 *
 * Todo lo que se dibuja acá es chrome de la galería, no de la app. Usa Tailwind
 * porque `vite.gallery.config.js` agrega `dev/gallery/**` al `content` de un
 * PostCSS inline; ninguna de estas clases llega al CSS de producción.
 *
 * Este archivo exporta SÓLO componentes (regla `react-refresh/only-export-components`).
 */
import type { ReactNode } from 'react'

export function Seccion({
  id,
  titulo,
  descripcion,
  children,
}: {
  id: string
  titulo: string
  descripcion?: ReactNode
  children: ReactNode
}) {
  return (
    <section
      id={id}
      className="scroll-mt-28 py-10 border-t border-stone-200 dark:border-gray-800 first:border-t-0"
    >
      <h2 className="text-2xl font-bold tracking-tight text-stone-900 dark:text-white">
        {titulo}
      </h2>
      {descripcion && (
        <p className="mt-1.5 max-w-3xl text-sm leading-relaxed text-stone-600 dark:text-stone-400">
          {descripcion}
        </p>
      )}
      <div className="mt-6 space-y-8">{children}</div>
    </section>
  )
}

export function Subtitulo({ children }: { children: ReactNode }) {
  return (
    <h3 className="text-xs font-semibold uppercase tracking-[0.16em] text-stone-500 dark:text-stone-400">
      {children}
    </h3>
  )
}

/**
 * Marco con etiqueta. El contenido va sobre el fondo REAL del body de la app
 * (`bg-stone-50 dark:bg-gray-900`, ver src/index.css) para que lo que se ve sea
 * lo que se va a ver en la app.
 */
export function Marco({
  etiqueta,
  children,
  compacto = false,
}: {
  etiqueta: string
  children: ReactNode
  /** Padding chico: para lo que ya trae su propio marco. */
  compacto?: boolean
}) {
  return (
    <figure className="m-0">
      <figcaption className="mb-1.5 font-mono text-[11px] leading-tight text-stone-500 dark:text-stone-400">
        {etiqueta}
      </figcaption>
      <div
        className={`rounded-lg border border-dashed border-stone-300 dark:border-gray-700 bg-stone-50 dark:bg-gray-900 ${
          compacto ? 'p-2' : 'p-4'
        }`}
      >
        {children}
      </div>
    </figure>
  )
}

/** Por qué algo NO está en la galería. Se lee acá y en el informe del PR. */
export function FueraDeLaV1({ children }: { children: ReactNode }) {
  return (
    <div className="rounded-lg border border-amber-300 dark:border-amber-800/60 bg-amber-50 dark:bg-amber-900/20 p-3 text-sm text-amber-900 dark:text-amber-100">
      <p className="font-semibold">Fuera de la v1</p>
      <div className="mt-1 space-y-1 leading-relaxed">{children}</div>
    </div>
  )
}
