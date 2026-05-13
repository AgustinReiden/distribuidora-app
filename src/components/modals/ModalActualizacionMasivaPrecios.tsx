import { useState, useMemo, useCallback, lazy, Suspense } from 'react'
import type { ChangeEvent } from 'react'
import { Percent, Search, AlertTriangle, TrendingUp, TrendingDown } from 'lucide-react'
import ModalBase from './ModalBase'
import { useActualizarPreciosMasivoMutation } from '../../hooks/queries'
import { useNotification } from '../../contexts/NotificationContext'
import { calcularNuevosPrecios } from '../../utils/precios'
import { formatPrecio } from '../../utils/formatters'
import type { ProductoDB, ProveedorDBExtended } from '../../types'

const ModalConfirmacion = lazy(() => import('./ModalConfirmacion'))

export interface ModalActualizacionMasivaPreciosProps {
  productos: ProductoDB[]
  proveedores: ProveedorDBExtended[]
  categorias: string[]
  onClose: () => void
}

const PREVIEW_LIMIT = 5

export default function ModalActualizacionMasivaPrecios({
  productos,
  proveedores,
  categorias,
  onClose,
}: ModalActualizacionMasivaPreciosProps) {
  const notify = useNotification()
  const mutation = useActualizarPreciosMasivoMutation()

  const [porcentajeStr, setPorcentajeStr] = useState('')
  const [busqueda, setBusqueda] = useState('')
  const [filtroProveedor, setFiltroProveedor] = useState<string>('todos')
  const [filtroCategoria, setFiltroCategoria] = useState<string>('todas')
  const [seleccionados, setSeleccionados] = useState<Set<string>>(new Set())
  const [confirmOpen, setConfirmOpen] = useState(false)

  const porcentaje = parseFloat(porcentajeStr.replace(',', '.'))
  const porcentajeValido = !isNaN(porcentaje) && porcentaje !== 0

  const proveedoresMap = useMemo(
    () => new Map(proveedores.map(p => [p.id, p.nombre])),
    [proveedores]
  )

  const productosFiltrados = useMemo(() => {
    const q = busqueda.trim().toLowerCase()
    return productos.filter(p => {
      if (q) {
        const matchTexto =
          p.nombre?.toLowerCase().includes(q) ||
          p.codigo?.toLowerCase().includes(q)
        if (!matchTexto) return false
      }
      if (filtroProveedor !== 'todos' && p.proveedor_id !== filtroProveedor) return false
      if (filtroCategoria !== 'todas' && p.categoria !== filtroCategoria) return false
      return true
    })
  }, [productos, busqueda, filtroProveedor, filtroCategoria])

  const productosSeleccionados = useMemo(
    () => productos.filter(p => seleccionados.has(p.id)),
    [productos, seleccionados]
  )

  const seleccionadosFueraDelFiltro = useMemo(() => {
    const idsFiltrados = new Set(productosFiltrados.map(p => p.id))
    return productosSeleccionados.filter(p => !idsFiltrados.has(p.id)).length
  }, [productosFiltrados, productosSeleccionados])

  const previewItems = useMemo(() => {
    if (!porcentajeValido) return []
    return productosSeleccionados.slice(0, PREVIEW_LIMIT).map(p => ({
      producto: p,
      nuevos: calcularNuevosPrecios(p, porcentaje),
    }))
  }, [productosSeleccionados, porcentaje, porcentajeValido])

  const algunoQuedaEnCero = useMemo(() => {
    if (!porcentajeValido) return false
    return productosSeleccionados.some(p => {
      const nuevos = calcularNuevosPrecios(p, porcentaje)
      return nuevos.precio_final === 0 || nuevos.precio_neto === 0
    })
  }, [productosSeleccionados, porcentaje, porcentajeValido])

  const visiblesTodosSeleccionados =
    productosFiltrados.length > 0 &&
    productosFiltrados.every(p => seleccionados.has(p.id))

  const toggleProducto = useCallback((id: string) => {
    setSeleccionados(prev => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }, [])

  const toggleSeleccionarVisibles = useCallback(() => {
    setSeleccionados(prev => {
      const next = new Set(prev)
      if (visiblesTodosSeleccionados) {
        productosFiltrados.forEach(p => next.delete(p.id))
      } else {
        productosFiltrados.forEach(p => next.add(p.id))
      }
      return next
    })
  }, [productosFiltrados, visiblesTodosSeleccionados])

  const handleDeseleccionarTodos = useCallback(() => {
    setSeleccionados(new Set())
  }, [])

  const puedeAplicar =
    porcentajeValido && productosSeleccionados.length > 0 && !mutation.isPending

  const handleAplicar = useCallback(() => {
    if (!puedeAplicar) return
    setConfirmOpen(true)
  }, [puedeAplicar])

  const handleConfirmar = useCallback(async () => {
    setConfirmOpen(false)
    const items = productosSeleccionados.map(p => {
      const nuevos = calcularNuevosPrecios(p, porcentaje)
      return {
        producto_id: p.id,
        precio_neto: nuevos.precio_neto,
        imp_internos: nuevos.imp_internos,
        precio_final: nuevos.precio_final,
      }
    })
    try {
      const result = await mutation.mutateAsync(items)
      const sufijoErrores = result.errores?.length
        ? `, ${result.errores.length} con error`
        : ''
      notify.success(`${result.actualizados} producto(s) actualizado(s)${sufijoErrores}`)
      onClose()
    } catch (err) {
      const mensaje = err instanceof Error ? err.message : 'Error actualizando precios'
      notify.error(mensaje)
    }
  }, [productosSeleccionados, porcentaje, mutation, notify, onClose])

  const handlePorcentajeChange = (e: ChangeEvent<HTMLInputElement>) => {
    const v = e.target.value
    // Permitir vacío, signo negativo, dígitos, punto/coma decimal
    if (v === '' || /^-?\d*[.,]?\d*$/.test(v)) {
      setPorcentajeStr(v)
    }
  }

  const signoIcono =
    porcentajeValido && porcentaje > 0 ? (
      <TrendingUp className="w-5 h-5 text-green-600 dark:text-green-400" aria-hidden="true" />
    ) : porcentajeValido && porcentaje < 0 ? (
      <TrendingDown className="w-5 h-5 text-red-600 dark:text-red-400" aria-hidden="true" />
    ) : (
      <Percent className="w-5 h-5 text-gray-400 dark:text-gray-500" aria-hidden="true" />
    )

  const mensajeConfirmacion = `Vas a actualizar ${productosSeleccionados.length} producto(s) con un ${
    porcentaje > 0 ? '+' : ''
  }${porcentaje}%. Esta acción modifica precio neto, final e impuestos internos. ¿Continuar?`

  return (
    <>
      <ModalBase
        onClose={onClose}
        title="Actualización masiva de precios"
        description="Aplicá un porcentaje de aumento o rebaja a varios productos a la vez."
        maxWidth="max-w-4xl"
      >
        <div className="flex flex-col">
          <div className="px-5 sm:px-6 py-5 space-y-5">
            {/* Input de porcentaje */}
            <div>
              <label htmlFor="pct-aumento" className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">
                Porcentaje de aumento o rebaja
              </label>
              <div className="relative">
                <div className="absolute inset-y-0 left-3 flex items-center pointer-events-none">
                  {signoIcono}
                </div>
                <input
                  id="pct-aumento"
                  type="text"
                  inputMode="decimal"
                  value={porcentajeStr}
                  onChange={handlePorcentajeChange}
                  placeholder="Ej: 3 para +3%, -5 para -5%"
                  className="w-full pl-10 pr-10 py-2.5 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
                  aria-describedby="pct-help"
                />
                <span className="absolute inset-y-0 right-3 flex items-center text-gray-500 dark:text-gray-400">%</span>
              </div>
              <p id="pct-help" className="mt-1.5 text-xs text-gray-500 dark:text-gray-400">
                Los nuevos precios se redondean a múltiplos de 10.
              </p>
            </div>

            {/* Filtros */}
            <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
              <div className="relative">
                <Search className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400 w-4 h-4" aria-hidden="true" />
                <input
                  type="text"
                  value={busqueda}
                  onChange={e => setBusqueda(e.target.value)}
                  placeholder="Buscar nombre o código"
                  className="w-full pl-9 pr-3 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white text-sm focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
                  aria-label="Buscar productos"
                />
              </div>
              <select
                value={filtroProveedor}
                onChange={e => setFiltroProveedor(e.target.value)}
                className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white text-sm focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
                aria-label="Filtrar por proveedor"
              >
                <option value="todos">Todos los proveedores</option>
                {proveedores.map(p => (
                  <option key={p.id} value={p.id}>{p.nombre}</option>
                ))}
              </select>
              <select
                value={filtroCategoria}
                onChange={e => setFiltroCategoria(e.target.value)}
                className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white text-sm focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
                aria-label="Filtrar por categoría"
              >
                <option value="todas">Todas las categorías</option>
                {categorias.map(c => (
                  <option key={c} value={c}>{c}</option>
                ))}
              </select>
            </div>

            {/* Acciones de selección */}
            <div className="flex flex-wrap items-center gap-2 text-sm">
              <button
                type="button"
                onClick={toggleSeleccionarVisibles}
                disabled={productosFiltrados.length === 0}
                className="px-3 py-1.5 rounded-md bg-indigo-100 dark:bg-indigo-900/30 text-indigo-700 dark:text-indigo-300 hover:bg-indigo-200 dark:hover:bg-indigo-900/50 disabled:opacity-50 disabled:cursor-not-allowed font-medium"
              >
                {visiblesTodosSeleccionados ? 'Quitar selección visibles' : 'Seleccionar visibles'}
              </button>
              {seleccionados.size > 0 && (
                <button
                  type="button"
                  onClick={handleDeseleccionarTodos}
                  className="px-3 py-1.5 rounded-md bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600 font-medium"
                >
                  Limpiar selección
                </button>
              )}
              <span className="ml-auto text-gray-600 dark:text-gray-400">
                <span className="font-medium text-gray-800 dark:text-gray-200">{productosSeleccionados.length}</span> seleccionado(s)
                {seleccionadosFueraDelFiltro > 0 && (
                  <span className="text-gray-500 dark:text-gray-500">
                    {' '}({seleccionadosFueraDelFiltro} fuera del filtro actual)
                  </span>
                )}
              </span>
            </div>

            {/* Lista de productos */}
            <div className="border dark:border-gray-700 rounded-lg overflow-hidden shadow-sm">
              <div className="max-h-80 overflow-y-auto">
                <table className="w-full text-sm">
                  <thead className="bg-gray-50 dark:bg-gray-800 sticky top-0 z-10 shadow-sm">
                    <tr className="text-left text-xs font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-400">
                      <th className="px-4 py-3 w-12"></th>
                      <th className="px-4 py-3">Producto</th>
                      <th className="px-4 py-3 hidden sm:table-cell">Proveedor</th>
                      <th className="px-4 py-3 text-right">Neto</th>
                      <th className="px-4 py-3 text-right">Final</th>
                    </tr>
                  </thead>
                  <tbody>
                    {productosFiltrados.length === 0 && (
                      <tr>
                        <td colSpan={5} className="px-4 py-10 text-center text-gray-500 dark:text-gray-400">
                          No hay productos que coincidan con los filtros.
                        </td>
                      </tr>
                    )}
                    {productosFiltrados.map(p => {
                      const seleccionado = seleccionados.has(p.id)
                      return (
                        <tr
                          key={p.id}
                          className={`border-t dark:border-gray-700 cursor-pointer transition-colors ${
                            seleccionado
                              ? 'bg-indigo-50 dark:bg-indigo-900/20'
                              : 'hover:bg-gray-50 dark:hover:bg-gray-800/50'
                          }`}
                          onClick={() => toggleProducto(p.id)}
                        >
                          <td className="px-4 py-3">
                            <input
                              type="checkbox"
                              checked={seleccionado}
                              onChange={() => toggleProducto(p.id)}
                              onClick={e => e.stopPropagation()}
                              aria-label={`Seleccionar ${p.nombre}`}
                              className="w-4 h-4 accent-indigo-600 cursor-pointer"
                            />
                          </td>
                          <td className="px-4 py-3">
                            <div className="font-medium text-gray-800 dark:text-gray-100">{p.nombre}</div>
                            {p.codigo && (
                              <div className="text-xs text-gray-500 dark:text-gray-400 mt-0.5">{p.codigo}</div>
                            )}
                          </td>
                          <td className="px-4 py-3 text-gray-600 dark:text-gray-400 hidden sm:table-cell">
                            {p.proveedor_id ? proveedoresMap.get(p.proveedor_id) ?? '—' : '—'}
                          </td>
                          <td className="px-4 py-3 text-right text-gray-700 dark:text-gray-300 tabular-nums">
                            {p.precio_sin_iva ? formatPrecio(p.precio_sin_iva) : '—'}
                          </td>
                          <td className="px-4 py-3 text-right font-semibold text-gray-800 dark:text-gray-100 tabular-nums">
                            {formatPrecio(p.precio)}
                          </td>
                        </tr>
                      )
                    })}
                  </tbody>
                </table>
              </div>
            </div>

            {/* Preview */}
            {productosSeleccionados.length > 0 && porcentajeValido && (
              <div className="bg-gray-50 dark:bg-gray-800/50 border dark:border-gray-700 rounded-lg p-4">
                <p className="text-xs font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-400 mb-3">
                  Vista previa — precio final ({Math.min(PREVIEW_LIMIT, productosSeleccionados.length)} de {productosSeleccionados.length})
                </p>
                <ul className="space-y-1.5 text-sm">
                  {previewItems.map(({ producto, nuevos }) => (
                    <li key={producto.id} className="flex items-center justify-between text-gray-700 dark:text-gray-300 gap-3">
                      <span className="truncate">{producto.nombre}</span>
                      <span className="font-mono tabular-nums whitespace-nowrap text-gray-500 dark:text-gray-400">
                        {formatPrecio(producto.precio)}
                        <span className="mx-1.5 text-gray-400">→</span>
                        <span className={`font-semibold ${porcentaje >= 0 ? 'text-green-700 dark:text-green-400' : 'text-red-700 dark:text-red-400'}`}>
                          {nuevos.precio_final !== null ? formatPrecio(nuevos.precio_final) : '—'}
                        </span>
                      </span>
                    </li>
                  ))}
                </ul>
                {algunoQuedaEnCero && (
                  <div className="mt-3 flex items-start gap-2 text-xs text-yellow-700 dark:text-yellow-400">
                    <AlertTriangle className="w-4 h-4 flex-shrink-0 mt-0.5" aria-hidden="true" />
                    <span>Algún producto seleccionado queda en $0 tras el redondeo. Revisalo antes de aplicar.</span>
                  </div>
                )}
              </div>
            )}
          </div>

          {/* Footer sticky */}
          <div className="sticky bottom-0 flex justify-end gap-2 px-5 sm:px-6 py-4 bg-white dark:bg-gray-800 border-t dark:border-gray-700">
            <button
              type="button"
              onClick={onClose}
              className="px-4 py-2 rounded-lg text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 font-medium transition-colors"
            >
              Cancelar
            </button>
            <button
              type="button"
              onClick={handleAplicar}
              disabled={!puedeAplicar}
              className="px-5 py-2 rounded-lg bg-indigo-600 text-white hover:bg-indigo-700 disabled:opacity-50 disabled:cursor-not-allowed font-medium shadow-sm transition-colors"
            >
              {mutation.isPending ? 'Aplicando...' : 'Aplicar'}
            </button>
          </div>
        </div>
      </ModalBase>

      {confirmOpen && (
        <Suspense fallback={null}>
          <ModalConfirmacion
            config={{
              visible: true,
              tipo: 'warning',
              titulo: 'Confirmar actualización',
              mensaje: mensajeConfirmacion,
              onConfirm: handleConfirmar,
            }}
            onClose={() => setConfirmOpen(false)}
          />
        </Suspense>
      )}
    </>
  )
}
