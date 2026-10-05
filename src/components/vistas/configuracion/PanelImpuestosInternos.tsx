/**
 * Encuadres de impuestos internos y sus alícuotas (mig 277).
 *
 * Es el único lugar donde vive una tasa: la ficha de cada producto elige un
 * encuadre y la base deriva su impuesto interno de acá. Global, no de la
 * sucursal activa: la ley es nacional, y cambiar una tasa recalcula las fichas
 * de las dos sucursales.
 *
 * Todos lo ven; sólo un admin lo cambia (la RLS y la RPC lo exigen igual).
 */
import { useState, type FormEvent } from 'react'
import { Landmark, Plus, Loader2 } from 'lucide-react'
import { Button } from '../../ui/Button'
import {
  useCatalogoIIQuery,
  useGuardarEncuadreIIMutation,
  useCambiarAlicuotaIIMutation,
} from '../../../hooks/queries/useImpuestosInternosQuery'
import { alicuotaVigente, alicuotasProgramadas, tasaEfectivaEncuadre, formatearNominal, type EncuadreII } from '../../../utils/impuestosInternos'
import { fechaLocalISO } from '../../../utils/formatters'
import { useNotification } from '../../../contexts/NotificationContext'

const INPUT = 'px-3 py-2 rounded-lg border border-stone-300 dark:border-gray-600 dark:bg-gray-900 dark:text-white text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500'

/** "8" o "8,5" → 0.08 / 0.085. null si no es un porcentaje válido. */
function nominalDesdeTexto(texto: string): number | null {
  const n = Number(texto.replace(',', '.'))
  if (!Number.isFinite(n) || n < 0 || n >= 100) return null
  return n / 100
}

function FormTasa({ encuadre, onListo }: { encuadre: EncuadreII; onListo: () => void }) {
  const notify = useNotification()
  const cambiar = useCambiarAlicuotaIIMutation()
  const hoy = fechaLocalISO()
  const [tasa, setTasa] = useState('')
  const [desde, setDesde] = useState(hoy)

  const nominal = nominalDesdeTexto(tasa)
  // Vale cualquier fecha, también futura (mig 282): las fichas no se mueven
  // hasta ese día.
  const valido = nominal !== null && desde !== ''

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    if (!valido || nominal === null) return
    try {
      await cambiar.mutateAsync({ encuadreId: encuadre.id, tasaNominal: nominal, vigenteDesde: desde })
      const fecha = desde.split('-').reverse().join('/')
      notify.success(desde > hoy
        ? `${encuadre.nombre}: ${formatearNominal(nominal)} programada desde ${fecha}`
        : `${encuadre.nombre}: ${formatearNominal(nominal)} desde ${fecha}`)
      onListo()
    } catch (err) {
      notify.error(err instanceof Error ? err.message : 'No se pudo cambiar la tasa')
    }
  }

  return (
    <form onSubmit={handleSubmit} className="mt-2 flex flex-wrap items-end gap-2">
      <div>
        <label htmlFor={`tasa-${encuadre.id}`} className="block text-xs text-stone-500 mb-1">Tasa nominal (%)</label>
        <input
          id={`tasa-${encuadre.id}`}
          inputMode="decimal"
          value={tasa}
          onChange={(e) => setTasa(e.target.value)}
          placeholder="8"
          className={`${INPUT} w-24`}
        />
      </div>
      <div>
        <label htmlFor={`desde-${encuadre.id}`} className="block text-xs text-stone-500 mb-1">Vigente desde</label>
        <input
          id={`desde-${encuadre.id}`}
          type="date"
          value={desde}
          onChange={(e) => setDesde(e.target.value)}
          className={INPUT}
        />
      </div>
      <Button type="submit" variant="primary" size="sm" disabled={!valido || cambiar.isPending} loading={cambiar.isPending}>
        Guardar tasa
      </Button>
      <Button type="button" variant="ghost" size="sm" onClick={onListo}>Cancelar</Button>
      <p className="w-full text-xs text-stone-500">
        La tasa anterior queda cerrada el día antes. Se puede cargar con fecha futura: las
        fichas no cambian hasta ese día, y ese día las actualiza el refresco automático de la
        madrugada. Otra tasa con la misma fecha corrige la que ya estaba.
      </p>
    </form>
  )
}

function FormEncuadre({ encuadre, onListo }: { encuadre?: EncuadreII; onListo: () => void }) {
  const notify = useNotification()
  const guardar = useGuardarEncuadreIIMutation()
  const cambiar = useCambiarAlicuotaIIMutation()
  const hoy = fechaLocalISO()
  const [nombre, setNombre] = useState(encuadre?.nombre ?? '')
  const [criterio, setCriterio] = useState(encuadre?.criterio ?? '')
  const [activo, setActivo] = useState(encuadre?.activo ?? true)
  // Sólo al crear: un encuadre nuevo nace con su primera tasa.
  const [tasa, setTasa] = useState('')
  const [desde, setDesde] = useState(hoy)

  const nominal = nominalDesdeTexto(tasa)
  const valido = nombre.trim() !== '' && (encuadre ? true : nominal !== null && desde !== '')

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    if (!valido) return
    try {
      const id = await guardar.mutateAsync({ id: encuadre?.id, data: { nombre, criterio, activo } })
      if (!encuadre && nominal !== null) {
        await cambiar.mutateAsync({ encuadreId: id, tasaNominal: nominal, vigenteDesde: desde })
      }
      notify.success(encuadre ? 'Encuadre actualizado' : `Encuadre "${nombre.trim()}" creado`)
      onListo()
    } catch (err) {
      notify.error(err instanceof Error ? err.message : 'No se pudo guardar el encuadre')
    }
  }

  const pendiente = guardar.isPending || cambiar.isPending
  return (
    <form onSubmit={handleSubmit} className="mt-2 space-y-2">
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
        <div>
          <label htmlFor={`nombre-${encuadre?.id ?? 'nuevo'}`} className="block text-xs text-stone-500 mb-1">Nombre</label>
          <input id={`nombre-${encuadre?.id ?? 'nuevo'}`} value={nombre} onChange={(e) => setNombre(e.target.value)} className={`${INPUT} w-full`} />
        </div>
        <div>
          <label htmlFor={`criterio-${encuadre?.id ?? 'nuevo'}`} className="block text-xs text-stone-500 mb-1">Criterio (qué productos entran)</label>
          <input id={`criterio-${encuadre?.id ?? 'nuevo'}`} value={criterio} onChange={(e) => setCriterio(e.target.value)} className={`${INPUT} w-full`} />
        </div>
      </div>
      {!encuadre && (
        <div className="flex flex-wrap gap-2">
          <div>
            <label htmlFor="tasa-nuevo" className="block text-xs text-stone-500 mb-1">Tasa nominal (%)</label>
            <input id="tasa-nuevo" inputMode="decimal" value={tasa} onChange={(e) => setTasa(e.target.value)} placeholder="10" className={`${INPUT} w-24`} />
          </div>
          <div>
            <label htmlFor="desde-nuevo" className="block text-xs text-stone-500 mb-1">Vigente desde</label>
            <input id="desde-nuevo" type="date" value={desde} onChange={(e) => setDesde(e.target.value)} className={INPUT} />
          </div>
        </div>
      )}
      {encuadre && (
        <label className="flex items-center gap-2 text-sm text-stone-700 dark:text-stone-300">
          <input type="checkbox" checked={activo} onChange={(e) => setActivo(e.target.checked)} />
          Activo (un encuadre inactivo no se ofrece en la ficha; los productos que ya lo tienen lo conservan)
        </label>
      )}
      <div className="flex gap-2">
        <Button type="submit" variant="primary" size="sm" disabled={!valido || pendiente} loading={pendiente}>
          {encuadre ? 'Guardar' : 'Crear encuadre'}
        </Button>
        <Button type="button" variant="ghost" size="sm" onClick={onListo}>Cancelar</Button>
      </div>
    </form>
  )
}

export default function PanelImpuestosInternos({ esAdmin }: { esAdmin: boolean }) {
  const { data, isLoading, error } = useCatalogoIIQuery()
  // Qué fila tiene abierto qué formulario. Uno por vez.
  const [abierto, setAbierto] = useState<{ id: string; modo: 'tasa' | 'editar' } | 'nuevo' | null>(null)
  const hoy = fechaLocalISO()

  return (
    <section className="bg-white dark:bg-gray-800 border border-stone-200/80 dark:border-gray-700 rounded-xl p-5 space-y-4 shadow-warm">
      <div>
        <h2 className="text-sm font-semibold text-stone-900 dark:text-white flex items-center gap-2">
          <Landmark className="w-4 h-4 text-stone-500" aria-hidden="true" />
          Impuestos internos
        </h2>
        <p className="text-xs text-stone-500 dark:text-stone-400 mt-1">
          Cada producto elige un encuadre en su ficha, y el encuadre define la tasa. Es la
          misma para todas las sucursales: cambiar una tasa recalcula al instante el impuesto
          interno de todas las fichas de ese encuadre (si es con fecha futura, el día que
          empieza). La tasa que se carga es la{' '}
          <strong>nominal</strong> de la ley; sobre el neto se aplica la efectiva, porque el
          impuesto se liquida por dentro (8% nominal = 8,6957% sobre el neto).
        </p>
      </div>

      {isLoading ? (
        <div className="flex justify-center py-4"><Loader2 className="w-5 h-5 animate-spin text-stone-400" aria-label="Cargando" /></div>
      ) : error ? (
        <p role="alert" className="text-sm text-rose-600">No se pudieron cargar los encuadres.</p>
      ) : (
        <ul className="divide-y divide-stone-200 dark:divide-gray-700">
          {(data?.encuadres ?? []).map(e => {
            const vigente = alicuotaVigente(e.id, hoy, data?.alicuotas ?? [])
            const efectiva = tasaEfectivaEncuadre(e.id, hoy, data?.alicuotas ?? []) ?? 0
            const programadas = alicuotasProgramadas(e.id, hoy, data?.alicuotas ?? [])
            const abiertoAca = abierto !== null && abierto !== 'nuevo' && abierto.id === e.id ? abierto.modo : null
            return (
              <li key={e.id} className="py-3">
                <div className="flex flex-wrap items-start justify-between gap-2">
                  <div className="min-w-0">
                    <p className="text-sm font-medium text-stone-900 dark:text-white">
                      {e.nombre}
                      {!e.activo && <span className="ml-2 text-xs text-stone-500">(inactivo)</span>}
                    </p>
                    {e.criterio && <p className="text-xs text-stone-500 dark:text-stone-400">{e.criterio}</p>}
                  </div>
                  <div className="text-right">
                    <p className="text-sm tabular-nums text-stone-900 dark:text-white">
                      {vigente ? `${formatearNominal(vigente.tasa_nominal)} nominal` : 'Sin tasa vigente'}
                    </p>
                    {vigente && vigente.tasa_nominal > 0 && (
                      <p className="text-xs tabular-nums text-stone-500">
                        {String(efectiva).replace('.', ',')}% sobre el neto
                      </p>
                    )}
                    {vigente && (
                      <p className="text-xs text-stone-400">desde {vigente.vigente_desde.split('-').reverse().join('/')}</p>
                    )}
                    {programadas.map(p => (
                      <p key={p.id} className="text-xs font-medium text-amber-700 dark:text-amber-400">
                        Programada: {formatearNominal(p.tasa_nominal)} desde {p.vigente_desde.split('-').reverse().join('/')}
                      </p>
                    ))}
                  </div>
                </div>
                {esAdmin && abiertoAca === null && (
                  <div className="mt-1 flex gap-2">
                    <Button type="button" variant="ghost" size="sm" onClick={() => setAbierto({ id: e.id, modo: 'tasa' })}>
                      Cambiar tasa
                    </Button>
                    <Button type="button" variant="ghost" size="sm" onClick={() => setAbierto({ id: e.id, modo: 'editar' })}>
                      Editar
                    </Button>
                  </div>
                )}
                {abiertoAca === 'tasa' && <FormTasa encuadre={e} onListo={() => setAbierto(null)} />}
                {abiertoAca === 'editar' && <FormEncuadre encuadre={e} onListo={() => setAbierto(null)} />}
              </li>
            )
          })}
        </ul>
      )}

      {esAdmin && (abierto === 'nuevo'
        ? <FormEncuadre onListo={() => setAbierto(null)} />
        : (
          <Button type="button" variant="secondary" size="sm" className="gap-1" onClick={() => setAbierto('nuevo')}>
            <Plus className="w-4 h-4" aria-hidden="true" /> Nuevo encuadre
          </Button>
        ))}
    </section>
  )
}
