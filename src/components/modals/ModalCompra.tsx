/**
 * Modal para registrar compras a proveedores
 *
 * Refactorizado con useReducer para mejor gestión de estado
 * Validación con Zod
 */
import React, { useReducer, useMemo, useCallback, useState, useEffect, useRef, Suspense } from 'react'
import type { ChangeEvent, FormEvent } from 'react'
import { X, ShoppingCart, Plus, Trash2, Package, Building2, FileText, Calculator, Search, Loader2, Camera, CheckCircle, AlertTriangle, Truck, ChevronDown, ChevronRight, Copy } from 'lucide-react'
import { formatPrecio } from '../../utils/formatters'
import { redondearSQL } from '../../utils/calculations'
import { OPCIONES_CONDICION_IVA, OPCIONES_CONDICION_SIN_ALICUOTA, claveCondicionIva, labelCondicionIva } from '../../utils/condicionIva'
import { prorratearCargo, calcularCostosCompra, calcularTotalesCompra } from '../../utils/prorrateoCompra'
import type { CostosCompra, TotalesCompra, ResultadoBasesII } from '../../utils/prorrateoCompra'
import NumberInput from '../ui/NumberInput'
import { supabase } from '../../lib/supabase'
// Del módulo y no del barrel: éste es un modal lazy y el barrel se lleva puesto
// todo el resto de los hooks de query al chunk.
import { useCargosPlantillaProveedorQuery } from '../../hooks/queries/useComprasQuery'
import { CompactErrorBoundary } from '../ErrorBoundary'
import type { CondicionIva, ProductoDB, ProveedorDBExtended, CompraFormInputExtended, PlantillaCargosProveedor, ProveedorFormInputExtended } from '../../types'
import { lazyWithReload } from '../../utils/lazyWithReload';
import {
  compraReducer, initialState, matchProductoEstricto, construirCompraItemDesdeScan,
  lineasParaMotor, cargosParaMotor, iiDeclaradoParaMotor,
  cuadreImpuestoInterno, DESVIO_II_TOLERADO, cargosPlantillaNuevos,
  cargosParaRPC, validarCargos, cargosNoGravadosEnFactura, noGravadoDeCargos,
  resolucionBasesII,
} from './ModalCompra.reducer'
import type {
  CompraItemForm, CargoCompraForm, CambiosCargo, BaseProrrateo,
  FacturaEscaneada, FacturaItemEscaneado, CompraState, CompraActionType,
} from './ModalCompra.reducer'


const ModalProveedor = lazyWithReload(() => import('./ModalProveedor'))
const ModalImportarCompra = lazyWithReload(() => import('./ModalImportarCompra'))

// =============================================================================
// TIPOS
// =============================================================================

/** Clave del selector fiscal para el par que tenga la línea. */
const claveCondicionLinea = (item: CompraItemForm): string =>
  claveCondicionIva(item.condicionIva, item.porcentajeIva)

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
  iiMaster: Record<string, number>;
  condicionMaster: Record<string, string>;
  onAgregarItem: (producto: ProductoDB) => void;
  onActualizarItem: (index: number, campo: keyof CompraItemForm, valor: number | string) => void;
  onCondicionItem: (index: number, clave: string) => void;
  onEliminarItem: (index: number) => void;
  onCrearProductoRapido?: (data: { nombre: string; codigo: string; costoSinIva: number }) => Promise<ProductoDB>;
  onImportarExcel?: () => void;
}

/** Props de ItemsList */
interface ItemsListProps {
  items: CompraItemForm[];
  onActualizarItem: (index: number, campo: keyof CompraItemForm, valor: number | string) => void;
  onCondicionItem: (index: number, clave: string) => void;
  onEliminarItem: (index: number) => void;
  /** Tasa de II vigente del producto (para avisar si la línea difiere) */
  iiMaster: Record<string, number>;
  /** Clave de condición vigente en la ficha del producto (mig 177) */
  condicionMaster: Record<string, string>;
}

/** Props de ItemRow */
interface ItemRowProps {
  item: CompraItemForm;
  index: number;
  onActualizarItem: (index: number, campo: keyof CompraItemForm, valor: number | string) => void;
  onCondicionItem: (index: number, clave: string) => void;
  onEliminarItem: (index: number) => void;
  /** Tasa de II vigente en el maestro del producto (undefined = desconocida) */
  iiDelProducto?: number;
  /** Clave de condición de la ficha (undefined = desconocida) */
  condicionDelProducto?: string;
}

/** Props de CargosSection */
interface CargosSectionProps {
  state: CompraState;
  dispatch: React.Dispatch<CompraActionType>;
  /** Cargos de la última compra de este proveedor. null = no hay ninguna con cargos. */
  plantilla?: PlantillaCargosProveedor | null;
  /** Lo que el impuesto interno declarado permite deducir. null = el motor no pudo. */
  resolucion: ResultadoBasesII | null;
}

/** Props de CargoRow */
interface CargoRowProps {
  cargo: CargoCompraForm;
  items: CompraItemForm[];
  dispatch: React.Dispatch<CompraActionType>;
  resolucion: ResultadoBasesII | null;
}

/** Props de GrillaPesos */
interface GrillaPesosProps {
  cargo: CargoCompraForm;
  items: CompraItemForm[];
  dispatch: React.Dispatch<CompraActionType>;
}

/** Props de VistaPreviaCostosSection */
interface VistaPreviaCostosProps {
  state: CompraState;
}

/** Props de ResumenSection */
interface ResumenSectionProps {
  totales: TotalesCompra;
  state: CompraState;
  dispatch: React.Dispatch<CompraActionType>;
  resolucion: ResultadoBasesII | null;
}

// Constantes
// Nota: `cuenta_corriente` ya no se ofrece como forma de pago (no es una forma
// de pago real). Las compras históricas con ese valor se siguen mostrando bien
// en ModalDetalleCompra; el mapeo del escaneo de factura lo conserva.
const FORMAS_PAGO = [
  { value: 'efectivo', label: 'Efectivo' },
  { value: 'transferencia', label: 'Transferencia' },
  { value: 'cheque', label: 'Cheque' },
  { value: 'tarjeta', label: 'Tarjeta' }
]

// Hook para cálculos de impuestos: delega en calcularTotalesCompra (fuente
// única, testeada con la factura Manaos). ZZ: lo pagado es todo (sin IVA, II
// ni percepciones).
//
// Los cargos entran acá y no sólo en la vista previa: desde que una bonificación
// se carga como cargo, el neto gravado, el IVA y el impuesto interno de la
// cabecera dependen de ellos, y son los que viajan a `compras.iva` y a
// `compras.impuestos_internos`. Sin esto la posición fiscal quedaba inflada.
//
// El motor lanza ante un peso o una cantidad corruptos —mientras el usuario
// tipea, un campo a medio escribir alcanza— así que la llamada va envuelta: se
// cae a la aritmética sin cargos para no dejar el resumen en blanco. No tapa
// nada: la vista previa muestra el error con su texto y `validarCargos` frena
// el guardado antes de que un número así llegue a la base.
function useCalculosImpuestos(
  items: CompraItemForm[],
  tipoFactura: 'ZZ' | 'FC',
  percepcionIva: number,
  percepcionIibb: number,
  noGravado: number,
  cargos: CargoCompraForm[],
  iiDeclarado: Record<number, number>
): TotalesCompra {
  return useMemo(
    () => {
      const extras = { percepcionIva, percepcionIibb, noGravado }
      // El borde va adentro del memo: `cargosParaMotor` arma un array nuevo en
      // cada render y como dependencia anularía la memoización.
      try {
        return calcularTotalesCompra(
          items, tipoFactura, extras,
          cargosParaMotor(cargos), iiDeclaradoParaMotor(iiDeclarado, tipoFactura)
        )
      } catch {
        return calcularTotalesCompra(items, tipoFactura, extras)
      }
    },
    [items, tipoFactura, percepcionIva, percepcionIibb, noGravado, cargos, iiDeclarado]
  )
}

const N8N_FACTURA_WEBHOOK_URL: string = import.meta.env.VITE_N8N_FACTURA_WEBHOOK_URL || ''
const MAX_IMAGE_SIZE = 8 * 1024 * 1024 // 8MB

export default function ModalCompra({ productos, proveedores, onSave, onClose, onCrearProductoRapido, onCrearProveedor }: ModalCompraProps) {
  const [state, dispatch] = useReducer(compraReducer, initialState)
  const [modalProveedorOpen, setModalProveedorOpen] = useState(false)
  const [modalImportarOpen, setModalImportarOpen] = useState(false)
  const totales = useCalculosImpuestos(
    state.items, state.tipoFactura, state.percepcionIva, state.percepcionIibb, state.noGravado,
    state.cargos, state.iiDeclarado
  )
  const { subtotal, iva, impuestosInternos, total } = totales

  // Qué bonificaciones bajan la base del impuesto interno, deducido del
  // declarado. Se calcula UNA vez acá y baja a las dos secciones que lo
  // muestran —los casilleros de "Cargos y prorrateo" y el cuadre del resumen—
  // porque son la misma respuesta dicha en dos lugares y calcularla dos veces
  // es la forma de que un día digan cosas distintas.
  const resolucionII = useMemo(
    () => resolucionBasesII(state.items, state.cargos, state.iiDeclarado, state.tipoFactura),
    [state.items, state.cargos, state.iiDeclarado, state.tipoFactura]
  )

  // Tasa de II vigente por producto: para autocompletar y detectar líneas que
  // difieren (alícuota cambiada en la factura → se propaga al producto al guardar).
  const iiMaster = useMemo<Record<string, number>>(
    () => Object.fromEntries(productos.map(p => [String(p.id), Number(p.impuestos_internos ?? 0)])),
    [productos]
  )

  // Condición fiscal vigente por producto. A diferencia del II, una condición
  // distinta en la línea NO se propaga al maestro: la venta hereda del producto
  // y un typo acá cambiaría el IVA de todas las ventas futuras. Solo se avisa.
  const condicionMaster = useMemo<Record<string, string>>(
    () => Object.fromEntries(productos.map(p => [
      String(p.id),
      (p.condicion_iva ?? 'gravado') === 'gravado'
        ? `gravado:${p.porcentaje_iva ?? 21}`
        : (p.condicion_iva ?? 'gravado'),
    ])),
    [productos]
  )
  const fileInputRef = useRef<HTMLInputElement>(null)

  // Cargos de la última compra de este proveedor, para reusarlos. Se pide al
  // elegir el proveedor y no al apretar el botón: así la sección sabe de
  // antemano si hay algo para traer, en vez de ofrecer un botón que a veces no
  // hace nada. Con proveedor nuevo (sin id) la query queda apagada.
  const plantillaCargos = useCargosPlantillaProveedorQuery(
    state.usarProveedorNuevo ? null : state.proveedorId
  )

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

  const handleCondicionItem = useCallback((index: number, clave: string) => {
    dispatch({ type: 'SET_CONDICION_ITEM', payload: { index, clave } })
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

    // Auto-vincular SOLO con certeza (código exacto o nombre exacto normalizados).
    // El resto queda pendiente de revisión humana.
    const itemsMatcheados: CompraItemForm[] = []
    const pendientes: FacturaItemEscaneado[] = []
    for (const scanItem of scan.items) {
      const match = matchProductoEstricto(scanItem, productos)
      if (match) {
        itemsMatcheados.push(construirCompraItemDesdeScan(match, scanItem))
      } else {
        pendientes.push(scanItem)
      }
    }

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
        items: itemsMatcheados,
        pendientes
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
    // Proveedor obligatorio: existente (proveedorId) o nombre nuevo escrito.
    const tieneProveedor = state.usarProveedorNuevo
      ? !!(state.proveedorNombre || '').trim()
      : !!state.proveedorId
    if (!tieneProveedor) {
      dispatch({ type: 'SET_ERROR', payload: 'Debe seleccionar un proveedor' })
      return
    }
    for (const item of state.items) {
      if (!item.cantidad || item.cantidad <= 0) {
        dispatch({ type: 'SET_ERROR', payload: `"${item.productoNombre}" debe tener cantidad mayor a 0` })
        return
      }
    }
    // Lo que la RPC va a rechazar de los cargos, dicho antes de salir a la red.
    // La validación que manda sigue siendo la de la mig 194 —corre aunque el
    // cliente esté viejo— pero un round trip para enterarse de que el flete no
    // tiene ninguna línea asignada es un round trip de más.
    const errorCargos = validarCargos(state.cargos)
    if (errorCargos) {
      dispatch({ type: 'SET_ERROR', payload: errorCargos })
      return
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
        impuestosInternos,
        percepcionIva: state.tipoFactura === 'FC' ? state.percepcionIva : 0,
        percepcionIibb: state.tipoFactura === 'FC' ? state.percepcionIibb : 0,
        noGravado: state.tipoFactura === 'FC' ? state.noGravado : 0,
        // mig 195. Ya viene en 0 en ZZ desde el motor; el `total` de arriba la
        // tiene adentro, así que las dos puntas del cuadre dicen lo mismo.
        bonificaciones: totales.bonificaciones,
        otrosImpuestos: 0,
        total,
        // Líneas FC cuya tasa de II fue editada a mano: la alícuota nueva se
        // propaga al producto tras registrar la compra (con toast resumen).
        cambiosImpuestosInternos: state.tipoFactura === 'FC'
          ? state.items
              .filter(it => difiereII(it, iiMaster[String(it.productoId)]))
              .map(it => ({
                productoId: it.productoId,
                nombre: it.productoNombre,
                impuestosInternos: it.impuestosInternos || 0,
              }))
          : [],
        formaPago: state.formaPago,
        notas: state.notas,
        tipoFactura: state.tipoFactura,
        // Los pesos viajan por ÍNDICE del array de items de abajo: los
        // compra_items.id no existen todavía. `cargosParaRPC` traduce contra
        // ESE mismo array, así que los dos tienen que salir de `state.items`.
        cargos: cargosParaRPC(state.items, state.cargos),
        // En ZZ la RPC lo descarta igual; mandarlo ya filtrado deja a las dos
        // puntas diciendo lo mismo.
        iiDeclarado: iiDeclaradoParaMotor(state.iiDeclarado, state.tipoFactura),
        items: state.items.map(item => {
          const costoConBonif = (item.costoUnitario || 0) * (1 - (item.bonificacion || 0) / 100)
          return {
            productoId: item.productoId,
            cantidad: item.cantidad,
            costoUnitario: item.costoUnitario || 0,
            subtotal: item.cantidad * costoConBonif,
            bonificacion: item.bonificacion || 0,
            porcentajeIva: item.porcentajeIva ?? 21,
            condicionIva: item.condicionIva ?? 'gravado',
            impuestosInternos: item.impuestosInternos ?? 0
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
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-6xl max-h-[90vh] overflow-hidden flex flex-col">
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

        {/* Panel de revisión de ítems no auto-vinculados */}
        {state.itemsPendientesScan.length > 0 && (
          <ItemsPendientesScanPanel
            pendientes={state.itemsPendientesScan}
            productos={productos}
            puedeCrear={!!onCrearProductoRapido}
            onVincular={(index, producto) =>
              dispatch({ type: 'RESOLVER_PENDIENTE_VINCULAR', payload: { index, producto } })
            }
            onCrearNuevo={async (index, datos) => {
              if (!onCrearProductoRapido) return
              const producto = await onCrearProductoRapido(datos)
              dispatch({ type: 'RESOLVER_PENDIENTE_CREAR', payload: { index, producto } })
            }}
            onOmitir={(index) =>
              dispatch({ type: 'RESOLVER_PENDIENTE_OMITIR', payload: { index } })
            }
            onDescartarTodos={() => dispatch({ type: 'LIMPIAR_PENDIENTES_SCAN' })}
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
        <CompactErrorBoundary componentName="ModalCompra" onClose={onClose}>
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
              iiMaster={iiMaster}
              condicionMaster={condicionMaster}
              onAgregarItem={handleAgregarItem}
              onActualizarItem={handleActualizarItem}
              onCondicionItem={handleCondicionItem}
              onEliminarItem={handleEliminarItem}
              onCrearProductoRapido={onCrearProductoRapido}
              onImportarExcel={() => setModalImportarOpen(true)}
            />

            {/* Cargos y prorrateo. También en ZZ —el 47,9% de las compras—: el
                tipo de comprobante decide si se agregan impuestos encima, no si
                se ignoran costos, y un flete que factura un transportista aparte
                no está adentro del precio pagado. La regla de ZZ se aplica en el
                borde del motor (lineasParaMotor), no apagando la sección.
                El único gate es tener líneas donde repartir. */}
            {state.items.length > 0 && (
              <>
                <CargosSection state={state} dispatch={dispatch} plantilla={plantillaCargos.data} resolucion={resolucionII} />
                <VistaPreviaCostosSection state={state} />
              </>
            )}

            {/* Totales */}
            {state.items.length > 0 && (
              <ResumenSection totales={totales} state={state} dispatch={dispatch} resolucion={resolucionII} />
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
        </CompactErrorBoundary>

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
        <h3 className="font-medium text-gray-800 dark:text-white">Proveedor <span className="text-red-500">*</span></h3>
      </div>

      <div className="flex items-center gap-2">
        <select
          value={state.proveedorId}
          onChange={(e: ChangeEvent<HTMLSelectElement>) => dispatch({ type: 'SET_PROVEEDOR_ID', payload: e.target.value })}
          className="flex-1 px-3 sm:px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white text-sm sm:text-base"
        >
          <option value="">Seleccionar proveedor...</option>
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
    <>
    {/* Tipo de Comprobante */}
    <div className="mb-3">
      <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
        Tipo de Comprobante
      </label>
      <div className="flex rounded-lg overflow-hidden border dark:border-gray-600">
        <button
          type="button"
          onClick={() => dispatch({ type: 'SET_TIPO_FACTURA', payload: 'FC' })}
          className={`flex-1 px-3 py-2 text-sm font-medium transition-colors ${
            state.tipoFactura === 'FC'
              ? 'bg-blue-600 text-white dark:bg-blue-500'
              : 'bg-gray-100 text-gray-600 hover:bg-gray-200 dark:bg-gray-700 dark:text-gray-300 dark:hover:bg-gray-600'
          }`}
        >
          FC Con Factura / IVA
        </button>
        <button
          type="button"
          onClick={() => dispatch({ type: 'SET_TIPO_FACTURA', payload: 'ZZ' })}
          className={`flex-1 px-3 py-2 text-sm font-medium transition-colors ${
            state.tipoFactura === 'ZZ'
              ? 'bg-gray-800 text-white dark:bg-gray-200 dark:text-gray-900'
              : 'bg-gray-100 text-gray-600 hover:bg-gray-200 dark:bg-gray-700 dark:text-gray-300 dark:hover:bg-gray-600'
          }`}
        >
          ZZ Sin Factura
        </button>
      </div>
    </div>

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
    </>
  )
}

function ProductosSection({ state, dispatch, productosFiltrados, iiMaster, condicionMaster, onAgregarItem, onActualizarItem, onCondicionItem, onEliminarItem, onCrearProductoRapido, onImportarExcel }: ProductosSectionProps) {
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
              <NumberInput
                min={0}
                emptyValue={0}
                value={itemRapido.costo || 0}
                onChange={(n) => setItemRapido(prev => ({ ...prev, costo: n }))}
                commitOnChange
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
        <ItemsList items={state.items} onActualizarItem={onActualizarItem} onCondicionItem={onCondicionItem} onEliminarItem={onEliminarItem} iiMaster={iiMaster} condicionMaster={condicionMaster} />
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

function ItemsList({ items, onActualizarItem, onCondicionItem, onEliminarItem, iiMaster, condicionMaster }: ItemsListProps) {
  return (
    <div className="space-y-2">
      {/* Header solo en desktop */}
      <div className="hidden md:grid grid-cols-12 gap-2 text-xs font-medium text-gray-500 uppercase px-2">
        <div className="col-span-3">Producto</div>
        <div className="col-span-1 text-center">Cant.</div>
        <div className="col-span-1 text-center">Bonif.%</div>
        <div className="col-span-2 text-center">Neto</div>
        <div className="col-span-2 text-center">IVA</div>
        <div className="col-span-1 text-center">Imp.Int.%</div>
        <div className="col-span-1 text-right">Subtot.</div>
        <div className="col-span-1"></div>
      </div>
      {items.map((item, index) => (
        <ItemRow
          key={index}
          item={item}
          index={index}
          onActualizarItem={onActualizarItem}
          onCondicionItem={onCondicionItem}
          onEliminarItem={onEliminarItem}
          iiDelProducto={iiMaster[String(item.productoId)]}
          condicionDelProducto={condicionMaster[String(item.productoId)]}
        />
      ))}
    </div>
  )
}

/** ¿La tasa de II de la línea difiere de la vigente en el producto? */
function difiereII(item: CompraItemForm, iiDelProducto?: number): boolean {
  if (iiDelProducto === undefined) return false
  return Math.abs((item.impuestosInternos || 0) - iiDelProducto) > 0.0001
}

/**
 * ¿La condición de la línea difiere de la de la ficha? A diferencia del II,
 * esto NO se propaga al producto: sólo se avisa (la venta hereda de la ficha).
 */
function difiereCondicion(item: CompraItemForm, condicionDelProducto?: string): boolean {
  if (condicionDelProducto === undefined) return false
  return claveCondicionLinea(item) !== condicionDelProducto
}

function ItemRow({ item, index, onActualizarItem, onCondicionItem, onEliminarItem, iiDelProducto, condicionDelProducto }: ItemRowProps) {
  const iiDifiere = difiereII(item, iiDelProducto)
  const condDifiere = difiereCondicion(item, condicionDelProducto)
  const selectCondicion = (extraClass = '') => (
    <select
      value={claveCondicionLinea(item)}
      onChange={(e) => onCondicionItem(index, e.target.value)}
      title={condDifiere
        ? `La ficha dice ${labelCondicionIva(condicionDelProducto!)}: el cambio aplica sólo a esta compra`
        : 'Condición frente al IVA de esta línea (autocompletada del producto)'}
      className={`w-full px-2 py-1 text-center border rounded text-sm dark:bg-gray-700 dark:text-white ${
        condDifiere ? 'border-amber-400 bg-amber-50 dark:bg-amber-900/20' : 'dark:border-gray-600'
      } ${extraClass}`}
    >
      {OPCIONES_CONDICION_IVA.map(o => (
        <option key={o.clave} value={o.clave}>{o.labelCorto}</option>
      ))}
    </select>
  )
  return (
    <div className={`bg-white dark:bg-gray-800 p-3 rounded-lg border ${iiDifiere || condDifiere ? 'border-amber-400 dark:border-amber-600' : 'dark:border-gray-600'}`}>
      {/* Mobile: Layout en cards */}
      <div className="md:hidden space-y-3">
        <div className="flex justify-between items-start">
          <div className="flex-1">
            <p className="font-medium text-gray-800 dark:text-white">{item.productoNombre}</p>
            <p className="text-xs text-gray-500">Stock: {item.stockActual}</p>
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
            <NumberInput
              integer
              min={1}
              emptyValue={1}
              value={item.cantidad}
              onChange={(n) => onActualizarItem(index, 'cantidad', n)}
              commitOnChange
              className="w-full px-2 py-1 text-center border dark:border-gray-600 rounded focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white text-sm"
            />
          </div>
          <div>
            <label className="block text-xs text-gray-500 mb-1">Bonif.%</label>
            <NumberInput
              min={0}
              max={100}
              emptyValue={0}
              value={item.bonificacion}
              onChange={(n) => onActualizarItem(index, 'bonificacion', n)}
              commitOnChange
              className="w-full px-2 py-1 text-center border dark:border-gray-600 rounded focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white text-sm"
            />
          </div>
          <div>
            <label className="block text-xs text-gray-500 mb-1">Neto</label>
            <NumberInput
              min={0}
              emptyValue={0}
              value={item.costoUnitario}
              onChange={(n) => onActualizarItem(index, 'costoUnitario', n)}
              commitOnChange
              className="w-full px-2 py-1 text-center border dark:border-gray-600 rounded focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white text-sm"
            />
          </div>
          <div>
            <label className="block text-xs text-gray-500 mb-1">IVA</label>
            {selectCondicion()}
          </div>
          <div>
            <label className="block text-xs text-gray-500 mb-1">II%</label>
            <NumberInput
              min={0}
              emptyValue={0}
              value={item.impuestosInternos || 0}
              onChange={(n) => onActualizarItem(index, 'impuestosInternos', n)}
              commitOnChange
              className={`w-full px-2 py-1 text-center border rounded text-sm dark:bg-gray-700 dark:text-white ${
                iiDifiere ? 'border-amber-400 bg-amber-50 dark:bg-amber-900/20' : 'dark:border-gray-600'
              }`}
            />
          </div>
        </div>
        {iiDifiere && (
          <p className="text-xs text-amber-700 dark:text-amber-300">
            ⚠ II difiere del producto ({iiDelProducto}% → {item.impuestosInternos}%): al registrar se actualiza la alícuota del producto.
          </p>
        )}
        {condDifiere && (
          <p className="text-xs text-amber-700 dark:text-amber-300">
            ⚠ La ficha dice {labelCondicionIva(condicionDelProducto!)}: el cambio aplica sólo a esta compra, el producto no se toca.
          </p>
        )}
        <div className="flex justify-between items-center pt-2 border-t dark:border-gray-600">
          <span className="text-sm text-gray-500">Subtotal:</span>
          <span className="font-semibold text-gray-800 dark:text-white">{formatPrecio(item.cantidad * item.costoUnitario * (1 - (item.bonificacion || 0) / 100))}</span>
        </div>
      </div>

      {/* Desktop: Layout en grid */}
      <div className="hidden md:grid grid-cols-12 gap-2 items-center">
        <div className="col-span-3">
          <p className="font-medium text-gray-800 dark:text-white text-sm">{item.productoNombre}</p>
          <p className="text-xs text-gray-500">Stock: {item.stockActual}</p>
        </div>
        <div className="col-span-1">
          <NumberInput
            integer
            min={1}
            emptyValue={1}
            value={item.cantidad}
            onChange={(n) => onActualizarItem(index, 'cantidad', n)}
            commitOnChange
            className="w-full px-2 py-1 text-center border dark:border-gray-600 rounded focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white text-sm"
          />
        </div>
        <div className="col-span-1">
          <NumberInput
            min={0}
            max={100}
            emptyValue={0}
            value={item.bonificacion}
            onChange={(n) => onActualizarItem(index, 'bonificacion', n)}
            commitOnChange
            className="w-full px-2 py-1 text-center border dark:border-gray-600 rounded focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white text-sm"
          />
        </div>
        <div className="col-span-2">
          <NumberInput
            min={0}
            emptyValue={0}
            value={item.costoUnitario}
            onChange={(n) => onActualizarItem(index, 'costoUnitario', n)}
            commitOnChange
            className="w-full px-2 py-1 text-center border dark:border-gray-600 rounded focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white text-sm"
          />
        </div>
        <div className="col-span-2">
          {selectCondicion()}
        </div>
        <div className="col-span-1">
          <NumberInput
            min={0}
            emptyValue={0}
            value={item.impuestosInternos || 0}
            onChange={(n) => onActualizarItem(index, 'impuestosInternos', n)}
            commitOnChange
            title={iiDifiere ? `Difiere del producto (${iiDelProducto}%): al registrar se actualiza la alícuota` : 'Tasa efectiva de imp. internos (autocompletada del producto)'}
            className={`w-full px-2 py-1 text-center border rounded text-sm dark:bg-gray-700 dark:text-white ${
              iiDifiere ? 'border-amber-400 bg-amber-50 dark:bg-amber-900/20' : 'dark:border-gray-600'
            }`}
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
      {iiDifiere && (
        <p className="hidden md:block text-xs text-amber-700 dark:text-amber-300 mt-1">
          ⚠ II difiere del producto ({iiDelProducto}% → {item.impuestosInternos}%): al registrar se actualiza la alícuota del producto.
        </p>
      )}
      {condDifiere && (
        <p className="hidden md:block text-xs text-amber-700 dark:text-amber-300 mt-1">
          ⚠ La ficha dice {labelCondicionIva(condicionDelProducto!)}: el cambio aplica sólo a esta compra, el producto no se toca.
        </p>
      )}
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
  // Contar items que se van a auto-vincular con certeza (mismas reglas que matchProductoEstricto)
  const itemsMatcheados = resultado.items.filter(item => matchProductoEstricto(item, productos) !== null).length
  const itemsPendientes = resultado.items.length - itemsMatcheados

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
        {resultado.items.length} items detectados · {itemsMatcheados} se vincularán automáticamente
        {itemsPendientes > 0 && ` · ${itemsPendientes} requerirán tu revisión`}
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

interface ItemsPendientesScanPanelProps {
  pendientes: FacturaItemEscaneado[];
  productos: ProductoDB[];
  puedeCrear: boolean;
  onVincular: (index: number, producto: ProductoDB) => void;
  onCrearNuevo: (index: number, datos: { nombre: string; codigo: string; costoSinIva: number }) => Promise<void>;
  onOmitir: (index: number) => void;
  onDescartarTodos: () => void;
}

type PendienteRowMode = 'idle' | 'vincular' | 'crear'

function ItemsPendientesScanPanel({
  pendientes,
  productos,
  puedeCrear,
  onVincular,
  onCrearNuevo,
  onOmitir,
  onDescartarTodos
}: ItemsPendientesScanPanelProps) {
  return (
    <div className="mx-3 sm:mx-4 mt-2 p-3 sm:p-4 bg-amber-50 dark:bg-amber-900/20 border border-amber-300 dark:border-amber-800 rounded-lg">
      <div className="flex items-start justify-between mb-3">
        <div className="flex items-center gap-2">
          <AlertTriangle className="w-5 h-5 text-amber-600" />
          <div>
            <h4 className="font-medium text-amber-800 dark:text-amber-200">
              {pendientes.length} {pendientes.length === 1 ? 'ítem necesita' : 'ítems necesitan'} tu revisión
            </h4>
            <p className="text-xs text-amber-700 dark:text-amber-300">
              No se pudieron vincular automáticamente. Elegí qué hacer con cada uno.
            </p>
          </div>
        </div>
        <button
          type="button"
          onClick={onDescartarTodos}
          className="text-amber-600 hover:text-amber-800 dark:text-amber-400 dark:hover:text-amber-200 text-xs font-medium underline"
          title="Descartar todos los pendientes"
        >
          Descartar todo
        </button>
      </div>

      <div className="space-y-2">
        {pendientes.map((scanItem, index) => (
          <ItemPendienteRow
            key={`${index}-${scanItem.codigo || ''}-${scanItem.descripcion}`}
            index={index}
            scanItem={scanItem}
            productos={productos}
            puedeCrear={puedeCrear}
            onVincular={onVincular}
            onCrearNuevo={onCrearNuevo}
            onOmitir={onOmitir}
          />
        ))}
      </div>
    </div>
  )
}

interface ItemPendienteRowProps {
  index: number;
  scanItem: FacturaItemEscaneado;
  productos: ProductoDB[];
  puedeCrear: boolean;
  onVincular: (index: number, producto: ProductoDB) => void;
  onCrearNuevo: (index: number, datos: { nombre: string; codigo: string; costoSinIva: number }) => Promise<void>;
  onOmitir: (index: number) => void;
}

function ItemPendienteRow({
  index,
  scanItem,
  productos,
  puedeCrear,
  onVincular,
  onCrearNuevo,
  onOmitir
}: ItemPendienteRowProps) {
  const [modo, setModo] = useState<PendienteRowMode>('idle')
  const [busqueda, setBusqueda] = useState('')
  const [nombreNuevo, setNombreNuevo] = useState(scanItem.descripcion)
  const [codigoNuevo, setCodigoNuevo] = useState(scanItem.codigo || '')
  const [costoNuevo, setCostoNuevo] = useState(scanItem.costoUnitario || 0)
  const [creando, setCreando] = useState(false)

  const productosFiltrados = useMemo(() => {
    const termino = busqueda.trim().toLowerCase()
    if (!termino) return productos.slice(0, 8)
    return productos
      .filter(p =>
        p.nombre?.toLowerCase().includes(termino) ||
        p.codigo?.toLowerCase().includes(termino)
      )
      .slice(0, 8)
  }, [productos, busqueda])

  const handleCrear = async () => {
    if (!nombreNuevo.trim()) return
    setCreando(true)
    try {
      await onCrearNuevo(index, {
        nombre: nombreNuevo.trim(),
        codigo: codigoNuevo.trim(),
        costoSinIva: costoNuevo
      })
      // El reducer remueve la fila; este componente se desmonta.
    } catch {
      // Error manejado arriba (toast del container)
    } finally {
      setCreando(false)
    }
  }

  return (
    <div className="bg-white dark:bg-gray-800 border border-amber-200 dark:border-amber-800/60 rounded-lg p-3 space-y-2">
      {/* Datos de la factura */}
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0 flex-1">
          <p className="font-medium text-gray-800 dark:text-white text-sm break-words">
            {scanItem.descripcion}
          </p>
          <p className="text-xs text-gray-500 dark:text-gray-400 mt-0.5">
            {scanItem.codigo && <span className="mr-2">Código: <span className="font-mono">{scanItem.codigo}</span></span>}
            <span>Cant: <span className="font-semibold">{scanItem.cantidad}</span></span>
            <span className="mx-1.5">·</span>
            <span>Costo: <span className="font-semibold">{formatPrecio(scanItem.costoUnitario || 0)}</span></span>
            {scanItem.iva > 0 && (
              <>
                <span className="mx-1.5">·</span>
                <span>IVA: <span className="font-semibold">{scanItem.iva}%</span></span>
              </>
            )}
          </p>
        </div>
      </div>

      {/* Acciones */}
      {modo === 'idle' && (
        <div className="flex flex-wrap gap-2">
          <button
            type="button"
            onClick={() => { setModo('vincular'); setBusqueda('') }}
            className="flex-1 min-w-[120px] px-3 py-1.5 bg-blue-600 hover:bg-blue-700 text-white rounded-lg text-sm font-medium transition-colors flex items-center justify-center gap-1"
          >
            <Search className="w-3.5 h-3.5" />
            Vincular existente
          </button>
          {puedeCrear && (
            <button
              type="button"
              onClick={() => setModo('crear')}
              className="flex-1 min-w-[120px] px-3 py-1.5 bg-green-600 hover:bg-green-700 text-white rounded-lg text-sm font-medium transition-colors flex items-center justify-center gap-1"
            >
              <Plus className="w-3.5 h-3.5" />
              Crear nuevo
            </button>
          )}
          <button
            type="button"
            onClick={() => onOmitir(index)}
            className="px-3 py-1.5 border border-gray-300 dark:border-gray-600 text-gray-600 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700 rounded-lg text-sm font-medium transition-colors"
            title="Omitir esta línea"
          >
            Omitir
          </button>
        </div>
      )}

      {/* Modo: Vincular existente */}
      {modo === 'vincular' && (
        <div className="space-y-2">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" />
            <input
              type="text"
              value={busqueda}
              onChange={(e) => setBusqueda(e.target.value)}
              placeholder="Buscar producto por nombre o código..."
              autoFocus
              className="w-full pl-10 pr-4 py-2 text-sm border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white"
            />
          </div>
          <div className="max-h-40 overflow-y-auto border border-gray-200 dark:border-gray-700 rounded-lg divide-y divide-gray-100 dark:divide-gray-700">
            {productosFiltrados.length === 0 ? (
              <p className="px-3 py-2 text-xs text-gray-500">Sin resultados</p>
            ) : (
              productosFiltrados.map(p => (
                <button
                  key={p.id}
                  type="button"
                  onClick={() => onVincular(index, p)}
                  className="w-full px-3 py-2 text-left hover:bg-blue-50 dark:hover:bg-blue-900/30 flex items-center justify-between"
                >
                  <div className="min-w-0 flex-1">
                    <p className="text-sm font-medium text-gray-800 dark:text-white truncate">{p.nombre}</p>
                    <p className="text-xs text-gray-500">
                      {p.codigo && `Cód: ${p.codigo} · `}Stock: {p.stock}
                    </p>
                  </div>
                  <Plus className="w-4 h-4 text-blue-600 shrink-0" />
                </button>
              ))
            )}
          </div>
          <button
            type="button"
            onClick={() => setModo('idle')}
            className="text-xs text-gray-500 hover:text-gray-700 dark:hover:text-gray-300 underline"
          >
            Cancelar
          </button>
        </div>
      )}

      {/* Modo: Crear nuevo */}
      {modo === 'crear' && puedeCrear && (
        <div className="bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 rounded-lg p-2 space-y-2">
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-2">
            <div className="sm:col-span-2">
              <label className="block text-xs text-gray-500 mb-0.5">Nombre *</label>
              <input
                type="text"
                value={nombreNuevo}
                onChange={(e) => setNombreNuevo(e.target.value)}
                placeholder="Nombre del producto"
                className="w-full px-2 py-1.5 text-sm border dark:border-gray-600 rounded focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
              />
            </div>
            <div>
              <label className="block text-xs text-gray-500 mb-0.5">Código</label>
              <input
                type="text"
                value={codigoNuevo}
                onChange={(e) => setCodigoNuevo(e.target.value)}
                placeholder="Código"
                className="w-full px-2 py-1.5 text-sm border dark:border-gray-600 rounded focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
              />
            </div>
          </div>
          <div>
            <label className="block text-xs text-gray-500 mb-0.5">Costo sin IVA</label>
            <NumberInput
              min={0}
              emptyValue={0}
              value={costoNuevo}
              onChange={(n) => setCostoNuevo(n)}
              commitOnChange
              className="w-full px-2 py-1.5 text-sm border dark:border-gray-600 rounded focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
            />
          </div>
          <div className="flex gap-2 pt-1">
            <button
              type="button"
              onClick={handleCrear}
              disabled={!nombreNuevo.trim() || creando}
              className="flex-1 px-3 py-1.5 bg-green-600 hover:bg-green-700 disabled:bg-green-300 text-white rounded text-sm font-medium transition-colors flex items-center justify-center gap-1"
            >
              {creando ? <Loader2 className="w-3.5 h-3.5 animate-spin" /> : <Plus className="w-3.5 h-3.5" />}
              Crear y vincular
            </button>
            <button
              type="button"
              onClick={() => setModo('idle')}
              disabled={creando}
              className="px-3 py-1.5 border border-gray-300 dark:border-gray-600 text-gray-600 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700 rounded text-sm transition-colors"
            >
              Cancelar
            </button>
          </div>
        </div>
      )}
    </div>
  )
}

/** Bases de reparto ofrecidas, con la ayuda que explica cada una. */
const BASES_PRORRATEO: Array<{ value: BaseProrrateo; label: string; ayuda: string }> = [
  { value: 'monto', label: 'Por monto', ayuda: 'Cada línea pesa lo que vale (neto ya bonificado). Es lo habitual para el flete.' },
  { value: 'cantidad', label: 'Por cantidad', ayuda: 'Cada línea pesa sus unidades. Sirve para pallets y separadores.' },
  // La mig 192 la llama 'unidades', pero la regla es peso 1 en TODAS las líneas:
  // lo que reparte son partes iguales, no unidades del producto.
  { value: 'unidades', label: 'Partes iguales', ayuda: 'Todas las líneas pesan lo mismo, sin importar monto ni cantidad.' },
]

/** ¿Este peso puede entrar a `prorratearCargo` sin hacerlo lanzar? */
function pesoInvalido(peso: number): boolean {
  return !Number.isFinite(peso) || peso < 0
}

/**
 * Reparto de un cargo línea por línea: el peso editable y la plata que le toca.
 *
 * `prorratearCargo` LANZA ante un peso no finito o negativo, y está bien que lo
 * haga: convertir basura en 0 la volvería indistinguible de una exclusión
 * deliberada, y el 0 ES el mecanismo de exclusión. Consecuencias acá:
 *  - Quien parsea es el formulario. NumberInput sólo emite números finitos y
 *    clampea a min=0, así que un campo a medio tipear ("", "1.") nunca llega al
 *    cálculo: el peso confirmado sigue siendo el anterior.
 *  - Igual se detectan las filas inválidas ANTES de llamar, y la llamada va
 *    envuelta. Un peso podrido deja su fila en error; no deja el modal en
 *    blanco.
 */
function GrillaPesos({ cargo, items, dispatch }: GrillaPesosProps) {
  // Sólo las líneas ya numeradas por el reducer; sin id no hay dónde colgar el peso.
  const lineas = items.flatMap(item =>
    item.lineaId === undefined ? [] : [{ item, id: item.lineaId }]
  )

  const pesoDe = (id: number): number => cargo.pesos[id] ?? 0
  const hayInvalidos = lineas.some(l => pesoInvalido(pesoDe(l.id)))

  // Sin useMemo: son un puñado de líneas y el React Compiler ya memoiza. Lo que
  // no puede faltar es el try, que es lo que separa "esa fila está en error" de
  // "el modal desapareció".
  const reparto = ((): Record<number, number> | null => {
    if (hayInvalidos) return null
    try {
      return prorratearCargo(cargo.monto, cargo.pesos)
    } catch {
      return null
    }
  })()

  const totalPeso = lineas.reduce((acc, l) => acc + (pesoInvalido(pesoDe(l.id)) ? 0 : pesoDe(l.id)), 0)
  const sumaRepartida = reparto ? Object.values(reparto).reduce((acc, v) => acc + v, 0) : 0
  // El residuo va a la línea de mayor peso justamente para que esto cierre al
  // centavo. Si alguna vez no cierra, es un bug del motor y hay que verlo.
  const cuadra = reparto !== null && Math.abs(sumaRepartida - cargo.monto) < 0.005

  const setPeso = (id: number, peso: number) =>
    dispatch({ type: 'SET_PESO_CARGO', payload: { cargoId: cargo.id, lineaId: id, peso } })

  const inputPeso = (id: number, invalida: boolean) => (
    <NumberInput
      min={0}
      emptyValue={0}
      value={invalida ? 0 : pesoDe(id)}
      onChange={(n) => setPeso(id, n)}
      commitOnChange
      title="0 excluye la línea de este cargo"
      className={`w-full px-2 py-1 text-right border rounded text-sm dark:bg-gray-700 dark:text-white ${
        invalida ? 'border-red-400 bg-red-50 dark:bg-red-900/20' : 'dark:border-gray-600'
      }`}
    />
  )

  const montoAsignado = (id: number) => (reparto === null ? null : reparto[id] ?? 0)

  return (
    <div className="mt-2 space-y-2">
      {/* Header solo en desktop */}
      <div className="hidden md:grid grid-cols-12 gap-2 text-xs font-medium text-gray-500 uppercase px-2">
        <div className="col-span-6">Producto</div>
        <div className="col-span-3 text-right">Peso</div>
        <div className="col-span-3 text-right">Le toca</div>
      </div>

      {lineas.map(({ item, id }) => {
        const invalida = pesoInvalido(pesoDe(id))
        const asignado = montoAsignado(id)
        return (
          <div key={id} className="bg-gray-50 dark:bg-gray-900 rounded px-2 py-2">
            {/* Mobile: apilado */}
            <div className="md:hidden space-y-2">
              <p className="text-sm text-gray-800 dark:text-white">{item.productoNombre}</p>
              <div className="grid grid-cols-2 gap-2 items-center">
                <div>
                  <label className="block text-xs text-gray-500 mb-1">Peso</label>
                  {inputPeso(id, invalida)}
                </div>
                <div className="text-right">
                  <span className="block text-xs text-gray-500 mb-1">Le toca</span>
                  <span className="text-sm font-medium text-gray-800 dark:text-white">
                    {asignado === null ? '—' : formatPrecio(asignado)}
                  </span>
                </div>
              </div>
            </div>

            {/* Desktop: grilla */}
            <div className="hidden md:grid grid-cols-12 gap-2 items-center">
              <p className="col-span-6 text-sm text-gray-800 dark:text-white truncate" title={item.productoNombre}>
                {item.productoNombre}
              </p>
              <div className="col-span-3">{inputPeso(id, invalida)}</div>
              <div className="col-span-3 text-right text-sm font-medium text-gray-800 dark:text-white">
                {asignado === null ? '—' : formatPrecio(asignado)}
              </div>
            </div>

            {invalida && (
              <p className="text-xs text-red-600 dark:text-red-400 mt-1">
                Peso inválido ({String(pesoDe(id))}): tiene que ser un número mayor o igual a 0. El 0 excluye la línea.
              </p>
            )}
          </div>
        )
      })}

      <div className="flex justify-between items-center text-sm pt-2 border-t dark:border-gray-600">
        <span className="text-gray-600 dark:text-gray-400">Suma repartida</span>
        <span className={`font-medium ${cuadra ? 'text-gray-800 dark:text-white' : 'text-red-600'}`}>
          {reparto === null ? '—' : formatPrecio(sumaRepartida)}
          <span className="text-gray-500 font-normal"> / {formatPrecio(cargo.monto)}</span>
        </span>
      </div>

      {hayInvalidos && (
        <p className="text-xs text-red-600 dark:text-red-400">
          Hay pesos inválidos: mientras estén así este cargo no se reparte.
        </p>
      )}
      {!hayInvalidos && totalPeso === 0 && (
        <p className="text-xs text-amber-700 dark:text-amber-300">
          ⚠ Todos los pesos están en 0: este cargo no se reparte a ninguna línea y no llega a ningún costo.
        </p>
      )}
      {!hayInvalidos && totalPeso > 0 && !cuadra && (
        <p className="text-xs text-red-600 dark:text-red-400">
          El reparto no suma el monto del cargo. Es un error de cálculo, no de carga: no registres la compra así.
        </p>
      )}
    </div>
  )
}

/**
 * Un cargo de la factura: concepto, monto y las tres decisiones fiscales.
 *
 * El signo vive en un toggle y no en el campo, porque NumberInput no deja
 * tipear el "-" (sanitiza a dígitos). Tipear -500 y que quede 500 en silencio
 * sería peor que pedir el gesto explícito.
 */
/**
 * Lo que el impuesto interno declarado tiene para decir sobre el casillero de
 * ESTE cargo.
 *
 * Desde el solver, `afectaBaseII` deja de ser una pregunta que el usuario no
 * puede contestar —lo decide el proveedor y la factura testigo demuestra que
 * trató dos bonificaciones del mismo comprobante de forma distinta— y pasa a ser
 * una respuesta que sale de la factura. Pero sigue siendo editable, así que la
 * leyenda tiene que decir de dónde salió el valor que se está viendo: deducido,
 * puesto a mano, o indeterminable.
 *
 * El caso que más importa es el tercero: un cargo que casi no mueve el impuesto
 * interno de ninguna alícuota no se puede deducir de ningún declarado, y decirlo
 * es mejor que dejar el casillero mudo al lado de otros que sí se resolvieron.
 */
function leyendaBaseII(
  cargo: CargoCompraForm,
  resolucion: ResultadoBasesII | null
): { texto: string; clase: string } | null {
  if (!resolucion || cargo.condicionIva !== 'gravado') return null
  if (resolucion.indeterminables.includes(cargo.id)) {
    return {
      texto: 'La factura no alcanza para deducirlo: este cargo casi no mueve el impuesto interno de ninguna alícuota.',
      clase: 'text-gray-500 dark:text-gray-400',
    }
  }
  if (resolucion.estado !== 'unica' || !resolucion.candidatos.includes(cargo.id)) return null
  const deducido = resolucion.soluciones[0].asignacion[cargo.id]
  if (!cargo.afectaBaseIIManual) {
    return {
      texto: 'Deducido del impuesto interno declarado en la factura. Cambialo si sabés que es otra cosa.',
      clase: 'text-green-700 dark:text-green-400',
    }
  }
  return deducido === cargo.afectaBaseII
    ? {
        texto: 'Lo marcaste vos, y es lo mismo que dice el impuesto interno declarado.',
        clase: 'text-gray-500 dark:text-gray-400',
      }
    : {
        texto: `Lo marcaste vos. Según el impuesto interno declarado, ${deducido ? 'sí' : 'no'} debería bajar la base — manda lo tuyo.`,
        clase: 'text-amber-700 dark:text-amber-300',
      }
}

function CargoRow({ cargo, items, dispatch, resolucion }: CargoRowProps) {
  // El signo es estado de la fila y no `cargo.monto < 0`: con monto en 0 el
  // toggle volvería solo a "Cargo" apenas se elige "Bonificación".
  const [esBonificacion, setEsBonificacion] = useState(cargo.monto < 0)
  const [mostrarPesos, setMostrarPesos] = useState(false)
  const set = (cambios: CambiosCargo) =>
    dispatch({ type: 'ACTUALIZAR_CARGO', payload: { id: cargo.id, cambios } })

  const cambiarSigno = (bonificacion: boolean) => {
    setEsBonificacion(bonificacion)
    const magnitud = Math.abs(cargo.monto)
    set({ monto: bonificacion ? -magnitud : magnitud })
  }

  const baseElegida = BASES_PRORRATEO.find(b => b.value === cargo.baseProrrateo)
  const leyenda = leyendaBaseII(cargo, resolucion)

  return (
    <div className="bg-white dark:bg-gray-800 p-3 rounded-lg border dark:border-gray-600 space-y-3">
      <div className="flex items-start gap-2">
        <div className="flex-1 min-w-0">
          <label className="block text-xs text-gray-500 mb-1">Concepto</label>
          <input
            type="text"
            value={cargo.concepto}
            onChange={(e: ChangeEvent<HTMLInputElement>) => set({ concepto: e.target.value })}
            placeholder="Flete, pallets, separadores, bonificación..."
            className="w-full px-3 py-1.5 text-sm border dark:border-gray-600 rounded focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
          />
        </div>
        <button
          type="button"
          onClick={() => dispatch({ type: 'ELIMINAR_CARGO', payload: cargo.id })}
          className="mt-5 p-1 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded shrink-0"
          title="Quitar este cargo"
        >
          <Trash2 className="w-4 h-4" />
        </button>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
        <div>
          <label className="block text-xs text-gray-500 mb-1">Monto (sin IVA)</label>
          <div className="flex gap-1">
            <div className="flex rounded overflow-hidden border dark:border-gray-600 shrink-0">
              {([false, true] as const).map(bonif => (
                <button
                  key={String(bonif)}
                  type="button"
                  onClick={() => cambiarSigno(bonif)}
                  title={bonif ? 'Resta del costo (bonificación)' : 'Suma al costo'}
                  className={`px-2 py-1.5 text-sm font-medium transition-colors ${
                    esBonificacion === bonif
                      ? 'bg-green-600 text-white'
                      : 'bg-gray-100 text-gray-600 hover:bg-gray-200 dark:bg-gray-700 dark:text-gray-300 dark:hover:bg-gray-600'
                  }`}
                >
                  {bonif ? '−' : '+'}
                </button>
              ))}
            </div>
            <NumberInput
              min={0}
              emptyValue={0}
              value={Math.abs(cargo.monto)}
              onChange={(n) => set({ monto: esBonificacion ? -Math.abs(n) : Math.abs(n) })}
              commitOnChange
              placeholder="0.00"
              className="w-full px-2 py-1.5 text-right text-sm border dark:border-gray-600 rounded focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
            />
          </div>
        </div>

        <div>
          <label className="block text-xs text-gray-500 mb-1" title="Un cargo gravado tributa a la alícuota de las líneas donde cae: no lleva alícuota propia.">
            Tratamiento frente al IVA
          </label>
          <select
            value={cargo.condicionIva}
            onChange={(e: ChangeEvent<HTMLSelectElement>) => set({ condicionIva: e.target.value as CondicionIva })}
            className="w-full px-2 py-1.5 text-sm border dark:border-gray-600 rounded focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
          >
            {OPCIONES_CONDICION_SIN_ALICUOTA.map(o => (
              <option key={o.condicion} value={o.condicion}>{o.label}</option>
            ))}
          </select>
        </div>

        <div>
          <label className="block text-xs text-gray-500 mb-1">Base de reparto</label>
          <select
            value={cargo.baseProrrateo}
            onChange={(e: ChangeEvent<HTMLSelectElement>) => set({ baseProrrateo: e.target.value as BaseProrrateo })}
            title={baseElegida?.ayuda}
            className="w-full px-2 py-1.5 text-sm border dark:border-gray-600 rounded focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
          >
            {BASES_PRORRATEO.map(b => (
              <option key={b.value} value={b.value}>{b.label}</option>
            ))}
          </select>
        </div>
      </div>

      {/* Las dos casillas son independientes: el flete de un tercero entra al
          costo pero no está en el papel; un redondeo de factura, al revés. */}
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
        <label className="flex items-start gap-2 cursor-pointer">
          <input
            type="checkbox"
            checked={cargo.enFactura}
            onChange={(e: ChangeEvent<HTMLInputElement>) => set({ enFactura: e.target.checked })}
            className="mt-0.5 w-4 h-4 rounded border-gray-300 text-green-600 focus:ring-green-500"
          />
          <span className="text-sm dark:text-gray-200">
            Viene en la factura
            <span className="block text-xs text-gray-500 dark:text-gray-400">
              Está impreso en el comprobante y suma al cuadre contra el papel.
            </span>
          </span>
        </label>
        <label className="flex items-start gap-2 cursor-pointer">
          <input
            type="checkbox"
            checked={cargo.prorrateaAlCosto}
            onChange={(e: ChangeEvent<HTMLInputElement>) => set({ prorrateaAlCosto: e.target.checked })}
            className="mt-0.5 w-4 h-4 rounded border-gray-300 text-green-600 focus:ring-green-500"
          />
          <span className="text-sm dark:text-gray-200">
            Entra al costo
            <span className="block text-xs text-gray-500 dark:text-gray-400">
              Se prorratea al costo unitario de los productos.
            </span>
          </span>
        </label>
      </div>

      {/* Sólo para un cargo gravado: el motor lo lee como `gravado &&
          afectaBaseII`, así que ofrecerlo en exento o no gravado prometería un
          efecto que no ocurre. Al salir de "gravado" el reducer lo apaga. */}
      {cargo.condicionIva === 'gravado' && (
        <label className="flex items-start gap-2 cursor-pointer">
          <input
            type="checkbox"
            checked={cargo.afectaBaseII}
            onChange={(e: ChangeEvent<HTMLInputElement>) => set({ afectaBaseII: e.target.checked })}
            className="mt-0.5 w-4 h-4 rounded border-gray-300 text-green-600 focus:ring-green-500"
          />
          <span className="text-sm dark:text-gray-200">
            Afecta la base de impuestos internos
            <span className="block text-xs text-gray-500 dark:text-gray-400">
              Un descuento de precio baja la base; una bonificación comercial no.
            </span>
            {leyenda && <span className={`block text-xs ${leyenda.clase}`}>{leyenda.texto}</span>}
          </span>
        </label>
      )}

      <div className="pt-2 border-t dark:border-gray-700">
        <button
          type="button"
          onClick={() => setMostrarPesos(v => !v)}
          className="text-sm text-blue-600 hover:underline"
        >
          {mostrarPesos
            ? 'Ocultar reparto'
            : `Ver reparto entre ${items.length} ${items.length === 1 ? 'línea' : 'líneas'} ▸`}
        </button>
        {mostrarPesos && <GrillaPesos cargo={cargo} items={items} dispatch={dispatch} />}
      </div>
    </div>
  )
}

/**
 * Sección "Cargos y prorrateo": el flete, los pallets y los separadores que hoy
 * no se cargan en ningún lado y son el 16,2% del costo.
 *
 * Plegada por defecto: el promedio es 4,1 ítems por compra y la compra chica no
 * tiene por qué ver esto. Va también en ZZ —el 47,9% de las compras—: el tipo de
 * comprobante decide si se agregan impuestos encima, no si se ignoran costos.
 */
function CargosSection({ state, dispatch, plantilla, resolucion }: CargosSectionProps) {
  const [abierta, setAbierta] = useState(false)
  const { cargos } = state
  const totalAlCosto = cargos.filter(c => c.prorrateaAlCosto).reduce((acc, c) => acc + c.monto, 0)
  const totalEnFactura = cargos.filter(c => c.enFactura).reduce((acc, c) => acc + c.monto, 0)
  // Los de la plantilla que faltan, con el MISMO criterio que usa el reducer al
  // aplicarla: lo que dice el botón es exactamente lo que va a pasar.
  const deLaPlantilla = plantilla?.cargos ?? []
  const paraTraer = cargosPlantillaNuevos(cargos, deLaPlantilla)
  const facturaPlantilla = plantilla?.numeroFactura ? `factura ${plantilla.numeroFactura}` : 'la última compra'

  return (
    <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-3 sm:p-4">
      <button
        type="button"
        onClick={() => setAbierta(v => !v)}
        className="w-full flex items-center justify-between gap-2 text-left"
      >
        <div className="flex items-center gap-2 min-w-0">
          {abierta
            ? <ChevronDown className="w-4 h-4 text-gray-500 shrink-0" />
            : <ChevronRight className="w-4 h-4 text-gray-500 shrink-0" />}
          <Truck className="w-5 h-5 text-gray-500 shrink-0" />
          <h3 className="font-medium text-gray-800 dark:text-white truncate">Cargos y prorrateo</h3>
          {cargos.length > 0 && (
            <span className="px-1.5 py-0.5 text-xs rounded bg-green-100 text-green-700 dark:bg-green-900/40 dark:text-green-300 shrink-0">
              {cargos.length}
            </span>
          )}
        </div>
        {!abierta && (
          <span className="text-xs text-gray-500 text-right shrink-0">
            {cargos.length === 0
              ? 'Flete, pallets, bonificaciones'
              : `${formatPrecio(totalAlCosto)} al costo`}
          </span>
        )}
      </button>

      {abierta && (
        <div className="mt-3 space-y-3">
          {cargos.length === 0 ? (
            <p className="text-sm text-gray-500">
              Conceptos de la factura que no son renglones de producto: flete, pallets,
              separadores, bonificaciones. Se reparten entre las líneas y entran al costo.
            </p>
          ) : (
            cargos.map(cargo => (
              <CargoRow key={cargo.id} cargo={cargo} items={state.items} dispatch={dispatch}
                        resolucion={resolucion} />
            ))
          )}

          <div className="flex flex-wrap items-center gap-2">
            <button
              type="button"
              onClick={() => dispatch({ type: 'AGREGAR_CARGO' })}
              className="flex items-center gap-1 px-3 py-1.5 bg-green-600 text-white rounded hover:bg-green-700 text-sm transition-colors"
            >
              <Plus className="w-4 h-4" /> Agregar cargo
            </button>

            {/* Plantilla del proveedor: el flete y los pallets de Manaos son los
                mismos todos los meses y el reparto a mano no es sostenible. Se
                traen los conceptos, las banderas y los pesos; el monto queda en
                0 porque es lo único que cambia factura a factura. */}
            {paraTraer.length > 0 && (
              <button
                type="button"
                onClick={() => dispatch({ type: 'APLICAR_CARGOS_PLANTILLA', payload: deLaPlantilla })}
                title={`Trae ${paraTraer.map(c => c.concepto).join(', ')} de ${facturaPlantilla}, con sus pesos y el monto en 0`}
                className="flex items-center gap-1 px-3 py-1.5 border border-green-600 text-green-700 dark:text-green-400 rounded hover:bg-green-50 dark:hover:bg-green-900/30 text-sm transition-colors"
              >
                <Copy className="w-4 h-4" /> Traer cargos de la última compra de este proveedor
              </button>
            )}
          </div>

          {deLaPlantilla.length > 0 && paraTraer.length === 0 && (
            <p className="text-xs text-gray-500">
              Los cargos de {facturaPlantilla} ({deLaPlantilla.map(c => c.concepto).join(', ')}) ya están cargados.
            </p>
          )}

          {cargos.length > 0 && (
            <div className="pt-2 border-t dark:border-gray-700 space-y-1 text-sm">
              <div className="flex justify-between">
                <span className="text-gray-600 dark:text-gray-400">En la factura:</span>
                <span className="font-medium text-gray-800 dark:text-white">{formatPrecio(totalEnFactura)}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-gray-600 dark:text-gray-400">Al costo de los productos:</span>
                <span className="font-medium text-gray-800 dark:text-white">{formatPrecio(totalAlCosto)}</span>
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  )
}

/**
 * Vista previa del costo de cada producto: las cuatro columnas que hoy el
 * gerente lee del Excel (base IVA, impuesto interno, no gravado, IVA) más el
 * costo unitario final, y abajo el costo puesto en depósito.
 *
 * La alimenta `calcularCostosCompra`, que es el espejo TS de la mig 193: lo que
 * se ve acá es lo que va a calcular la base al registrar.
 *
 * `calcularCostosCompra` lanza ante una cantidad o un peso corrupto —el mismo
 * criterio que `prorratearCargo`, y por la misma razón— así que la llamada va
 * envuelta: un dato podrido muestra el error acá adentro y no deja el modal en
 * blanco.
 */
function VistaPreviaCostosSection({ state }: VistaPreviaCostosProps) {
  const [abierta, setAbierta] = useState(false)

  const esZZ = state.tipoFactura === 'ZZ'
  const lineas = lineasParaMotor(state.items, state.tipoFactura)
  const cargos = cargosParaMotor(state.cargos)
  const iiDeclarado = iiDeclaradoParaMotor(state.iiDeclarado, state.tipoFactura)

  const calculo = ((): { ok: true; costos: CostosCompra } | { ok: false; error: string } => {
    try {
      return { ok: true, costos: calcularCostosCompra(lineas, cargos, iiDeclarado) }
    } catch (err) {
      return { ok: false, error: err instanceof Error ? err.message : 'No se pudo calcular el costo' }
    }
  })()

  const porLinea = calculo.ok
    ? new Map(calculo.costos.lineas.map(l => [l.id, l]))
    : new Map<number, CostosCompra['lineas'][number]>()
  const costoEnDeposito = calculo.ok
    ? calculo.costos.lineas.reduce((acc, l) => {
        const item = state.items.find(i => i.lineaId === l.id)
        return acc + l.costoRealUnitario * (item?.cantidad || 0)
      }, 0)
    : 0

  // Factores de ajuste realmente aplicados (los que no son 1). Es lo único que
  // hace falta decir acá: el que los carga es el panel de control.
  const ajustesII = calculo.ok
    ? Object.entries(calculo.costos.factorAjuste)
        .filter(([, factor]) => redondearSQL(factor, 4) !== 1)
        .map(([tasa, factor]) => `${tasa}% ×${redondearSQL(factor, 4)}`)
    : []

  const celda = (valor: number | undefined) => (valor === undefined ? '—' : formatPrecio(valor))

  return (
    <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-3 sm:p-4">
      <button
        type="button"
        onClick={() => setAbierta(v => !v)}
        className="w-full flex items-center justify-between gap-2 text-left"
      >
        <div className="flex items-center gap-2 min-w-0">
          {abierta
            ? <ChevronDown className="w-4 h-4 text-gray-500 shrink-0" />
            : <ChevronRight className="w-4 h-4 text-gray-500 shrink-0" />}
          <Calculator className="w-5 h-5 text-gray-500 shrink-0" />
          <h3 className="font-medium text-gray-800 dark:text-white truncate">Costo por producto</h3>
        </div>
        {!abierta && (
          <span className="text-xs text-gray-500 text-right shrink-0">
            {calculo.ok ? `${formatPrecio(costoEnDeposito)} en depósito` : 'no se pudo calcular'}
          </span>
        )}
      </button>

      {abierta && (
        <div className="mt-3 space-y-3">
          {!calculo.ok ? (
            <div className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg flex items-start gap-2">
              <AlertTriangle className="w-4 h-4 text-red-500 mt-0.5 shrink-0" />
              <p className="text-sm text-red-600 dark:text-red-400">{calculo.error}</p>
            </div>
          ) : (
            <>
              {/* La apertura del II se carga en "Control contra factura", que es
                  donde se cuadra contra el papel; acá sólo se avisa que el
                  ajuste está aplicado, porque mueve la columna de al lado. */}
              {ajustesII.length > 0 && (
                <p className="text-xs text-blue-700 dark:text-blue-300">
                  Impuesto interno ajustado al declarado en la factura ({ajustesII.join(', ')}).
                  El campo está en "Control contra factura".
                </p>
              )}

              {/* Header solo en desktop */}
              <div className="hidden md:grid grid-cols-12 gap-2 text-xs font-medium text-gray-500 uppercase px-2">
                <div className="col-span-2">Producto</div>
                <div className="col-span-2 text-right">Base IVA</div>
                <div className="col-span-2 text-right">Imp. int.</div>
                <div className="col-span-2 text-right">No grav.</div>
                <div className="col-span-2 text-right">IVA</div>
                <div className="col-span-2 text-right">Costo unit.</div>
              </div>

              <div className="space-y-2">
                {state.items.map((item, index) => {
                  const c = item.lineaId === undefined ? undefined : porLinea.get(item.lineaId)
                  return (
                    <div key={item.lineaId ?? index} className="bg-white dark:bg-gray-800 rounded px-2 py-2 border dark:border-gray-600">
                      {/* Mobile: apilado */}
                      <div className="md:hidden space-y-1">
                        <p className="text-sm font-medium text-gray-800 dark:text-white">{item.productoNombre}</p>
                        <div className="grid grid-cols-2 gap-x-3 gap-y-0.5 text-xs">
                          <span className="text-gray-500">Base IVA</span>
                          <span className="text-right dark:text-gray-200">{celda(c?.baseIvaUnitaria)}</span>
                          <span className="text-gray-500">Imp. interno</span>
                          <span className="text-right dark:text-gray-200">{celda(c?.iiUnitario)}</span>
                          <span className="text-gray-500">No gravado</span>
                          <span className="text-right dark:text-gray-200">{celda(c?.cargosUnitarios)}</span>
                          <span className="text-gray-500">IVA</span>
                          <span className="text-right dark:text-gray-200">{celda(c?.ivaUnitario)}</span>
                        </div>
                        <div className="flex justify-between items-center pt-1 border-t dark:border-gray-600">
                          <span className="text-xs text-gray-500">Costo unitario</span>
                          <span className="text-sm font-semibold text-gray-800 dark:text-white">{celda(c?.costoRealUnitario)}</span>
                        </div>
                      </div>

                      {/* Desktop: grilla */}
                      <div className="hidden md:grid grid-cols-12 gap-2 items-center text-xs">
                        <p className="col-span-2 text-gray-800 dark:text-white truncate" title={item.productoNombre}>
                          {item.productoNombre}
                        </p>
                        <span className="col-span-2 text-right dark:text-gray-200">{celda(c?.baseIvaUnitaria)}</span>
                        <span className="col-span-2 text-right dark:text-gray-200">{celda(c?.iiUnitario)}</span>
                        <span className="col-span-2 text-right dark:text-gray-200">{celda(c?.cargosUnitarios)}</span>
                        <span className="col-span-2 text-right dark:text-gray-200">{celda(c?.ivaUnitario)}</span>
                        <span className="col-span-2 text-right font-semibold text-gray-800 dark:text-white">{celda(c?.costoRealUnitario)}</span>
                      </div>
                    </div>
                  )
                })}
              </div>

              <p className="text-xs text-gray-500">
                Todos los importes son por unidad.
                {esZZ && ' En ZZ lo pagado ya incluye IVA e impuestos internos: por eso las dos columnas van en cero y el cargo suma igual.'}
              </p>

              <div className="flex justify-between items-center pt-2 border-t dark:border-gray-600">
                <span className="font-medium text-gray-800 dark:text-white">Costo puesto en depósito</span>
                <span className="text-lg font-bold text-green-600">{formatPrecio(costoEnDeposito)}</span>
              </div>
              <p className="text-xs text-gray-500">
                Neto + impuestos internos + los cargos que entran al costo. El IVA queda afuera:
                es crédito fiscal, no costo.
              </p>
            </>
          )}
        </div>
      )}
    </div>
  )
}

/** Fila del panel de control: calculado vs impreso en la factura */
function ControlRow({ label, calculado, impreso, onChange }: {
  label: string;
  calculado: number;
  impreso: number;
  onChange: (n: number) => void;
}) {
  const cargado = impreso > 0
  const diff = impreso - calculado
  const ok = Math.abs(diff) <= 1
  return (
    <div className="grid grid-cols-12 gap-2 items-center text-sm">
      <span className="col-span-4 text-gray-600 dark:text-gray-400">{label}</span>
      <span className="col-span-3 text-right text-gray-800 dark:text-white">{formatPrecio(calculado)}</span>
      <div className="col-span-3">
        <NumberInput
          min={0}
          emptyValue={0}
          value={impreso}
          onChange={onChange}
          commitOnChange
          className="w-full px-2 py-1 text-right border dark:border-gray-600 rounded dark:bg-gray-700 dark:text-white text-sm"
          placeholder="factura"
        />
      </div>
      <span className={`col-span-2 text-right text-xs font-medium ${!cargado ? 'text-gray-400' : ok ? 'text-green-600' : 'text-red-600'}`}>
        {!cargado ? '—' : ok ? '✓' : formatPrecio(diff)}
      </span>
    </div>
  )
}

function ResumenSection({ totales, state, dispatch, resolucion }: ResumenSectionProps) {
  const { subtotalBruto, bonificacionTotal, subtotal, bonificaciones, netoGravado, netoExento,
          netoNoGravado, netoPorAlicuota, iva, impuestosInternos, percepcionIva, percepcionIibb,
          noGravado, total } = totales
  const esFC = state.tipoFactura === 'FC'
  const [bonifGlobal, setBonifGlobal] = useState(0)
  const [mostrarControl, setMostrarControl] = useState(false)
  const ctrl = state.controlFactura
  const percepcionesCalc = percepcionIva + percepcionIibb
  const cuadreII = cuadreImpuestoInterno(state.items, state.cargos, state.iiDeclarado, state.tipoFactura)
  // Los cargos que pre-llenan el "No gravado" de cabecera, para poder nombrarlos.
  const cargosNoGravados = cargosNoGravadosEnFactura(state.cargos)
  const noGravadoCargos = noGravadoDeCargos(state.cargos)

  // ── Lo que el impuesto interno declarado permite deducir ───────────────────
  // El ajuste que se está aplicando HOY, alícuota por alícuota. Es lo que hay
  // que nombrar cuando la deducción no sale: el usuario tiene que saber que
  // está viendo una aproximación y no un cálculo.
  const ajusteII = (cuadreII ?? [])
    .filter(c => c.declarado !== undefined && Math.abs(c.desvio) > 1e-9)
    .map(c => `${redondearSQL(c.desvio * 100, 2)}% al ${c.tasa}%`)
    .join(' y ')
  const nombreCargo = (id: number) =>
    state.cargos.find(c => c.id === id)?.concepto.trim() || '(sin concepto)'
  const deduccion = resolucion?.estado === 'unica' ? resolucion.soluciones[0].asignacion : null
  const porQueNo =
    resolucion?.estado === 'ambigua'
      ? 'Hay más de una combinación que llega al mismo número, así que la factura no alcanza para elegir.'
      : resolucion?.estado === 'sin_solucion'
        ? 'Ninguna combinación llega a lo declarado: puede faltar un cargo, o estar mal cargada una alícuota.'
        : resolucion?.estado === 'demasiadas_hipotesis'
          ? 'Hay demasiadas bonificaciones gravadas para probarlas todas sin arriesgar una coincidencia.'
          : ''

  return (
    <div className="bg-green-50 dark:bg-green-900/20 rounded-lg p-4 space-y-4">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Calculator className="w-5 h-5 text-green-600" />
          <h3 className="font-medium text-gray-800 dark:text-white">Resumen</h3>
        </div>
        {/* Bonificación global (ej: 0,60% de Refres Now) aplicada a todas las líneas */}
        <div className="flex items-center gap-1.5">
          <span className="text-xs text-gray-500">Bonif. global %</span>
          <NumberInput
            min={0}
            max={100}
            emptyValue={0}
            value={bonifGlobal}
            onChange={setBonifGlobal}
            commitOnChange
            className="w-16 px-2 py-1 text-center border dark:border-gray-600 rounded dark:bg-gray-700 dark:text-white text-sm"
          />
          <button
            type="button"
            onClick={() => dispatch({ type: 'APLICAR_BONIF_GLOBAL', payload: bonifGlobal })}
            className="px-2 py-1 text-xs bg-green-600 text-white rounded hover:bg-green-700"
          >
            Aplicar
          </button>
        </div>
      </div>

      {esFC && (
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
          <div>
            <label className="block text-xs text-gray-500 mb-1">
              Percepción IVA
              <button
                type="button"
                onClick={() => dispatch({ type: 'SET_EXTRAS', payload: { percepcionIva: Math.round(subtotal * 3) / 100 } })}
                className="ml-2 text-blue-600 hover:underline"
                title="RG 5329: 3% sobre el gravado"
              >
                3% del gravado
              </button>
            </label>
            <NumberInput
              min={0}
              emptyValue={0}
              value={state.percepcionIva}
              onChange={(n) => dispatch({ type: 'SET_EXTRAS', payload: { percepcionIva: n } })}
              commitOnChange
              className="w-full px-2 py-1.5 border dark:border-gray-600 rounded dark:bg-gray-700 dark:text-white text-sm"
            />
          </div>
          <div>
            <label className="block text-xs text-gray-500 mb-1">Percepción IIBB</label>
            <NumberInput
              min={0}
              emptyValue={0}
              value={state.percepcionIibb}
              onChange={(n) => dispatch({ type: 'SET_EXTRAS', payload: { percepcionIibb: n } })}
              commitOnChange
              className="w-full px-2 py-1.5 border dark:border-gray-600 rounded dark:bg-gray-700 dark:text-white text-sm"
            />
          </div>
          <div>
            <label className="block text-xs text-gray-500 mb-1" title="Conceptos fuera del IVA (ej: pallets/separadores valorizados)">
              No gravado
              {/* La vuelta al automático, que si no un número tipeado queda
                  clavado para siempre. Mismo gesto explícito que re-elegir la
                  base de reparto de un cargo. */}
              {state.noGravadoManual && noGravadoCargos !== state.noGravado && (
                <button
                  type="button"
                  onClick={() => dispatch({ type: 'USAR_NO_GRAVADO_DE_CARGOS' })}
                  className="ml-2 text-blue-600 hover:underline"
                  title="Volver a la suma de los cargos no gravados que vienen en la factura"
                >
                  usar los cargos ({formatPrecio(noGravadoCargos)})
                </button>
              )}
            </label>
            <NumberInput
              min={0}
              emptyValue={0}
              value={state.noGravado}
              onChange={(n) => dispatch({ type: 'SET_EXTRAS', payload: { noGravado: n } })}
              commitOnChange
              className="w-full px-2 py-1.5 border dark:border-gray-600 rounded dark:bg-gray-700 dark:text-white text-sm"
            />
            {/* De dónde sale el número. Sin esto el campo parece pedir un dato
                que el modal ya tiene cargado tres secciones más arriba. */}
            <p className="mt-1 text-[11px] leading-tight text-gray-500">
              {state.noGravadoManual
                ? `Tipeado a mano.${cargosNoGravados.length > 0 ? ` Los cargos no gravados de la factura suman ${formatPrecio(noGravadoCargos)}.` : ''}`
                : cargosNoGravados.length > 0
                  ? `Sale de los cargos no gravados de la factura: ${cargosNoGravados.map(c => c.concepto.trim() || 'sin concepto').join(', ')}.`
                  : 'Se completa solo con los cargos no gravados que vengan en la factura.'}
            </p>
          </div>
        </div>
      )}

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
          <span className="text-gray-600 dark:text-gray-400">{esFC ? 'Gravado (neto):' : 'Subtotal Neto:'}</span>
          <span className="font-medium text-gray-800 dark:text-white">{formatPrecio(esFC ? netoGravado : subtotal)}</span>
        </div>
        {/* Sub-fila y no una fila propia: el gravado de arriba YA tiene la
            bonificación restada. Se muestra porque es la diferencia entre el
            neto de los renglones y lo que la factura llama gravado, y hasta la
            mig 195 no estaba en ningún lado —el total quedaba 306.784,09 arriba
            del papel en la factura testigo—. */}
        {esFC && bonificaciones !== 0 && (
          <div className="flex justify-between text-xs text-orange-600 dark:text-orange-400 pl-3">
            <span>└ incluye bonificaciones de la factura:</span>
            <span className="font-medium">{formatPrecio(bonificaciones)}</span>
          </div>
        )}
        {/* Con condiciones mezcladas el "gravado" solo ya no explica el total */}
        {esFC && netoExento > 0 && (
          <div className="flex justify-between text-sm">
            <span className="text-gray-600 dark:text-gray-400">Exento (neto):</span>
            <span className="font-medium text-gray-800 dark:text-white">{formatPrecio(netoExento)}</span>
          </div>
        )}
        {esFC && netoNoGravado > 0 && (
          <div className="flex justify-between text-sm">
            <span className="text-gray-600 dark:text-gray-400">No gravado (líneas):</span>
            <span className="font-medium text-gray-800 dark:text-white">{formatPrecio(netoNoGravado)}</span>
          </div>
        )}
        {esFC && (
          <div className="flex justify-between text-sm">
            <span className="text-gray-600 dark:text-gray-400">
              IVA (sobre neto{Object.keys(netoPorAlicuota).length > 1
                ? `, ${Object.keys(netoPorAlicuota).join('% + ')}%`
                : ''}):
            </span>
            <span className="font-medium text-gray-800 dark:text-white">{formatPrecio(iva)}</span>
          </div>
        )}
        {impuestosInternos > 0 && (
          <div className="flex justify-between text-sm">
            <span className="text-gray-600 dark:text-gray-400">Impuestos Internos:</span>
            <span className="font-medium text-gray-800 dark:text-white">{formatPrecio(impuestosInternos)}</span>
          </div>
        )}
        {percepcionesCalc > 0 && (
          <div className="flex justify-between text-sm">
            <span className="text-gray-600 dark:text-gray-400">Percepciones (IVA + IIBB):</span>
            <span className="font-medium text-gray-800 dark:text-white">{formatPrecio(percepcionesCalc)}</span>
          </div>
        )}
        {noGravado > 0 && (
          <div className="flex justify-between text-sm">
            <span className="text-gray-600 dark:text-gray-400">No gravado (cabecera):</span>
            <span className="font-medium text-gray-800 dark:text-white">{formatPrecio(noGravado)}</span>
          </div>
        )}
        <div className="flex justify-between text-lg font-bold pt-2 border-t dark:border-gray-600">
          <span className="text-gray-800 dark:text-white">Total:</span>
          <span className="text-green-600">{formatPrecio(total)}</span>
        </div>
      </div>

      {/* Control contra factura: reemplaza las columnas "control" del Excel */}
      {esFC && (
        <div className="pt-2 border-t dark:border-gray-700">
          <button
            type="button"
            onClick={() => setMostrarControl(v => !v)}
            className="text-sm text-blue-600 hover:underline"
          >
            {mostrarControl ? 'Ocultar control contra factura' : 'Control contra factura ▸'}
          </button>
          {mostrarControl && (
            <div className="mt-2 space-y-1.5">
              <div className="grid grid-cols-12 gap-2 text-xs text-gray-500">
                <span className="col-span-4">Concepto</span>
                <span className="col-span-3 text-right">Calculado</span>
                <span className="col-span-3 text-right">Factura dice</span>
                <span className="col-span-2 text-right">Dif.</span>
              </div>
              <ControlRow label="Gravado" calculado={netoGravado} impreso={ctrl.gravado}
                onChange={(n) => dispatch({ type: 'SET_CONTROL', payload: { gravado: n } })} />
              {/* Solo informativos: la factura los imprime abiertos y sin esto
                  no se puede cuadrar una mixta contra el papel. */}
              {Object.entries(netoPorAlicuota)
                .filter(() => Object.keys(netoPorAlicuota).length > 1)
                .map(([alicuota, neto]) => (
                  <div key={alicuota} className="grid grid-cols-12 gap-2 text-xs text-gray-500 pl-3">
                    <span className="col-span-4">└ neto al {alicuota}%</span>
                    <span className="col-span-3 text-right">{formatPrecio(neto)}</span>
                    <span className="col-span-5 text-right">IVA {formatPrecio(neto * parseFloat(alicuota) / 100)}</span>
                  </div>
                ))}
              {netoExento > 0 && (
                <div className="grid grid-cols-12 gap-2 text-xs text-gray-500 pl-3">
                  <span className="col-span-4">└ exento</span>
                  <span className="col-span-3 text-right">{formatPrecio(netoExento)}</span>
                  <span className="col-span-5"></span>
                </div>
              )}
              {netoNoGravado > 0 && (
                <div className="grid grid-cols-12 gap-2 text-xs text-gray-500 pl-3">
                  <span className="col-span-4">└ no gravado (líneas)</span>
                  <span className="col-span-3 text-right">{formatPrecio(netoNoGravado)}</span>
                  <span className="col-span-5"></span>
                </div>
              )}
              <ControlRow label="IVA" calculado={iva} impreso={ctrl.iva}
                onChange={(n) => dispatch({ type: 'SET_CONTROL', payload: { iva: n } })} />
              <ControlRow label="Imp. internos" calculado={impuestosInternos} impreso={ctrl.impuestosInternos}
                onChange={(n) => dispatch({ type: 'SET_CONTROL', payload: { impuestosInternos: n } })} />
              {/* Apertura del II POR ALÍCUOTA. La factura lo trae abierto y casi
                  nunca coincide al peso con el calculado: el gerente hoy corrige
                  esa diferencia a mano en un Excel, con un factor de 1,0496. Acá
                  ese número se carga una vez y viaja a la base, que es la única
                  forma de que el costo guardado lo tenga.
                  Las alícuotas salen de las líneas, no de una lista fija. */}
              {cuadreII === null ? (
                <p className="text-xs text-red-600 dark:text-red-400 pl-3">
                  No se pudo abrir el impuesto interno por alícuota (ver "Costo por producto").
                </p>
              ) : cuadreII.map(c => (
                <div key={c.tasa} className="grid grid-cols-12 gap-2 items-center text-xs">
                  <span className="col-span-4 text-gray-500 pl-3">└ declarado al {c.tasa}%</span>
                  <span className="col-span-3 text-right text-gray-500">{formatPrecio(c.calculado)}</span>
                  <div className="col-span-3">
                    <NumberInput
                      min={0}
                      emptyValue={0}
                      value={c.declarado ?? 0}
                      onChange={(n) => dispatch({ type: 'SET_II_DECLARADO', payload: { tasa: c.tasa, monto: n } })}
                      commitOnChange
                      placeholder="factura"
                      title="Lo que la factura declara de impuesto interno para esta alícuota"
                      className="w-full px-2 py-1 text-right border dark:border-gray-600 rounded dark:bg-gray-700 dark:text-white text-xs"
                    />
                  </div>
                  <span className={`col-span-2 text-right font-medium ${
                    c.declarado === undefined ? 'text-gray-400'
                      : Math.abs(c.desvio) > DESVIO_II_TOLERADO ? 'text-amber-600' : 'text-green-600'
                  }`}>
                    {c.declarado === undefined ? '—' : `×${redondearSQL(c.factor, 4)}`}
                  </span>
                </div>
              ))}
              {/* LA DEDUCCIÓN. El casillero "afecta la base de impuestos
                  internos" no lo puede contestar el que carga la factura: lo
                  decide el proveedor, y la testigo demuestra que trató las dos
                  bonificaciones del MISMO comprobante de forma distinta. Pero la
                  factura declara el impuesto interno POR ALÍCUOTA, y eso es una
                  ecuación: con las dos bonificaciones reales hay 4 combinaciones
                  y una sola cierra —a 6 centavos sobre 338.884—. */}
              {resolucion && resolucion.candidatos.length > 0 && (
                deduccion ? (
                  <p className="text-xs text-green-700 dark:text-green-400 pl-3">
                    ✓ El impuesto interno declarado determina las bonificaciones:{' '}
                    {resolucion.candidatos
                      .map(id => `"${nombreCargo(id)}" ${deduccion[id] ? 'baja' : 'no baja'} la base`)
                      .join('; ')}
                    . Quedó marcado así en "Cargos y prorrateo"; si sabés que está mal, cambialo ahí.
                  </p>
                ) : ajusteII ? (
                  <p className="text-xs text-amber-700 dark:text-amber-300 pl-3">
                    No pude determinar qué bonificaciones bajan la base. Apliqué un ajuste
                    del {ajusteII}. {porQueNo} Ese ajuste reparte el impuesto interno de la
                    bonificación entre TODOS los productos de la alícuota, incluso los que no
                    estuvieron en la promoción: a ésos les carga de más y a los de la promoción,
                    de menos. Es una aproximación — si sabés cuál bonificación es descuento de
                    precio, marcala a mano en "Cargos y prorrateo".
                  </p>
                ) : null
              )}
              {/* Aviso, no bloqueo: hay facturas con redondeos raros. */}
              {(cuadreII ?? [])
                .filter(c => Math.abs(c.desvio) > DESVIO_II_TOLERADO)
                .map(c => (
                  <p key={c.tasa} className="text-xs text-amber-700 dark:text-amber-300 pl-3">
                    ⚠ El impuesto interno declarado al {c.tasa}% difiere un {redondearSQL(c.desvio * 100, 2)}%
                    del calculado. Revisá si alguna bonificación no debería bajar la base, o si alguna
                    alícuota está mal cargada.
                  </p>
                ))}
              <ControlRow label="Percepciones" calculado={percepcionesCalc} impreso={ctrl.percepciones}
                onChange={(n) => dispatch({ type: 'SET_CONTROL', payload: { percepciones: n } })} />
              <ControlRow label="TOTAL" calculado={total} impreso={ctrl.total}
                onChange={(n) => dispatch({ type: 'SET_CONTROL', payload: { total: n } })} />
              <p className="text-xs text-gray-500 pt-1">
                Tipeá los totales impresos en la factura: si una diferencia no da ✓ (± $1), revisá
                bonificaciones, tasas de II del producto o el no gravado antes de registrar.
              </p>
            </div>
          )}
        </div>
      )}
    </div>
  )
}
