/**
 * Modal para cerrar/confirmar una rendición diaria.
 *
 * Flujo:
 *   1. Admin/encargado elige estado final: "confirmada" o "disconformidad".
 *   2. Opcionalmente agrega observaciones (texto libre).
 *   3. Revisa los gastos pagados con la plata del día: suma, edita o quita. Cada uno se carga
 *      con el mismo «Registrar gasto» de la vista Gastos, con la plata fija en esta rendición.
 *      El modal trabaja en borrador: no escribe nada hasta confirmar.
 *   4. Al submit se llama `confirmar_rendicion` (RPC) con los cambios `{vistos, guardar, quitar}`:
 *      guarda el control y los gastos en una sola transacción. Lo que el modal no tocó no viaja,
 *      así un encargado reconfirma sin pisar lo que cargó un admin.
 */
import { useState, memo, useRef, Suspense } from 'react'
import { Plus, Pencil, Trash2, CheckCircle2, AlertTriangle, FileText } from 'lucide-react'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import { formatPrecio } from '../../utils/formatters'
import { lazyWithReload } from '../../utils/lazyWithReload'
import { etiquetaComprobante, puedeTocarGasto } from '../../utils/gastos'
import {
  cambiosDelCierre,
  efectivoAEntregar,
  gastosVistos,
  itemsDelCierre,
  totalDelCierre,
  type ItemCierre,
} from '../../utils/rendicionGastos'
import { usePropsModalGasto } from '../../hooks/usePropsModalGasto'
import type { CambiosGastosRendicion, GastoDeRendicion, GastoVisto, GuardarGastoPayload } from '../../types/gastos'

const ModalGasto = lazyWithReload(() => import('./ModalGasto'))

export interface ModalCerrarRendicionProps {
  /** Fecha de la rendición (YYYY-MM-DD) para mostrar en el header */
  fecha: string
  transportistaId: string
  /** Nombre del transportista para contexto */
  transportistaNombre: string
  /** Total cobrado en esa rendición, para mostrar como referencia */
  totalCobrado: number
  /** Total entregado en esa fecha, para que el usuario compare */
  totalEntregado: number
  /** Cobros vinculados a un pedido entregado el mismo dia. */
  totalEntregas: number
  /** Cobros de cuenta corriente (resto: pago sin pedido, FIFO o pedido no
   *  entregado en la fecha). */
  totalCtasCte: number
  /** Efectivo cobrado: de ahí se descuentan los gastos pagados con esa plata. */
  totalEfectivo: number
  /** Los gastos vivos de esta rendición. */
  gastos: GastoDeRendicion[]
  /** Observaciones existentes (si la rendición ya tenía) para prellenar */
  observacionesPrevias?: string | null
  /** Callback al confirmar. Recibe estado + observaciones + los cambios en los gastos. */
  onConfirmar: (
    estado: 'confirmada' | 'disconformidad',
    observaciones: string | null,
    gastos: CambiosGastosRendicion
  ) => Promise<void>
  onClose: () => void
  guardando: boolean
}

/** Qué está abierto en el modal de gasto: uno nuevo, o el ítem que se edita. */
type Editor = { clave: string | null }

function formatFechaCorta(fechaISO: string): string {
  const [y, m, d] = fechaISO.split('-')
  return `${d}/${m}/${y}`
}

const ModalCerrarRendicion = memo(function ModalCerrarRendicion({
  fecha,
  transportistaId,
  transportistaNombre,
  totalCobrado,
  totalEntregado,
  totalEntregas,
  totalCtasCte,
  totalEfectivo,
  gastos,
  observacionesPrevias,
  onConfirmar,
  onClose,
  guardando
}: ModalCerrarRendicionProps) {
  const [estado, setEstado] = useState<'confirmada' | 'disconformidad'>('confirmada')
  const [observaciones, setObservaciones] = useState<string>(observacionesPrevias || '')
  // Los gastos que mostró el modal al abrirse, con su `updated_at`: el server rechaza el cierre si
  // alguno se cargó, se quitó o se editó mientras tanto.
  const [vistos] = useState<GastoVisto[]>(() => gastosVistos(gastos))
  const [items, setItems] = useState<ItemCierre[]>(() => itemsDelCierre(gastos))
  const [editor, setEditor] = useState<Editor | null>(null)
  const contador = useRef(0)
  const propsGasto = usePropsModalGasto()
  const quien = {
    esAdmin: propsGasto.esAdmin,
    usuarioId: propsGasto.usuarioId ?? '',
    tieneTodasLasSucursales: propsGasto.tieneTodasLasSucursales,
  }

  const diferencia = totalCobrado - totalEntregado
  const { cantidad: cantidadGastos, total: totalGastos } = totalDelCierre(items)
  const aEntregar = efectivoAEntregar(totalEfectivo, totalGastos)

  const itemEditado = editor?.clave ? items.find(i => i.clave === editor.clave) ?? null : null

  const guardarEnBorrador = async (payload: GuardarGastoPayload): Promise<void> => {
    if (editor?.clave) {
      setItems(prev => prev.map(i =>
        i.clave === editor.clave ? { ...i, payload, editado: i.original !== null } : i))
    } else {
      contador.current += 1
      setItems(prev => [...prev, {
        clave: `n${contador.current}`, original: null, payload, editado: false, quitado: false,
      }])
    }
  }

  const quitar = (item: ItemCierre): void => {
    // Un borrador se va de la lista; uno ya guardado queda marcado y se anula al confirmar.
    setItems(prev => item.original === null
      ? prev.filter(i => i.clave !== item.clave)
      : prev.map(i => (i.clave === item.clave ? { ...i, quitado: true } : i)))
  }

  const deshacerQuitar = (item: ItemCierre): void => {
    setItems(prev => prev.map(i => (i.clave === item.clave ? { ...i, quitado: false } : i)))
  }

  const rubroDe = (item: ItemCierre): string =>
    item.original?.rubro?.nombre
    ?? propsGasto.rubros.find(r => r.id === Number(item.payload.rubro_id))?.nombre
    ?? 'Gasto'

  const vehiculoDe = (item: ItemCierre): string | null => {
    const v = item.original?.vehiculo
      ?? propsGasto.vehiculos.find(x => x.id === Number(item.payload.vehiculo_id))
    return v ? `${v.descripcion} ${v.patente}` : null
  }

  const handleSubmit = async (): Promise<void> => {
    await onConfirmar(
      estado,
      observaciones.trim() || null,
      cambiosDelCierre(items, vistos)
    )
  }

  return (
    <ModalBase title="Cerrar rendición" onClose={onClose} maxWidth="max-w-2xl">
      <div className="p-4 space-y-4">
        {/* Contexto: fecha + transportista */}
        <div className="bg-gray-50 dark:bg-gray-700/50 rounded-lg p-3">
          <p className="text-sm text-gray-600 dark:text-gray-400">
            Rendición de <span className="font-semibold text-gray-800 dark:text-white">{transportistaNombre}</span>{' '}
            del <span className="font-semibold text-gray-800 dark:text-white">{formatFechaCorta(fecha)}</span>
          </p>
          <div className="grid grid-cols-3 gap-3 mt-3 text-sm">
            <div>
              <p className="text-xs text-gray-500">Cobrado</p>
              <p className="font-bold text-gray-800 dark:text-white">{formatPrecio(totalCobrado)}</p>
            </div>
            <div>
              <p className="text-xs text-gray-500">Entregado</p>
              <p className="font-bold text-gray-800 dark:text-white">{formatPrecio(totalEntregado)}</p>
            </div>
            <div>
              <p className="text-xs text-gray-500">Diferencia</p>
              <p className={`font-bold ${diferencia === 0 ? 'text-gray-800 dark:text-white' : diferencia < 0 ? 'text-red-600' : 'text-emerald-600'}`}>
                {formatPrecio(diferencia)}
              </p>
            </div>
          </div>
          <div className="grid grid-cols-2 gap-3 mt-3 text-sm border-t border-gray-200 dark:border-gray-600 pt-3">
            <div>
              <p className="text-xs text-gray-500">Entregas (cobro del día)</p>
              <p className="font-bold text-emerald-700 dark:text-emerald-400">{formatPrecio(totalEntregas)}</p>
            </div>
            <div>
              <p className="text-xs text-gray-500">Ctas Ctes (cobro de saldos)</p>
              <p className="font-bold text-blue-700 dark:text-blue-400">{formatPrecio(totalCtasCte)}</p>
            </div>
          </div>
        </div>

        {/* Efectivo */}
        <div className="bg-gray-50 dark:bg-gray-700/50 rounded-lg p-3 text-sm space-y-1">
          <p className="text-xs font-medium text-gray-500 uppercase tracking-wide">Efectivo</p>
          <div className="flex items-center justify-between">
            <span className="text-gray-600 dark:text-gray-400">Cobrado en efectivo</span>
            <span className="font-medium text-gray-800 dark:text-white">{formatPrecio(totalEfectivo)}</span>
          </div>
          <div className="flex items-center justify-between">
            <span className="text-gray-600 dark:text-gray-400">{`Gastos pagados con esa plata (${cantidadGastos})`}</span>
            <span className="font-medium text-gray-800 dark:text-white">{`− ${formatPrecio(totalGastos)}`}</span>
          </div>
          <div className="flex items-center justify-between border-t border-gray-200 dark:border-gray-600 pt-1">
            <span className="font-semibold text-gray-800 dark:text-white">A entregar</span>
            <span className={`font-bold ${aEntregar < 0 ? 'text-red-600' : 'text-gray-800 dark:text-white'}`}>
              {formatPrecio(aEntregar)}
            </span>
          </div>
          {aEntregar < 0 && (
            <p role="alert" className="text-xs text-red-600">Los gastos superan el efectivo cobrado.</p>
          )}
        </div>

        {/* Estado final */}
        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
            Resultado de la rendición
          </label>
          <div className="grid grid-cols-2 gap-2">
            <button
              type="button"
              onClick={() => setEstado('confirmada')}
              className={`flex items-center gap-2 px-4 py-3 rounded-lg border-2 transition-colors ${
                estado === 'confirmada'
                  ? 'bg-emerald-50 border-emerald-500 dark:bg-emerald-900/20 dark:border-emerald-600'
                  : 'bg-white border-gray-200 hover:bg-gray-50 dark:bg-gray-700 dark:border-gray-600'
              }`}
            >
              <CheckCircle2 className={`w-5 h-5 ${estado === 'confirmada' ? 'text-emerald-600' : 'text-gray-400'}`} />
              <div className="text-left">
                <p className={`font-medium ${estado === 'confirmada' ? 'text-emerald-700 dark:text-emerald-300' : 'text-gray-700 dark:text-gray-300'}`}>
                  Confirmar
                </p>
                <p className="text-xs text-gray-500">Todo cuadra</p>
              </div>
            </button>
            <button
              type="button"
              onClick={() => setEstado('disconformidad')}
              className={`flex items-center gap-2 px-4 py-3 rounded-lg border-2 transition-colors ${
                estado === 'disconformidad'
                  ? 'bg-red-50 border-red-500 dark:bg-red-900/20 dark:border-red-600'
                  : 'bg-white border-gray-200 hover:bg-gray-50 dark:bg-gray-700 dark:border-gray-600'
              }`}
            >
              <AlertTriangle className={`w-5 h-5 ${estado === 'disconformidad' ? 'text-red-600' : 'text-gray-400'}`} />
              <div className="text-left">
                <p className={`font-medium ${estado === 'disconformidad' ? 'text-red-700 dark:text-red-300' : 'text-gray-700 dark:text-gray-300'}`}>
                  Disconformidad
                </p>
                <p className="text-xs text-gray-500">Hay algo para revisar</p>
              </div>
            </button>
          </div>
        </div>

        {/* Observaciones */}
        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1 flex items-center gap-1">
            <FileText className="w-4 h-4" />
            Observaciones {estado === 'disconformidad' && <span className="text-red-500">*</span>}
          </label>
          <textarea
            value={observaciones}
            onChange={e => setObservaciones(e.target.value)}
            rows={3}
            placeholder={estado === 'disconformidad'
              ? 'Describí qué hay que revisar (ej: faltan $500 en efectivo, cheque rechazado…)'
              : 'Opcional: notas sobre el día…'}
            className="w-full px-3 py-2 border rounded-lg resize-none dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
          />
        </div>

        {/* Gastos */}
        <div>
          <div className="flex items-center justify-between mb-2">
            <span className="text-sm font-medium text-gray-700 dark:text-gray-300">
              Gastos pagados con la plata del día
            </span>
            <Button
              type="button"
              onClick={() => setEditor({ clave: null })}
              variant="ghost"
              size="sm"
              className="gap-1 text-xs text-blue-600 dark:text-blue-400 hover:bg-blue-50 dark:hover:bg-blue-900/20"
            >
              <Plus className="w-3 h-3" aria-hidden="true" />
              Agregar gasto
            </Button>
          </div>
          <p className="text-xs text-gray-500 dark:text-gray-400 mb-2">
            Abre el mismo «Registrar gasto», con la plata fija en esta rendición. Cada gasto queda en Gastos con su rubro y su vehículo.
          </p>

          {items.length === 0 ? (
            <div className="text-center py-4 border border-dashed dark:border-gray-600 rounded-lg text-sm text-gray-400">
              Sin gastos pagados con esta plata
            </div>
          ) : (
            <ul className="space-y-2">
              {items.map(item => {
                const rubro = rubroDe(item)
                const vehiculo = vehiculoDe(item)
                const puedeTocar = item.original === null || puedeTocarGasto(item.original, quien)
                const p = item.payload
                return (
                  <li
                    key={item.clave}
                    className="flex items-start justify-between gap-2 p-2 border rounded-lg dark:border-gray-600"
                  >
                    <div className={`min-w-0 flex-1 text-sm ${item.quitado ? 'line-through text-gray-400' : 'text-gray-800 dark:text-white'}`}>
                      <p className="font-medium">{vehiculo ? `${rubro} · ${vehiculo}` : rubro}</p>
                      <p className="text-xs text-gray-500">
                        {etiquetaComprobante(p.comprobante)}
                        {p.comprobante_numero ? ` ${p.comprobante_numero}` : ''}
                        {p.litros ? ` · ${String(p.litros).replace('.', ',')} litros` : ''}
                      </p>
                      {item.quitado && (
                        <p className="text-xs text-amber-600 no-underline">Se quita al confirmar</p>
                      )}
                    </div>
                    <span className={`font-semibold text-sm ${item.quitado ? 'line-through text-gray-400' : 'text-gray-800 dark:text-white'}`}>
                      {formatPrecio(p.monto_total)}
                    </span>
                    {item.quitado ? (
                      <Button type="button" variant="ghost" size="sm" onClick={() => deshacerQuitar(item)}>
                        Deshacer
                      </Button>
                    ) : puedeTocar && (
                      <div className="flex items-center gap-1">
                        <Button
                          type="button"
                          variant="ghost"
                          size="iconSm"
                          aria-label={`Editar gasto de ${rubro}`}
                          onClick={() => setEditor({ clave: item.clave })}
                        >
                          <Pencil className="w-4 h-4" aria-hidden="true" />
                        </Button>
                        <Button
                          type="button"
                          variant="ghost"
                          size="iconSm"
                          aria-label={`Quitar gasto de ${rubro}`}
                          onClick={() => quitar(item)}
                          className="text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 dark:text-red-400"
                        >
                          <Trash2 className="w-4 h-4" aria-hidden="true" />
                        </Button>
                      </div>
                    )}
                  </li>
                )
              })}
            </ul>
          )}
          <p className="mt-2 text-xs text-gray-500 dark:text-gray-400">
            Si lo pagó con plata propia, no va acá.
          </p>
        </div>
      </div>

      {/* El modal del gasto va ADENTRO de este (regla de Radix): como hermano queda detrás del overlay. */}
      {editor && (
        <Suspense fallback={null}>
          <ModalGasto
            {...propsGasto}
            gasto={itemEditado?.original ?? null}
            borrador={itemEditado?.payload ?? null}
            desdeCierre={{ transportistaId, transportistaNombre, fecha }}
            onSave={guardarEnBorrador}
            onClose={() => setEditor(null)}
          />
        </Suspense>
      )}

      {/* Footer */}
      <div className="flex items-center justify-end gap-2 p-4 border-t bg-gray-50 dark:bg-gray-800 dark:border-gray-700">
        <Button variant="ghost" size="md" onClick={onClose} disabled={guardando}>
          Cancelar
        </Button>
        <Button
          variant={estado === 'confirmada' ? 'success' : 'danger'}
          size="md"
          onClick={handleSubmit}
          disabled={guardando || (estado === 'disconformidad' && !observaciones.trim())}
          loading={guardando}
        >
          {estado === 'confirmada' ? 'Confirmar rendición' : 'Marcar disconformidad'}
        </Button>
      </div>
    </ModalBase>
  )
})

export default ModalCerrarRendicion
