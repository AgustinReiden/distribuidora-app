/**
 * Paleta, sombras, radios y tipografía EN USO.
 *
 * Es la sección que muestra de un vistazo el efecto de un remapeo
 * (`gray → stone`, `blue → marca`): si una familia cambia, cambia acá primero.
 */
import { FAMILIAS_COLOR } from '../fixtures/paleta'
import { Marco, Seccion, Subtitulo } from '../ui/Marco'

const SOMBRAS = [
  { clase: 'shadow-warm', nombre: 'shadow-warm', uso: 'Reposo de cards y botones de la toolbar' },
  { clase: 'shadow-warm-md', nombre: 'shadow-warm-md', uso: 'Hover de card y de botón' },
  { clase: 'shadow-warm-lg', nombre: 'shadow-warm-lg', uso: 'Elevación alta (poco usada)' },
]

const RADIOS = [
  { clase: 'rounded', nombre: 'rounded' },
  { clase: 'rounded-md', nombre: 'rounded-md' },
  { clase: 'rounded-lg', nombre: 'rounded-lg' },
  { clase: 'rounded-xl', nombre: 'rounded-xl' },
  { clase: 'rounded-2xl', nombre: 'rounded-2xl' },
  { clase: 'rounded-full', nombre: 'rounded-full' },
]

const TAMANOS_TEXTO = [
  { clase: 'text-xs', nombre: 'text-xs' },
  { clase: 'text-sm', nombre: 'text-sm' },
  { clase: 'text-base', nombre: 'text-base' },
  { clase: 'text-lg', nombre: 'text-lg' },
  { clase: 'text-xl', nombre: 'text-xl' },
  { clase: 'text-2xl', nombre: 'text-2xl' },
  { clase: 'text-3xl', nombre: 'text-3xl' },
]

const PESOS = [
  { clase: 'font-normal', nombre: '400 · font-normal' },
  { clase: 'font-medium', nombre: '500 · font-medium' },
  { clase: 'font-semibold', nombre: '600 · font-semibold' },
  { clase: 'font-bold', nombre: '700 · font-bold' },
  { clase: 'font-extrabold', nombre: '800 · font-extrabold' },
]

export default function SeccionPaleta() {
  return (
    <Seccion
      id="paleta"
      titulo="Paleta en uso"
      descripcion={
        <>
          Las doce familias de Tailwind que aparecen en la app, en sus diez pasos. Las clases
          están escritas completas en <code>dev/gallery/fixtures/paleta.ts</code>: Tailwind
          escanea texto y no genera una clase armada en runtime.
        </>
      }
    >
      <div className="space-y-5">
        {FAMILIAS_COLOR.map((familia) => (
          <div key={familia.nombre}>
            <div className="flex flex-wrap items-baseline gap-x-3">
              <span className="font-mono text-sm font-semibold text-stone-800 dark:text-stone-200">
                {familia.nombre}
              </span>
              <span className="text-xs text-stone-500 dark:text-stone-400">{familia.uso}</span>
            </div>
            <div className="mt-1.5 grid grid-cols-5 sm:grid-cols-10 gap-1">
              {familia.pasos.map((muestra) => (
                <div
                  key={muestra.paso}
                  className={`${muestra.clase} ${muestra.texto} h-12 rounded flex items-end justify-start p-1 text-[10px] font-semibold tabular-nums`}
                  title={muestra.clase}
                >
                  {muestra.paso}
                </div>
              ))}
            </div>
          </div>
        ))}
      </div>

      <div>
        <Subtitulo>Sombras cálidas (tailwind.config.js)</Subtitulo>
        <div className="mt-3 grid gap-4 sm:grid-cols-3">
          {SOMBRAS.map((s) => (
            <Marco key={s.nombre} etiqueta={s.nombre}>
              <div
                className={`${s.clase} rounded-xl bg-white dark:bg-gray-800 border border-stone-200 dark:border-gray-700 p-4`}
              >
                <p className="text-sm font-medium text-stone-800 dark:text-stone-100">{s.nombre}</p>
                <p className="mt-1 text-xs text-stone-500 dark:text-stone-400">{s.uso}</p>
              </div>
            </Marco>
          ))}
        </div>
      </div>

      <div>
        <Subtitulo>Radios en uso</Subtitulo>
        <div className="mt-3 flex flex-wrap gap-4">
          {RADIOS.map((r) => (
            <div key={r.nombre} className="text-center">
              <div
                className={`${r.clase} h-16 w-16 bg-blue-600 border border-blue-700`}
                aria-hidden="true"
              />
              <p className="mt-1 font-mono text-[11px] text-stone-500 dark:text-stone-400">
                {r.nombre}
              </p>
            </div>
          ))}
        </div>
      </div>

      <div>
        <Subtitulo>Tipografía</Subtitulo>
        <Marco etiqueta="tamaños · el body usa system-ui con letter-spacing -0.005em">
          <div className="space-y-2">
            {TAMANOS_TEXTO.map((t) => (
              <p key={t.nombre} className={`${t.clase} text-stone-900 dark:text-stone-100`}>
                <span className="font-mono text-stone-400 dark:text-stone-500">{t.nombre}</span>{' '}
                Pedidos del día · Almacén Don Ramón
              </p>
            ))}
          </div>
        </Marco>
        <div className="mt-4 grid gap-4 sm:grid-cols-2">
          <Marco etiqueta="pesos 400–800">
            <div className="space-y-2">
              {PESOS.map((p) => (
                <p key={p.nombre} className={`${p.clase} text-lg text-stone-900 dark:text-stone-100`}>
                  {p.nombre}
                </p>
              ))}
            </div>
          </Marco>
          <Marco etiqueta="tabular-nums · así se alinean los montos en las cards">
            <table className="w-full text-sm text-stone-800 dark:text-stone-200">
              <tbody>
                <tr>
                  <td className="py-0.5">Sin tabular-nums</td>
                  <td className="py-0.5 text-right">$ 1.284.500</td>
                </tr>
                <tr>
                  <td className="py-0.5">Sin tabular-nums</td>
                  <td className="py-0.5 text-right">$ 118.402.900</td>
                </tr>
                <tr>
                  <td className="py-0.5">Con tabular-nums</td>
                  <td className="py-0.5 text-right tabular-nums">$ 1.284.500</td>
                </tr>
                <tr>
                  <td className="py-0.5">Con tabular-nums</td>
                  <td className="py-0.5 text-right tabular-nums">$ 118.402.900</td>
                </tr>
              </tbody>
            </table>
          </Marco>
        </div>
      </div>
    </Seccion>
  )
}
