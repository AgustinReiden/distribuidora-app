/**
 * ProductoMedidas
 *
 * Sección de la ficha "Medidas para repartir costos" (mig 278): cuántas
 * unidades de este producto entran en un pallet, en un separador, en un lugar
 * del flete. Es un dato FÍSICO del producto —no el peso de la última compra—, y
 * es lo que usa la base de reparto 'medida' de la compra para pre-llenar los
 * pesos de un cargo: peso = cantidad / unidades por medida.
 *
 * Opcional: un producto sin medidas sigue comprándose igual; la compra pide el
 * dato en la línea (y ofrece guardarlo acá) recién cuando un cargo lo necesita.
 *
 * Se guarda al salir de cada campo, con `guardar_producto_medidas` (sucursal
 * activa). Vaciar el campo borra el valor. Vive aparte de ModalProducto por la
 * misma razón que ProductoLotes: ese archivo ya es largo, y así la ficha la
 * carga lazy y sus tests no arrastran las queries.
 */
import { useState } from 'react'
import { Ruler } from 'lucide-react'
import {
  useCargoMedidasQuery,
  useProductoMedidasQuery,
  useGuardarProductoMedidasMutation,
} from '../../hooks/queries'
import { useAuth } from '../../hooks/supabase/useAuth'

export interface ProductoMedidasProps {
  /** Producto en edición. Sin id (alta nueva) la sección no se muestra. */
  productoId: string | number
}

/** "120" / "333,3333": sin ceros de cola, con coma. */
const mostrar = (n: number | undefined): string =>
  n === undefined ? '' : String(Math.round(n * 10000) / 10000).replace('.', ',')

/** Lo tipeado → número válido (> 0), null (vacío = borrar) o undefined (basura). */
function leer(texto: string): number | null | undefined {
  // Con coma, la coma es el decimal y los puntos son miles ("1.200,5"); sin
  // coma, el punto es el decimal ("333.33").
  const crudo = texto.trim()
  const t = crudo.includes(',') ? crudo.replace(/\./g, '').replace(',', '.') : crudo
  if (t === '') return null
  const n = Number(t)
  return Number.isFinite(n) && n > 0 ? n : undefined
}

export default function ProductoMedidas({ productoId }: ProductoMedidasProps) {
  const { isAdminOrEncargado, perfil } = useAuth()
  const { data: medidas = [] } = useCargoMedidasQuery()
  const { data: ficha = {} } = useProductoMedidasQuery()
  const guardar = useGuardarProductoMedidasMutation()
  // Lo que se está tipeando, por medida. Vacío = se muestra lo de la ficha.
  const [borrador, setBorrador] = useState<Record<string, string>>({})
  const [estado, setEstado] = useState<Record<string, 'ok' | 'error' | 'invalido'>>({})

  // Mismo criterio que la RPC: quien carga compras.
  const puedeEditar = isAdminOrEncargado || perfil?.rol === 'deposito'
  const activas = medidas.filter(m => m.activo)
  if (activas.length === 0) return null

  const valores = ficha[String(productoId)] ?? {}

  async function confirmar(medidaId: string) {
    const texto = borrador[medidaId]
    if (texto === undefined) return
    const nuevo = leer(texto)
    if (nuevo === undefined) {
      setEstado(e => ({ ...e, [medidaId]: 'invalido' }))
      return
    }
    const actual = valores[medidaId]
    setBorrador(b => {
      const { [medidaId]: _, ...resto } = b
      return resto
    })
    if ((nuevo ?? undefined) === actual) return
    try {
      await guardar.mutateAsync([{ productoId: String(productoId), medidaId, unidadesPor: nuevo }])
      setEstado(e => ({ ...e, [medidaId]: 'ok' }))
    } catch {
      setEstado(e => ({ ...e, [medidaId]: 'error' }))
    }
  }

  return (
    <section className="mt-6 border-t pt-4 dark:border-gray-700" aria-labelledby="producto-medidas-titulo">
      <h3 id="producto-medidas-titulo" className="flex items-center gap-2 text-sm font-semibold text-gray-700 dark:text-gray-200">
        <Ruler className="w-4 h-4" aria-hidden="true" />
        Medidas para repartir costos
      </h3>
      <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
        Cuántas unidades entran en cada medida. La compra las usa para repartir pallets, separadores y flete. Opcional;
        se guarda al salir del campo, y vacío lo borra.
      </p>
      <div className="mt-3 grid grid-cols-1 sm:grid-cols-3 gap-3">
        {activas.map(m => {
          const base = m.medidaBaseId ? medidas.find(b => b.id === m.medidaBaseId) : undefined
          const propio = valores[m.id]
          const heredado = propio === undefined && base ? valores[base.id] : undefined
          const st = estado[m.id]
          return (
            <label key={m.id} className="block text-sm">
              <span className="block text-xs text-gray-600 dark:text-gray-300 mb-1">u. por {m.unidadSingular} ({m.nombre})</span>
              <input
                type="text"
                inputMode="decimal"
                disabled={!puedeEditar || guardar.isPending}
                value={borrador[m.id] ?? mostrar(propio)}
                placeholder={heredado !== undefined ? `${mostrar(heredado)} (de ${base?.nombre})` : 'sin cargar'}
                onChange={e => {
                  const v = e.target.value
                  setBorrador(b => ({ ...b, [m.id]: v }))
                  setEstado(s => {
                    const { [m.id]: _, ...resto } = s
                    return resto
                  })
                }}
                onBlur={() => { void confirmar(m.id) }}
                onKeyDown={e => { if (e.key === 'Enter') { e.preventDefault(); void confirmar(m.id) } }}
                className="w-full px-3 py-1.5 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white disabled:opacity-60"
              />
              {st === 'ok' && <span className="block text-xs text-green-700 dark:text-green-400 mt-0.5">Guardado</span>}
              {st === 'error' && <span className="block text-xs text-red-600 mt-0.5">No se pudo guardar</span>}
              {st === 'invalido' && <span className="block text-xs text-red-600 mt-0.5">Tiene que ser un número mayor que 0</span>}
            </label>
          )
        })}
      </div>
    </section>
  )
}
