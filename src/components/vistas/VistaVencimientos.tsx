/**
 * VistaVencimientos
 *
 * El panel donde se trabaja lo que está por vencer (migs 223/224/225).
 *
 * ES UNA PANTALLA OPERATIVA, NO UN REPORTE
 * ----------------------------------------
 * Por eso vive en el menú y no como una pestaña de Reportes: acá no se viene a
 * mirar un número, se viene a decidir qué se liquida, qué se bonifica y qué se
 * da de baja. La acción está en la misma fila que el dato.
 *
 * LO VENCIDO NO BLOQUEA NADA
 * --------------------------
 * Un lote vencido se pinta en rojo y aparece primero, pero el producto se sigue
 * pudiendo vender. Es una decisión de negocio: una fecha mal tipeada no puede
 * frenar la operación de una distribuidora, y la corrección tiene su camino
 * propio en la ficha del producto.
 *
 * La baja va por `dar_de_baja_lote`, que escribe la merma con motivo
 * 'vencimiento' y recién después toca el stock. El costo lo congela solo el
 * trigger de la mig 119, así que la pérdida queda valorizada sin que esta
 * pantalla tenga que saber nada de costos.
 */
import { useMemo, useState } from 'react'
import { AlertTriangle, CalendarClock, Check, Loader2, PackageX, RefreshCw, X } from 'lucide-react'
import type { LoteReporte } from '../../hooks/queries/useLotesQuery'
import { estadoVencimiento, formatearFechaVencimiento } from '../../utils/vencimientos'
import type { EstadoVencimiento } from '../../utils/vencimientos'
import BadgeVencimiento from '../vencimientos/BadgeVencimiento'

type Filtro = 'todos' | 'vencido' | 'critico' | 'alerta'

const FILTROS: { clave: Filtro; label: string }[] = [
  { clave: 'todos', label: 'Todos' },
  { clave: 'vencido', label: 'Vencidos' },
  { clave: 'critico', label: 'Urgentes' },
  { clave: 'alerta', label: 'Por vencer' },
]

export interface VistaVencimientosProps {
  lotes: LoteReporte[]
  cargando: boolean
  refrescando: boolean
  diasAlerta: number
  diasCritico: number
  puedeDarDeBaja: boolean
  darDeBajaPendiente: boolean
  onRefrescar: () => void
  onDarDeBaja: (loteId: number, cantidad: number) => Promise<void>
  nombreSucursal?: string | null
}

export default function VistaVencimientos({
  lotes,
  cargando,
  refrescando,
  diasAlerta,
  diasCritico,
  puedeDarDeBaja,
  darDeBajaPendiente,
  onRefrescar,
  onDarDeBaja,
  nombreSucursal,
}: VistaVencimientosProps) {
  const [filtro, setFiltro] = useState<Filtro>('todos')
  /** Lote con el formulario de baja abierto. */
  const [dandoDeBaja, setDandoDeBaja] = useState<number | null>(null)
  const [cantidadBaja, setCantidadBaja] = useState('')

  // El estado se calcula acá y no viene de la RPC: la regla vive en
  // src/utils/vencimientos.ts, en un solo lugar. Ver el encabezado de ese
  // archivo para por qué tampoco se usa el `dias_restantes` del servidor.
  const conEstado = useMemo(
    () =>
      lotes.map(l => ({
        lote: l,
        estado: estadoVencimiento(l.fecha_vencimiento, diasAlerta, diasCritico),
      })),
    [lotes, diasAlerta, diasCritico],
  )

  const conteos = useMemo(() => {
    const acc: Record<EstadoVencimiento, number> = { vencido: 0, critico: 0, alerta: 0, ok: 0 }
    for (const { estado } of conEstado) acc[estado] += 1
    return acc
  }, [conEstado])

  const visibles = useMemo(
    () => (filtro === 'todos' ? conEstado : conEstado.filter(c => c.estado === filtro)),
    [conEstado, filtro],
  )

  async function confirmarBaja(lote: LoteReporte) {
    const cantidad = Number(cantidadBaja)
    if (!Number.isFinite(cantidad) || cantidad <= 0 || cantidad > lote.cantidad_restante) return
    await onDarDeBaja(lote.lote_id, cantidad)
    setDandoDeBaja(null)
    setCantidadBaja('')
  }

  return (
    <div className="p-4 sm:p-6 max-w-6xl mx-auto">
      <div className="flex flex-wrap items-center justify-between gap-3 mb-4">
        <div>
          <h1 className="text-xl font-semibold flex items-center gap-2 dark:text-white">
            <CalendarClock className="w-5 h-5 text-indigo-600" aria-hidden="true" />
            Vencimientos
          </h1>
          <p className="text-sm text-stone-500 dark:text-gray-400">
            {nombreSucursal ? `${nombreSucursal} · ` : ''}
            Rojo a {diasCritico} días, amarillo a {diasAlerta}. Se configura en Configuración.
          </p>
        </div>
        <button
          type="button"
          onClick={onRefrescar}
          disabled={refrescando}
          className="inline-flex items-center gap-1.5 px-3 py-1.5 text-sm border rounded-lg dark:border-gray-600 dark:text-gray-200 hover:bg-stone-50 dark:hover:bg-gray-700 disabled:opacity-50"
        >
          <RefreshCw className={`w-4 h-4 ${refrescando ? 'animate-spin' : ''}`} aria-hidden="true" />
          Actualizar
        </button>
      </div>

      <div className="flex flex-wrap gap-2 mb-4">
        {FILTROS.map(f => {
          const n = f.clave === 'todos' ? conEstado.length : conteos[f.clave]
          return (
            <button
              key={f.clave}
              type="button"
              onClick={() => setFiltro(f.clave)}
              className={`px-3 py-1.5 rounded-lg text-sm border transition-colors ${
                filtro === f.clave
                  ? 'bg-indigo-600 text-white border-indigo-600'
                  : 'border-stone-200 text-stone-600 hover:bg-stone-50 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-700'
              }`}
            >
              {f.label} <span className="opacity-70">({n})</span>
            </button>
          )
        })}
      </div>

      {cargando ? (
        <div className="flex justify-center py-12">
          <Loader2 className="w-6 h-6 animate-spin text-stone-400" aria-hidden="true" />
        </div>
      ) : visibles.length === 0 ? (
        <div className="text-center py-12 text-stone-500 dark:text-gray-400">
          <PackageX className="w-10 h-10 mx-auto mb-2 opacity-40" aria-hidden="true" />
          {conEstado.length === 0 ? (
            <>
              <p>No hay vencimientos cargados.</p>
              <p className="text-sm">
                Se cargan al registrar la factura de compra, o a mano desde la ficha del producto.
              </p>
            </>
          ) : (
            <p>Nada en esta categoría.</p>
          )}
        </div>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-xs text-stone-500 dark:text-gray-400 border-b dark:border-gray-700">
                <th className="text-left py-2 pr-2">Producto</th>
                <th className="text-left py-2 px-2 w-28">Vence</th>
                <th className="text-left py-2 px-2 w-40">Estado</th>
                <th className="text-right py-2 px-2 w-24">Quedan</th>
                <th className="text-right py-2 px-2 w-24">Stock</th>
                <th className="py-2 pl-2 w-32"></th>
              </tr>
            </thead>
            <tbody>
              {visibles.map(({ lote, estado }) => (
                <tr
                  key={lote.lote_id}
                  className={`border-b dark:border-gray-700 ${
                    estado === 'vencido' ? 'bg-red-50/60 dark:bg-red-900/10' : ''
                  }`}
                >
                  <td className="py-2 pr-2 dark:text-gray-200">
                    <span className="font-medium">{lote.producto_nombre}</span>
                    {lote.producto_codigo && (
                      <span className="ml-1 text-xs text-stone-400">{lote.producto_codigo}</span>
                    )}
                    {lote.bolsa_producto > 0 && (
                      <span
                        className="block text-xs text-stone-400 dark:text-gray-500"
                        title="Unidades del producto que no están en ningún lote: salen antes que este"
                      >
                        + {lote.bolsa_producto} u. sin vencimiento cargado
                      </span>
                    )}
                  </td>
                  <td className="py-2 px-2 font-mono text-xs dark:text-gray-300">
                    {formatearFechaVencimiento(lote.fecha_vencimiento)}
                  </td>
                  <td className="py-2 px-2">
                    <BadgeVencimiento
                      fecha={lote.fecha_vencimiento}
                      diasAlerta={diasAlerta}
                      diasCritico={diasCritico}
                    />
                  </td>
                  <td className="py-2 px-2 text-right tabular-nums dark:text-gray-200">
                    <strong>{lote.cantidad_restante}</strong>
                    <span className="text-stone-400"> / {lote.cantidad}</span>
                  </td>
                  <td className="py-2 px-2 text-right tabular-nums text-stone-500 dark:text-gray-400">
                    {lote.stock_producto}
                  </td>
                  <td className="py-2 pl-2 text-right">
                    {dandoDeBaja === lote.lote_id ? (
                      <span className="inline-flex items-center gap-1">
                        <input
                          type="number"
                          min={1}
                          max={lote.cantidad_restante}
                          value={cantidadBaja}
                          onChange={e => setCantidadBaja(e.target.value)}
                          aria-label="Unidades a dar de baja"
                          className="w-16 px-2 py-1 border rounded text-sm text-right dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                        />
                        <button
                          type="button"
                          onClick={() => void confirmarBaja(lote)}
                          disabled={darDeBajaPendiente}
                          aria-label="Confirmar la baja"
                          className="p-1 text-green-600 hover:text-green-700 disabled:opacity-50"
                        >
                          {darDeBajaPendiente
                            ? <Loader2 className="w-4 h-4 animate-spin" aria-hidden="true" />
                            : <Check className="w-4 h-4" aria-hidden="true" />}
                        </button>
                        <button
                          type="button"
                          onClick={() => { setDandoDeBaja(null); setCantidadBaja('') }}
                          aria-label="Cancelar la baja"
                          className="p-1 text-stone-400 hover:text-stone-600"
                        >
                          <X className="w-4 h-4" aria-hidden="true" />
                        </button>
                      </span>
                    ) : (
                      puedeDarDeBaja && (
                        <button
                          type="button"
                          onClick={() => {
                            setDandoDeBaja(lote.lote_id)
                            setCantidadBaja(String(lote.cantidad_restante))
                          }}
                          className="inline-flex items-center gap-1 px-2 py-1 text-xs border rounded text-red-700 border-red-200 hover:bg-red-50 dark:text-red-300 dark:border-red-800 dark:hover:bg-red-900/20"
                        >
                          <AlertTriangle className="w-3 h-3" aria-hidden="true" />
                          Dar de baja
                        </button>
                      )
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {conteos.vencido > 0 && (
        <p className="mt-4 text-xs text-stone-500 dark:text-gray-400">
          Los lotes vencidos <strong>no</strong> bloquean la venta: el producto se sigue pudiendo
          cargar en un pedido. Dar de baja descuenta el stock y lo registra como merma por
          vencimiento, con su costo.
        </p>
      )}
    </div>
  )
}
