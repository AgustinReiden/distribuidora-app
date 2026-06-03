/**
 * ModalAceptarMovimiento — la sucursal destino acepta (o deniega) un movimiento.
 *
 * Por cada item sugiere el match con un producto del destino (código/nombre
 * exacto). Quien acepta confirma el match, elige otro producto, o crea uno nuevo
 * (copiando el de origen). Al aceptar, el backend mueve el stock atómicamente.
 */
import { memo, useEffect, useMemo, useState } from 'react'
import { Loader2, Check, X, AlertTriangle } from 'lucide-react'
import ModalBase from './ModalBase'
import { formatPrecio } from '../../utils/formatters'
import { sugerirMatchProducto } from '../../utils/matchProducto'
import type { ProductoDB } from '../../types'
import type { MovimientoSucursalDB, MovimientoItemDB, ResolucionItem } from '../../hooks/queries'

const NUEVO = '__nuevo__'

export interface ModalAceptarMovimientoProps {
  movimiento: MovimientoSucursalDB
  items: MovimientoItemDB[]
  loadingItems: boolean
  productosDestino: ProductoDB[]
  guardando: boolean
  onConfirmar: (resoluciones: ResolucionItem[]) => Promise<void>
  onDenegar: (motivo: string) => Promise<void>
  onClose: () => void
}

const ModalAceptarMovimiento = memo(function ModalAceptarMovimiento({
  movimiento, items, loadingItems, productosDestino, guardando, onConfirmar, onDenegar, onClose,
}: ModalAceptarMovimientoProps) {
  // item_id -> producto_destino_id (string) | NUEVO
  const [sel, setSel] = useState<Record<number, string>>({})
  const [modoDenegar, setModoDenegar] = useState(false)
  const [motivo, setMotivo] = useState('')
  const [error, setError] = useState('')

  // Inicializar selección con la sugerencia automática por item.
  useEffect(() => {
    if (items.length === 0) return
    setSel(prev => {
      const next = { ...prev }
      for (const it of items) {
        if (next[it.id] != null) continue
        const sug = sugerirMatchProducto({ codigo: it.origen_codigo, nombre: it.origen_nombre }, productosDestino)
        next[it.id] = sug ? String(sug.id) : NUEVO
      }
      return next
    })
  }, [items, productosDestino])

  const productosPorId = useMemo(() => {
    const m = new Map<string, ProductoDB>()
    for (const p of productosDestino) m.set(String(p.id), p)
    return m
  }, [productosDestino])

  const handleAceptar = async () => {
    setError('')
    const resoluciones: ResolucionItem[] = items.map(it => {
      const v = sel[it.id] ?? NUEVO
      return v === NUEVO
        ? { item_id: it.id, accion: 'crear_nuevo' }
        : { item_id: it.id, accion: 'match_existente', producto_destino_id: Number(v) }
    })
    try {
      await onConfirmar(resoluciones)
    } catch (e) {
      setError((e as Error).message || 'Error al aceptar el movimiento')
    }
  }

  const handleDenegar = async () => {
    setError('')
    try {
      await onDenegar(motivo.trim())
    } catch (e) {
      setError((e as Error).message || 'Error al denegar el movimiento')
    }
  }

  return (
    <ModalBase
      title={`Aceptar movimiento #${movimiento.id}`}
      description={`Entrante de ${movimiento.origen?.nombre || 'otra sucursal'}. Confirmá el producto de destino para cada item.`}
      onClose={onClose}
      maxWidth="max-w-2xl"
    >
      <div className="p-4 space-y-3 max-h-[65vh] overflow-y-auto">
        {loadingItems ? (
          <div className="flex items-center justify-center py-8 text-gray-500">
            <Loader2 className="w-5 h-5 animate-spin text-blue-600" /><span className="ml-2">Cargando items...</span>
          </div>
        ) : (
          items.map(it => {
            const v = sel[it.id] ?? NUEVO
            const destProd = v !== NUEVO ? productosPorId.get(v) : undefined
            const costoOrigen = it.origen_costo_con_iva ?? 0
            const costoDest = destProd?.costo_con_iva ?? 0
            const costoResultante = v === NUEVO ? costoOrigen : Math.max(costoOrigen, costoDest)
            return (
              <div key={it.id} className="border dark:border-gray-600 rounded-lg p-3">
                <div className="flex items-center justify-between gap-2">
                  <div className="min-w-0">
                    <p className="font-medium dark:text-white truncate">{it.origen_nombre}</p>
                    <p className="text-xs text-gray-500">
                      {it.cantidad} u · {it.origen_codigo ? `cód ${it.origen_codigo} · ` : ''}costo origen {formatPrecio(costoOrigen)}
                    </p>
                  </div>
                </div>
                <div className="mt-2">
                  <label className="block text-xs font-medium mb-1 text-gray-600 dark:text-gray-400">Producto en esta sucursal</label>
                  <select
                    value={v}
                    onChange={e => setSel(prev => ({ ...prev, [it.id]: e.target.value }))}
                    className="w-full px-2 py-2 text-sm border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                  >
                    <option value={NUEVO}>➕ Crear nuevo (copia de origen)</option>
                    {productosDestino.map(p => (
                      <option key={p.id} value={p.id}>{p.nombre}{p.codigo ? ` (${p.codigo})` : ''}</option>
                    ))}
                  </select>
                  <p className="text-xs text-gray-500 mt-1">
                    {v === NUEVO
                      ? `Se creará el producto copiando precio y costo de origen.`
                      : `Costo destino quedará en ${formatPrecio(costoResultante)} (el mayor). Precio sin cambios.`}
                  </p>
                </div>
              </div>
            )
          })
        )}

        {modoDenegar && (
          <div className="border border-red-200 dark:border-red-800 rounded-lg p-3 bg-red-50 dark:bg-red-900/20">
            <label className="block text-sm font-medium mb-1 text-red-700 dark:text-red-300">Motivo del rechazo (opcional)</label>
            <textarea
              value={motivo} onChange={e => setMotivo(e.target.value)} rows={2}
              className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
              placeholder="Ej: no esperábamos este envío"
            />
          </div>
        )}

        {error && (
          <div className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg flex items-start gap-2 text-sm text-red-600 dark:text-red-400">
            <AlertTriangle className="w-4 h-4 flex-shrink-0 mt-0.5" /><span>{error}</span>
          </div>
        )}
      </div>

      <div className="flex justify-between gap-2 p-4 border-t bg-gray-50 dark:bg-gray-800 dark:border-gray-700">
        {!modoDenegar ? (
          <>
            <button onClick={() => setModoDenegar(true)} disabled={guardando}
              className="px-4 py-2 text-red-600 hover:bg-red-50 dark:hover:bg-red-900/20 rounded-lg disabled:opacity-50">
              Denegar
            </button>
            <div className="flex gap-2">
              <button onClick={onClose} className="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 rounded-lg">Cancelar</button>
              <button onClick={() => { void handleAceptar() }} disabled={guardando || loadingItems || items.length === 0}
                className="px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 flex items-center disabled:opacity-50">
                {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}<Check className="w-4 h-4 mr-1" /> Aceptar y mover stock
              </button>
            </div>
          </>
        ) : (
          <>
            <button onClick={() => setModoDenegar(false)} disabled={guardando}
              className="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 rounded-lg disabled:opacity-50">
              Volver
            </button>
            <button onClick={() => { void handleDenegar() }} disabled={guardando}
              className="px-4 py-2 bg-red-600 text-white rounded-lg hover:bg-red-700 flex items-center disabled:opacity-50">
              {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}<X className="w-4 h-4 mr-1" /> Confirmar rechazo
            </button>
          </>
        )}
      </div>
    </ModalBase>
  )
})

export default ModalAceptarMovimiento
