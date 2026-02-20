/**
 * Modal para registrar compras a proveedores
 *
 * Refactorizado con useReducer para mejor gestión de estado
 * Validación con Zod
 */
import React, { useReducer, useMemo, useCallback, useState, useEffect, useRef, lazy, Suspense } from 'react'
import type { ChangeEvent, FormEvent } from 'react'
import { X, ShoppingCart, Plus, Trash2, Package, Building2, FileText, Calculator, Search, Loader2, Camera, CheckCircle, AlertTriangle } from 'lucide-react'
import { formatPrecio } from '../../utils/formatters'
import { supabase } from '../../lib/supabase'
import type { ProductoDB, ProveedorDBExtended, CompraFormInputExtended, ProveedorFormInputExtended } from '../../types'

const ModalProveedor = lazy(() => import('./ModalProveedor'))
const ModalImportarCompra = lazy(() => import('./ModalImportarCompra'))

// =============================================================================
// TIPOS
// =============================================================================

/** Item de compra en el formulario */
export interface CompraItemForm {
  productoId: string;
  productoNombre: string;
  productoCodigo?: string | null;
  cantidad: number;
  bonificacion: number;
  costoUnitario: number;
  impuestosInternos: number;
  porcentajeIva: number;
  stockActual: number;
}

/** Resultado del escaneo de factura via n8n */
export interface FacturaEscaneada {
  proveedorNombre: string | null;
  proveedorCuit: string | null;
  numeroFactura: string | null;
  fechaCompra: string | null;
  items: Array<{
    codigo: string | null;
    descripcion: string;
    cantidad: number;
    costoUnitario: number;
    bonificacion: number;
    iva: number;
  }>;
  subtotal: number | null;
  iva: number | null;
  total: number | null;
  formaPago: string | null;
  confianza: number;
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
  modoItemRapido: boolean;
  guardando: boolean;
  error: string;
  // Escaneo de factura
  escaneando: boolean;
  resultadoEscaneo: FacturaEscaneada | null;
  errorEscaneo: string;
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
  | { type: 'LIMPIAR_BUSQUEDA' }
  | { type: 'SET_MODO_ITEM_RAPIDO'; payload: boolean }
  | { type: 'AGREGAR_ITEM_RAPIDO'; payload: { productoId: string; nombre: string; codigo: string; costoUnitario: number } }
  | { type: 'IMPORTAR_ITEMS'; payload: CompraItemForm[] }
  | { type: 'SET_ESCANEANDO'; payload: boolean }
  | { type: 'SET_RESULTADO_ESCANEO'; payload: FacturaEscaneada | null }
  | { type: 'SET_ERROR_ESCANEO'; payload: string }
  | { type: 'APLICAR_ESCANEO'; payload: { proveedorId: string; proveedorNombre: string; numeroFactura: string; fechaCompra: string; formaPago: string; items: CompraItemForm[] } };

/** Props del componente principal */
export interface ModalCompraProps {
  productos: ProductoDB[];
  proveedores: ProveedorDBExtended[];
  onSave: (compra: CompraFormInputExtended) => Promise<void>;
  onClose: () => void;
  onCrearProductoRapido?: (data: { nombre: string; codigo: string; costoSinIva: number }) => Promise<ProductoDB>;
  onCrearProveedor?: (data: ProveedorFormInputExtended) => Promise<ProveedorDBExtended>;
}

/** Props de ProveedorSection */
interface ProveedorSectionProps {
  state: CompraState;
  dispatch: React.Dispatch<CompraActionType>;
  proveedores: ProveedorDBExtended[];
  onAgregarProveedor?: () => void;
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
  onCrearProductoRapido?: (data: { nombre: string; codigo: string; costoSinIva: number }) => Promise<ProductoDB>;
  onImportarExcel?: () => void;
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
  subtotalBruto: number;
  bonificacionTotal: number;
  subtotal: number;
  iva: number;
  impuestosInternos: number;
  total: number;
}

/** Return type del hook de cálculos */
interface CalculosImpuestos {
  subtotalBruto: number;
  bonificacionTotal: number;
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
  modoItemRapido: false,
  guardando: false,
  error: '',
  // Escaneo
  escaneando: false,
  resultadoEscaneo: null,
  errorEscaneo: ''
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
          bonificacion: 0,
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

    case 'SET_MODO_ITEM_RAPIDO':
      return { ...state, modoItemRapido: action.payload }

    case 'AGREGAR_ITEM_RAPIDO': {
      const { productoId, nombre, codigo, costoUnitario } = action.payload
      return {
        ...state,
        items: [...state.items, {
          productoId,
          productoNombre: nombre,
          productoCodigo: codigo,
          cantidad: 1,
          bonificacion: 0,
          costoUnitario,
          impuestosInternos: 0,
          porcentajeIva: 21,
          stockActual: 0
        }],
        modoItemRapido: false,
        busquedaProducto: '',
        mostrarBuscador: false
      }
    }

    case 'IMPORTAR_ITEMS':
      return {
        ...state,
        items: [...state.items, ...action.payload]
      }

    case 'SET_ESCANEANDO':
      return { ...state, escaneando: action.payload, errorEscaneo: '' }

    case 'SET_RESULTADO_ESCANEO':
      return { ...state, resultadoEscaneo: action.payload, escaneando: false }

    case 'SET_ERROR_ESCANEO':
      return { ...state, errorEscaneo: action.payload, escaneando: false }

    case 'APLICAR_ESCANEO': {
      const { proveedorId, proveedorNombre, numeroFactura, fechaCompra, formaPago, items } = action.payload
      return {
        ...state,
        proveedorId,
        proveedorNombre,
        usarProveedorNuevo: !proveedorId && !!proveedorNombre,
        numeroFactura,
        fechaCompra: fechaCompra || state.fechaCompra,
        formaPago: formaPago || state.formaPago,
        items,
        resultadoEscaneo: null,
        errorEscaneo: ''
      }
    }

    default:
      return state
  }
}

// Hook para cálculos de impuestos (bonificacion e imp. internos como porcentaje)
function useCalculosImpuestos(items: CompraItemForm[]): CalculosImpuestos {
  return useMemo(() => {
    let subtotalBruto = 0
    let bonificacionTotal = 0
    let iva = 0
    let impuestosInternos = 0

    for (const item of items) {
      const bruto = item.cantidad * item.costoUnitario
      const bonif = bruto * (item.bonificacion || 0) / 100
      const neto = bruto - bonif
      subtotalBruto += bruto
      bonificacionTotal += bonif
      iva += neto * ((item.porcentajeIva ?? 21) / 100)
      impuestosInternos += neto * ((item.impuestosInternos || 0) / 100)
    }

    const subtotal = subtotalBruto - bonificacionTotal
    const total = subtotal + iva + impuestosInternos
    return { subtotalBruto, bonificacionTotal, subtotal, iva, impuestosInternos, total }
  }, [items])
}

const N8N_FACTURA_WEBHOOK_URL: string = import.meta.env.VITE_N8N_FACTURA_WEBHOOK_URL || ''
const MAX_IMAGE_SIZE = 8 * 1024 * 1024 // 8MB

export default function ModalCompra({ productos, proveedores, onSave, onClose, onCrearProductoRapido, onCrearProveedor }: ModalCompraProps) {
  const [state, dispatch] = useReducer(compraReducer, initialState)
  const [modalProveedorOpen, setModalProveedorOpen] = useState(false)
  const [modalImportarOpen, setModalImportarOpen] = useState(false)
  const { subtotalBruto, bonificacionTotal, subtotal, iva, impuestosInternos, total } = useCalculosImpuestos(state.items)
  const fileInputRef = useRef<HTMLInputElement>(null)

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

  // Escanear factura por foto
  const handleEscanearFactura = useCallback(async (file: File) => {
    if (!N8N_FACTURA_WEBHOOK_URL) {
      dispatch({ type: 'SET_ERROR_ESCANEO', payload: 'Escaneo no configurado. Falta VITE_N8N_FACTURA_WEBHOOK_URL' })
      return
    }
    if (file.size > MAX_IMAGE_SIZE) {
      dispatch({ type: 'SET_ERROR_ESCANEO', payload: 'La imagen es demasiado grande (máx 8MB)' })
      return
    }

    dispatch({ type: 'SET_ESCANEANDO', payload: true })
    try {
      // 1. Upload a Supabase Storage
      const fileName = `facturas/${Date.now()}_${file.name.replace(/[^a-zA-Z0-9._-]/g, '_')}`
      const { error: uploadError } = await supabase.storage
        .from('facturas')
        .upload(fileName, file)

      if (uploadError) {
        // Si el bucket no existe, dar mensaje claro
        if (uploadError.message.includes('not found') || uploadError.message.includes('Bucket')) {
          throw new Error('Bucket "facturas" no existe en Supabase Storage. Créalo desde el dashboard.')
        }
        throw uploadError
      }

      const { data: urlData } = supabase.storage.from('facturas').getPublicUrl(fileName)
      const imageUrl = urlData.publicUrl

      // 2. Enviar a n8n webhook
      const response = await fetch(N8N_FACTURA_WEBHOOK_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ imageUrl })
      })

      if (!response.ok) {
        const errorText = await response.text()
        throw new Error(`Error del servidor: ${response.status} - ${errorText}`)
      }

      const result = await response.json()

      if (!result.success) {
        throw new Error(result.error || 'No se pudo procesar la factura')
      }

      dispatch({ type: 'SET_RESULTADO_ESCANEO', payload: result.data as FacturaEscaneada })
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Error al escanear factura'
      dispatch({ type: 'SET_ERROR_ESCANEO', payload: msg })
    }
  }, [])

  // Aplicar resultado del escaneo al formulario
  const handleAplicarEscaneo = useCallback(() => {
    const scan = state.resultadoEscaneo
    if (!scan) return

    // Intentar matchear proveedor por CUIT
    let proveedorIdMatch = ''
    if (scan.proveedorCuit) {
      const cuitNorm = scan.proveedorCuit.replace(/-/g, '')
      const match = proveedores.find(p =>
        p.cuit && p.cuit.replace(/-/g, '') === cuitNorm
      )
      if (match) proveedorIdMatch = match.id
    }

    // Matchear items por código de producto
    const itemsConvertidos: CompraItemForm[] = scan.items.map(scanItem => {
      let productoMatch: ProductoDB | undefined
      if (scanItem.codigo) {
        productoMatch = productos.find(p =>
          p.codigo && p.codigo.toLowerCase() === scanItem.codigo!.toLowerCase()
        )
      }
      if (!productoMatch) {
        // Intentar match por nombre parcial
        const descLower = scanItem.descripcion.toLowerCase()
        productoMatch = productos.find(p =>
          p.nombre.toLowerCase().includes(descLower) ||
          descLower.includes(p.nombre.toLowerCase())
        )
      }

      return {
        productoId: productoMatch?.id || '',
        productoNombre: productoMatch?.nombre || scanItem.descripcion,
        productoCodigo: productoMatch?.codigo || scanItem.codigo,
        cantidad: scanItem.cantidad || 1,
        bonificacion: scanItem.bonificacion || 0,
        costoUnitario: scanItem.costoUnitario || 0,
        impuestosInternos: 0,
        porcentajeIva: scanItem.iva || 21,
        stockActual: productoMatch?.stock || 0
      }
    })

    const formaPagoMap: Record<string, string> = {
      'efectivo': 'efectivo',
      'transferencia': 'transferencia',
      'cheque': 'cheque',
      'cuenta_corriente': 'cuenta_corriente',
      'tarjeta': 'tarjeta'
    }

    dispatch({
      type: 'APLICAR_ESCANEO',
      payload: {
        proveedorId: proveedorIdMatch,
        proveedorNombre: proveedorIdMatch ? '' : (scan.proveedorNombre || ''),
        numeroFactura: scan.numeroFactura || '',
        fechaCompra: scan.fechaCompra || '',
        formaPago: formaPagoMap[scan.formaPago || ''] || 'efectivo',
        items: itemsConvertidos
      }
    })
  }, [state.resultadoEscaneo, productos, proveedores])

  const handleSubmit = async (e: FormEvent<HTMLFormElement> | React.MouseEvent<HTMLButtonElement>) => {
    e.preventDefault()
    dispatch({ type: 'SET_ERROR', payload: '' })

    // Validación manual (evita problemas de compatibilidad con Zod v4)
    if (state.items.length === 0) {
      dispatch({ type: 'SET_ERROR', payload: 'Debe agregar al menos un producto' })
      return
    }
    if (!state.fechaCompra) {
      dispatch({ type: 'SET_ERROR', payload: 'La fecha de compra es obligatoria' })
      return
    }
    for (const item of state.items) {
      if (!item.cantidad || item.cantidad <= 0) {
        dispatch({ type: 'SET_ERROR', payload: `"${item.productoNombre}" debe tener cantidad mayor a 0` })
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
        items: state.items.map(item => {
          const costoConBonif = (item.costoUnitario || 0) * (1 - (item.bonificacion || 0) / 100)
          return {
            productoId: item.productoId,
            cantidad: item.cantidad,
            costoUnitario: item.costoUnitario || 0,
            subtotal: item.cantidad * costoConBonif,
            bonificacion: item.bonificacion || 0
          }
        })
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
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-2 sm:p-4">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-4xl max-h-[90vh] overflow-hidden flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between p-3 sm:p-4 border-b dark:border-gray-700 shrink-0">
          <div className="flex items-center gap-2 min-w-0">
            <div className="p-1.5 sm:p-2 bg-green-100 dark:bg-green-900/30 rounded-lg shrink-0">
              <ShoppingCart className="w-5 h-5 text-green-600" />
            </div>
            <div className="min-w-0">
              <h2 className="text-base sm:text-lg font-semibold text-gray-800 dark:text-white truncate">Nueva Compra</h2>
              <p className="text-sm text-gray-500 hidden sm:block">Registrar compra a proveedor</p>
            </div>
          </div>
          <div className="flex items-center gap-1.5 sm:gap-2 shrink-0">
            {N8N_FACTURA_WEBHOOK_URL && (
              <>
                <input
                  ref={fileInputRef}
                  type="file"
                  accept="image/*"
                  className="hidden"
                  onChange={(e) => {
                    const file = e.target.files?.[0]
                    if (file) handleEscanearFactura(file)
                    e.target.value = ''
                  }}
                />
                <button
                  type="button"
                  onClick={() => fileInputRef.current?.click()}
                  disabled={state.escaneando}
                  className="flex items-center gap-1.5 px-2.5 sm:px-3 py-1.5 bg-purple-600 text-white rounded-lg hover:bg-purple-700 disabled:bg-purple-400 text-sm transition-colors"
                >
                  {state.escaneando ? (
                    <><Loader2 className="w-4 h-4 animate-spin" /> <span className="hidden sm:inline">Escaneando...</span></>
                  ) : (
                    <><Camera className="w-4 h-4" /> <span className="hidden sm:inline">Escanear Factura</span></>
                  )}
                </button>
              </>
            )}
            <button onClick={onClose} className="p-2 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg">
              <X className="w-5 h-5" />
            </button>
          </div>
        </div>

        {/* Preview resultado escaneo */}
        {state.resultadoEscaneo && (
          <ScanPreview
            resultado={state.resultadoEscaneo}
            productos={productos}
            proveedores={proveedores}
            onAplicar={handleAplicarEscaneo}
            onDescartar={() => dispatch({ type: 'SET_RESULTADO_ESCANEO', payload: null })}
          />
        )}

        {/* Error de escaneo */}
        {state.errorEscaneo && (
          <div className="mx-3 sm:mx-4 mt-2 p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg flex items-start gap-2">
            <AlertTriangle className="w-4 h-4 text-red-500 mt-0.5 shrink-0" />
            <div className="flex-1">
              <p className="text-sm text-red-600 dark:text-red-400">{state.errorEscaneo}</p>
            </div>
            <button onClick={() => dispatch({ type: 'SET_ERROR_ESCANEO', payload: '' })} className="text-red-400 hover:text-red-600">
              <X className="w-4 h-4" />
            </button>
          </div>
        )}

        {/* Contenido scrolleable */}
        <form onSubmit={handleSubmit} className="flex-1 overflow-y-auto p-3 sm:p-4 space-y-4">
          {/* Sección Proveedor */}
          <ProveedorSection
            state={state}
            dispatch={dispatch}
            proveedores={proveedores}
            onAgregarProveedor={onCrearProveedor ? () => setModalProveedorOpen(true) : undefined}
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
            onCrearProductoRapido={onCrearProductoRapido}
            onImportarExcel={() => setModalImportarOpen(true)}
          />

          {/* Totales */}
          {state.items.length > 0 && (
            <ResumenSection
              subtotalBruto={subtotalBruto}
              bonificacionTotal={bonificacionTotal}
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

        </form>

        {/* Footer con botones */}
        <div className="p-3 sm:p-4 border-t dark:border-gray-700 shrink-0 space-y-3">
          {/* Error visible junto al botón */}
          {state.error && (
            <div className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
              <p className="text-sm text-red-600 dark:text-red-400">{state.error}</p>
            </div>
          )}
          <div className="flex gap-3">
            <button
              type="button"
              onClick={onClose}
              className="flex-1 px-4 py-2 border dark:border-gray-600 rounded-lg hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors"
            >
              Cancelar
            </button>
            <button
              type="button"
              onClick={handleSubmit}
              disabled={state.guardando || state.items.length === 0}
              className="flex-1 px-4 py-2 bg-green-600 hover:bg-green-700 disabled:bg-green-400 text-white rounded-lg transition-colors flex items-center justify-center gap-2"
            >
              {state.guardando ? (
                <>
                  <Loader2 className="w-4 h-4 animate-spin" />
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

      {/* Modal Proveedor anidado */}
      {modalProveedorOpen && onCrearProveedor && (
        <Suspense fallback={null}>
          <ModalProveedor
            onSave={async (data) => {
              const nuevoProveedor = await onCrearProveedor({
                nombre: data.nombre,
                cuit: data.cuit || null,
                direccion: data.direccion || null,
                latitud: data.latitud || null,
                longitud: data.longitud || null,
                telefono: data.telefono || null,
                email: data.email || null,
                contacto: data.contacto || null,
                notas: data.notas || null,
                activo: true
              })
              dispatch({ type: 'SET_PROVEEDOR_ID', payload: nuevoProveedor.id })
              dispatch({ type: 'SET_USAR_PROVEEDOR_NUEVO', payload: false })
              setModalProveedorOpen(false)
            }}
            onClose={() => setModalProveedorOpen(false)}
          />
        </Suspense>
      )}

      {/* Modal Importar Excel */}
      {modalImportarOpen && (
        <Suspense fallback={null}>
          <ModalImportarCompra
            productos={productos}
            onImportar={(items) => {
              dispatch({ type: 'IMPORTAR_ITEMS', payload: items })
              setModalImportarOpen(false)
            }}
            onClose={() => setModalImportarOpen(false)}
          />
        </Suspense>
      )}
    </div>
  )
}

// Subcomponentes para mejor organización

function ProveedorSection({ state, dispatch, proveedores, onAgregarProveedor }: ProveedorSectionProps) {
  return (
    <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-3 sm:p-4 space-y-3">
      <div className="flex items-center gap-2 mb-2">
        <Building2 className="w-5 h-5 text-gray-500" />
        <h3 className="font-medium text-gray-800 dark:text-white">Proveedor</h3>
      </div>

      <div className="flex items-center gap-2">
        <select
          value={state.proveedorId}
          onChange={(e: ChangeEvent<HTMLSelectElement>) => dispatch({ type: 'SET_PROVEEDOR_ID', payload: e.target.value })}
          className="flex-1 px-3 sm:px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white text-sm sm:text-base"
        >
          <option value="">Seleccionar proveedor (opcional)...</option>
          {proveedores.map(p => (
            <option key={p.id} value={p.id}>{p.nombre} {p.cuit ? `(${p.cuit})` : ''}</option>
          ))}
        </select>
        {onAgregarProveedor && (
          <button
            type="button"
            onClick={onAgregarProveedor}
            className="flex items-center gap-1 px-3 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 transition-colors whitespace-nowrap text-sm"
            title="Agregar proveedor nuevo"
          >
            <Plus className="w-4 h-4" />
            <span className="hidden sm:inline">Nuevo</span>
          </button>
        )}
      </div>
    </div>
  )
}

function DatosCompraSection({ state, dispatch }: DatosCompraSectionProps) {
  return (
    <div className="grid grid-cols-1 md:grid-cols-3 gap-3 sm:gap-4">
      <div>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
          N Factura / Remito
        </label>
        <input
          type="text"
          value={state.numeroFactura}
          onChange={(e: ChangeEvent<HTMLInputElement>) => dispatch({ type: 'SET_NUMERO_FACTURA', payload: e.target.value })}
          placeholder="Ej: 0001-00012345"
          className="w-full px-3 sm:px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white text-sm sm:text-base"
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
          className="w-full px-3 sm:px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white text-sm sm:text-base"
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
          className="w-full px-3 sm:px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white text-sm sm:text-base"
        >
          {FORMAS_PAGO.map(fp => (
            <option key={fp.value} value={fp.value}>{fp.label}</option>
          ))}
        </select>
      </div>
    </div>
  )
}

function ProductosSection({ state, dispatch, productosFiltrados, onAgregarItem, onActualizarItem, onEliminarItem, onCrearProductoRapido, onImportarExcel }: ProductosSectionProps) {
  const [itemRapido, setItemRapido] = useState({ nombre: '', codigo: '', costo: 0 })
  const [creandoItem, setCreandoItem] = useState(false)
  const buscadorRef = useRef<HTMLDivElement>(null)

  // Cerrar dropdown al hacer click fuera
  useEffect(() => {
    if (!state.mostrarBuscador) return
    const handleClickOutside = (e: MouseEvent) => {
      if (buscadorRef.current && !buscadorRef.current.contains(e.target as Node)) {
        dispatch({ type: 'SET_MOSTRAR_BUSCADOR', payload: false })
      }
    }
    document.addEventListener('mousedown', handleClickOutside)
    return () => document.removeEventListener('mousedown', handleClickOutside)
  }, [state.mostrarBuscador, dispatch])

  const handleCrearProductoRapido = async () => {
    if (!onCrearProductoRapido || !itemRapido.nombre.trim()) return
    setCreandoItem(true)
    try {
      const producto = await onCrearProductoRapido({
        nombre: itemRapido.nombre,
        codigo: itemRapido.codigo,
        costoSinIva: itemRapido.costo
      })
      dispatch({ type: 'AGREGAR_ITEM_RAPIDO', payload: {
        productoId: producto.id,
        nombre: producto.nombre,
        codigo: producto.codigo || '',
        costoUnitario: producto.costo_sin_iva || itemRapido.costo
      }})
      setItemRapido({ nombre: '', codigo: '', costo: 0 })
    } catch {
      // Error handled by container
    } finally {
      setCreandoItem(false)
    }
  }

  return (
    <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-3 sm:p-4 space-y-3">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Package className="w-5 h-5 text-gray-500" />
          <h3 className="font-medium text-gray-800 dark:text-white">Productos</h3>
        </div>
        {onImportarExcel && (
          <button
            type="button"
            onClick={onImportarExcel}
            className="flex items-center gap-1 text-sm text-blue-600 hover:text-blue-700 dark:text-blue-400"
          >
            <FileText className="w-4 h-4" />
            Importar Excel
          </button>
        )}
      </div>

      {/* Buscador de productos */}
      <div className="relative" ref={buscadorRef}>
        <div className="flex items-center gap-2">
          <div className="relative flex-1">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" />
            <input
              type="text"
              value={state.busquedaProducto}
              onChange={(e: ChangeEvent<HTMLInputElement>) => dispatch({ type: 'SET_BUSQUEDA', payload: e.target.value })}
              onFocus={() => dispatch({ type: 'SET_MOSTRAR_BUSCADOR', payload: true })}
              onKeyDown={(e) => { if (e.key === 'Escape') dispatch({ type: 'SET_MOSTRAR_BUSCADOR', payload: false }) }}
              placeholder="Buscar producto por nombre o codigo..."
              className="w-full pl-10 pr-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
            />
          </div>
          {onCrearProductoRapido && (
            <button
              type="button"
              onClick={() => {
                dispatch({ type: 'SET_MODO_ITEM_RAPIDO', payload: !state.modoItemRapido })
                dispatch({ type: 'SET_MOSTRAR_BUSCADOR', payload: false })
              }}
              className="px-3 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors"
              title="Crear producto nuevo"
            >
              <Plus className="w-4 h-4" />
            </button>
          )}
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
              <div className="px-4 py-2">
                <p className="text-sm text-gray-500">No se encontraron productos</p>
                {onCrearProductoRapido && (
                  <button
                    type="button"
                    onClick={() => {
                      dispatch({ type: 'SET_MODO_ITEM_RAPIDO', payload: true })
                      dispatch({ type: 'SET_MOSTRAR_BUSCADOR', payload: false })
                      setItemRapido(prev => ({ ...prev, nombre: state.busquedaProducto }))
                    }}
                    className="mt-1 text-green-600 hover:underline text-sm flex items-center gap-1"
                  >
                    <Plus className="w-3 h-3" /> Crear producto rapido
                  </button>
                )}
              </div>
            )}
          </div>
        )}
      </div>

      {/* Formulario de item rapido */}
      {state.modoItemRapido && onCrearProductoRapido && (
        <div className="bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-lg p-3 space-y-2">
          <div className="flex items-center justify-between">
            <p className="text-sm font-medium text-blue-800 dark:text-blue-300">Crear producto rapido</p>
            <button
              type="button"
              onClick={() => dispatch({ type: 'SET_MODO_ITEM_RAPIDO', payload: false })}
              className="text-blue-400 hover:text-blue-600"
            >
              <X className="w-4 h-4" />
            </button>
          </div>
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-2">
            <div>
              <label className="block text-xs text-gray-500 mb-1">Nombre *</label>
              <input
                type="text"
                value={itemRapido.nombre}
                onChange={(e: ChangeEvent<HTMLInputElement>) => setItemRapido(prev => ({ ...prev, nombre: e.target.value }))}
                placeholder="Nombre del producto"
                className="w-full px-3 py-1.5 text-sm border dark:border-gray-600 rounded focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white"
              />
            </div>
            <div>
              <label className="block text-xs text-gray-500 mb-1">Codigo</label>
              <input
                type="text"
                value={itemRapido.codigo}
                onChange={(e: ChangeEvent<HTMLInputElement>) => setItemRapido(prev => ({ ...prev, codigo: e.target.value }))}
                placeholder="Codigo"
                className="w-full px-3 py-1.5 text-sm border dark:border-gray-600 rounded focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white"
              />
            </div>
            <div>
              <label className="block text-xs text-gray-500 mb-1">Costo neto</label>
              <input
                type="number"
                min="0"
                step="0.01"
                value={itemRapido.costo || ''}
                onChange={(e: ChangeEvent<HTMLInputElement>) => setItemRapido(prev => ({ ...prev, costo: parseFloat(e.target.value) || 0 }))}
                placeholder="0.00"
                className="w-full px-3 py-1.5 text-sm border dark:border-gray-600 rounded focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white"
              />
            </div>
          </div>
          <button
            type="button"
            onClick={handleCrearProductoRapido}
            disabled={!itemRapido.nombre.trim() || creandoItem}
            className="w-full px-3 py-1.5 bg-blue-600 text-white rounded hover:bg-blue-700 disabled:bg-blue-400 text-sm flex items-center justify-center gap-1"
          >
            {creandoItem ? (
              <><Loader2 className="w-3 h-3 animate-spin" /> Creando...</>
            ) : (
              <><Plus className="w-3 h-3" /> Crear y Agregar</>
            )}
          </button>
        </div>
      )}

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
        <div className="col-span-3">Producto</div>
        <div className="col-span-2 text-center">Cant.</div>
        <div className="col-span-1 text-center">Bonif.%</div>
        <div className="col-span-2 text-center">Neto</div>
        <div className="col-span-2 text-center">Imp.Int.%</div>
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
        <div className="grid grid-cols-4 gap-2">
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
            <label className="block text-xs text-gray-500 mb-1">Bonif.%</label>
            <input
              type="number"
              min="0"
              max="100"
              step="0.01"
              value={item.bonificacion}
              onChange={(e: ChangeEvent<HTMLInputElement>) => onActualizarItem(index, 'bonificacion', parseFloat(e.target.value) || 0)}
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
            <label className="block text-xs text-gray-500 mb-1">II%</label>
            <input
              type="number"
              min="0"
              step="0.01"
              value={item.impuestosInternos || 0}
              readOnly
              className="w-full px-2 py-1 text-center border dark:border-gray-600 rounded bg-gray-100 dark:bg-gray-600 dark:text-gray-300 text-sm cursor-not-allowed"
            />
          </div>
        </div>
        <div className="flex justify-between items-center pt-2 border-t dark:border-gray-600">
          <span className="text-sm text-gray-500">Subtotal:</span>
          <span className="font-semibold text-gray-800 dark:text-white">{formatPrecio(item.cantidad * item.costoUnitario * (1 - (item.bonificacion || 0) / 100))}</span>
        </div>
      </div>

      {/* Desktop: Layout en grid */}
      <div className="hidden md:grid grid-cols-12 gap-2 items-center">
        <div className="col-span-3">
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
        <div className="col-span-1">
          <input
            type="number"
            min="0"
            max="100"
            step="0.01"
            value={item.bonificacion}
            onChange={(e: ChangeEvent<HTMLInputElement>) => onActualizarItem(index, 'bonificacion', parseFloat(e.target.value) || 0)}
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
            readOnly
            className="w-full px-2 py-1 text-center border dark:border-gray-600 rounded bg-gray-100 dark:bg-gray-600 dark:text-gray-300 text-sm cursor-not-allowed"
          />
        </div>
        <div className="col-span-1 text-right font-medium text-gray-800 dark:text-white text-sm">
          {formatPrecio(item.cantidad * item.costoUnitario * (1 - (item.bonificacion || 0) / 100))}
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

/** Preview del resultado del escaneo de factura */
function ScanPreview({ resultado, productos, proveedores, onAplicar, onDescartar }: {
  resultado: FacturaEscaneada;
  productos: ProductoDB[];
  proveedores: ProveedorDBExtended[];
  onAplicar: () => void;
  onDescartar: () => void;
}) {
  // Contar items matcheados
  const itemsMatcheados = resultado.items.filter(item => {
    if (item.codigo) {
      return productos.some(p => p.codigo?.toLowerCase() === item.codigo!.toLowerCase())
    }
    const desc = item.descripcion.toLowerCase()
    return productos.some(p =>
      p.nombre.toLowerCase().includes(desc) || desc.includes(p.nombre.toLowerCase())
    )
  }).length

  // Verificar match de proveedor
  const proveedorMatch = resultado.proveedorCuit
    ? proveedores.find(p => p.cuit?.replace(/-/g, '') === resultado.proveedorCuit!.replace(/-/g, ''))
    : null

  const confianzaPct = Math.round((resultado.confianza || 0) * 100)
  const confianzaColor = confianzaPct >= 80 ? 'text-green-600' : confianzaPct >= 50 ? 'text-yellow-600' : 'text-red-600'

  return (
    <div className="mx-3 sm:mx-4 mt-2 p-3 sm:p-4 bg-purple-50 dark:bg-purple-900/20 border border-purple-200 dark:border-purple-800 rounded-lg">
      <div className="flex items-start justify-between mb-3">
        <div className="flex items-center gap-2">
          <CheckCircle className="w-5 h-5 text-purple-600" />
          <h4 className="font-medium text-purple-800 dark:text-purple-200">Factura escaneada</h4>
          <span className={`text-xs font-medium ${confianzaColor}`}>
            {confianzaPct}% confianza
          </span>
        </div>
        <button onClick={onDescartar} className="text-purple-400 hover:text-purple-600">
          <X className="w-4 h-4" />
        </button>
      </div>

      <div className="grid grid-cols-2 md:grid-cols-4 gap-3 text-sm mb-3">
        {resultado.proveedorNombre && (
          <div>
            <span className="text-gray-500 text-xs">Proveedor</span>
            <p className="font-medium dark:text-white">
              {resultado.proveedorNombre}
              {proveedorMatch && <span className="text-green-600 text-xs ml-1">(encontrado)</span>}
            </p>
          </div>
        )}
        {resultado.numeroFactura && (
          <div>
            <span className="text-gray-500 text-xs">N Factura</span>
            <p className="font-medium dark:text-white">{resultado.numeroFactura}</p>
          </div>
        )}
        {resultado.fechaCompra && (
          <div>
            <span className="text-gray-500 text-xs">Fecha</span>
            <p className="font-medium dark:text-white">{resultado.fechaCompra}</p>
          </div>
        )}
        {resultado.total != null && (
          <div>
            <span className="text-gray-500 text-xs">Total</span>
            <p className="font-medium dark:text-white">{formatPrecio(resultado.total)}</p>
          </div>
        )}
      </div>

      <p className="text-xs text-gray-500 mb-3">
        {resultado.items.length} items detectados, {itemsMatcheados} matcheados con productos existentes
      </p>

      <div className="flex gap-2">
        <button
          onClick={onAplicar}
          className="flex-1 px-3 py-1.5 bg-purple-600 text-white rounded-lg hover:bg-purple-700 text-sm font-medium transition-colors"
        >
          Aplicar datos
        </button>
        <button
          onClick={onDescartar}
          className="px-3 py-1.5 border border-purple-300 dark:border-purple-600 text-purple-700 dark:text-purple-300 rounded-lg hover:bg-purple-100 dark:hover:bg-purple-900/30 text-sm transition-colors"
        >
          Descartar
        </button>
      </div>
    </div>
  )
}

function ResumenSection({ subtotalBruto, bonificacionTotal, subtotal, iva, impuestosInternos, total }: ResumenSectionProps) {
  return (
    <div className="bg-green-50 dark:bg-green-900/20 rounded-lg p-4">
      <div className="flex items-center gap-2 mb-3">
        <Calculator className="w-5 h-5 text-green-600" />
        <h3 className="font-medium text-gray-800 dark:text-white">Resumen</h3>
      </div>

      <div className="space-y-2">
        {bonificacionTotal > 0 && (
          <>
            <div className="flex justify-between text-sm">
              <span className="text-gray-600 dark:text-gray-400">Subtotal Bruto:</span>
              <span className="font-medium text-gray-800 dark:text-white">{formatPrecio(subtotalBruto)}</span>
            </div>
            <div className="flex justify-between text-sm text-orange-600">
              <span>Bonificacion:</span>
              <span className="font-medium">-{formatPrecio(bonificacionTotal)}</span>
            </div>
          </>
        )}
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
      </div>
    </div>
  )
}
