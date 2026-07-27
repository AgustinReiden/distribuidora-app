/**
 * ModalCrearMovimiento — la sucursal origen crea una "salida" hacia otra
 * sucursal, o edita una pendiente (`modo="editar"`, solo admin).
 *
 * Desde la mig 139 crear DESCUENTA el stock del origen en el acto (la
 * mercadería ya salió del depósito), y editar lo ajusta por diferencia.
 */
import { memo, useEffect, useMemo, useState } from 'react'
import { Loader2, Search, Plus, Trash2, Building2, PackageMinus } from 'lucide-react'
import ModalBase from './ModalBase'
import NumberInput from '../ui/NumberInput'
import { stockDisponibleParaEnvio } from '../../utils/movimientos'
import type { MovimientoSucursalDB, MovimientoItemDB } from '../../hooks/queries'
import type { ProductoDB, SucursalDB } from '../../types'

interface LineaItem {
  productoId: string
  nombre: string
  cantidad: number
  /** Tope editable: stock en góndola + lo que este envío ya tenía reservado. */
  stock: number
}

export interface ModalCrearMovimientoProps {
  sucursales: SucursalDB[]
  productos: ProductoDB[]
  guardando: boolean
  onClose: () => void
  onConfirmar?: (payload: {
    sucursalDestinoId: number
    notas?: string
    items: Array<{ producto_id: number; cantidad: number }>
  }) => Promise<void>
  /** Modo edición de un envío pendiente. */
  modo?: 'crear' | 'editar'
  movimiento?: MovimientoSucursalDB
  itemsIniciales?: MovimientoItemDB[]
  loadingItems?: boolean
  onGuardarEdicion?: (payload: {
    notas?: string
    items: Array<{ producto_id: number; cantidad: number }>
  }) => Promise<void>
}

const ModalCrearMovimiento = memo(function ModalCrearMovimiento({
  sucursales, productos, guardando, onClose, onConfirmar,
  modo = 'crear', movimiento, itemsIniciales, loadingItems, onGuardarEdicion,
}: ModalCrearMovimientoProps) {
  const esEditar = modo === 'editar'
  const [destino, setDestino] = useState<string>(esEditar ? String(movimiento?.sucursal_destino_id ?? '') : '')
  const [notas, setNotas] = useState<string>(esEditar ? (movimiento?.notas ?? '') : '')
  const [busqueda, setBusqueda] = useState<string>('')
  const [lineas, setLineas] = useState<LineaItem[]>([])
  const [error, setError] = useState<string>('')

  // Cantidades que este envío ya tiene reservadas, por producto: en edición el
  // stock de `productos` viene descontado por este mismo envío.
  const reservadoPorProducto = useMemo(() => {
    const m = new Map<string, number>()
    if (!esEditar) return m
    for (const it of itemsIniciales ?? []) {
      const k = String(it.producto_origen_id)
      m.set(k, (m.get(k) ?? 0) + it.cantidad)
    }
    return m
  }, [esEditar, itemsIniciales])

  const stockDe = (productoId: string, stockActual: number) =>
    stockDisponibleParaEnvio(stockActual, reservadoPorProducto.get(productoId) ?? 0)

  // Prellenar las líneas cuando llegan los items del envío que se edita.
  useEffect(() => {
    if (!esEditar || !itemsIniciales?.length) return
    setLineas(itemsIniciales.map(it => {
      const pid = String(it.producto_origen_id)
      const prod = productos.find(p => String(p.id) === pid)
      return {
        productoId: pid,
        nombre: prod?.nombre ?? it.origen_nombre,
        cantidad: it.cantidad,
        stock: stockDisponibleParaEnvio(prod?.stock ?? 0, it.cantidad),
      }
    }))
  }, [esEditar, itemsIniciales, productos])

  const resultados = useMemo(() => {
    const term = busqueda.trim().toLowerCase()
    if (!term) return []
    return productos
      .filter(p => p.nombre.toLowerCase().includes(term) || (p.codigo || '').toLowerCase().includes(term))
      .slice(0, 20)
  }, [productos, busqueda])

  const agregar = (p: ProductoDB) => {
    setLineas(prev => prev.some(l => l.productoId === p.id)
      ? prev
      : [...prev, { productoId: p.id, nombre: p.nombre, cantidad: 1, stock: stockDe(p.id, p.stock || 0) }])
    setBusqueda('')
  }

  const setCantidad = (id: string, cant: number) =>
    setLineas(prev => prev.map(l => l.productoId === id ? { ...l, cantidad: cant } : l))

  const quitar = (id: string) => setLineas(prev => prev.filter(l => l.productoId !== id))

  const handleSubmit = async () => {
    setError('')
    if (!esEditar && !destino) { setError('Elegí la sucursal destino.'); return }
    const items = lineas.filter(l => l.cantidad > 0).map(l => ({ producto_id: Number(l.productoId), cantidad: l.cantidad }))
    if (items.length === 0) {
      setError(esEditar
        ? 'Un envío no puede quedar sin productos. Si querés darlo de baja, usá Cancelar.'
        : 'Agregá al menos un producto con cantidad.')
      return
    }
    const excedido = lineas.find(l => l.cantidad > l.stock)
    if (excedido) { setError(`${excedido.nombre}: no hay stock para ${excedido.cantidad} (disponible ${excedido.stock}).`); return }
    try {
      if (esEditar) {
        await onGuardarEdicion?.({ notas: notas.trim() || undefined, items })
      } else {
        await onConfirmar?.({ sucursalDestinoId: Number(destino), notas: notas.trim() || undefined, items })
      }
    } catch (e) {
      setError((e as Error).message || `Error al ${esEditar ? 'editar' : 'crear'} el movimiento`)
    }
  }

  return (
    <ModalBase
      title={esEditar ? `Editar envío #${movimiento?.id}` : 'Nueva salida de stock'}
      description={esEditar
        ? 'El stock de esta sucursal se ajusta según los cambios que hagas.'
        : 'El stock sale de esta sucursal al confirmar. La otra sucursal lo ingresa cuando lo recibe.'}
      onClose={onClose}
      maxWidth="max-w-xl"
    >
      <div className="p-4 space-y-4 max-h-[70vh] overflow-y-auto">
        <div className="flex gap-2 p-3 rounded-lg bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800">
          <PackageMinus className="w-5 h-5 text-amber-600 dark:text-amber-400 shrink-0 mt-0.5" />
          <p className="text-sm text-amber-800 dark:text-amber-200">
            {esEditar
              ? 'Este envío ya descontó su stock. Si subís una cantidad se descuenta la diferencia; si la bajás o quitás un producto, vuelve al stock.'
              : 'Al crear la salida el stock se descuenta de esta sucursal, porque la mercadería ya salió del depósito.'}
          </p>
        </div>

        <div>
          <label className="block text-sm font-medium mb-1 dark:text-gray-200 flex items-center gap-1">
            <Building2 className="w-4 h-4" /> Sucursal destino
          </label>
          <select
            value={destino}
            onChange={e => setDestino(e.target.value)}
            disabled={esEditar}
            className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white disabled:opacity-60 disabled:cursor-not-allowed"
          >
            <option value="">Seleccionar sucursal...</option>
            {sucursales.map(s => <option key={s.id} value={s.id}>{s.nombre}</option>)}
          </select>
          {esEditar && (
            <p className="text-xs text-gray-500 mt-1">
              El destino no se puede cambiar. Para eso, cancelá el envío y creá uno nuevo.
            </p>
          )}
        </div>

        <div>
          <label className="block text-sm font-medium mb-1 dark:text-gray-200">Agregar productos</label>
          <div className="relative">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" />
            <input
              type="text" value={busqueda} onChange={e => setBusqueda(e.target.value)}
              placeholder="Buscar por nombre o código..."
              className="w-full pl-9 pr-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            />
          </div>
          {resultados.length > 0 && (
            <div className="mt-1 border rounded-lg divide-y dark:border-gray-600 dark:divide-gray-600 max-h-48 overflow-y-auto">
              {resultados.map(p => (
                <button
                  key={p.id} type="button" onClick={() => agregar(p)}
                  className="w-full flex items-center justify-between px-3 py-2 text-left text-sm hover:bg-gray-50 dark:hover:bg-gray-700/50"
                >
                  <span className="truncate dark:text-white">{p.nombre}</span>
                  <span className="text-xs text-gray-400 flex-shrink-0 ml-2">stock {stockDe(p.id, p.stock ?? 0)}</span>
                </button>
              ))}
            </div>
          )}
        </div>

        {esEditar && loadingItems && (
          <p className="text-sm text-gray-500 flex items-center gap-2">
            <Loader2 className="w-4 h-4 animate-spin" /> Cargando el envío…
          </p>
        )}

        {lineas.length > 0 && (
          <div className="border rounded-lg divide-y dark:border-gray-600 dark:divide-gray-600">
            {lineas.map(l => (
              <div key={l.productoId} className="flex items-center gap-2 px-3 py-2">
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-medium dark:text-white truncate">{l.nombre}</p>
                  <p className={`text-xs ${l.cantidad > l.stock ? 'text-red-500' : 'text-gray-400'}`}>
                    stock disponible: {l.stock}
                  </p>
                </div>
                <NumberInput
                  integer
                  min={0}
                  max={l.stock}
                  emptyValue={0}
                  commitOnChange
                  value={l.cantidad}
                  onChange={(n) => setCantidad(l.productoId, n)}
                  className="w-20 px-2 py-1 text-sm border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                />
                <button type="button" onClick={() => quitar(l.productoId)} className="p-1 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded">
                  <Trash2 className="w-4 h-4" />
                </button>
              </div>
            ))}
          </div>
        )}

        <div>
          <label className="block text-sm font-medium mb-1 dark:text-gray-200">Notas (opcional)</label>
          <textarea
            value={notas} onChange={e => setNotas(e.target.value)} rows={2}
            className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            placeholder="Observaciones del envío..."
          />
        </div>

        {error && (
          <div className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg text-sm text-red-600 dark:text-red-400">
            {error}
          </div>
        )}
      </div>

      <div className="flex justify-end gap-2 p-4 border-t bg-gray-50 dark:bg-gray-800 dark:border-gray-700">
        <button onClick={onClose} className="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 rounded-lg">
          Cancelar
        </button>
        <button
          onClick={() => { void handleSubmit() }}
          disabled={guardando}
          className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 flex items-center disabled:opacity-50"
        >
          {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
          {esEditar ? 'Guardar cambios' : 'Crear salida'}
        </button>
      </div>
    </ModalBase>
  )
})

export default ModalCrearMovimiento
