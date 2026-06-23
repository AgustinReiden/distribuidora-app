import React, { useState, useMemo, FormEvent, ChangeEvent } from 'react'
import { X, ArrowLeftRight, ArrowDown, ArrowUp, FileText, Search, Package, AlertTriangle, User as UserIcon } from 'lucide-react'
import { useZodValidation } from '../../hooks/useZodValidation'
import { modalCambioProductoSchema } from '../../lib/schemas'
import { formatPrecio } from '../../utils/formatters'
import NumberInput from '../ui/NumberInput'
import type { ClienteDB, ProductoDB } from '../../types'

export interface CambioProductoSaveData {
  clienteId: string
  productoDevueltoId: string
  cantidadDevuelta: number
  productoEntregadoId: string
  cantidadEntregada: number
  observaciones: string
}

export interface ModalCambioProductoProps {
  clientes: ClienteDB[]
  productos: ProductoDB[]
  onSave: (data: CambioProductoSaveData) => Promise<void>
  onClose: () => void
  /**
   * 'standalone' (default): cambio de dep\u00F3sito, ajusta stock/saldo al registrar.
   * 'enRuta': crea una parada de cambio en el recorrido; el ajuste ocurre cuando
   * el chofer la completa. Solo cambia textos/t\u00EDtulo.
   */
  modo?: 'standalone' | 'enRuta'
  /** Si viene, el cliente queda fijo (no se puede buscar/cambiar). */
  clienteFijo?: ClienteDB | null
}

function normalizar(s: string | null | undefined): string {
  return (s || '').replace(/[\s\u00A0]+/g, ' ').trim().toLowerCase()
}

export default function ModalCambioProducto({
  clientes,
  productos,
  onSave,
  onClose,
  modo = 'standalone',
  clienteFijo = null,
}: ModalCambioProductoProps): React.ReactElement {
  const { validate, getFirstError } = useZodValidation(modalCambioProductoSchema)

  const enRuta = modo === 'enRuta'

  const [clienteId, setClienteId] = useState<string>(clienteFijo?.id ?? '')
  const [busquedaCliente, setBusquedaCliente] = useState<string>(
    clienteFijo ? (clienteFijo.nombre_fantasia || clienteFijo.razon_social || '') : '',
  )

  const [productoDevueltoId, setProductoDevueltoId] = useState<string>('')
  const [busquedaDevuelto, setBusquedaDevuelto] = useState<string>('')
  const [cantidadDevuelta, setCantidadDevuelta] = useState<number | string>(1)

  const [productoEntregadoId, setProductoEntregadoId] = useState<string>('')
  const [busquedaEntregado, setBusquedaEntregado] = useState<string>('')
  const [cantidadEntregada, setCantidadEntregada] = useState<number | string>(1)

  const [observaciones, setObservaciones] = useState<string>('')
  const [guardando, setGuardando] = useState<boolean>(false)
  const [error, setError] = useState<string>('')

  const clienteSeleccionado = useMemo(
    () => clientes.find(c => c.id === clienteId) || null,
    [clientes, clienteId],
  )

  const productoDevuelto = useMemo(
    () => productos.find(p => p.id === productoDevueltoId) || null,
    [productos, productoDevueltoId],
  )

  const productoEntregado = useMemo(
    () => productos.find(p => p.id === productoEntregadoId) || null,
    [productos, productoEntregadoId],
  )

  const clientesFiltrados = useMemo<ClienteDB[]>(() => {
    if (busquedaCliente.length < 2) return []
    const q = normalizar(busquedaCliente)
    const cuit = busquedaCliente.replace(/[-\s]/g, '')
    return clientes.filter(c =>
      normalizar(c.nombre_fantasia).includes(q) ||
      normalizar(c.razon_social).includes(q) ||
      normalizar(c.direccion).includes(q) ||
      (c.cuit || '').includes(cuit) ||
      String(c.codigo || '').includes(busquedaCliente.trim())
    ).slice(0, 8)
  }, [clientes, busquedaCliente])

  const filtrarProductos = (busqueda: string, excluirId: string): ProductoDB[] => {
    const termino = normalizar(busqueda)
    if (!termino) return []
    return productos
      .filter(p => p.id !== excluirId)
      .filter(p =>
        normalizar(p.nombre).includes(termino) ||
        normalizar(p.codigo).includes(termino),
      )
      .slice(0, 8)
  }

  const productosDevueltoFiltrados = useMemo(
    () => filtrarProductos(busquedaDevuelto, productoEntregadoId),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [productos, busquedaDevuelto, productoEntregadoId],
  )

  const productosEntregadoFiltrados = useMemo(
    () => filtrarProductos(busquedaEntregado, productoDevueltoId),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [productos, busquedaEntregado, productoDevueltoId],
  )

  const cantDevNum = typeof cantidadDevuelta === 'string' ? parseInt(cantidadDevuelta) || 0 : cantidadDevuelta
  const cantEntNum = typeof cantidadEntregada === 'string' ? parseInt(cantidadEntregada) || 0 : cantidadEntregada

  const stockEntregadoInsuficiente =
    productoEntregado != null && cantEntNum > productoEntregado.stock

  const diferencia = useMemo(() => {
    const d = (productoEntregado?.precio || 0) * cantEntNum
            - (productoDevuelto?.precio || 0) * cantDevNum
    return Number.isFinite(d) ? d : 0
  }, [productoEntregado, productoDevuelto, cantEntNum, cantDevNum])

  const handleSeleccionarCliente = (c: ClienteDB) => {
    setClienteId(c.id)
    setBusquedaCliente(c.nombre_fantasia || c.razon_social || '')
  }

  const handleSeleccionarDevuelto = (p: ProductoDB) => {
    setProductoDevueltoId(p.id)
    setBusquedaDevuelto(p.nombre)
  }

  const handleSeleccionarEntregado = (p: ProductoDB) => {
    setProductoEntregadoId(p.id)
    setBusquedaEntregado(p.nombre)
  }

  const handleSubmit = async (e: FormEvent<HTMLFormElement>): Promise<void> => {
    e.preventDefault()
    setError('')

    const result = validate({
      clienteId,
      productoDevueltoId,
      cantidadDevuelta: cantDevNum,
      productoEntregadoId,
      cantidadEntregada: cantEntNum,
      observaciones,
    })
    if (!result.success) {
      setError(getFirstError() || 'Error de validación')
      return
    }

    if (stockEntregadoInsuficiente) {
      setError(`Stock insuficiente del producto a entregar (${productoEntregado?.stock} disponibles)`)
      return
    }

    setGuardando(true)
    try {
      await onSave({
        clienteId: result.data.clienteId,
        productoDevueltoId: result.data.productoDevueltoId,
        cantidadDevuelta: result.data.cantidadDevuelta,
        productoEntregadoId: result.data.productoEntregadoId,
        cantidadEntregada: result.data.cantidadEntregada,
        observaciones: result.data.observaciones || '',
      })
      onClose()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Error al registrar el cambio')
    } finally {
      setGuardando(false)
    }
  }

  const submitDeshabilitado = guardando
    || !clienteId
    || !productoDevueltoId
    || !productoEntregadoId
    || cantDevNum <= 0
    || cantEntNum <= 0
    || stockEntregadoInsuficiente

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-lg max-h-[90vh] overflow-y-auto">
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b dark:border-gray-700 sticky top-0 bg-white dark:bg-gray-800 z-10">
          <div className="flex items-center gap-2">
            <div className="p-2 bg-indigo-100 dark:bg-indigo-900/30 rounded-lg">
              <ArrowLeftRight className="w-5 h-5 text-indigo-600 dark:text-indigo-400" />
            </div>
            <div>
              <h2 className="text-lg font-semibold text-gray-800 dark:text-white">
                {enRuta ? 'Cambio/devolución en la ruta' : 'Cambio de productos'}
              </h2>
              <p className="text-sm text-gray-500">
                {enRuta
                  ? 'Se agrega como parada; el stock y el saldo se ajustan al completarla'
                  : 'El cliente devuelve uno y se le entrega otro'}
              </p>
            </div>
          </div>
          <button onClick={onClose} className="p-2 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg" aria-label="Cerrar">
            <X className="w-5 h-5" />
          </button>
        </div>

        <form onSubmit={handleSubmit} className="p-4 space-y-4">
          {/* Cliente */}
          <div className="relative">
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              <UserIcon className="w-4 h-4 inline mr-1" />
              Cliente *
            </label>
            <div className="relative">
              <Search className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400 w-4 h-4" aria-hidden="true" />
              <input
                type="text"
                value={busquedaCliente}
                onChange={(e: ChangeEvent<HTMLInputElement>) => {
                  setBusquedaCliente(e.target.value)
                  setClienteId('')
                }}
                disabled={!!clienteFijo}
                placeholder="Buscar por nombre, razón social o CUIT..."
                className="w-full pl-10 pr-3 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-indigo-500 dark:bg-gray-700 dark:text-white disabled:bg-gray-100 dark:disabled:bg-gray-900 disabled:text-gray-500"
              />
            </div>
            {!clienteFijo && !clienteId && clientesFiltrados.length > 0 && (
              <ul className="absolute z-20 mt-1 w-full bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-lg max-h-56 overflow-auto">
                {clientesFiltrados.map(c => (
                  <li key={c.id}>
                    <button
                      type="button"
                      onClick={() => handleSeleccionarCliente(c)}
                      className="w-full px-3 py-2 text-left hover:bg-gray-100 dark:hover:bg-gray-700 text-sm"
                    >
                      <p className="font-medium text-gray-800 dark:text-white">{c.nombre_fantasia || c.razon_social}</p>
                      <p className="text-xs text-gray-500">{c.direccion}{c.cuit ? ` · CUIT ${c.cuit}` : ''}</p>
                    </button>
                  </li>
                ))}
              </ul>
            )}
            {clienteSeleccionado && (
              <p className="mt-1 text-xs text-gray-500">
                Saldo actual: <span className="font-semibold">{formatPrecio(clienteSeleccionado.saldo_cuenta || 0)}</span>
              </p>
            )}
          </div>

          {/* Producto a devolver */}
          <div className="relative border border-green-200 dark:border-green-800 rounded-lg p-3 bg-green-50/50 dark:bg-green-900/10">
            <label className="block text-sm font-medium text-green-700 dark:text-green-400 mb-1">
              <ArrowDown className="w-4 h-4 inline mr-1" />
              Producto que devuelve el cliente (entra al depósito) *
            </label>
            <div className="relative">
              <Search className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400 w-4 h-4" aria-hidden="true" />
              <input
                type="text"
                value={busquedaDevuelto}
                onChange={(e: ChangeEvent<HTMLInputElement>) => {
                  setBusquedaDevuelto(e.target.value)
                  setProductoDevueltoId('')
                }}
                placeholder="Buscar por nombre o código..."
                className="w-full pl-10 pr-3 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
              />
            </div>
            {!productoDevueltoId && productosDevueltoFiltrados.length > 0 && (
              <ul className="absolute z-20 mt-1 left-3 right-3 bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-lg max-h-56 overflow-auto">
                {productosDevueltoFiltrados.map(p => (
                  <li key={p.id}>
                    <button
                      type="button"
                      onClick={() => handleSeleccionarDevuelto(p)}
                      className="w-full px-3 py-2 text-left hover:bg-gray-100 dark:hover:bg-gray-700 text-sm"
                    >
                      <p className="font-medium text-gray-800 dark:text-white">{p.nombre}</p>
                      <p className="text-xs text-gray-500">
                        {p.codigo ? `Código: ${p.codigo} · ` : ''}Stock: {p.stock} · {formatPrecio(p.precio)}
                      </p>
                    </button>
                  </li>
                ))}
              </ul>
            )}
            {productoDevuelto && (
              <div className="mt-2 flex items-center gap-3 p-2 bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg">
                <Package className="w-5 h-5 text-gray-400" />
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-medium text-gray-800 dark:text-white truncate">{productoDevuelto.nombre}</p>
                  <p className="text-xs text-gray-500">
                    Precio: {formatPrecio(productoDevuelto.precio)} · Stock actual: {productoDevuelto.stock}
                  </p>
                </div>
                <NumberInput
                  integer
                  min={1}
                  emptyValue={1}
                  commitOnChange
                  value={Number(cantidadDevuelta) || 0}
                  onChange={(n) => setCantidadDevuelta(n)}
                  className="w-20 px-2 py-1 border dark:border-gray-600 rounded text-right dark:bg-gray-700 dark:text-white"
                  aria-label="Cantidad devuelta"
                />
              </div>
            )}
          </div>

          {/* Producto a entregar */}
          <div className="relative border border-red-200 dark:border-red-800 rounded-lg p-3 bg-red-50/50 dark:bg-red-900/10">
            <label className="block text-sm font-medium text-red-700 dark:text-red-400 mb-1">
              <ArrowUp className="w-4 h-4 inline mr-1" />
              Producto que se entrega al cliente (sale del depósito) *
            </label>
            <div className="relative">
              <Search className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400 w-4 h-4" aria-hidden="true" />
              <input
                type="text"
                value={busquedaEntregado}
                onChange={(e: ChangeEvent<HTMLInputElement>) => {
                  setBusquedaEntregado(e.target.value)
                  setProductoEntregadoId('')
                }}
                placeholder="Buscar por nombre o código..."
                className="w-full pl-10 pr-3 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-red-500 dark:bg-gray-700 dark:text-white"
              />
            </div>
            {!productoEntregadoId && productosEntregadoFiltrados.length > 0 && (
              <ul className="absolute z-20 mt-1 left-3 right-3 bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-lg max-h-56 overflow-auto">
                {productosEntregadoFiltrados.map(p => (
                  <li key={p.id}>
                    <button
                      type="button"
                      onClick={() => handleSeleccionarEntregado(p)}
                      className="w-full px-3 py-2 text-left hover:bg-gray-100 dark:hover:bg-gray-700 text-sm"
                    >
                      <p className="font-medium text-gray-800 dark:text-white">{p.nombre}</p>
                      <p className="text-xs text-gray-500">
                        {p.codigo ? `Código: ${p.codigo} · ` : ''}Stock: {p.stock} · {formatPrecio(p.precio)}
                      </p>
                    </button>
                  </li>
                ))}
              </ul>
            )}
            {productoEntregado && (
              <div className="mt-2 flex items-center gap-3 p-2 bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg">
                <Package className="w-5 h-5 text-gray-400" />
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-medium text-gray-800 dark:text-white truncate">{productoEntregado.nombre}</p>
                  <p className="text-xs text-gray-500">
                    Precio: {formatPrecio(productoEntregado.precio)} · Stock actual: {productoEntregado.stock}
                  </p>
                </div>
                <NumberInput
                  integer
                  min={1}
                  max={productoEntregado.stock}
                  emptyValue={1}
                  commitOnChange
                  value={Number(cantidadEntregada) || 0}
                  onChange={(n) => setCantidadEntregada(n)}
                  className="w-20 px-2 py-1 border dark:border-gray-600 rounded text-right dark:bg-gray-700 dark:text-white"
                  aria-label="Cantidad entregada"
                />
              </div>
            )}
            {stockEntregadoInsuficiente && (
              <p className="mt-2 text-xs text-red-600 dark:text-red-400 flex items-center gap-1">
                <AlertTriangle className="w-3 h-3" />
                Stock insuficiente. Disponible: {productoEntregado?.stock}
              </p>
            )}
          </div>

          {/* Diferencia de precio */}
          {productoDevuelto && productoEntregado && cantDevNum > 0 && cantEntNum > 0 && (
            <div className={`p-3 rounded-lg border ${
              diferencia > 0
                ? 'bg-orange-50 dark:bg-orange-900/20 border-orange-200 dark:border-orange-800'
                : diferencia < 0
                ? 'bg-emerald-50 dark:bg-emerald-900/20 border-emerald-200 dark:border-emerald-800'
                : 'bg-gray-50 dark:bg-gray-900 border-gray-200 dark:border-gray-700'
            }`}>
              <div className="flex items-center justify-between">
                <span className="text-sm text-gray-700 dark:text-gray-300">Diferencia de precio</span>
                <span className={`text-base font-semibold ${
                  diferencia > 0
                    ? 'text-orange-700 dark:text-orange-400'
                    : diferencia < 0
                    ? 'text-emerald-700 dark:text-emerald-400'
                    : 'text-gray-700 dark:text-gray-300'
                }`}>
                  {formatPrecio(diferencia)}
                </span>
              </div>
              <p className="mt-1 text-xs text-gray-600 dark:text-gray-400">
                {diferencia > 0
                  ? `Se sumarán ${formatPrecio(diferencia)} a la cuenta del cliente.`
                  : diferencia < 0
                  ? `El cliente queda con saldo a favor por ${formatPrecio(Math.abs(diferencia))}.`
                  : 'El cambio no afecta la cuenta corriente.'}
              </p>
            </div>
          )}

          {/* Observaciones */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              <FileText className="w-4 h-4 inline mr-1" />
              Observaciones (motivo del cambio)
            </label>
            <textarea
              value={observaciones}
              onChange={(e: ChangeEvent<HTMLTextAreaElement>) => setObservaciones(e.target.value)}
              placeholder="Detalle del motivo, condición del producto devuelto, etc."
              rows={3}
              className="w-full px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-indigo-500 dark:bg-gray-700 dark:text-white"
            />
          </div>

          {/* Error */}
          {error && (
            <div className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
              <p className="text-sm text-red-600 dark:text-red-400">{error}</p>
            </div>
          )}

          {/* Botones */}
          <div className="flex gap-3 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="flex-1 px-4 py-2 border dark:border-gray-600 rounded-lg hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors"
            >
              Cancelar
            </button>
            <button
              type="submit"
              disabled={submitDeshabilitado}
              className="flex-1 px-4 py-2 bg-indigo-600 hover:bg-indigo-700 disabled:bg-indigo-300 dark:disabled:bg-indigo-800 text-white rounded-lg transition-colors flex items-center justify-center gap-2"
            >
              {guardando ? (
                <span className="animate-pulse">{enRuta ? 'Agregando...' : 'Registrando...'}</span>
              ) : (
                <>
                  <ArrowLeftRight className="w-4 h-4" />
                  {enRuta ? 'Agregar a la ruta' : 'Registrar cambio'}
                </>
              )}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}
