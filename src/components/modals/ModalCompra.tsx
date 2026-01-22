/**
 * Modal para registrar compras a proveedores
 *
 * Refactorizado con useReducer para mejor gestión de estado
 */
import React, { useReducer, useMemo, useCallback } from 'react'
import type { ChangeEvent, FormEvent } from 'react'
import { X, ShoppingCart, Plus, Trash2, Package, Building2, FileText, Calculator, Search } from 'lucide-react'
import { formatPrecio } from '../../utils/formatters'
import type { ProductoDB, ProveedorDBExtended, CompraFormInputExtended } from '../../types'

// =============================================================================
// TIPOS
// =============================================================================

/** Item de compra en el formulario */
export interface CompraItemForm {
  productoId: string;
  productoNombre: string;
  productoCodigo?: string | null;
  cantidad: number;
  costoUnitario: number;
  impuestosInternos: number;
  porcentajeIva: number;
  stockActual: number;
}

/** Estado del reducer de compra */
export interface CompraState {
  proveedorId: string;
  proveedorNombre: string;
  usarProveedorNuevo: boolean;
  numeroFactura: string;
  fechaCompra: string;
  formaPago: string;
  notas: string;
  items: CompraItemForm[];
  busquedaProducto: string;
  mostrarBuscador: boolean;
  guardando: boolean;
  error: string;
}

/** Tipos de acciones del reducer */
type CompraActionType =
  | { type: 'SET_PROVEEDOR_ID'; payload: string }
  | { type: 'SET_PROVEEDOR_NOMBRE'; payload: string }
  | { type: 'SET_USAR_PROVEEDOR_NUEVO'; payload: boolean }
  | { type: 'SET_NUMERO_FACTURA'; payload: string }
  | { type: 'SET_FECHA_COMPRA'; payload: string }
  | { type: 'SET_FORMA_PAGO'; payload: string }
  | { type: 'SET_NOTAS'; payload: string }
  | { type: 'SET_BUSQUEDA'; payload: string }
  | { type: 'SET_MOSTRAR_BUSCADOR'; payload: boolean }
  | { type: 'SET_GUARDANDO'; payload: boolean }
  | { type: 'SET_ERROR'; payload: string }
  | { type: 'AGREGAR_ITEM'; payload: ProductoDB & { porcentaje_iva?: number } }
  | { type: 'ACTUALIZAR_ITEM'; payload: { index: number; campo: keyof CompraItemForm; valor: number | string } }
  | { type: 'ELIMINAR_ITEM'; payload: number }
  | { type: 'LIMPIAR_BUSQUEDA' };

/** Props del componente principal */
export interface ModalCompraProps {
  productos: ProductoDB[];
  proveedores: ProveedorDBExtended[];
  onSave: (compra: CompraFormInputExtended) => Promise<void>;
  onClose: () => void;
  onAgregarProveedor?: (proveedor: ProveedorDBExtended) => Promise<void>;
}

/** Props de ProveedorSection */
interface ProveedorSectionProps {
  state: CompraState;
  dispatch: React.Dispatch<CompraActionType>;
  proveedores: ProveedorDBExtended[];
}

/** Props de DatosCompraSection */
interface DatosCompraSectionProps {
  state: CompraState;
  dispatch: React.Dispatch<CompraActionType>;
}

/** Props de ProductosSection */
interface ProductosSectionProps {
  state: CompraState;
  dispatch: React.Dispatch<CompraActionType>;
  productosFiltrados: ProductoDB[];
  onAgregarItem: (producto: ProductoDB) => void;
  onActualizarItem: (index: number, campo: keyof CompraItemForm, valor: number | string) => void;
  onEliminarItem: (index: number) => void;
}

/** Props de ItemsList */
interface ItemsListProps {
  items: CompraItemForm[];
  onActualizarItem: (index: number, campo: keyof CompraItemForm, valor: number | string) => void;
  onEliminarItem: (index: number) => void;
}

/** Props de ItemRow */
interface ItemRowProps {
  item: CompraItemForm;
  index: number;
  onActualizarItem: (index: number, campo: keyof CompraItemForm, valor: number | string) => void;
  onEliminarItem: (index: number) => void;
}

/** Props de ResumenSection */
interface ResumenSectionProps {
  subtotal: number;
  iva: number;
  impuestosInternos: number;
  total: number;
}

/** Return type del hook de cálculos */
interface CalculosImpuestos {
  subtotal: number;
  iva: number;
  impuestosInternos: number;
  total: number;
}

// Constantes
const FORMAS_PAGO = [
  { value: 'efectivo', label: 'Efectivo' },
  { value: 'transferencia', label: 'Transferencia' },
  { value: 'cheque', label: 'Cheque' },
  { value: 'cuenta_corriente', label: 'Cuenta Corriente' },
  { value: 'tarjeta', label: 'Tarjeta' }
]

// Estado inicial
const initialState: CompraState = {
  // Proveedor
  proveedorId: '',
  proveedorNombre: '',
  usarProveedorNuevo: false,
  // Datos de compra
  numeroFactura: '',
  fechaCompra: new Date().toISOString().split('T')[0],
  formaPago: 'efectivo',
  notas: '',
  // Items
  items: [],
  // UI
  busquedaProducto: '',
  mostrarBuscador: false,
  guardando: false,
  error: ''
}

// Tipos de acciones
const ACTIONS = {
  SET_PROVEEDOR_ID: 'SET_PROVEEDOR_ID',
  SET_PROVEEDOR_NOMBRE: 'SET_PROVEEDOR_NOMBRE',
  SET_USAR_PROVEEDOR_NUEVO: 'SET_USAR_PROVEEDOR_NUEVO',
  SET_NUMERO_FACTURA: 'SET_NUMERO_FACTURA',
  SET_FECHA_COMPRA: 'SET_FECHA_COMPRA',
  SET_FORMA_PAGO: 'SET_FORMA_PAGO',
  SET_NOTAS: 'SET_NOTAS',
  SET_BUSQUEDA: 'SET_BUSQUEDA',
  SET_MOSTRAR_BUSCADOR: 'SET_MOSTRAR_BUSCADOR',
  SET_GUARDANDO: 'SET_GUARDANDO',
  SET_ERROR: 'SET_ERROR',
  AGREGAR_ITEM: 'AGREGAR_ITEM',
  ACTUALIZAR_ITEM: 'ACTUALIZAR_ITEM',
  ELIMINAR_ITEM: 'ELIMINAR_ITEM',
  LIMPIAR_BUSQUEDA: 'LIMPIAR_BUSQUEDA'
}

// Reducer
function compraReducer(state: CompraState, action: CompraActionType): CompraState {
  switch (action.type) {
    case 'SET_PROVEEDOR_ID':
      return { ...state, proveedorId: action.payload }
    case 'SET_PROVEEDOR_NOMBRE':
      return { ...state, proveedorNombre: action.payload }
    case 'SET_USAR_PROVEEDOR_NUEVO':
      return { ...state, usarProveedorNuevo: action.payload }
    case 'SET_NUMERO_FACTURA':
      return { ...state, numeroFactura: action.payload }
    case 'SET_FECHA_COMPRA':
      return { ...state, fechaCompra: action.payload }
    case 'SET_FORMA_PAGO':
      return { ...state, formaPago: action.payload }
    case 'SET_NOTAS':
      return { ...state, notas: action.payload }
    case 'SET_BUSQUEDA':
      return { ...state, busquedaProducto: action.payload, mostrarBuscador: true }
    case 'SET_MOSTRAR_BUSCADOR':
      return { ...state, mostrarBuscador: action.payload }
    case 'SET_GUARDANDO':
      return { ...state, guardando: action.payload }
    case 'SET_ERROR':
      return { ...state, error: action.payload }

    case 'AGREGAR_ITEM': {
      const producto = action.payload
      const existente = state.items.find(i => i.productoId === producto.id)

      if (existente) {
        return {
          ...state,
          items: state.items.map(i =>
            i.productoId === producto.id
              ? { ...i, cantidad: i.cantidad + 1 }
              : i
          ),
          busquedaProducto: '',
          mostrarBuscador: false
        }
      }

      return {
        ...state,
        items: [...state.items, {
          productoId: producto.id,
          productoNombre: producto.nombre,
          productoCodigo: producto.codigo,
          cantidad: 1,
          costoUnitario: producto.costo_sin_iva || 0,
          impuestosInternos: producto.impuestos_internos || 0,
          porcentajeIva: producto.porcentaje_iva ?? 21,
          stockActual: producto.stock
        }],
        busquedaProducto: '',
        mostrarBuscador: false
      }
    }

    case 'ACTUALIZAR_ITEM':
      return {
        ...state,
        items: state.items.map((item, i) =>
          i === action.payload.index
            ? { ...item, [action.payload.campo]: action.payload.valor }
            : item
        )
      }

    case 'ELIMINAR_ITEM':
      return {
        ...state,
        items: state.items.filter((_, i) => i !== action.payload)
      }

    case 'LIMPIAR_BUSQUEDA':
      return { ...state, busquedaProducto: '', mostrarBuscador: false }

    default:
      return state
  }
}

// Hook para cálculos de impuestos
function useCalculosImpuestos(items: CompraItemForm[]): CalculosImpuestos {
  const subtotal = useMemo(() =>
    items.reduce((sum, item) => sum + (item.cantidad * item.costoUnitario), 0),
    [items]
  )

  const iva = useMemo(() =>
    items.reduce((sum, item) => {
      const porcentajeIva = item.porcentajeIva ?? 21
      return sum + (item.cantidad * item.costoUnitario * porcentajeIva / 100)
    }, 0),
    [items]
  )

  const impuestosInternos = useMemo(() =>
    items.reduce((sum, item) => sum + (item.cantidad * (item.impuestosInternos || 0)), 0),
    [items]
  )

  const total = useMemo(() => subtotal + iva + impuestosInternos, [subtotal, iva, impuestosInternos])

  return { subtotal, iva, impuestosInternos, total }
}

export default function ModalCompra({ productos, proveedores, onSave, onClose, onAgregarProveedor: _onAgregarProveedor }: ModalCompraProps) {
  const [state, dispatch] = useReducer(compraReducer, initialState)
  const { subtotal, iva, impuestosInternos, total } = useCalculosImpuestos(state.items)

  // Productos filtrados
  const productosFiltrados = useMemo(() => {
    if (!state.busquedaProducto.trim()) return productos.slice(0, 10)
    const termino = state.busquedaProducto.toLowerCase()
    return productos.filter(p =>
      p.nombre?.toLowerCase().includes(termino) ||
      p.codigo?.toLowerCase().includes(termino)
    ).slice(0, 10)
  }, [productos, state.busquedaProducto])

  // Handlers con useCallback para evitar re-renders
  const handleAgregarItem = useCallback((producto: ProductoDB) => {
    dispatch({ type: 'AGREGAR_ITEM', payload: producto })
  }, [])

  const handleActualizarItem = useCallback((index: number, campo: keyof CompraItemForm, valor: number | string) => {
    dispatch({ type: 'ACTUALIZAR_ITEM', payload: { index, campo, valor } })
  }, [])

  const handleEliminarItem = useCallback((index: number) => {
    dispatch({ type: 'ELIMINAR_ITEM', payload: index })
  }, [])

  const handleSubmit = async (e: FormEvent<HTMLFormElement> | React.MouseEvent<HTMLButtonElement>) => {
    e.preventDefault()
    dispatch({ type: 'SET_ERROR', payload: '' })

    // Validaciones
    if (state.items.length === 0) {
      dispatch({ type: 'SET_ERROR', payload: 'Debe agregar al menos un producto' })
      return
    }

    if (state.usarProveedorNuevo) {
      if (!state.proveedorNombre.trim()) {
        dispatch({ type: 'SET_ERROR', payload: 'Debe ingresar el nombre del proveedor' })
        return
      }
    } else {
      if (!state.proveedorId) {
        dispatch({ type: 'SET_ERROR', payload: 'Debe seleccionar un proveedor' })
        return
      }
    }

    for (const item of state.items) {
      if (item.cantidad <= 0) {
        dispatch({ type: 'SET_ERROR', payload: `La cantidad de "${item.productoNombre}" debe ser mayor a 0` })
        return
      }
    }

    dispatch({ type: 'SET_GUARDANDO', payload: true })
    try {
      await onSave({
        proveedorId: state.usarProveedorNuevo ? null : (state.proveedorId || null),
        proveedorNombre: state.usarProveedorNuevo || !state.proveedorId ? state.proveedorNombre : null,
        numeroFactura: state.numeroFactura,
        fechaCompra: state.fechaCompra,
        subtotal,
        iva,
        otrosImpuestos: impuestosInternos,
        total,
        formaPago: state.formaPago,
        notas: state.notas,
        items: state.items.map(item => ({
          productoId: item.productoId,
          cantidad: item.cantidad,
          costoUnitario: item.costoUnitario || 0,
          subtotal: item.cantidad * item.costoUnitario
        }))
      })
      onClose()
    } catch (err) {
      const error = err as Error
      dispatch({ type: 'SET_ERROR', payload: error.message || 'Error al registrar la compra' })
    } finally {
      dispatch({ type: 'SET_GUARDANDO', payload: false })
    }
  }

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-4xl max-h-[90vh] overflow-hidden flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b dark:border-gray-700 shrink-0">
          <div className="flex items-center gap-2">
            <div className="p-2 bg-green-100 dark:bg-green-900/30 rounded-lg">
              <ShoppingCart className="w-5 h-5 text-green-600" />
            </div>
            <div>
              <h2 className="text-lg font-semibold text-gray-800 dark:text-white">Nueva Compra</h2>
              <p className="text-sm text-gray-500">Registrar compra a proveedor</p>
            </div>
          </div>
          <button onClick={onClose} className="p-2 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg">
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Contenido scrolleable */}
        <form onSubmit={handleSubmit} className="flex-1 overflow-y-auto p-4 space-y-4">
          {/* Sección Proveedor */}
          <ProveedorSection
            state={state}
            dispatch={dispatch}
            proveedores={proveedores}
          />

          {/* Datos de la compra */}
          <DatosCompraSection state={state} dispatch={dispatch} />

          {/* Productos */}
          <ProductosSection
            state={state}
            dispatch={dispatch}
            productosFiltrados={productosFiltrados}
            onAgregarItem={handleAgregarItem}
            onActualizarItem={handleActualizarItem}
            onEliminarItem={handleEliminarItem}
          />

          {/* Totales */}
          {state.items.length > 0 && (
            <ResumenSection
              subtotal={subtotal}
              iva={iva}
              impuestosInternos={impuestosInternos}
              total={total}
            />
          )}

          {/* Notas */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              <FileText className="w-4 h-4 inline mr-1" />
              Notas (opcional)
            </label>
            <textarea
              value={state.notas}
              onChange={(e: ChangeEvent<HTMLTextAreaElement>) => dispatch({ type: 'SET_NOTAS', payload: e.target.value })}
              placeholder="Observaciones adicionales..."
              rows={2}
              className="w-full px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
            />
          </div>

          {/* Error */}
          {state.error && (
            <div className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
              <p className="text-sm text-red-600 dark:text-red-400">{state.error}</p>
            </div>
          )}
        </form>

        {/* Footer con botones */}
        <div className="flex gap-3 p-4 border-t dark:border-gray-700 shrink-0">
          <button
            type="button"
            onClick={onClose}
            className="flex-1 px-4 py-2 border dark:border-gray-600 rounded-lg hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors"
          >
            Cancelar
          </button>
          <button
            onClick={handleSubmit}
            disabled={state.guardando || state.items.length === 0}
            className="flex-1 px-4 py-2 bg-green-600 hover:bg-green-700 disabled:bg-green-400 text-white rounded-lg transition-colors flex items-center justify-center gap-2"
          >
            {state.guardando ? (
              <>
                <span className="animate-spin">...</span>
                Registrando...
              </>
            ) : (
              <>
                <ShoppingCart className="w-4 h-4" />
                Registrar Compra
              </>
            )}
          </button>
        </div>
      </div>
    </div>
  )
}

// Subcomponentes para mejor organización

function ProveedorSection({ state, dispatch, proveedores }: ProveedorSectionProps) {
  return (
    <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-4 space-y-3">
      <div className="flex items-center gap-2 mb-2">
        <Building2 className="w-5 h-5 text-gray-500" />
        <h3 className="font-medium text-gray-800 dark:text-white">Proveedor</h3>
      </div>

      <div className="flex items-center gap-4 mb-2">
        <label className="flex items-center gap-2 cursor-pointer">
          <input
            type="radio"
            checked={!state.usarProveedorNuevo}
            onChange={() => dispatch({ type: 'SET_USAR_PROVEEDOR_NUEVO', payload: false })}
            className="text-green-600"
          />
          <span className="text-sm">Seleccionar existente</span>
        </label>
        <label className="flex items-center gap-2 cursor-pointer">
          <input
            type="radio"
            checked={state.usarProveedorNuevo}
            onChange={() => dispatch({ type: 'SET_USAR_PROVEEDOR_NUEVO', payload: true })}
            className="text-green-600"
          />
          <span className="text-sm">Ingresar nombre</span>
        </label>
      </div>

      {!state.usarProveedorNuevo ? (
        <select
          value={state.proveedorId}
          onChange={(e: ChangeEvent<HTMLSelectElement>) => dispatch({ type: 'SET_PROVEEDOR_ID', payload: e.target.value })}
          className="w-full px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
        >
          <option value="">Seleccionar proveedor...</option>
          {proveedores.map(p => (
            <option key={p.id} value={p.id}>{p.nombre} {p.cuit ? `(${p.cuit})` : ''}</option>
          ))}
        </select>
      ) : (
        <input
          type="text"
          value={state.proveedorNombre}
          onChange={(e: ChangeEvent<HTMLInputElement>) => dispatch({ type: 'SET_PROVEEDOR_NOMBRE', payload: e.target.value })}
          placeholder="Nombre del proveedor"
          className="w-full px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
        />
      )}
    </div>
  )
}

function DatosCompraSection({ state, dispatch }: DatosCompraSectionProps) {
  return (
    <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
      <div>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
          N Factura / Remito
        </label>
        <input
          type="text"
          value={state.numeroFactura}
          onChange={(e: ChangeEvent<HTMLInputElement>) => dispatch({ type: 'SET_NUMERO_FACTURA', payload: e.target.value })}
          placeholder="Ej: 0001-00012345"
          className="w-full px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
        />
      </div>
      <div>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
          Fecha de Compra *
        </label>
        <input
          type="date"
          value={state.fechaCompra}
          onChange={(e: ChangeEvent<HTMLInputElement>) => dispatch({ type: 'SET_FECHA_COMPRA', payload: e.target.value })}
          className="w-full px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
          required
        />
      </div>
      <div>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
          Forma de Pago
        </label>
        <select
          value={state.formaPago}
          onChange={(e: ChangeEvent<HTMLSelectElement>) => dispatch({ type: 'SET_FORMA_PAGO', payload: e.target.value })}
          className="w-full px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
        >
          {FORMAS_PAGO.map(fp => (
            <option key={fp.value} value={fp.value}>{fp.label}</option>
          ))}
        </select>
      </div>
    </div>
  )
}

function ProductosSection({ state, dispatch, productosFiltrados, onAgregarItem, onActualizarItem, onEliminarItem }: ProductosSectionProps) {
  return (
    <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-4 space-y-3">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Package className="w-5 h-5 text-gray-500" />
          <h3 className="font-medium text-gray-800 dark:text-white">Productos</h3>
        </div>
      </div>

      {/* Buscador de productos */}
      <div className="relative">
        <div className="flex items-center gap-2">
          <div className="relative flex-1">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" />
            <input
              type="text"
              value={state.busquedaProducto}
              onChange={(e: ChangeEvent<HTMLInputElement>) => dispatch({ type: 'SET_BUSQUEDA', payload: e.target.value })}
              onFocus={() => dispatch({ type: 'SET_MOSTRAR_BUSCADOR', payload: true })}
              placeholder="Buscar producto por nombre o codigo..."
              className="w-full pl-10 pr-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
            />
          </div>
        </div>

        {/* Dropdown de resultados */}
        {state.mostrarBuscador && (
          <div className="absolute z-10 w-full mt-1 bg-white dark:bg-gray-800 border dark:border-gray-600 rounded-lg shadow-lg max-h-48 overflow-y-auto">
            {productosFiltrados.length > 0 ? (
              productosFiltrados.map(p => (
                <button
                  key={p.id}
                  type="button"
                  onClick={() => onAgregarItem(p)}
                  className="w-full px-4 py-2 text-left hover:bg-gray-100 dark:hover:bg-gray-700 flex items-center justify-between"
                >
                  <div>
                    <p className="font-medium text-gray-800 dark:text-white">{p.nombre}</p>
                    <p className="text-xs text-gray-500">
                      {p.codigo && `Codigo: ${p.codigo} - `}
                      Stock: {p.stock}
                    </p>
                  </div>
                  <Plus className="w-4 h-4 text-green-600" />
                </button>
              ))
            ) : (
              <p className="px-4 py-2 text-sm text-gray-500">No se encontraron productos</p>
            )}
            <button
              type="button"
              onClick={() => dispatch({ type: 'SET_MOSTRAR_BUSCADOR', payload: false })}
              className="w-full px-4 py-2 text-sm text-gray-500 hover:bg-gray-100 dark:hover:bg-gray-700 border-t dark:border-gray-600"
            >
              Cerrar
            </button>
          </div>
        )}
      </div>

      {/* Lista de items */}
      {state.items.length > 0 ? (
        <ItemsList items={state.items} onActualizarItem={onActualizarItem} onEliminarItem={onEliminarItem} />
      ) : (
        <div className="text-center py-8 text-gray-500">
          <Package className="w-12 h-12 mx-auto mb-2 opacity-50" />
          <p>No hay productos agregados</p>
          <p className="text-sm">Use el buscador para agregar productos</p>
        </div>
      )}
    </div>
  )
}

function ItemsList({ items, onActualizarItem, onEliminarItem }: ItemsListProps) {
  return (
    <div className="space-y-2">
      {/* Header solo en desktop */}
      <div className="hidden md:grid grid-cols-12 gap-2 text-xs font-medium text-gray-500 uppercase px-2">
        <div className="col-span-4">Producto</div>
        <div className="col-span-2 text-center">Cant.</div>
        <div className="col-span-2 text-center">Neto</div>
        <div className="col-span-2 text-center">Imp.Int.</div>
        <div className="col-span-1 text-right">Subtot.</div>
        <div className="col-span-1"></div>
      </div>
      {items.map((item, index) => (
        <ItemRow
          key={index}
          item={item}
          index={index}
          onActualizarItem={onActualizarItem}
          onEliminarItem={onEliminarItem}
        />
      ))}
    </div>
  )
}

function ItemRow({ item, index, onActualizarItem, onEliminarItem }: ItemRowProps) {
  return (
    <div className="bg-white dark:bg-gray-800 p-3 rounded-lg border dark:border-gray-600">
      {/* Mobile: Layout en cards */}
      <div className="md:hidden space-y-3">
        <div className="flex justify-between items-start">
          <div className="flex-1">
            <p className="font-medium text-gray-800 dark:text-white">{item.productoNombre}</p>
            <p className="text-xs text-gray-500">Stock: {item.stockActual} | IVA: {item.porcentajeIva}%</p>
          </div>
          <button
            type="button"
            onClick={() => onEliminarItem(index)}
            className="p-1 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded"
          >
            <Trash2 className="w-4 h-4" />
          </button>
        </div>
        <div className="grid grid-cols-3 gap-2">
          <div>
            <label className="block text-xs text-gray-500 mb-1">Cant.</label>
            <input
              type="number"
              min="1"
              value={item.cantidad}
              onChange={(e: ChangeEvent<HTMLInputElement>) => onActualizarItem(index, 'cantidad', parseInt(e.target.value) || 0)}
              className="w-full px-2 py-1 text-center border dark:border-gray-600 rounded focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white text-sm"
            />
          </div>
          <div>
            <label className="block text-xs text-gray-500 mb-1">Neto</label>
            <input
              type="number"
              min="0"
              step="0.01"
              value={item.costoUnitario}
              onChange={(e: ChangeEvent<HTMLInputElement>) => onActualizarItem(index, 'costoUnitario', parseFloat(e.target.value) || 0)}
              className="w-full px-2 py-1 text-center border dark:border-gray-600 rounded focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white text-sm"
            />
          </div>
          <div>
            <label className="block text-xs text-gray-500 mb-1">Imp.Int.</label>
            <input
              type="number"
              min="0"
              step="0.01"
              value={item.impuestosInternos || 0}
              onChange={(e: ChangeEvent<HTMLInputElement>) => onActualizarItem(index, 'impuestosInternos', parseFloat(e.target.value) || 0)}
              className="w-full px-2 py-1 text-center border dark:border-gray-600 rounded focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white text-sm"
            />
          </div>
        </div>
        <div className="flex justify-between items-center pt-2 border-t dark:border-gray-600">
          <span className="text-sm text-gray-500">Subtotal:</span>
          <span className="font-semibold text-gray-800 dark:text-white">{formatPrecio(item.cantidad * item.costoUnitario)}</span>
        </div>
      </div>

      {/* Desktop: Layout en grid */}
      <div className="hidden md:grid grid-cols-12 gap-2 items-center">
        <div className="col-span-4">
          <p className="font-medium text-gray-800 dark:text-white text-sm">{item.productoNombre}</p>
          <p className="text-xs text-gray-500">Stock: {item.stockActual} | IVA: {item.porcentajeIva}%</p>
        </div>
        <div className="col-span-2">
          <input
            type="number"
            min="1"
            value={item.cantidad}
            onChange={(e: ChangeEvent<HTMLInputElement>) => onActualizarItem(index, 'cantidad', parseInt(e.target.value) || 0)}
            className="w-full px-2 py-1 text-center border dark:border-gray-600 rounded focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white text-sm"
          />
        </div>
        <div className="col-span-2">
          <input
            type="number"
            min="0"
            step="0.01"
            value={item.costoUnitario}
            onChange={(e: ChangeEvent<HTMLInputElement>) => onActualizarItem(index, 'costoUnitario', parseFloat(e.target.value) || 0)}
            className="w-full px-2 py-1 text-center border dark:border-gray-600 rounded focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white text-sm"
          />
        </div>
        <div className="col-span-2">
          <input
            type="number"
            min="0"
            step="0.01"
            value={item.impuestosInternos || 0}
            onChange={(e: ChangeEvent<HTMLInputElement>) => onActualizarItem(index, 'impuestosInternos', parseFloat(e.target.value) || 0)}
            className="w-full px-2 py-1 text-center border dark:border-gray-600 rounded focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white text-sm"
          />
        </div>
        <div className="col-span-1 text-right font-medium text-gray-800 dark:text-white text-sm">
          {formatPrecio(item.cantidad * item.costoUnitario)}
        </div>
        <div className="col-span-1 text-right">
          <button
            type="button"
            onClick={() => onEliminarItem(index)}
            className="p-1 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded"
          >
            <Trash2 className="w-4 h-4" />
          </button>
        </div>
      </div>
    </div>
  )
}

function ResumenSection({ subtotal, iva, impuestosInternos, total }: ResumenSectionProps) {
  return (
    <div className="bg-green-50 dark:bg-green-900/20 rounded-lg p-4">
      <div className="flex items-center gap-2 mb-3">
        <Calculator className="w-5 h-5 text-green-600" />
        <h3 className="font-medium text-gray-800 dark:text-white">Resumen</h3>
      </div>

      <div className="space-y-2">
        <div className="flex justify-between text-sm">
          <span className="text-gray-600 dark:text-gray-400">Subtotal Neto:</span>
          <span className="font-medium text-gray-800 dark:text-white">{formatPrecio(subtotal)}</span>
        </div>
        <div className="flex justify-between text-sm">
          <span className="text-gray-600 dark:text-gray-400">IVA (sobre neto):</span>
          <span className="font-medium text-gray-800 dark:text-white">{formatPrecio(iva)}</span>
        </div>
        {impuestosInternos > 0 && (
          <div className="flex justify-between text-sm">
            <span className="text-gray-600 dark:text-gray-400">Impuestos Internos:</span>
            <span className="font-medium text-gray-800 dark:text-white">{formatPrecio(impuestosInternos)}</span>
          </div>
        )}
        <div className="flex justify-between text-lg font-bold pt-2 border-t dark:border-gray-600">
          <span className="text-gray-800 dark:text-white">Total:</span>
          <span className="text-green-600">{formatPrecio(total)}</span>
        </div>
        <p className="text-xs text-gray-500 pt-1">
          Costo real (neto + imp.int. sin IVA): {formatPrecio(subtotal + impuestosInternos)}
        </p>
      </div>
    </div>
  )
}
