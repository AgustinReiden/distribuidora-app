/**
 * Modal para registrar compras a proveedores
 *
 * Refactorizado con useReducer para mejor gestión de estado
 * Validación con Zod
 */
import React, { useReducer, useMemo, useCallback, useState, useEffect, useRef, useId, Suspense, createContext, useContext } from 'react'
import type { ChangeEvent, FormEvent } from 'react'
import { X, ShoppingCart, Plus, Trash2, Package, Building2, FileText, Calculator, Search, Camera, CheckCircle, AlertTriangle, Truck, ChevronDown, ChevronRight, Copy, Save, RefreshCw } from 'lucide-react'
import { formatPrecio, fechaLocalISO } from '../../utils/formatters'
import { redondearSQL } from '../../utils/calculations'
import { OPCIONES_CONDICION_IVA, OPCIONES_CONDICION_SIN_ALICUOTA, claveCondicionIva, labelCondicionIva } from '../../utils/condicionIva'
import { prorratearCargo, calcularCostosCompra, calcularTotalesCompra } from '../../utils/prorrateoCompra'
import type { CostosCompra, TotalesCompra, ResultadoBasesII } from '../../utils/prorrateoCompra'
import NumberInput from '../ui/NumberInput'
import { Button } from '../ui/Button'
import { supabase, getSucursalHeader } from '../../lib/supabase'
import AuthDataContext from '../../contexts/AuthDataContext'
import { CONTENT_TYPE_POR_EXTENSION, extensionArchivoFactura, mapearFacturaV2, nuevoUuid, rutaEscaneoFactura } from '../../utils/escaneoFactura'
import { RespuestaEscaneoSchema } from './ModalCompra.escaneo'
// Del módulo y no del barrel: éste es un modal lazy y el barrel se lleva puesto
// todo el resto de los hooks de query al chunk.
import { useCargosPlantillaProveedorQuery, useComprasMismaFacturaQuery, useCostosAnterioresQuery } from '../../hooks/queries/useComprasQuery'
import type { CompraMismaFactura } from '../../hooks/queries/useComprasQuery'
// Ídem: del módulo (mig 292).
import { CANDIDATOS_VACIOS, useCandidatosEscaneoQuery } from '../../hooks/queries/useEscaneoQuery'
import type { CandidatosEscaneo } from '../../hooks/queries/useEscaneoQuery'
import { equivalenciasParaRegistrar, matchEscaneo, matchProveedor } from '../../utils/matchEscaneo'
import type { ResultadoMatchLinea } from '../../utils/matchEscaneo'
// Ídem: del módulo, por el mismo motivo (mig 278).
import { useCargoConceptosQuery, useCargoMedidasQuery, useProductoMedidasQuery } from '../../hooks/queries/useCargosCatalogoQuery'
import {
  conceptoPorNombre, fichaTieneValor, medidaEditable, medidasParaFicha, pluralMedida, resolverMedida,
  textoMedidaLinea, unidadesPorDesdeCantidadDeMedidas,
} from '../../utils/medidasCargo'
import type { ConceptoCargo, ContextoMedidas, MedidaCargo, MedidasPorProducto } from '../../utils/medidasCargo'
import { useBorradorCompra } from '../../hooks/useBorradorCompra'
import type { CambioEnOtraPestana } from '../../hooks/useBorradorCompra'
import { claveBorradorCompra, fechaHoraBorrador, lineasSinProductoVigente } from '../../utils/borradorCompra'
import type { LecturaBorrador } from '../../utils/borradorCompra'
import { fechaCortaCompra } from '../../utils/facturaDuplicada'
import type { CriterioFacturaDuplicada } from '../../utils/facturaDuplicada'
import { Combobox } from '../ui/Combobox'
import { useCatalogoIIQuery } from '../../hooks/queries/useImpuestosInternosQuery'
import { CompactErrorBoundary } from '../ErrorBoundary'
import type { CondicionIva, ProductoDB, ProveedorDBExtended, CompraFormInputExtended, PlantillaCargosProveedor, ProveedorFormInputExtended, CompraDBExtended, CompraItemDBExtended } from '../../types'
import { Badge } from '../ui/Badge'
import { toneDeEstadoCompra, ETIQUETA_ESTADO_COMPRA } from '../../lib/estadoTones'
import { formatearFechaVencimiento } from '../../utils/vencimientos'
import { hidratarCompraGuardada } from '../../utils/hidratarCompra'
import { costoEfectivoCompra } from '../../utils/notaCredito'
import { pesosDesactualizados } from '../../utils/pesosDesactualizados'
import {
  armarEdicionCompra, cargosLeidos, edicionCompraTieneCambios, totalesDeEdicion,
  validarEdicionCompra, vencimientosPorProducto as vencimientosDeLotes,
} from '../../utils/edicionCompra'
import type { ActualizarCompraItemsInput } from '../../hooks/queries/useComprasQuery'
import { variacionCosto, formatearVariacion, tooltipCostoAnterior } from '../../utils/costoAnterior'
import type { CostoAnterior } from '../../utils/costoAnterior'
import { lazyWithReload } from '../../utils/lazyWithReload';
import {
  compraReducer, initialState, construirCompraItemDesdeScan,
  lineasParaMotor, cargosParaMotor, iiDeclaradoParaMotor,
  cuadreImpuestoInterno, DESVIO_II_TOLERADO,
  cargosParaRPC, validarCargos, cargosNoGravadosEnFactura, noGravadoDeCargos,
  resolucionBasesII, validarMedidasCargos, lineasSinMedida, lineaEnAlcance,
  aplicaComprobanteTercero, ivaTerceroEfectivo, sugerenciasBonificacion, alicuotasIIExplicadas,
} from './ModalCompra.reducer'
import type { SugerenciaBonificacion } from '../../utils/detectarBonificacionNoDescontada'
import type {
  CompraItemForm, CargoCompraForm, CambiosCargo, BaseProrrateo,
  FacturaEscaneada, ItemPendienteScan, CompraState, CompraActionType,
  VencimientoLinea,
} from './ModalCompra.reducer'
import VencimientosLineaCompra from '../vencimientos/VencimientosLineaCompra'
import { validarVencimientosLineas } from '../../utils/vencimientos'
import { compraTieneCambios } from '../../utils/compraTieneCambios'
import ModalBase from './ModalBase'
import SelectorConAlta from '../productos/SelectorConAlta'
import type { OpcionCatalogo } from '../productos/SelectorConAlta'
import type { CategoriaDB } from '../../hooks/queries/useCategoriasQuery'
import type { MarcaDB } from '../../hooks/queries/useMarcasQuery'


const ModalProveedor = lazyWithReload(() => import('./ModalProveedor'))
const ModalImportarCompra = lazyWithReload(() => import('./ModalImportarCompra'))
const ModalConfirmacion = lazyWithReload(() => import('./ModalConfirmacion'))

// =============================================================================
// TIPOS
// =============================================================================

/** Clave del selector fiscal para el par que tenga la línea. */
const claveCondicionLinea = (item: CompraItemForm): string =>
  claveCondicionIva(item.condicionIva, item.porcentajeIva)

/** Lo que manda el alta de un producto nuevo desde la factura. */
export interface ProductoRapidoInput {
  nombre: string;
  codigo: string;
  costoSinIva: number;
  /** Categoría elegida de la lista ('' = sin categoría). */
  categoria: string;
  /** Marca elegida de la lista ('' = sin marca). */
  marcaId: string;
  /** Proveedor habitual del producto; arranca en el de la factura ('' = sin proveedor). */
  proveedorId: string;
  /** Tipeadas con "+ Nueva": las crea el container y mandan sobre las elegidas. */
  categoriaNueva?: string;
  marcaNueva?: string;
  /** Encuadre de impuestos internos (mig 277). '' = sin definir. */
  iiEncuadreId?: string;
}

/** Props del componente principal */
export interface ModalCompraProps {
  productos: ProductoDB[];
  proveedores: ProveedorDBExtended[];
  /** Para clasificar el producto que se crea desde la factura. */
  categorias?: CategoriaDB[];
  marcas?: MarcaDB[];
  /** Obligatorio en 'nueva'. En 'ver' no hay nada que guardar; 'editar' usa `onGuardarEdicion`. */
  onSave?: (compra: CompraFormInputExtended) => Promise<void>;
  /**
   * 'editar': guarda con `actualizar_compra_items`. Si rechaza, el error se
   * muestra ADENTRO del modal y el modal queda abierto; si resuelve, lo cierra
   * el container.
   */
  onGuardarEdicion?: (input: ActualizarCompraItemsInput) => Promise<void>;
  /** 'editar': cambiar proveedor (admin) abre el flujo de anular + recrear. */
  canCambiarProveedor?: boolean;
  /** 'editar': el container cierra este modal y abre ModalCambiarProveedor. */
  onCambiarProveedor?: () => void;
  onClose: () => void;
  onCrearProductoRapido?: (data: ProductoRapidoInput) => Promise<ProductoDB>;
  onCrearProveedor?: (data: ProveedorFormInputExtended) => Promise<ProveedorDBExtended>;
  /**
   * Sucursal y usuario de la carga: arman la clave del borrador local. Sin los
   * dos no hay borrador (ver useBorradorCompra).
   */
  sucursalId?: number | null;
  usuarioId?: string | null;
  /**
   * 'nueva' carga una compra; 'ver' muestra una guardada con el MISMO
   * formulario, en sólo lectura; 'editar' la abre editable (líneas y cargos;
   * el cabezal no) a partir de la misma hidratación (utils/hidratarCompra).
   */
  modo?: ModoModalCompra;
  /** 'ver' / 'editar': la compra guardada, con items y cargos embebidos. */
  compra?: CompraDBExtended | null;
  /**
   * 'ver' / 'editar': los lotes que cargó esta compra (migs 223/224). En
   * 'editar', `undefined` = todavía no llegaron (se precargan una sola vez,
   * cuando llegan); `[]` = la compra no tiene.
   */
  lotes?: LoteDeLaCompra[];
  /** 'ver': las notas de crédito de esta compra. */
  notasCredito?: NotaCreditoDeLaCompra[];
  /**
   * 'ver': anula la compra. La confirmación la muestra ESTE modal, adentro de
   * su Dialog: como hermano en el container quedaría detrás del overlay de
   * Radix (CLAUDE.md).
   */
  onAnular?: (compraId: string) => Promise<void>;
  /** 'ver': abre la nota de crédito (el container cierra este modal antes). */
  onNotaCredito?: (compra: CompraDBExtended) => void;
}

export type ModoModalCompra = 'nueva' | 'ver' | 'editar'

/** Un lote de la compra, como lo trae useLotesCompraQuery. */
interface LoteDeLaCompra {
  producto_id: number | string;
  fecha_vencimiento: string;
  cantidad: number;
}

/** Una nota de crédito de la compra, como la trae useNotasCreditoByCompraQuery. */
interface NotaCreditoDeLaCompra {
  id: string;
  numero_nota?: string | null;
  fecha: string;
  total: number;
  motivo?: string | null;
  /** 'ajuste' = sin mercadería (mig 280). Ausente en respuestas viejas. */
  tipo?: 'devolucion' | 'ajuste' | null;
  /** II que acredita la nota (mig 280). */
  impuestos_internos?: number | null;
  items?: Array<{
    producto_id: string;
    cantidad: number;
    costo_unitario: number;
    subtotal: number;
    producto?: { nombre: string } | null;
  }>;
}

/**
 * Lo que sólo existe en modo 'ver': la fila guardada detrás de cada línea y lo
 * que se muestra de ella. `null` = se está cargando una compra, todo editable.
 *
 * Va por contexto y no por props porque lo consumen secciones a tres niveles de
 * profundidad (ItemRow, CargoRow, la vista previa) que en 'nueva' no lo usan.
 */
interface ContextoVer {
  itemPorLinea: Map<number, CompraItemDBExtended>;
  costoGuardadoPorLinea: Map<number, number | null>;
  /** producto_id → "dd/mm/aaaa (N u.)" de los lotes que cargó esta compra. */
  vencimientosPorProducto: Map<string, string[]>;
  proveedorCuit: string | null;
}
const VerCompraContext = createContext<ContextoVer | null>(null)
/** null = modo carga; un objeto = modo 'ver', todo en sólo lectura. */
const useContextoVer = () => useContext(VerCompraContext)

/** Las listas que ofrecen las dos altas rápidas, y el proveedor de la factura. */
interface CatalogoAltaRapida {
  categorias: OpcionCatalogo[];
  marcas: OpcionCatalogo[];
  proveedores: OpcionCatalogo[];
  /** '' = la factura todavía no tiene proveedor, o tiene uno nuevo sin dar de alta. */
  proveedorFactura: string;
  /** Encuadres de impuestos internos activos (mig 277). */
  encuadresII: OpcionCatalogo[];
}

/** Props de ProveedorSection */
interface ProveedorSectionProps {
  state: CompraState;
  dispatch: React.Dispatch<CompraActionType>;
  proveedores: ProveedorDBExtended[];
  /** `nombre`: lo tipeado en el buscador, para arrancar el alta con eso. */
  onAgregarProveedor?: (nombre?: string) => void;
}

/** Props de DatosCompraSection */
interface DatosCompraSectionProps {
  state: CompraState;
  dispatch: React.Dispatch<CompraActionType>;
  /** Al salir del número de factura: dispara ya el chequeo de duplicada. */
  onBlurNumero?: () => void;
}

/** Props de ProductosSection */
interface ProductosSectionProps {
  state: CompraState;
  dispatch: React.Dispatch<CompraActionType>;
  productosFiltrados: ProductoDB[];
  condicionMaster: Record<string, string>;
  onAgregarItem: (producto: ProductoDB) => void;
  onActualizarItem: (index: number, campo: keyof CompraItemForm, valor: number | string) => void;
  onCondicionItem: (index: number, clave: string) => void;
  onEliminarItem: (index: number) => void;
  /** Vencimientos de la línea (migs 223/224). Viajan aparte de p_items. */
  onVencimientosItem: (index: number, vencimientos: VencimientoLinea[]) => void;
  catalogo: CatalogoAltaRapida;
  onCrearProductoRapido?: (data: ProductoRapidoInput) => Promise<ProductoDB>;
  onImportarExcel?: () => void;
  lineasNoVigentes?: ReadonlySet<number>;
}

/** Props de ItemsList */
interface ItemsListProps {
  items: CompraItemForm[];
  onActualizarItem: (index: number, campo: keyof CompraItemForm, valor: number | string) => void;
  onCondicionItem: (index: number, clave: string) => void;
  onEliminarItem: (index: number) => void;
  /** Vencimientos de la línea (migs 223/224). Viajan aparte de p_items. */
  onVencimientosItem: (index: number, vencimientos: VencimientoLinea[]) => void;
  /** Clave de condición vigente en la ficha del producto (mig 177) */
  condicionMaster: Record<string, string>;
  /** lineaIds de un borrador retomado cuyo producto ya no existe o está inactivo. */
  lineasNoVigentes?: ReadonlySet<number>;
}

/** Props de ItemRow */
interface ItemRowProps {
  item: CompraItemForm;
  index: number;
  onActualizarItem: (index: number, campo: keyof CompraItemForm, valor: number | string) => void;
  onCondicionItem: (index: number, clave: string) => void;
  onEliminarItem: (index: number) => void;
  /** Vencimientos de la línea (migs 223/224). Viajan aparte de p_items. */
  onVencimientosItem: (index: number, vencimientos: VencimientoLinea[]) => void;
  /** Clave de condición de la ficha (undefined = desconocida) */
  condicionDelProducto?: string;
  /** Línea de un borrador retomado cuyo producto ya no existe o está inactivo. */
  productoNoVigente?: boolean;
}

/** Props de CargosSection */
interface CargosSectionProps {
  state: CompraState;
  dispatch: React.Dispatch<CompraActionType>;
  /** Cargos de la última compra de este proveedor. null = no hay ninguna con cargos. */
  plantilla?: PlantillaCargosProveedor | null;
  /** Lo que el impuesto interno declarado permite deducir. null = el motor no pudo. */
  resolucion: ResultadoBasesII | null;
  /** 'editar': arranca abierta, porque los cargos son la mitad de lo que se edita. */
  abiertaInicial?: boolean;
  /** #908: bonificaciones que la factura sugiere que faltan. Nunca en 'ver'. */
  sugerencias?: SugerenciaBonificacion[];
  /** El concepto "Bonificación" del catálogo (mig 278), para el cargo que se agrega. */
  conceptoBonificacion?: ConceptoCargo | null;
}

/** Props de CargoRow */
interface CargoRowProps {
  cargo: CargoCompraForm;
  items: CompraItemForm[];
  dispatch: React.Dispatch<CompraActionType>;
  resolucion: ResultadoBasesII | null;
  medidas: ContextoMedidas;
}

/** Props de GrillaPesos */
interface GrillaPesosProps {
  cargo: CargoCompraForm;
  items: CompraItemForm[];
  dispatch: React.Dispatch<CompraActionType>;
  /** Unidades por medida: catálogo, ficha y lo tipeado en esta compra (mig 278). */
  medidas: ContextoMedidas;
}

/** Props de VistaPreviaCostosSection */
interface VistaPreviaCostosProps {
  state: CompraState;
  /** producto_id → la compra anterior del producto, para la variación. */
  anteriores?: Map<string, CostoAnterior>;
}

/** Props de ResumenSection */
interface ResumenSectionProps {
  totales: TotalesCompra;
  state: CompraState;
  dispatch: React.Dispatch<CompraActionType>;
  resolucion: ResultadoBasesII | null;
  /**
   * 'editar': las percepciones son de la cabecera, que no se edita. Se muestran
   * sin input y la RPC conserva las guardadas.
   */
  percepcionesFijas?: boolean;
}

// Constantes
// Nota: `cuenta_corriente` ya no se ofrece como forma de pago (no es una forma
// de pago real). Las compras históricas con ese valor se siguen mostrando bien
// en el modo 'ver'; el mapeo del escaneo de factura lo conserva.
const FORMAS_PAGO = [
  { value: 'efectivo', label: 'Efectivo' },
  { value: 'transferencia', label: 'Transferencia' },
  { value: 'cheque', label: 'Cheque' },
  { value: 'tarjeta', label: 'Tarjeta' }
]

/** Para mostrar, incluida la histórica `cuenta_corriente` (modo 'ver'). */
const ETIQUETA_FORMA_PAGO: Record<string, string> = {
  efectivo: 'Efectivo',
  transferencia: 'Transferencia',
  cheque: 'Cheque',
  cuenta_corriente: 'Cuenta Corriente',
  tarjeta: 'Tarjeta',
}

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
  iiDeclarado: Record<number, number>,
  // Sólo al editar: la cabecera guardada puede traerlo y entra al total.
  otrosImpuestos = 0
): TotalesCompra {
  return useMemo(
    () => {
      const extras = { percepcionIva, percepcionIibb, noGravado, otrosImpuestos }
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
    [items, tipoFactura, percepcionIva, percepcionIibb, noGravado, cargos, iiDeclarado, otrosImpuestos]
  )
}

/** Mismo tope que el bucket `facturas` (mig 239) y que la edge function. */
const MAX_ARCHIVO_FACTURA = 8 * 1024 * 1024 // 8MB

/**
 * Mensaje del error de `functions.invoke`. Con un 4xx/5xx supabase-js tira un
 * FunctionsHttpError con un mensaje genérico ("Edge Function returned a
 * non-2xx status code") y la Response en `context`: el mensaje en castellano
 * que armó la función viene en el body, `{ success: false, error }`.
 */
async function mensajeErrorFuncion(error: unknown): Promise<string> {
  const contexto = (error as { context?: unknown })?.context
  if (contexto instanceof Response) {
    try {
      const body = await contexto.clone().json() as { error?: unknown }
      if (typeof body?.error === 'string' && body.error) return body.error
    } catch {
      // body no-JSON (p. ej. un 502 del gateway): cae al genérico.
    }
  }
  return 'No se pudo escanear la factura. Probá de nuevo en un rato.'
}
/** Pausa en el tipeo del cabezal antes de buscar una factura duplicada. */
const DEMORA_CHEQUEO_DUPLICADA_MS = 700

/** Las listas de las dos altas rápidas (categorías, marcas, proveedores, encuadres). */
function useCatalogoAltaRapida(
  categorias: CategoriaDB[],
  marcas: MarcaDB[],
  proveedores: ProveedorDBExtended[],
  proveedorFactura: string,
): CatalogoAltaRapida {
  const { data: catalogoII } = useCatalogoIIQuery()
  return useMemo<CatalogoAltaRapida>(() => ({
    // Sólo las categorías que tienen fila. La ficha ofrece también los nombres
    // que existen nada más como texto en algún producto, y elegir uno de esos
    // deja al producto nuevo sin `categoria_id`; acá no se ofrecen. Si falta
    // alguna, "+ Nueva categoría" la crea de verdad.
    categorias: categorias
      .filter(c => c.activa !== false)
      .map(c => ({ valor: c.nombre, texto: c.nombre })),
    marcas: marcas
      .filter(m => m.activa)
      .map(m => ({ valor: m.id, texto: m.nombre })),
    proveedores: proveedores.map(p => ({ valor: String(p.id), texto: p.nombre })),
    proveedorFactura,
    encuadresII: (catalogoII?.encuadres ?? [])
      .filter(e => e.activo)
      .map(e => ({ valor: e.id, texto: e.nombre })),
  }), [categorias, marcas, proveedores, proveedorFactura, catalogoII])
}

/** Los diez primeros productos que matchean el buscador (nombre o código). */
function useProductosFiltrados(productos: ProductoDB[], busqueda: string): ProductoDB[] {
  return useMemo(() => {
    if (!busqueda.trim()) return productos.slice(0, 10)
    const termino = busqueda.toLowerCase()
    return productos.filter(p =>
      p.nombre?.toLowerCase().includes(termino) ||
      p.codigo?.toLowerCase().includes(termino)
    ).slice(0, 10)
  }, [productos, busqueda])
}

const FICHA_VACIA: MedidasPorProducto<number> = {}

/**
 * Lleva al reducer lo que llega de las queries de medidas (mig 278): el puente
 * medida → base del catálogo y la ficha de la sucursal. Va por el estado, y no
 * por props, porque el pre-llenado de los pesos vive en el reducer.
 *
 * Al EDITAR, que esto dispare el wrapper del reducer es inocuo: todos los pesos
 * hidratados son manuales y `sincronizarCargos` no los toca.
 */
function useReferenciaMedidas(state: CompraState, dispatch: React.Dispatch<CompraActionType>) {
  const { data: catalogo } = useCargoMedidasQuery()
  const { data: ficha } = useProductoMedidasQuery()
  const bases = useMemo(
    () => Object.fromEntries((catalogo ?? []).map(m => [m.id, m.medidaBaseId])) as Record<string, string | null>,
    [catalogo]
  )
  const fichaEstable = ficha ?? FICHA_VACIA
  useEffect(() => {
    if (state.medidas.bases === bases && state.medidas.ficha === fichaEstable) return
    dispatch({ type: 'SET_MEDIDAS_REFERENCIA', payload: { bases, ficha: fichaEstable } })
  }, [bases, fichaEstable, state.medidas.bases, state.medidas.ficha, dispatch])
}

export default function ModalCompra(props: ModalCompraProps) {
  if (props.modo === 'ver') {
    return props.compra ? <ModalCompraVer {...props} compra={props.compra} /> : null
  }
  if (props.modo === 'editar') {
    return props.compra ? <ModalCompraEditar {...props} compra={props.compra} /> : null
  }
  return <ModalCompraCarga {...props} />
}

function ModalCompraCarga({ productos, proveedores, categorias = [], marcas = [], onSave, onClose, onCrearProductoRapido, onCrearProveedor, sucursalId = null, usuarioId = null }: ModalCompraProps) {
  const [state, dispatch] = useReducer(compraReducer, initialState)
  const puedeEscanear = useContext(AuthDataContext)?.isAdminOrEncargado ?? false
  const [modalProveedorOpen, setModalProveedorOpen] = useState(false)
  // Lo tipeado en el buscador de proveedor cuando se eligió "+ Nuevo proveedor".
  const [nombreProveedorNuevo, setNombreProveedorNuevo] = useState('')

  // ── Borrador local ─────────────────────────────────────────────────────────
  // La clave se congela al montar: al cambiar de sucursal este modal se cierra
  // (ComprasContainer), pero en ese último render ya ve la sucursal nueva, y el
  // flush del desmontaje escribiría el borrador de Tucumán en la clave de Taco
  // Pozo.
  const [claveBorrador] = useState(() =>
    sucursalId !== null && sucursalId !== undefined && usuarioId
      ? claveBorradorCompra(sucursalId, usuarioId)
      : null
  )
  const borrador = useBorradorCompra(claveBorrador, state)
  // Las líneas que vinieron del borrador: sólo ésas se contrastan contra el
  // catálogo. Una línea recién agregada con el alta rápida todavía no está en
  // `productos` (llega con el refetch) y no es un problema.
  const [lineasRestauradas, setLineasRestauradas] = useState<ReadonlySet<number>>(() => new Set())
  const lineasNoVigentes = useMemo<ReadonlySet<number>>(() => {
    // Con el catálogo sin cargar todo parecería borrado.
    if (lineasRestauradas.size === 0 || productos.length === 0) return new Set()
    const restauradas = state.items.filter(i => i.lineaId !== undefined && lineasRestauradas.has(i.lineaId))
    return new Set(lineasSinProductoVigente(restauradas, productos).map(i => i.lineaId as number))
  }, [lineasRestauradas, state.items, productos])

  const retomarBorrador = () => {
    const restaurado = borrador.retomar()
    if (!restaurado) return
    dispatch({ type: 'HIDRATAR', payload: restaurado })
    setLineasRestauradas(new Set(restaurado.items.flatMap(i => (i.lineaId === undefined ? [] : [i.lineaId]))))
  }

  // ── Factura duplicada ──────────────────────────────────────────────────────
  // Se consulta con lo tipeado ya asentado: al salir del número, o tras una
  // pausa. Nunca al guardar: el aviso es para el que está cargando el cabezal.
  const criterioActual = useMemo<CriterioFacturaDuplicada>(() => ({
    proveedorId: state.usarProveedorNuevo ? null : (state.proveedorId ? String(state.proveedorId) : null),
    proveedorNombre: state.usarProveedorNuevo || !state.proveedorId ? state.proveedorNombre : '',
    numeroFactura: state.numeroFactura,
  }), [state.usarProveedorNuevo, state.proveedorId, state.proveedorNombre, state.numeroFactura])
  const [criterioDuplicada, setCriterioDuplicada] = useState<CriterioFacturaDuplicada>(criterioActual)
  useEffect(() => {
    const t = setTimeout(() => setCriterioDuplicada(criterioActual), DEMORA_CHEQUEO_DUPLICADA_MS)
    return () => clearTimeout(t)
  }, [criterioActual])
  const { data: comprasMismaFactura } = useComprasMismaFacturaQuery(criterioDuplicada)
  // Mientras se tipea, el resultado es del número de antes: no se muestra.
  const duplicadaVigente =
    criterioDuplicada.proveedorId === criterioActual.proveedorId &&
    criterioDuplicada.proveedorNombre === criterioActual.proveedorNombre &&
    criterioDuplicada.numeroFactura === criterioActual.numeroFactura
  const duplicadas = duplicadaVigente ? (comprasMismaFactura ?? []) : []
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

  // ── Catálogo de cargos y medidas (mig 278) ─────────────────────────────────
  useReferenciaMedidas(state, dispatch)
  const { data: conceptosCatalogo } = useCargoConceptosQuery()

  // Plantilla del proveedor AUTOMÁTICA: al elegir el proveedor se precargan los
  // cargos de su última compra no cancelada, con el monto vacío y su alcance
  // (qué productos tocaban). Cambiar de proveedor reemplaza sólo los de
  // plantilla que nadie tocó. Va UNA vez por proveedor —`plantillaProveedorId`
  // vive en el estado, así un borrador retomado no la vuelve a aplicar— y sólo
  // con la respuesta de ESE proveedor (sin placeholder: con otra key, la query
  // vuelve a 'pending').
  const proveedorParaPlantilla = state.usarProveedorNuevo ? '' : String(state.proveedorId || '')
  useEffect(() => {
    if (!proveedorParaPlantilla || proveedorParaPlantilla === state.plantillaProveedorId) return
    if (!plantillaCargos.isSuccess) return
    // Una compra anterior a la mig 278 no trae concepto_id: se resuelve por el
    // nombre contra el catálogo, con la misma normalización.
    const cargos = (plantillaCargos.data?.cargos ?? []).map(c =>
      c.conceptoId ? c : { ...c, conceptoId: conceptoPorNombre(conceptosCatalogo ?? [], c.concepto)?.id ?? null }
    )
    dispatch({ type: 'APLICAR_PLANTILLA_PROVEEDOR', payload: { proveedorId: proveedorParaPlantilla, cargos } })
  }, [proveedorParaPlantilla, state.plantillaProveedorId, plantillaCargos.isSuccess, plantillaCargos.data, conceptosCatalogo])

  // #908 · La bonificación que el proveedor no descontó de la base del II. Se
  // corrobora contra el gravado o el total que se hayan tipeado del papel.
  const sugerenciasBonif = useMemo(
    () => sugerenciasBonificacion(state, {
      gravadoImpreso: state.controlFactura.gravado,
      gravadoCalculado: totales.netoGravado,
      totalImpreso: state.controlFactura.total,
      totalCalculado: totales.total,
    }, plantillaCargos.data?.cargos),
    [state, totales, plantillaCargos.data]
  )
  const conceptoBonificacion = conceptoPorNombre(conceptosCatalogo ?? [], 'Bonificación') ?? null

  // Cargos de plantilla que se quedaron sin monto: al guardar se pregunta si se
  // quitan, en vez de fallar o de guardar un flete de $0.
  const [sinMontoPorQuitar, setSinMontoPorQuitar] = useState<CargoCompraForm[] | null>(null)

  // La compra anterior de cada producto, para la variación del costo final en
  // "Costo por producto". Sin id propio: cualquier compra del mismo día o antes.
  const { data: costosAnteriores } = useCostosAnterioresQuery(
    state.items.map(i => String(i.productoId)),
    { compraId: null, fechaCompra: state.fechaCompra, numeroFactura: state.numeroFactura },
  )

  // Un proveedor nuevo del escaneo todavía no tiene id: no hay a quién
  // vincular el producto hasta que se registre la compra.
  const catalogoAlta = useCatalogoAltaRapida(
    categorias, marcas, proveedores,
    state.usarProveedorNuevo ? '' : String(state.proveedorId || ''),
  )
  const productosFiltrados = useProductosFiltrados(productos, state.busquedaProducto)

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

  const handleVencimientosItem = useCallback((index: number, vencimientos: VencimientoLinea[]) => {
    dispatch({ type: 'SET_VENCIMIENTOS_ITEM', payload: { index, vencimientos } })
  }, [])

  const handleEliminarItem = useCallback((index: number) => {
    dispatch({ type: 'ELIMINAR_ITEM', payload: index })
  }, [])

  // Escanear factura (foto o PDF). Sube al bucket privado `facturas` bajo la
  // sucursal activa y la lee la edge function `escanear-factura`, que valida
  // rol, sucursal y ruta antes de mandarla a Gemini. Reemplaza al webhook de
  // n8n, que era público y sin auth.
  const handleEscanearFactura = useCallback(async (file: File) => {
    if (file.size > MAX_ARCHIVO_FACTURA) {
      dispatch({ type: 'SET_ERROR_ESCANEO', payload: 'El archivo es demasiado grande (máx 8MB)' })
      return
    }
    const ext = extensionArchivoFactura(file)
    if (!ext) {
      dispatch({ type: 'SET_ERROR_ESCANEO', payload: 'Formato no soportado. Subí una foto (JPG, PNG, WEBP o HEIC) o un PDF.' })
      return
    }
    // La misma sucursal que la función va a leer del header X-Sucursal-ID.
    const sucursalActiva = getSucursalHeader() ?? sucursalId
    if (sucursalActiva == null) {
      dispatch({ type: 'SET_ERROR_ESCANEO', payload: 'No hay una sucursal activa. Elegí una sucursal y volvé a intentar.' })
      return
    }

    dispatch({ type: 'SET_ESCANEANDO', payload: true })
    try {
      const path = rutaEscaneoFactura(sucursalActiva, nuevoUuid(), ext)
      const { error: uploadError } = await supabase.storage
        .from('facturas')
        .upload(path, file, { contentType: CONTENT_TYPE_POR_EXTENSION[ext] })
      if (uploadError) {
        throw new Error('No se pudo subir el archivo de la factura. Probá de nuevo.')
      }

      const { data, error } = await supabase.functions.invoke('escanear-factura', { body: { path } })
      if (error) throw new Error(await mensajeErrorFuncion(error))

      const respuesta = RespuestaEscaneoSchema.safeParse(data)
      if (!respuesta.success) {
        throw new Error('La respuesta del escáner no tiene el formato esperado. Probá de nuevo o cargá la factura a mano.')
      }
      if (!respuesta.data.success) throw new Error(respuesta.data.error)

      dispatch({
        type: 'SET_RESULTADO_ESCANEO',
        payload: mapearFacturaV2(respuesta.data.data, respuesta.data.advertencias) satisfies FacturaEscaneada,
      })
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Error al escanear factura'
      dispatch({ type: 'SET_ERROR_ESCANEO', payload: msg })
    }
  }, [sucursalId])

  // Aplicar resultado del escaneo al formulario. Los candidatos (equivalencias
  // aprendidas y lo ya comprado al proveedor, mig 292) los trae ScanPreview.
  const handleAplicarEscaneo = useCallback((candidatos: CandidatosEscaneo) => {
    const scan = state.resultadoEscaneo
    if (!scan) return

    const { proveedorIdMatch, resultados } = resolverEscaneo(scan, productos, proveedores, candidatos)

    // Sólo 'vinculado' (equivalencia aprendida o nuestro código, único) entra
    // solo a las líneas. Lo sugerido por parecido y lo que no se encontró van
    // al panel de pendientes, con la sugerencia preseleccionada: decide la persona.
    const itemsMatcheados: CompraItemForm[] = []
    const pendientes: ItemPendienteScan[] = []
    scan.items.forEach((scanItem, i) => {
      const r = resultados[i]
      const producto = r.productoId ? productos.find(p => String(p.id) === r.productoId) : undefined
      if (r.estado === 'vinculado' && producto) {
        itemsMatcheados.push(construirCompraItemDesdeScan(producto, scanItem, r.unidadesPorBulto))
        return
      }
      pendientes.push({
        ...scanItem,
        sugerencia: {
          productoId: producto ? String(producto.id) : undefined,
          confianza: r.confianza,
          motivo: r.motivo,
          alternativas: r.alternativas.map(a => a.productoId),
          ...(r.unidadesPorBulto ? { unidadesPorBulto: r.unidadesPorBulto } : {}),
        },
      })
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
        items: itemsMatcheados,
        pendientes,
        tipoFactura: scan.tipoFactura ?? null,
        control: scan.control
      }
    })
  }, [state.resultadoEscaneo, productos, proveedores])

  const handleSubmit = (e: FormEvent<HTMLFormElement> | React.MouseEvent<HTMLButtonElement>) => {
    e.preventDefault()
    dispatch({ type: 'SET_ERROR', payload: '' })
    // Un cargo de la plantilla sin monto no es un error de carga: es un flete
    // que esta factura no trajo. Se pregunta antes de validar el resto.
    const sinMonto = state.cargos.filter(c => c.plantilla && !c.monto)
    if (sinMonto.length > 0) {
      setSinMontoPorQuitar(sinMonto)
      return
    }
    void registrar(new Set())
  }

  /** Quita los de plantilla sin monto y registra. */
  const quitarSinMontoYRegistrar = () => {
    const ids = new Set((sinMontoPorQuitar ?? []).map(c => c.id))
    setSinMontoPorQuitar(null)
    for (const id of ids) dispatch({ type: 'ELIMINAR_CARGO', payload: id })
    void registrar(ids)
  }

  /**
   * `quitar`: ids de cargos que el usuario acaba de sacar (los de plantilla sin
   * monto). Se filtran acá porque el dispatch todavía no se aplicó. Un cargo de
   * $0 no mueve ningún total, así que los totales de arriba siguen valiendo.
   */
  const registrar = async (quitar: Set<number>) => {
    const cargosAGuardar = state.cargos.filter(c => !quitar.has(c.id))

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
    // Etiquetar menos unidades que la línea es legal (el resto queda en la bolsa
    // "sin vencimiento"); etiquetar más no. Y nada lo frenaba: el badge de la
    // línea se ponía rojo y el guardado seguía, porque `sincronizar_lotes_compra`
    // sólo clampea contra el stock TOTAL del producto y no ve la línea. El
    // sobrante entraba a un lote que la compra no trajo.
    const errorVencimientos = validarVencimientosLineas(
      state.items.map(it => ({ nombre: it.productoNombre, cantidad: it.cantidad, vencimientos: it.vencimientos })),
    )
    if (errorVencimientos) {
      dispatch({ type: 'SET_ERROR', payload: errorVencimientos })
      return
    }
    // Lo que la RPC va a rechazar de los cargos, dicho antes de salir a la red.
    // La validación que manda sigue siendo la de la mig 194 —corre aunque el
    // cliente esté viejo— pero un round trip para enterarse de que el flete no
    // tiene ninguna línea asignada es un round trip de más.
    const errorCargos = validarCargos(cargosAGuardar) ?? validarMedidasCargos(cargosAGuardar, state.items, state.medidas)
    if (errorCargos) {
      dispatch({ type: 'SET_ERROR', payload: errorCargos })
      return
    }

    if (!onSave) return
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
        formaPago: state.formaPago,
        notas: state.notas,
        tipoFactura: state.tipoFactura,
        // Los pesos viajan por ÍNDICE del array de items de abajo: los
        // compra_items.id no existen todavía. `cargosParaRPC` traduce contra
        // ESE mismo array, así que los dos tienen que salir de `state.items`.
        cargos: cargosParaRPC(state.items, cargosAGuardar),
        // En ZZ la RPC lo descarta igual; mandarlo ya filtrado deja a las dos
        // puntas diciendo lo mismo.
        iiDeclarado: iiDeclaradoParaMotor(state.iiDeclarado, state.tipoFactura),
        // Las u/pallet con "guardar en la ficha" (mig 278): van DESPUÉS de la
        // compra, sin bloquearla, como los vencimientos.
        medidasFicha: medidasParaFicha(state.medidas, state.items.map(i => String(i.productoId))),
        // Lo que esta factura le enseña al escáner (mig 292): cada línea
        // escaneada contra el producto con el que quedó. Va después de la
        // compra, sin bloquearla.
        equivalenciasEscaneo: equivalenciasParaRegistrar(state.items),
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
            impuestosInternos: item.impuestosInternos ?? 0,
            // Viajan aparte de p_items: los manda `sincronizar_lotes_compra`
            // una vez que la compra existe (mig 224).
            vencimientos: item.vencimientos ?? []
          }
        })
      })
      // Antes de cerrar: si el debounce del borrador sobreviviera al guardado,
      // la compra registrada se volvería a ofrecer como borrador.
      borrador.finalizar()
      onClose()
    } catch (err) {
      const error = err as Error
      dispatch({ type: 'SET_ERROR', payload: error.message || 'Error al registrar la compra' })
    } finally {
      dispatch({ type: 'SET_GUARDANDO', payload: false })
    }
  }

  // Los dos modales anidados (alta de proveedor, importar Excel) son hechos a
  // mano: Radix no los registra como capas propias, así que para él siguen
  // siendo "adentro de la compra". Ver `handleEscapeKeyDown` y el `className`
  // de ModalBase más abajo.
  const modalAnidadoAbierto = modalProveedorOpen || modalImportarOpen

  // Escape cierra sólo si no hay nada que perder (ver `compraTieneCambios`).
  // La X y "Cancelar" cierran siempre, como antes de pasar a ModalBase.
  //
  // Radix escucha Escape en el `document` en fase de CAPTURA: le llega antes
  // que al `onKeyDown` de cualquier input, y ningún `stopPropagation` de adentro
  // lo frena. Por eso la lista del buscador abierta se mira acá: ese Escape es
  // para cerrarla a ella (lo hace el input), no al modal. Con un modal anidado
  // abierto pasa lo mismo: sin esto, un Escape adentro del alta de proveedor
  // cerraría la compra entera por detrás.
  const handleEscapeKeyDown = (event: KeyboardEvent) => {
    // Un combobox con la lista abierta (el de proveedor): ese Escape es para
    // cerrar la lista, igual que el sub-buscador de productos.
    const enfocado = document.activeElement
    const comboboxAbierto = enfocado?.getAttribute('role') === 'combobox' &&
      enfocado.getAttribute('aria-expanded') === 'true'
    if (state.mostrarBuscador || comboboxAbierto || modalAnidadoAbierto || compraTieneCambios(state)) {
      event.preventDefault()
    }
  }

  // Sólo admin y encargado: el mismo gate que la edge function y que la RLS del
  // bucket. Sin el contexto de auth (tests que montan el modal suelto) no se
  // muestra.
  const botonEscanear = puedeEscanear ? (
    <>
      <input
        ref={fileInputRef}
        type="file"
        accept="image/*,application/pdf"
        className="hidden"
        onChange={(e) => {
          const file = e.target.files?.[0]
          if (file) handleEscanearFactura(file)
          e.target.value = ''
        }}
      />
      <Button
        type="button"
        onClick={() => fileInputRef.current?.click()}
        disabled={state.escaneando}
        loading={state.escaneando}
        variant="primary"
        size="sm"
        className="gap-1.5 px-2.5 sm:px-3"
        // En celular el rótulo está oculto y el ícono es decorativo: sin esto el
        // botón no tiene nombre, y es el primer tabulable del diálogo (el foco
        // inicial de Radix cae acá cuando el botón se muestra).
        aria-label={state.escaneando ? 'Escaneando...' : 'Escanear Factura'}
      >
        {!state.escaneando && <Camera className="w-4 h-4" />}
        <span className="hidden sm:inline">{state.escaneando ? 'Escaneando...' : 'Escanear Factura'}</span>
      </Button>
    </>
  ) : undefined

  // bodyBare: el modal trae su propia columna. Con el DialogBody de siempre
  // habría doble scroll y el footer con "Registrar Compra" se iría con el
  // formulario, abajo de todo.
  //
  // El carrito verde que acompañaba al título no pasa a `headerExtra`: ese
  // slot queda pegado a la X, y ahí sería un adorno. Sigue en el botón
  // "Registrar Compra".
  //
  // `h-[90vh]` sólo con un modal anidado abierto: el contenido de ModalBase va
  // centrado con `transform`, y un `fixed` adentro de un elemento transformado
  // se posiciona contra ESE elemento y no contra la pantalla (y su
  // `overflow-hidden` lo recorta). El anidado queda encerrado en la caja de la
  // compra; así esa caja le da toda la altura que la pantalla permite, y un
  // "Importar" al pie de una vista previa larga no queda cortado.
  return (
    <ModalBase
      title="Nueva Compra"
      onClose={onClose}
      maxWidth="max-w-6xl"
      bodyBare
      headerExtra={botonEscanear}
      onEscapeKeyDown={handleEscapeKeyDown}
      className={modalAnidadoAbierto ? 'h-[90vh]' : undefined}
    >
      <div className="flex flex-1 min-h-0 flex-col">
        {/* Subtítulo: queda fijo arriba del área que scrollea. No va como
            `description` de ModalBase: la visible queda cruzada por el borde
            del header (#800). */}
        <p className="hidden sm:block px-4 py-2 border-b dark:border-gray-700 text-sm text-gray-500 dark:text-gray-400 flex-shrink-0">
          Registrar compra a proveedor
        </p>

        {/* Los paneles del escaneo quedan fijos entre el header y el
            formulario, fuera del scroll, como antes de ModalBase: el botón
            "Escanear Factura" está siempre a la vista y el resultado (o el
            error) llega asíncrono, así que tiene que aparecer donde se lo ve
            aunque el formulario esté scrolleado. */}

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
            catalogo={catalogoAlta}
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
            <Button onClick={() => dispatch({ type: 'SET_ERROR_ESCANEO', payload: '' })} variant="ghost" size="iconSm" className="text-red-400 hover:text-red-600 dark:text-red-400 dark:hover:text-red-600">
              <X className="w-4 h-4" />
            </Button>
          </div>
        )}

        {borrador.otraPestana && (
          <AvisoOtraPestana cambio={borrador.otraPestana} onCerrar={borrador.cerrarAvisoOtraPestana} />
        )}

        {/* Contenido: lo único que scrollea. */}
        <div className="flex-1 overflow-y-auto">
          <CompactErrorBoundary componentName="ModalCompra" onClose={onClose}>
            {/* Un borrador al abrir se decide ANTES de cargar nada: con el
                formulario a la vista, lo tipeado mientras tanto se perdería al
                retomar, o el autosave pisaría el borrador. */}
            {borrador.pendiente.tipo !== 'ninguno' ? (
              <OfertaBorrador
                lectura={borrador.pendiente}
                proveedores={proveedores}
                onRetomar={retomarBorrador}
                onDescartar={borrador.descartarPendiente}
              />
            ) : (
            <form onSubmit={handleSubmit} className="p-3 sm:p-4 space-y-4">
              {/* Sección Proveedor */}
              <ProveedorSection
                state={state}
                dispatch={dispatch}
                proveedores={proveedores}
                onAgregarProveedor={onCrearProveedor
                  ? (nombre?: string) => {
                      setNombreProveedorNuevo(nombre ?? '')
                      setModalProveedorOpen(true)
                    }
                  : undefined}
              />

              {/* Datos de la compra */}
              <DatosCompraSection
                state={state}
                dispatch={dispatch}
                onBlurNumero={() => setCriterioDuplicada(criterioActual)}
              />
              {duplicadas.length > 0 && <AvisoFacturaDuplicada compras={duplicadas} />}

              {/* Productos */}
              <ProductosSection
                state={state}
                dispatch={dispatch}
                productosFiltrados={productosFiltrados}
                  condicionMaster={condicionMaster}
                onAgregarItem={handleAgregarItem}
                onActualizarItem={handleActualizarItem}
                onCondicionItem={handleCondicionItem}
                onEliminarItem={handleEliminarItem}
                onVencimientosItem={handleVencimientosItem}
                catalogo={catalogoAlta}
                onCrearProductoRapido={onCrearProductoRapido}
                onImportarExcel={() => setModalImportarOpen(true)}
                lineasNoVigentes={lineasNoVigentes}
              />

              {/* Cargos y prorrateo. También en ZZ —el 47,9% de las compras—: el
                  tipo de comprobante decide si se agregan impuestos encima, no si
                  se ignoran costos, y un flete que factura un transportista aparte
                  no está adentro del precio pagado. La regla de ZZ se aplica en el
                  borde del motor (lineasParaMotor), no apagando la sección.
                  El único gate es tener líneas donde repartir. */}
              {state.items.length > 0 && (
                <>
                  <CargosSection state={state} dispatch={dispatch} plantilla={plantillaCargos.data} resolucion={resolucionII}
                                 sugerencias={sugerenciasBonif} conceptoBonificacion={conceptoBonificacion} />
                  <VistaPreviaCostosSection state={state} anteriores={costosAnteriores} />
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
            )}
          </CompactErrorBoundary>
        </div>

        {/* Footer con botones: fuera del scroll, siempre a la vista */}
        <div className="p-3 sm:p-4 border-t dark:border-gray-700 flex-shrink-0 space-y-3">
          {/* El cuadre contra el papel, a la vista mientras se carga: es el
              mismo total y el mismo "Factura dice" del panel de control. */}
          {state.items.length > 0 && borrador.pendiente.tipo === 'ninguno' && (
            <BarraCuadre
              total={total}
              totalFactura={state.controlFactura.total}
              conControl={state.tipoFactura === 'FC'}
              onTotalFactura={(n) => dispatch({ type: 'SET_CONTROL', payload: { total: n } })}
            />
          )}
          {/* Cargos de la plantilla sin monto: se pregunta, no se falla. */}
          {sinMontoPorQuitar && (
            <div role="alertdialog" aria-label="Cargos sin monto" className="p-3 bg-amber-50 dark:bg-amber-900/20 border border-amber-300 dark:border-amber-700 rounded-lg space-y-2">
              <p className="text-sm text-amber-800 dark:text-amber-200">
                {sinMontoPorQuitar.map(c => c.concepto.trim() || '(sin concepto)').join(', ')} sin monto: ¿quitar?
                <span className="block text-xs">
                  {sinMontoPorQuitar.length === 1 ? 'Vino' : 'Vinieron'} de la última compra del proveedor y en esta factura no {sinMontoPorQuitar.length === 1 ? 'tiene' : 'tienen'} importe.
                </span>
              </p>
              <div className="flex flex-wrap gap-2">
                <Button type="button" onClick={quitarSinMontoYRegistrar} variant="success" size="sm">
                  Quitar y registrar
                </Button>
                <Button type="button" onClick={() => setSinMontoPorQuitar(null)} variant="secondary" size="sm">
                  Volver a cargar el monto
                </Button>
              </div>
            </div>
          )}
          {/* Error visible junto al botón */}
          {state.error && (
            <div className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
              <p className="text-sm text-red-600 dark:text-red-400">{state.error}</p>
            </div>
          )}
          <div className="flex gap-3">
            <Button
              type="button"
              onClick={onClose}
              variant="secondary"
              size="md"
              className="flex-1"
            >
              Cancelar
            </Button>
            <Button
              type="button"
              onClick={handleSubmit}
              disabled={state.guardando || state.items.length === 0}
              loading={state.guardando}
              variant="success"
              size="md"
              className="flex-1"
            >
              {!state.guardando && <ShoppingCart className="w-4 h-4" />}
              {state.guardando ? 'Registrando...' : 'Registrar Compra'}
            </Button>
          </div>
        </div>
      </div>

      {/* Los modales anidados van ADENTRO de ModalBase: afuera quedarían
          detrás del overlay de Radix, con `pointer-events: none` heredado del
          body y fuera del focus trap (CLAUDE.md). */}

      {/* Modal Proveedor anidado */}
      {modalProveedorOpen && onCrearProveedor && (
        <Suspense fallback={null}>
          <ModalProveedor
            nombreInicial={nombreProveedorNuevo}
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
    </ModalBase>
  )
}

// =============================================================================
// MODO 'ver': la compra guardada en el mismo formulario, en sólo lectura
// =============================================================================

/**
 * La compra guardada, con el mismo layout que la carga.
 *
 * El estado sale de `hidratarCompraGuardada` y NO pasa por el reducer: en 'ver'
 * nada lo modifica, así que es un `useMemo` sobre la compra. Así, si la compra
 * se refresca (por ejemplo, al anularla) la pantalla la sigue sin remontar.
 *
 * Todo lo editable queda adentro de un `<fieldset disabled>`, que deshabilita
 * de una vez inputs, selects y botones; lo que no se puede mostrar bien
 * deshabilitado (el buscador de proveedor, la forma de pago histórica) se
 * muestra como texto, y lo que es sólo para cargar (buscador de productos,
 * agregar cargo, papeleras) no se muestra.
 *
 * Conserva todo lo que hacía ModalDetalleCompra: estado, usuario, fecha de
 * carga, total de unidades, stock antes → después, vencimientos de la compra,
 * forma de pago, notas, totales GUARDADOS de la cabecera, notas de crédito, y
 * los botones de nota de crédito y anular.
 */
function ModalCompraVer({ compra, proveedores, onClose, lotes = [], notasCredito = [], onAnular, onNotaCredito }: ModalCompraProps & { compra: CompraDBExtended }) {
  const hidratada = useMemo(() => hidratarCompraGuardada(compra), [compra])
  const { estado: state } = hidratada
  const [confirmarAnular, setConfirmarAnular] = useState(false)

  const vencimientosPorProducto = useMemo(() => {
    // Los lotes son del PRODUCTO, no de la línea (UNIQUE de la mig 223).
    const mapa = new Map<string, string[]>()
    for (const lote of lotes) {
      const clave = String(lote.producto_id)
      const texto = `${formatearFechaVencimiento(lote.fecha_vencimiento)} (${lote.cantidad} u.)`
      mapa.set(clave, [...(mapa.get(clave) ?? []), texto])
    }
    return mapa
  }, [lotes])

  const proveedorCuit = compra.proveedor?.cuit ?? null
  const contexto = useMemo<ContextoVer>(() => ({
    itemPorLinea: hidratada.itemPorLinea,
    costoGuardadoPorLinea: hidratada.costoGuardadoPorLinea,
    vencimientosPorProducto,
    proveedorCuit,
  }), [hidratada, vencimientosPorProducto, proveedorCuit])

  // La anterior de ESTA compra: estrictamente antes por (fecha, id), sin la
  // misma compra ni la misma factura.
  const { data: costosAnteriores } = useCostosAnterioresQuery(
    state.items.map(i => String(i.productoId)),
    { compraId: String(compra.id), fechaCompra: state.fechaCompra, numeroFactura: state.numeroFactura },
  )

  const estadoCompra = (compra.estado as string | undefined) ?? 'pendiente'
  const estadoNormalizado = ETIQUETA_ESTADO_COMPRA[estadoCompra] ? estadoCompra : 'pendiente'
  const cancelada = estadoCompra === 'cancelada'
  // `bonificacion` es un PORCENTAJE (mig 113): no se suma a las unidades.
  const totalUnidades = (compra.items ?? []).reduce((acc, i) => acc + Number(i.cantidad || 0), 0)
  const cargadaEl = compra.created_at
    ? new Date(compra.created_at).toLocaleDateString('es-AR', { year: 'numeric', month: 'long', day: 'numeric', hour: '2-digit', minute: '2-digit' })
    : ''
  const noop = () => {}

  return (
    <ModalBase
      title={`Compra #${compra.id}`}
      onClose={onClose}
      maxWidth="max-w-6xl"
      bodyBare
      headerExtra={
        <Badge tone={toneDeEstadoCompra(estadoNormalizado)} className="px-3 py-1 font-medium">
          {ETIQUETA_ESTADO_COMPRA[estadoNormalizado]}
        </Badge>
      }
    >
      <VerCompraContext.Provider value={contexto}>
        <div className="flex flex-1 min-h-0 flex-col">
          <p className="px-4 py-2 border-b dark:border-gray-700 text-sm text-gray-500 dark:text-gray-400 flex-shrink-0">
            {[
              cargadaEl && `Cargada el ${cargadaEl}`,
              compra.usuario?.nombre && `Registrado por: ${compra.usuario.nombre}`,
              `${totalUnidades} ${totalUnidades === 1 ? 'unidad' : 'unidades'}`,
            ].filter(Boolean).join(' · ')}
          </p>

          <div className="flex-1 overflow-y-auto">
            <CompactErrorBoundary componentName="ModalCompra" onClose={onClose}>
              <fieldset disabled className="p-3 sm:p-4 space-y-4 min-w-0 border-0 m-0">
                <legend className="sr-only">Compra guardada, sólo lectura</legend>
                <ProveedorSection state={state} dispatch={noop} proveedores={proveedores} />
                <DatosCompraSection state={state} dispatch={noop} />
                <ProductosSection
                  state={state}
                  dispatch={noop}
                  productosFiltrados={[]}
                  // La condición de la ficha es la de HOY: en una compra guardada
                  // el aviso "la ficha dice otra cosa" sería ruido.
                  condicionMaster={{}}
                  onAgregarItem={noop}
                  onActualizarItem={noop}
                  onCondicionItem={noop}
                  onEliminarItem={noop}
                  onVencimientosItem={noop}
                  catalogo={{ categorias: [], marcas: [], proveedores: [], proveedorFactura: '', encuadresII: [] }}
                />
                {state.items.length > 0 && (
                  <>
                    <CargosSection state={state} dispatch={noop} resolucion={null} />
                    <VistaPreviaCostosSection state={state} anteriores={costosAnteriores} />
                  </>
                )}
                <TotalesGuardados compra={compra} />
                {notasCredito.length > 0 && <NotasCreditoDeLaCompra notas={notasCredito} totalCompra={Number(compra.total ?? 0)} />}
                {compra.notas && (
                  <div>
                    <span className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                      <FileText className="w-4 h-4 inline mr-1" />
                      Notas
                    </span>
                    <p className="px-4 py-2 rounded-lg bg-gray-50 dark:bg-gray-900 text-gray-800 dark:text-white whitespace-pre-wrap">{compra.notas}</p>
                  </div>
                )}
              </fieldset>
            </CompactErrorBoundary>
          </div>

          <div className="p-3 sm:p-4 border-t dark:border-gray-700 flex-shrink-0 flex flex-wrap gap-3">
            {!cancelada && onNotaCredito && (
              <Button
                type="button"
                onClick={() => onNotaCredito(compra)}
                variant="ghost"
                size="md"
                className="text-blue-600 dark:text-blue-400 border border-blue-200 dark:border-blue-800 hover:bg-blue-50 dark:hover:bg-blue-900/20"
              >
                <FileText className="w-4 h-4" />
                Nota de Credito
              </Button>
            )}
            {!cancelada && onAnular && (
              <Button
                type="button"
                onClick={() => setConfirmarAnular(true)}
                variant="ghost"
                size="md"
                className="text-red-600 dark:text-red-400 border border-red-200 dark:border-red-800 hover:bg-red-50 dark:hover:bg-red-900/20"
              >
                Anular Compra
              </Button>
            )}
            <Button type="button" onClick={onClose} variant="secondary" size="md" className="flex-1">
              Cerrar
            </Button>
          </div>
        </div>
      </VerCompraContext.Provider>

      {/* ADENTRO de ModalBase: como hermano en el container quedaría detrás
          del overlay de Radix y fallaría en silencio (CLAUDE.md). */}
      {confirmarAnular && onAnular && (
        <Suspense fallback={null}>
          <ModalConfirmacion
            config={{
              visible: true,
              tipo: 'danger',
              titulo: 'Anular compra',
              mensaje: '¿Anular esta compra? Se revertirá el stock de los productos.',
              onConfirm: () => {
                setConfirmarAnular(false)
                void onAnular(String(compra.id))
              },
            }}
            onClose={() => setConfirmarAnular(false)}
          />
        </Suspense>
      )}
    </ModalBase>
  )
}

// =============================================================================
// MODO 'editar': la compra guardada, editable (líneas y cargos)
// =============================================================================

/**
 * Editar una compra = el formulario de carga arrancando desde la compra
 * guardada. Reemplaza a ModalEditarCompra (admin, 7 días: la regla la aplica
 * VistaCompras con `adminPuedeEditarCompra` y la vuelve a aplicar la RPC).
 *
 * El estado sale de `hidratarCompraGuardada` —pesos todos manuales, afecta-base
 * manual, II/IVA/bonificación del snapshot— y desde ahí cada edición se
 * comporta como en 'nueva', con una excepción: si cambia la cantidad de una
 * línea, el peso manual de un cargo por cantidad se marca desactualizado con
 * un "recalcular" (utils/pesosDesactualizados) en vez de pisarse solo.
 *
 * El cabezal (proveedor, fecha, número, tipo, forma de pago, notas) NO se
 * edita, igual que antes: se muestra con el render de 'ver'. El proveedor se
 * corrige con "Cambiar proveedor" (ModalCambiarProveedor), que se traba con
 * cambios sin guardar —cargos incluidos— porque clona la compra de la BASE.
 *
 * No toca el borrador local: el borrador es sólo de 'nueva'.
 *
 * Lo que se valida y lo que viaja vive en utils/edicionCompra.
 */
function ModalCompraEditar({
  compra, productos, proveedores, categorias = [], marcas = [], onClose, onCrearProductoRapido,
  onGuardarEdicion, usuarioId = null, lotes, canCambiarProveedor = false, onCambiarProveedor,
}: ModalCompraProps & { compra: CompraDBExtended }) {
  // Se hidrata UNA vez, al montar: si la compra se refresca mientras se edita,
  // no se pisa lo tipeado.
  const [hidratada] = useState(() => hidratarCompraGuardada(compra))
  const [state, dispatch] = useReducer(compraReducer, hidratada.estado)
  // Contra qué se mide "hay cambios sin guardar": lo hidratado, más los
  // vencimientos cuando se precargan (precargar no es una edición del usuario).
  const [referencia, setReferencia] = useState<CompraState>(hidratada.estado)
  const leidos = cargosLeidos(compra)
  // Las medidas de la ficha y el catálogo (mig 278), para las líneas nuevas o
  // recalculadas de un cargo por medida. Las hidratadas quedan como estaban.
  useReferenciaMedidas(state, dispatch)

  // ── Vencimientos (migs 223/224) ────────────────────────────────────────────
  // Una sola vez, con un ref y no con una dependencia: los lotes llegan del
  // container y cualquier movimiento de lote refresca esa query, así que sin el
  // ref la precarga volvería a correr y pisaría lo que se esté tipeando. Sin
  // esto, guardar borraría los lotes: `sincronizar_lotes_compra` recibe la FOTO
  // completa (y se llama aunque la lista esté vacía).
  const vencimientosPrecargados = useRef(false)
  useEffect(() => {
    if (vencimientosPrecargados.current || !lotes) return
    vencimientosPrecargados.current = true
    if (lotes.length === 0) return
    const porProducto = Object.fromEntries(vencimientosDeLotes(lotes))
    dispatch({ type: 'PRECARGAR_VENCIMIENTOS', payload: porProducto })
    setReferencia(r => ({
      ...r,
      items: r.items.map(it => {
        const v = porProducto[String(it.productoId)]
        return v ? { ...it, vencimientos: v } : it
      }),
    }))
  }, [lotes])

  const totalesMotor = useCalculosImpuestos(
    state.items, state.tipoFactura, state.percepcionIva, state.percepcionIibb, state.noGravado,
    state.cargos, state.iiDeclarado, Number(compra.otros_impuestos ?? 0)
  )
  const totales = useMemo(() => totalesDeEdicion(compra, totalesMotor), [compra, totalesMotor])

  const resolucionII = useMemo(
    () => resolucionBasesII(state.items, state.cargos, state.iiDeclarado, state.tipoFactura),
    [state.items, state.cargos, state.iiDeclarado, state.tipoFactura]
  )

  // #908. Al editar, el "total de la factura" es el total GUARDADO de la compra
  // (hidratarCompra), no lo que dice el papel: si la compra se guardó sin la
  // bonificación, coincide con lo calculado y desmentiría la sugerencia. Sólo
  // corrobora el gravado, si se tipeó. Sin plantilla: la "última compra" del
  // proveedor puede ser esta misma.
  const { data: conceptosEdicion } = useCargoConceptosQuery()
  const sugerenciasBonif = useMemo(
    () => sugerenciasBonificacion(state, {
      gravadoImpreso: state.controlFactura.gravado,
      gravadoCalculado: totalesMotor.netoGravado,
      totalImpreso: 0,
      totalCalculado: 0,
    }, null),
    [state, totalesMotor]
  )
  const conceptoBonificacion = conceptoPorNombre(conceptosEdicion ?? [], 'Bonificación') ?? null

  const hayCambios = useMemo(() => edicionCompraTieneCambios(referencia, state), [referencia, state])

  // El aviso "la ficha dice otra cosa" sólo para las líneas agregadas acá: en
  // las guardadas, la ficha es la de HOY y la compra no.
  const condicionMaster = useMemo<Record<string, string>>(() => {
    const originales = new Set([...hidratada.itemPorLinea.values()].map(i => String(i.producto_id)))
    return Object.fromEntries(productos
      .filter(p => !originales.has(String(p.id)))
      .map(p => [
        String(p.id),
        (p.condicion_iva ?? 'gravado') === 'gravado'
          ? `gravado:${p.porcentaje_iva ?? 21}`
          : (p.condicion_iva ?? 'gravado'),
      ]))
  }, [productos, hidratada])

  const catalogoAlta = useCatalogoAltaRapida(
    categorias, marcas, proveedores, compra.proveedor_id ? String(compra.proveedor_id) : '',
  )
  const productosFiltrados = useProductosFiltrados(productos, state.busquedaProducto)

  // La anterior de ESTA compra, como en 'ver'; el costo que se compara es el
  // recalculado con lo que se está editando.
  const { data: costosAnteriores } = useCostosAnterioresQuery(
    state.items.map(i => String(i.productoId)),
    { compraId: String(compra.id), fechaCompra: state.fechaCompra, numeroFactura: state.numeroFactura },
  )

  // El cabezal se muestra con el render de 'ver' (texto, sin inputs).
  const contextoCabezal = useMemo<ContextoVer>(() => ({
    itemPorLinea: hidratada.itemPorLinea,
    costoGuardadoPorLinea: hidratada.costoGuardadoPorLinea,
    vencimientosPorProducto: new Map(),
    proveedorCuit: compra.proveedor?.cuit ?? null,
  }), [hidratada, compra.proveedor?.cuit])

  const puedeCambiarProveedor = Boolean(canCambiarProveedor && onCambiarProveedor && compra.estado !== 'cancelada')

  const handleGuardar = async () => {
    dispatch({ type: 'SET_ERROR', payload: '' })
    const error = validarEdicionCompra(state)
    if (error) {
      dispatch({ type: 'SET_ERROR', payload: error })
      return
    }
    if (!onGuardarEdicion) return
    dispatch({ type: 'SET_GUARDANDO', payload: true })
    try {
      await onGuardarEdicion(armarEdicionCompra({ compra, state, totales, usuarioId }))
    } catch (err) {
      // Las RPCs devuelven sus rechazos como {success:false} con HTTP 200 y el
      // container los convierte en Error. El mensaje queda ACÁ, con el modal
      // abierto: un toast que se va solo no alcanza para corregir y reintentar.
      dispatch({ type: 'SET_ERROR', payload: err instanceof Error ? err.message : 'No se pudo actualizar la compra.' })
    } finally {
      dispatch({ type: 'SET_GUARDANDO', payload: false })
    }
  }

  // Escape no cierra si hay algo sin guardar (la X y "Cancelar" sí).
  const handleEscapeKeyDown = (event: KeyboardEvent) => {
    const enfocado = document.activeElement
    const comboboxAbierto = enfocado?.getAttribute('role') === 'combobox' &&
      enfocado.getAttribute('aria-expanded') === 'true'
    if (state.mostrarBuscador || comboboxAbierto || hayCambios) event.preventDefault()
  }

  return (
    <ModalBase
      title={`Editar Compra #${compra.id}`}
      onClose={onClose}
      maxWidth="max-w-6xl"
      bodyBare
      onEscapeKeyDown={handleEscapeKeyDown}
    >
      <div className="flex flex-1 min-h-0 flex-col">
        <p className="px-4 py-2 border-b dark:border-gray-700 text-sm text-gray-500 dark:text-gray-400 flex-shrink-0">
          Se editan las líneas y los cargos. El proveedor, la factura, la fecha, el tipo, la forma de pago y las notas quedan como están.
        </p>

        <div className="flex-1 overflow-y-auto">
          <CompactErrorBoundary componentName="ModalCompra" onClose={onClose}>
            <div className="p-3 sm:p-4 space-y-4">
              <VerCompraContext.Provider value={contextoCabezal}>
                <fieldset disabled className="space-y-4 min-w-0 border-0 m-0 p-0">
                  <legend className="sr-only">Cabezal de la compra, no se edita</legend>
                  <ProveedorSection state={state} dispatch={dispatch} proveedores={proveedores} />
                  <DatosCompraSection state={state} dispatch={dispatch} />
                </fieldset>
              </VerCompraContext.Provider>

              {puedeCambiarProveedor && (
                <div className="flex flex-wrap items-center gap-2">
                  <Button
                    type="button"
                    onClick={() => onCambiarProveedor?.()}
                    disabled={hayCambios}
                    title={hayCambios
                      ? 'Guardá o descartá los cambios primero'
                      : 'Anular y recrear la compra con otro proveedor'}
                    variant="ghost"
                    size="md"
                    className="text-amber-800 dark:text-amber-300 border border-amber-300 dark:border-amber-700 hover:bg-amber-50 dark:hover:bg-amber-900/30"
                  >
                    <Building2 className="w-4 h-4" />
                    Cambiar proveedor
                  </Button>
                  {hayCambios && (
                    <span className="text-xs text-gray-500 dark:text-gray-400">
                      Guardá los cambios primero: el cambio de proveedor copia la compra como está guardada.
                    </span>
                  )}
                </div>
              )}

              <ProductosSection
                state={state}
                dispatch={dispatch}
                productosFiltrados={productosFiltrados}
                condicionMaster={condicionMaster}
                onAgregarItem={(producto) => dispatch({ type: 'AGREGAR_ITEM', payload: producto })}
                onActualizarItem={(index, campo, valor) => dispatch({ type: 'ACTUALIZAR_ITEM', payload: { index, campo, valor } })}
                onCondicionItem={(index, clave) => dispatch({ type: 'SET_CONDICION_ITEM', payload: { index, clave } })}
                onEliminarItem={(index) => dispatch({ type: 'ELIMINAR_ITEM', payload: index })}
                onVencimientosItem={(index, vencimientos) => dispatch({ type: 'SET_VENCIMIENTOS_ITEM', payload: { index, vencimientos } })}
                catalogo={catalogoAlta}
                onCrearProductoRapido={onCrearProductoRapido}
              />

              {state.items.length > 0 && (
                <>
                  {leidos ? (
                    <CargosSection state={state} dispatch={dispatch} resolucion={resolucionII} abiertaInicial
                                   sugerencias={sugerenciasBonif} conceptoBonificacion={conceptoBonificacion} />
                  ) : (
                    // Sin el embed no se sabe qué cargos tiene: ofrecer editarlos
                    // sería reescribirlos desde cero. Se guarda con `cargos: null`
                    // y la RPC rechaza si la compra tiene alguno.
                    <p className="p-3 rounded-lg bg-amber-50 dark:bg-amber-900/20 text-sm text-amber-800 dark:text-amber-300">
                      No se pudieron leer los cargos de esta compra, así que no se pueden editar. Recargá la página antes de guardar.
                    </p>
                  )}
                  <VistaPreviaCostosSection state={state} anteriores={costosAnteriores} />
                  <ResumenSection totales={totales} state={state} dispatch={dispatch} resolucion={resolucionII} percepcionesFijas />
                </>
              )}

              {compra.notas && (
                <div>
                  <span className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                    <FileText className="w-4 h-4 inline mr-1" />
                    Notas
                  </span>
                  <p className="px-4 py-2 rounded-lg bg-gray-50 dark:bg-gray-900 text-gray-800 dark:text-white whitespace-pre-wrap">{compra.notas}</p>
                </div>
              )}
            </div>
          </CompactErrorBoundary>
        </div>

        <div className="p-3 sm:p-4 border-t dark:border-gray-700 flex-shrink-0 space-y-3">
          {/* Al editar, el cuadre es contra el total que la compra YA tenía. */}
          {state.items.length > 0 && (
            <BarraCuadre
              total={totales.total}
              totalFactura={0}
              conControl={false}
              onTotalFactura={() => {}}
              totalOriginal={Number(compra.total ?? 0)}
            />
          )}
          {state.error && (
            <div role="alert" className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
              <p className="text-sm text-red-600 dark:text-red-400">{state.error}</p>
            </div>
          )}
          <div className="flex gap-3">
            <Button type="button" onClick={onClose} disabled={state.guardando} variant="secondary" size="md" className="flex-1">
              Cancelar
            </Button>
            <Button
              type="button"
              onClick={handleGuardar}
              disabled={state.guardando}
              loading={state.guardando}
              variant="success"
              size="md"
              className="flex-1"
            >
              {!state.guardando && <Save className="w-4 h-4" />}
              {state.guardando ? 'Guardando...' : 'Guardar cambios'}
            </Button>
          </div>
        </div>
      </div>
    </ModalBase>
  )
}

/**
 * Los totales TAL COMO SE GUARDARON en la cabecera. En 'ver' no se recalculan:
 * una compra vieja (sin cargos, sin snapshot de II) recalculada hoy podría dar
 * otro número, y lo que vale es lo que quedó registrado.
 */
function TotalesGuardados({ compra }: { compra: CompraDBExtended }) {
  const n = (v: number | null | undefined) => Number(v ?? 0)
  const fila = (label: string, valor: number, clase = 'text-gray-800 dark:text-white') => (
    <div className="flex justify-between text-sm">
      <span className="text-gray-600 dark:text-gray-400">{label}</span>
      <span className={`font-medium ${clase}`}>{formatPrecio(valor)}</span>
    </div>
  )
  return (
    <div className="bg-green-50 dark:bg-green-900/20 rounded-lg p-4 space-y-2">
      <div className="flex items-center gap-2">
        <Calculator className="w-5 h-5 text-green-600" />
        <h3 className="font-medium text-gray-800 dark:text-white">Totales registrados</h3>
      </div>
      {fila('Subtotal:', n(compra.subtotal))}
      {fila('IVA:', n(compra.iva))}
      {n(compra.impuestos_internos) > 0 && fila('Impuestos internos:', n(compra.impuestos_internos))}
      {n(compra.percepcion_iva) > 0 && fila('Percepción IVA:', n(compra.percepcion_iva))}
      {n(compra.percepcion_iibb) > 0 && fila('Percepción IIBB:', n(compra.percepcion_iibb))}
      {n(compra.no_gravado) > 0 && fila('No gravado (cabecera):', n(compra.no_gravado))}
      {/* Sin esta fila el total no cierra contra las de arriba: el subtotal es
          el neto de los RENGLONES y la bonificación general no es un renglón. */}
      {n(compra.bonificaciones) !== 0 && fila('Bonificaciones de la factura:', n(compra.bonificaciones), 'text-orange-600 dark:text-orange-400')}
      {n(compra.otros_impuestos) > 0 && fila('Otros impuestos:', n(compra.otros_impuestos))}
      <div className="flex justify-between text-lg font-bold pt-2 border-t border-green-200 dark:border-green-800">
        <span className="text-gray-800 dark:text-white">Total:</span>
        <span className="text-green-600">{formatPrecio(n(compra.total))}</span>
      </div>
    </div>
  )
}

function NotasCreditoDeLaCompra({ notas, totalCompra }: { notas: NotaCreditoDeLaCompra[]; totalCompra: number }) {
  // Los ajustes sin mercadería (mig 280) abaratan lo que quedó de la compra;
  // una devolución no: lo devuelto deja de ser de esta compra.
  const hayAjustes = notas.some(nc => nc.tipo === 'ajuste')
  const costoEfectivo = costoEfectivoCompra(totalCompra, notas)
  return (
    <div className="bg-blue-50 dark:bg-blue-900/20 rounded-lg p-4">
      <div className="flex items-center gap-2 mb-3">
        <FileText className="w-5 h-5 text-blue-600" />
        <h3 className="font-medium text-gray-800 dark:text-white">Notas de Credito ({notas.length})</h3>
      </div>
      {hayAjustes && (
        <div className="flex justify-between items-baseline mb-3 text-sm" data-testid="costo-efectivo">
          <span className="text-gray-600 dark:text-gray-400">Costo efectivo (total − ajustes sin mercadería):</span>
          <span className="font-bold text-gray-800 dark:text-white">{formatPrecio(costoEfectivo)}</span>
        </div>
      )}
      <div className="space-y-3">
        {notas.map(nc => (
          <div key={nc.id} className="bg-white dark:bg-gray-800 rounded-lg p-3 border border-blue-200 dark:border-blue-800">
            <div className="flex justify-between items-start mb-2">
              <div>
                <span className="text-sm font-medium text-gray-800 dark:text-white">{nc.numero_nota || `NC #${nc.id}`}</span>
                <span className="ml-2 text-xs text-gray-500">{new Date(nc.fecha).toLocaleDateString('es-AR')}</span>
                {nc.tipo === 'ajuste' && (
                  <Badge tone="brand" className="ml-2 text-[11px]">Ajuste sin mercadería</Badge>
                )}
              </div>
              <span className="text-sm font-bold text-blue-600">-{formatPrecio(nc.total)}</span>
            </div>
            {nc.motivo && <p className="text-xs text-gray-500 dark:text-gray-400 mb-2">{nc.motivo}</p>}
            {Number(nc.impuestos_internos) > 0 && (
              <p className="text-xs text-gray-500 dark:text-gray-400 mb-2">Impuestos internos: {formatPrecio(Number(nc.impuestos_internos))}</p>
            )}
            {nc.items && nc.items.length > 0 && (
              <div className="text-xs text-gray-600 dark:text-gray-400 space-y-1">
                {nc.items.map((item, idx) => (
                  <div key={idx} className="flex justify-between">
                    <span>{item.producto?.nombre || 'Producto'} x{item.cantidad}</span>
                    <span>{formatPrecio(item.subtotal)}</span>
                  </div>
                ))}
              </div>
            )}
          </div>
        ))}
      </div>
    </div>
  )
}

/** "+12,3%" rojo / "−4,1%" verde contra la compra anterior del producto. */
function VariacionCosto({ actual, anterior, tipoFactura }: {
  actual: number | undefined | null;
  anterior: CostoAnterior | undefined;
  tipoFactura: 'ZZ' | 'FC';
}) {
  if (!anterior) return null
  const v = variacionCosto(actual, anterior.costoRealUnitario)
  if (v === null) return null
  const { texto, tono } = formatearVariacion(v)
  const clase = tono === 'sube'
    ? 'text-red-600 dark:text-red-400'
    : tono === 'baja' ? 'text-green-600 dark:text-green-400' : 'text-gray-500'
  return (
    <span
      data-testid="variacion-costo"
      className={`ml-1 text-[11px] font-medium tabular-nums ${clase}`}
      title={tooltipCostoAnterior(anterior, tipoFactura, fechaLocalISO())}
    >
      {texto}
    </span>
  )
}

// Subcomponentes para mejor organización

function ProveedorSection({ state, dispatch, proveedores, onAgregarProveedor }: ProveedorSectionProps) {
  const ver = useContextoVer()
  if (ver) {
    // En 'ver' el nombre va como texto: el proveedor puede no estar en la lista
    // (dado de baja, o el nombre suelto de un escaneo) y el combobox deshabilitado
    // lo mostraría vacío.
    return (
      <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-3 sm:p-4">
        <div className="flex items-center gap-2 mb-2">
          <Building2 className="w-5 h-5 text-gray-500" />
          <h3 className="font-medium text-gray-800 dark:text-white">Proveedor</h3>
        </div>
        <p className="text-lg font-medium text-gray-800 dark:text-white">
          {state.proveedorNombre || 'Sin proveedor especificado'}
        </p>
        {ver.proveedorCuit && <p className="text-sm text-gray-500">CUIT: {ver.proveedorCuit}</p>}
      </div>
    )
  }
  return (
    <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-3 sm:p-4 space-y-3">
      <div className="flex items-center gap-2 mb-2">
        <Building2 className="w-5 h-5 text-gray-500" />
        <h3 className="font-medium text-gray-800 dark:text-white">Proveedor <span className="text-red-500">*</span></h3>
      </div>

      <div className="flex items-center gap-2">
        {/* Buscador y no <select>: con la lista de proveedores entera ya no se
            encontraba uno a ojo. Busca por nombre y por CUIT, sin tildes. */}
        <Combobox
          className="flex-1"
          opciones={proveedores}
          getKey={p => String(p.id)}
          getLabel={p => p.nombre}
          getTextosBusqueda={p => [p.nombre, p.cuit]}
          renderOpcion={p => (
            <span className="flex items-center justify-between gap-2">
              <span>{p.nombre}</span>
              {p.cuit && <span className="text-xs text-gray-500 tabular-nums">{p.cuit}</span>}
            </span>
          )}
          // Un proveedor del escaneo que no está dado de alta no tiene id:
          // se muestra su nombre tal cual vino.
          valor={state.usarProveedorNuevo ? null : (state.proveedorId ? String(state.proveedorId) : null)}
          textoSinOpcion={state.usarProveedorNuevo ? state.proveedorNombre : ''}
          onSeleccionar={p => {
            dispatch({ type: 'SET_PROVEEDOR_ID', payload: String(p.id) })
            // Elegir uno de la lista ES dejar de usar el nombre suelto del
            // escaneo; si no, se guardaría el nombre y no el elegido.
            if (state.usarProveedorNuevo) dispatch({ type: 'SET_USAR_PROVEEDOR_NUEVO', payload: false })
          }}
          onCrear={onAgregarProveedor ? (texto) => onAgregarProveedor(texto) : undefined}
          textoCrear={t => `+ Nuevo proveedor "${t}"`}
          placeholder="Buscar proveedor por nombre o CUIT..."
          aria-label="Proveedor de la factura"
          textoSinResultados="Ningún proveedor coincide"
        />
        {onAgregarProveedor && (
          <Button
            type="button"
            onClick={() => onAgregarProveedor()}
            variant="success"
            size="md"
            className="gap-1 whitespace-nowrap"
            title="Agregar proveedor nuevo"
          >
            <Plus className="w-4 h-4" />
            <span className="hidden sm:inline">Nuevo</span>
          </Button>
        )}
      </div>
    </div>
  )
}

/**
 * Aviso de factura ya cargada (utils/facturaDuplicada). No bloquea ni borra
 * nada: una factura partida entre sucursales es legal y, dentro de la misma,
 * puede haber una razón que el modal no conoce.
 */
function AvisoFacturaDuplicada({ compras }: { compras: CompraMismaFactura[] }) {
  const [verDetalle, setVerDetalle] = useState(false)
  const hoy = fechaLocalISO()
  const lista = compras
    .map(c => `#${c.id}${c.fechaCompra ? ` del ${fechaCortaCompra(c.fechaCompra, hoy)}` : ''}`)
    .join(', ')
  return (
    <div role="status" className="p-3 rounded-lg border border-amber-300 bg-amber-50 dark:border-amber-700 dark:bg-amber-900/20 text-sm text-amber-800 dark:text-amber-200">
      <div className="flex items-start gap-2">
        <AlertTriangle className="w-4 h-4 mt-0.5 shrink-0" />
        <p>
          {compras.length === 1 ? 'Ya hay una compra con este número' : `Ya hay ${compras.length} compras con este número`}
          {': '}{lista}{' '}
          <button
            type="button"
            onClick={() => setVerDetalle(v => !v)}
            aria-expanded={verDetalle}
            className="underline font-medium"
          >
            ({verDetalle ? 'ocultar' : 'ver'})
          </button>
        </p>
      </div>
      {verDetalle && (
        <ul className="mt-2 ml-6 space-y-0.5 text-xs">
          {compras.map(c => (
            <li key={c.id}>
              Compra #{c.id} · {fechaCortaCompra(c.fechaCompra, hoy) || 'sin fecha'} · factura {c.numeroFactura || '—'} · {formatPrecio(c.total)}
            </li>
          ))}
          <li className="pt-1 text-amber-700 dark:text-amber-300">
            Es sólo un aviso: si es otra factura, o la cargás a propósito, seguí.
          </li>
        </ul>
      )}
    </div>
  )
}

/** Lo que dice el storage al abrir: retomar, ver o descartar. Nunca se tira solo. */
function OfertaBorrador({ lectura, proveedores, onRetomar, onDescartar }: {
  lectura: LecturaBorrador;
  proveedores: ProveedorDBExtended[];
  onRetomar: () => void;
  onDescartar: () => void;
}) {
  if (lectura.tipo === 'ninguno') return null

  if (lectura.tipo === 'ok') {
    const { estado, guardadoEn } = lectura.borrador
    const cuando = fechaHoraBorrador(guardadoEn)
    const lineas = estado.items.length
    const proveedor = estado.usarProveedorNuevo
      ? estado.proveedorNombre
      : proveedores.find(p => String(p.id) === String(estado.proveedorId))?.nombre ?? ''
    const detalle = [proveedor, estado.numeroFactura && `factura ${estado.numeroFactura}`].filter(Boolean).join(' · ')
    return (
      <div className="p-4 sm:p-6">
        <div role="region" aria-label="Borrador sin registrar" className="p-4 rounded-lg border border-blue-200 bg-blue-50 dark:border-blue-800 dark:bg-blue-900/20 space-y-3">
          <p className="font-medium text-gray-800 dark:text-white">Tenés una compra a medio cargar, sin registrar.</p>
          {detalle && <p className="text-sm text-gray-600 dark:text-gray-300">{detalle}</p>}
          <div className="flex flex-col sm:flex-row gap-2">
            <Button type="button" variant="primary" size="md" onClick={onRetomar}>
              Retomar borrador del {cuando} ({lineas} {lineas === 1 ? 'línea' : 'líneas'})
            </Button>
            <Button type="button" variant="secondary" size="md" onClick={onDescartar}>
              Descartar
            </Button>
          </div>
        </div>
      </div>
    )
  }

  // Otra versión del formato, o algo que no se puede leer: no se carga a
  // ciegas. Se puede mirar (y copiar a mano) antes de descartarlo.
  const cuando = lectura.tipo === 'otra_version' ? fechaHoraBorrador(lectura.guardadoEn) : ''
  let contenido = lectura.crudo
  try { contenido = JSON.stringify(JSON.parse(lectura.crudo), null, 2) } catch { /* se muestra crudo */ }
  return (
    <div className="p-4 sm:p-6">
      <div role="region" aria-label="Borrador sin registrar" className="p-4 rounded-lg border border-amber-300 bg-amber-50 dark:border-amber-700 dark:bg-amber-900/20 space-y-3">
        <p className="font-medium text-gray-800 dark:text-white">
          {lectura.tipo === 'otra_version'
            ? `Hay un borrador${cuando ? ` del ${cuando}` : ''} guardado con otra versión de la app: no se puede retomar automáticamente.`
            : 'Hay un borrador guardado que no se puede leer.'}
        </p>
        <p className="text-sm text-gray-600 dark:text-gray-300">
          Podés mirarlo para copiar lo que te sirva y después descartarlo.
        </p>
        <details>
          <summary className="cursor-pointer text-sm text-blue-700 dark:text-blue-300">Ver contenido</summary>
          <pre className="mt-2 max-h-64 overflow-auto rounded bg-white p-2 text-xs dark:bg-gray-800 dark:text-gray-200">{contenido}</pre>
        </details>
        <Button type="button" variant="secondary" size="md" onClick={onDescartar}>
          Descartar
        </Button>
      </div>
    </div>
  )
}

/** Otra pestaña tocó el mismo borrador. */
function AvisoOtraPestana({ cambio, onCerrar }: { cambio: NonNullable<CambioEnOtraPestana>; onCerrar: () => void }) {
  return (
    <div role="alert" className="mx-3 sm:mx-4 mt-2 p-3 rounded-lg border border-amber-300 bg-amber-50 dark:border-amber-700 dark:bg-amber-900/20 flex items-start gap-2">
      <AlertTriangle className="w-4 h-4 text-amber-600 mt-0.5 shrink-0" />
      <p className="flex-1 text-sm text-amber-800 dark:text-amber-200">
        {cambio === 'borrado'
          ? 'En otra pestaña esta compra se registró o se descartó. Antes de registrar acá, revisá el listado de compras para no cargarla dos veces.'
          : 'Este borrador se está editando en otra pestaña. Seguí en una sola: lo que se guarde en una pisa lo de la otra.'}
      </p>
      <Button onClick={onCerrar} variant="ghost" size="iconSm" aria-label="Cerrar aviso" className="text-amber-600">
        <X className="w-4 h-4" />
      </Button>
    </div>
  )
}

/**
 * Calculado contra impreso, con la diferencia. La misma regla del panel
 * "Control contra factura": sin cargar no hay veredicto, y ± $1 es redondeo.
 */
function cuadreContraFactura(calculado: number, impreso: number) {
  const cargado = impreso > 0
  const diff = impreso - calculado
  return { cargado, diff, ok: Math.abs(diff) <= 1 }
}

/** El cuadre del total, fijo al pie del modal. */
function BarraCuadre({ total, totalFactura, conControl, onTotalFactura, totalOriginal }: {
  total: number;
  totalFactura: number;
  /** FC: hay "Factura dice". En ZZ sólo se muestra el total. */
  conControl: boolean;
  onTotalFactura: (n: number) => void;
  /**
   * 'editar': el total GUARDADO de la compra. Reemplaza a "Factura dice" (que
   * no se tipea) en FC y en ZZ: lo que se cuadra al editar es contra lo que la
   * compra ya tenía registrado.
   */
  totalOriginal?: number;
}) {
  if (totalOriginal !== undefined) {
    const { diff, ok } = cuadreContraFactura(total, totalOriginal)
    return (
      <div role="group" aria-label="Cuadre contra el total original" className="flex flex-wrap items-center gap-x-4 gap-y-1.5 text-sm">
        <span className="text-gray-600 dark:text-gray-400">
          Total calculado <span className="font-semibold text-gray-800 dark:text-white tabular-nums">{formatPrecio(total)}</span>
        </span>
        <span className="text-gray-600 dark:text-gray-400">
          Total original <span data-testid="cuadre-total-original" className="font-semibold text-gray-800 dark:text-white tabular-nums">{formatPrecio(totalOriginal)}</span>
        </span>
        <span
          data-testid="cuadre-diferencia"
          className={`font-medium tabular-nums ${ok ? 'text-green-600' : 'text-amber-600'}`}
        >
          {ok ? '✓ Igual al original' : `Dif. ${formatPrecio(-diff)}`}
        </span>
      </div>
    )
  }
  const { cargado, diff, ok } = cuadreContraFactura(total, totalFactura)
  return (
    <div role="group" aria-label="Cuadre contra la factura" className="flex flex-wrap items-center gap-x-4 gap-y-1.5 text-sm">
      <span className="text-gray-600 dark:text-gray-400">
        Total calculado <span className="font-semibold text-gray-800 dark:text-white tabular-nums">{formatPrecio(total)}</span>
      </span>
      {conControl && (
        <>
          <label className="flex items-center gap-1.5 text-gray-600 dark:text-gray-400">
            Factura dice
            <NumberInput
              min={0}
              emptyValue={0}
              value={totalFactura}
              onChange={onTotalFactura}
              commitOnChange
              aria-label="Total impreso en la factura"
              placeholder="total"
              className="w-32 px-2 py-1 text-right border dark:border-gray-600 rounded dark:bg-gray-700 dark:text-white text-sm"
            />
          </label>
          <span
            data-testid="cuadre-diferencia"
            className={`font-medium tabular-nums ${!cargado ? 'text-gray-400' : ok ? 'text-green-600' : 'text-red-600'}`}
          >
            {!cargado ? 'Dif. —' : ok ? '✓ Cierra' : `Dif. ${formatPrecio(diff)}`}
          </span>
        </>
      )}
    </div>
  )
}

function DatosCompraSection({ state, dispatch, onBlurNumero }: DatosCompraSectionProps) {
  const ver = useContextoVer()
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
          onBlur={onBlurNumero}
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
        {ver ? (
          // Como texto: el select no ofrece `cuenta_corriente`, que sigue en
          // compras históricas.
          <input
            type="text"
            value={ETIQUETA_FORMA_PAGO[state.formaPago] ?? state.formaPago}
            readOnly
            aria-label="Forma de Pago"
            className="w-full px-3 sm:px-4 py-2 border dark:border-gray-600 rounded-lg dark:bg-gray-700 dark:text-white text-sm sm:text-base"
          />
        ) : (
        <select
          value={state.formaPago}
          onChange={(e: ChangeEvent<HTMLSelectElement>) => dispatch({ type: 'SET_FORMA_PAGO', payload: e.target.value })}
          className="w-full px-3 sm:px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white text-sm sm:text-base"
        >
          {FORMAS_PAGO.map(fp => (
            <option key={fp.value} value={fp.value}>{fp.label}</option>
          ))}
        </select>
        )}
      </div>
    </div>
    </>
  )
}

/** Categoría, marca y proveedor del producto que se crea desde la factura. */
interface ClasificacionRapida {
  categoria: string;
  /** null = eligiendo de la lista; un string = escribiendo una nueva. */
  categoriaNueva: string | null;
  marcaId: string;
  marcaNueva: string | null;
  /** null = el de la factura, y lo sigue si cambia; un string = elegido a mano. */
  proveedorId: string | null;
  /** Encuadre de impuestos internos (mig 277). '' = sin definir. */
  iiEncuadreId: string;
}

const CLASIFICACION_VACIA: ClasificacionRapida = {
  categoria: '',
  categoriaNueva: null,
  marcaId: '',
  marcaNueva: null,
  proveedorId: null,
  iiEncuadreId: '',
}

function datosClasificacion(
  c: ClasificacionRapida,
  proveedorFactura: string,
): Pick<ProductoRapidoInput, 'categoria' | 'marcaId' | 'proveedorId' | 'categoriaNueva' | 'marcaNueva' | 'iiEncuadreId'> {
  return {
    categoria: c.categoria,
    marcaId: c.marcaId,
    proveedorId: c.proveedorId ?? proveedorFactura,
    categoriaNueva: c.categoriaNueva?.trim() ? c.categoriaNueva : undefined,
    marcaNueva: c.marcaNueva?.trim() ? c.marcaNueva : undefined,
    iiEncuadreId: c.iiEncuadreId,
  }
}

/**
 * Los campos de clasificación de las dos altas rápidas: la del buscador y la de
 * los ítems del escaneo que no se vincularon solos.
 *
 * El proveedor arranca en el de la factura y lo sigue: si se elige o se cambia
 * el de la compra con el alta abierta, el del producto cambia con él. Deja de
 * seguirlo cuando se lo elige a mano, que es el caso del producto que
 * habitualmente trae otro.
 */
function CamposClasificacion({ catalogo, valor, onChange }: {
  catalogo: CatalogoAltaRapida;
  valor: ClasificacionRapida;
  onChange: React.Dispatch<React.SetStateAction<ClasificacionRapida>>;
}) {
  const idProveedor = useId()
  const idEncuadre = useId()
  return (
    <div className="grid grid-cols-1 sm:grid-cols-4 gap-2">
      <SelectorConAlta
        compacto
        sustantivo="categoría"
        opciones={catalogo.categorias}
        valor={valor.categoria}
        onValor={(categoria) => onChange(prev => ({ ...prev, categoria }))}
        nuevo={valor.categoriaNueva}
        onNuevo={(categoriaNueva) => onChange(prev => ({ ...prev, categoriaNueva }))}
      />
      <SelectorConAlta
        compacto
        sustantivo="marca"
        opciones={catalogo.marcas}
        valor={valor.marcaId}
        onValor={(marcaId) => onChange(prev => ({ ...prev, marcaId }))}
        nuevo={valor.marcaNueva}
        onNuevo={(marcaNueva) => onChange(prev => ({ ...prev, marcaNueva }))}
      />
      <div>
        <label htmlFor={idProveedor} className="block text-xs text-gray-500 mb-1">Proveedor</label>
        <select
          id={idProveedor}
          value={valor.proveedorId ?? catalogo.proveedorFactura}
          onChange={(e: ChangeEvent<HTMLSelectElement>) => {
            const proveedorId = e.target.value
            onChange(prev => ({ ...prev, proveedorId }))
          }}
          className="w-full px-3 py-1.5 text-sm border dark:border-gray-600 rounded focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white"
        >
          <option value="">Sin proveedor</option>
          {catalogo.proveedores.map(p => (
            <option key={p.valor} value={p.valor}>{p.texto}</option>
          ))}
        </select>
      </div>
      {/* Sin esto el producto nace sin impuesto interno y su costo queda corto
          desde la primera compra (mig 277). */}
      <div>
        <label htmlFor={idEncuadre} className="block text-xs text-gray-500 mb-1">Imp. internos</label>
        <select
          id={idEncuadre}
          value={valor.iiEncuadreId}
          onChange={(e: ChangeEvent<HTMLSelectElement>) => {
            const iiEncuadreId = e.target.value
            onChange(prev => ({ ...prev, iiEncuadreId }))
          }}
          className="w-full px-3 py-1.5 text-sm border dark:border-gray-600 rounded focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white"
        >
          <option value="">Sin definir</option>
          {catalogo.encuadresII.map(e => (
            <option key={e.valor} value={e.valor}>{e.texto}</option>
          ))}
        </select>
      </div>
    </div>
  )
}

function ProductosSection({ state, dispatch, productosFiltrados, condicionMaster, onAgregarItem, onActualizarItem, onCondicionItem, onEliminarItem, onVencimientosItem, catalogo, onCrearProductoRapido, onImportarExcel, lineasNoVigentes }: ProductosSectionProps) {
  const ver = useContextoVer()
  const [itemRapido, setItemRapido] = useState({ nombre: '', codigo: '', costo: 0 })
  const [clasificacion, setClasificacion] = useState<ClasificacionRapida>(CLASIFICACION_VACIA)
  const [creandoItem, setCreandoItem] = useState(false)
  const buscadorRef = useRef<HTMLDivElement>(null)

  // Cerrar dropdown al hacer click fuera. En fase de CAPTURA: el contenido de
  // ModalBase corta la propagación de `mousedown` (para que Radix no tome un
  // arrastre como click afuera), y en burbujeo este listener no se enteraría
  // de ningún click adentro del modal.
  useEffect(() => {
    if (!state.mostrarBuscador) return
    const handleClickOutside = (e: MouseEvent) => {
      if (buscadorRef.current && !buscadorRef.current.contains(e.target as Node)) {
        dispatch({ type: 'SET_MOSTRAR_BUSCADOR', payload: false })
      }
    }
    document.addEventListener('mousedown', handleClickOutside, true)
    return () => document.removeEventListener('mousedown', handleClickOutside, true)
  }, [state.mostrarBuscador, dispatch])

  const handleCrearProductoRapido = async () => {
    if (!onCrearProductoRapido || !itemRapido.nombre.trim()) return
    setCreandoItem(true)
    try {
      const producto = await onCrearProductoRapido({
        nombre: itemRapido.nombre,
        codigo: itemRapido.codigo,
        costoSinIva: itemRapido.costo,
        ...datosClasificacion(clasificacion, catalogo.proveedorFactura),
      })
      dispatch({ type: 'AGREGAR_ITEM_RAPIDO', payload: {
        productoId: producto.id,
        nombre: producto.nombre,
        codigo: producto.codigo || '',
        costoUnitario: producto.costo_sin_iva || itemRapido.costo,
        impuestosInternos: Number(producto.impuestos_internos ?? 0),
      }})
      setItemRapido({ nombre: '', codigo: '', costo: 0 })
      setClasificacion(CLASIFICACION_VACIA)
    } catch {
      // El toast lo tira el container. Acá se deja el formulario intacto —con
      // lo que la usuaria tipeó— para que pueda corregir el dato que falló.
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
          <Button
            type="button"
            onClick={onImportarExcel}
            variant="ghost"
            size="sm"
            className="gap-1 text-blue-600 hover:text-blue-700 dark:text-blue-400"
          >
            <FileText className="w-4 h-4" />
            Importar Excel
          </Button>
        )}
      </div>

      {/* Buscador de productos: sólo para cargar. */}
      {!ver && (
      <div className="relative" ref={buscadorRef}>
        <div className="flex items-center gap-2">
          <div className="relative flex-1">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" />
            <input
              type="text"
              value={state.busquedaProducto}
              onChange={(e: ChangeEvent<HTMLInputElement>) => dispatch({ type: 'SET_BUSQUEDA', payload: e.target.value })}
              onFocus={() => dispatch({ type: 'SET_MOSTRAR_BUSCADOR', payload: true })}
              onKeyDown={(e) => {
                if (e.key !== 'Escape') return
                // Este Escape es de la lista, no del modal. El stopPropagation
                // no alcanza para frenar a Radix, que lo escucha en captura
                // antes que este handler: lo que deja el modal abierto es el
                // `mostrarBuscador` que mira su onEscapeKeyDown.
                e.stopPropagation()
                dispatch({ type: 'SET_MOSTRAR_BUSCADOR', payload: false })
              }}
              placeholder="Buscar producto por nombre o codigo..."
              className="w-full pl-10 pr-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
            />
          </div>
          {onCrearProductoRapido && (
            <Button
              type="button"
              onClick={() => {
                dispatch({ type: 'SET_MODO_ITEM_RAPIDO', payload: !state.modoItemRapido })
                dispatch({ type: 'SET_MOSTRAR_BUSCADOR', payload: false })
              }}
              variant="primary"
              size="icon"
              title="Crear producto nuevo"
            >
              <Plus className="w-4 h-4" />
            </Button>
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
                  <Button
                    type="button"
                    onClick={() => {
                      dispatch({ type: 'SET_MODO_ITEM_RAPIDO', payload: true })
                      dispatch({ type: 'SET_MOSTRAR_BUSCADOR', payload: false })
                      setItemRapido(prev => ({ ...prev, nombre: state.busquedaProducto }))
                    }}
                    variant="ghost"
                    size="sm"
                    className="mt-1 gap-1 text-green-600 hover:underline dark:text-green-400"
                  >
                    <Plus className="w-3 h-3" /> Crear producto rapido
                  </Button>
                )}
              </div>
            )}
          </div>
        )}
      </div>

      )}

      {/* Formulario de item rapido */}
      {!ver && state.modoItemRapido && onCrearProductoRapido && (
        <div className="bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-lg p-3 space-y-2">
          <div className="flex items-center justify-between">
            <p className="text-sm font-medium text-blue-800 dark:text-blue-300">Crear producto rapido</p>
            <Button
              type="button"
              onClick={() => dispatch({ type: 'SET_MODO_ITEM_RAPIDO', payload: false })}
              variant="ghost"
              size="iconSm"
              className="text-blue-400 hover:text-blue-600 dark:text-blue-400 dark:hover:text-blue-600"
            >
              <X className="w-4 h-4" />
            </Button>
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
          <CamposClasificacion catalogo={catalogo} valor={clasificacion} onChange={setClasificacion} />
          <Button
            type="button"
            onClick={handleCrearProductoRapido}
            disabled={!itemRapido.nombre.trim() || creandoItem}
            loading={creandoItem}
            variant="primary"
            size="sm"
            className="w-full gap-1"
          >
            {!creandoItem && <Plus className="w-3 h-3" />}
            {creandoItem ? 'Creando...' : 'Crear y Agregar'}
          </Button>
        </div>
      )}

      {/* Lista de items */}
      {state.items.length > 0 ? (
        <ItemsList items={state.items} onActualizarItem={onActualizarItem} onCondicionItem={onCondicionItem} onEliminarItem={onEliminarItem} onVencimientosItem={onVencimientosItem} condicionMaster={condicionMaster} lineasNoVigentes={lineasNoVigentes} />
      ) : ver ? (
        // La RLS de compra_items y compra_cargos puede dejar la compra visible
        // y las líneas no (hoy las tres piden admin o depósito, pero son
        // policies separadas). Una nota y no una tabla vacía que parece rota.
        <p className="py-4 text-sm text-gray-500 dark:text-gray-400">
          No se pueden mostrar las líneas ni los cargos de esta compra: tu usuario no tiene acceso a ese detalle.
          Los totales de abajo son los registrados.
        </p>
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

function ItemsList({ items, onActualizarItem, onCondicionItem, onEliminarItem, onVencimientosItem, condicionMaster, lineasNoVigentes }: ItemsListProps) {
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
          onVencimientosItem={onVencimientosItem}
          condicionDelProducto={condicionMaster[String(item.productoId)]}
          productoNoVigente={item.lineaId !== undefined && !!lineasNoVigentes?.has(item.lineaId)}
        />
      ))}
    </div>
  )
}

/**
 * La tasa de impuesto interno de la línea, para mostrar. No se edita (mig 277):
 * sale del encuadre de la ficha. Antes era un input y lo tipeado viajaba de
 * vuelta a la ficha; así entraron el 9,18 y el 4,24 —el factor del Excel— en
 * nueve productos, y la próxima factura los autocompletaba.
 */
function TasaIILinea({ item }: { item: CompraItemForm }) {
  const tasa = item.impuestosInternos || 0
  return (
    <span
      className="block w-full px-2 py-1 text-center text-sm text-gray-700 dark:text-gray-300 tabular-nums"
      title="Tasa efectiva de impuestos internos: sale del encuadre del producto. Para cambiarla, editá el encuadre en la ficha."
    >
      {tasa ? `${String(tasa).replace('.', ',')}%` : '—'}
    </span>
  )
}

/**
 * ¿La condición de la línea difiere de la de la ficha? NO se propaga al
 * producto: sólo se avisa (la venta hereda de la ficha).
 */
function difiereCondicion(item: CompraItemForm, condicionDelProducto?: string): boolean {
  if (condicionDelProducto === undefined) return false
  return claveCondicionLinea(item) !== condicionDelProducto
}

function ItemRow({ item, index, onActualizarItem, onCondicionItem, onEliminarItem, onVencimientosItem, condicionDelProducto, productoNoVigente }: ItemRowProps) {
  const ver = useContextoVer()
  const condDifiere = difiereCondicion(item, condicionDelProducto)
  // En 'ver': el stock de ESA compra (antes → después) y, si la línea es
  // anterior al snapshot de alícuota, que el IVA no se sabe.
  const guardada = ver && item.lineaId !== undefined ? ver.itemPorLinea.get(item.lineaId) : undefined
  const ivaSinDato = !!guardada && guardada.porcentaje_iva == null && (guardada.condicion_iva ?? 'gravado') === 'gravado'
  const lineaStock = guardada
    ? `Stock: ${guardada.stock_anterior ?? '—'} → ${guardada.stock_nuevo ?? '—'}${ivaSinDato ? ' · IVA s/d' : ''}`
    : `Stock: ${item.stockActual}`
  const papelera = (
    <button
      type="button"
      onClick={() => onEliminarItem(index)}
      className="p-1 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded"
    >
      <Trash2 className="w-4 h-4" />
    </button>
  )
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
    <div className={`bg-white dark:bg-gray-800 p-3 rounded-lg border ${productoNoVigente ? 'border-red-400 dark:border-red-600' : condDifiere ? 'border-amber-400 dark:border-amber-600' : 'dark:border-gray-600'}`}>
      {/* Línea de un borrador retomado: el producto se borró o se dio de baja
          desde que se guardó. Se marca y no se quita: decide quien carga. */}
      {productoNoVigente && (
        <p className="mb-2 text-xs font-medium text-red-700 dark:text-red-400">
          ⚠ Este producto ya no existe o está inactivo. Quitá la línea o reemplazala por otro producto.
        </p>
      )}
      {/* Mobile: Layout en cards */}
      <div className="md:hidden space-y-3">
        <div className="flex justify-between items-start">
          <div className="flex-1">
            <p className="font-medium text-gray-800 dark:text-white">{item.productoNombre}</p>
            <p className="text-xs text-gray-500">{lineaStock}</p>
          </div>
          {!ver && papelera}
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
              aria-label={`Cantidad de ${item.productoNombre}`}
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
            <span className="block text-xs text-gray-500 mb-1">II%</span>
            <TasaIILinea item={item} />
          </div>
        </div>
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
          <p className="text-xs text-gray-500">{lineaStock}</p>
        </div>
        <div className="col-span-1">
          <NumberInput
            integer
            min={1}
            emptyValue={1}
            value={item.cantidad}
            onChange={(n) => onActualizarItem(index, 'cantidad', n)}
            commitOnChange
            aria-label={`Cantidad de ${item.productoNombre}`}
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
          <TasaIILinea item={item} />
        </div>
        <div className="col-span-1 text-right font-medium text-gray-800 dark:text-white text-sm">
          {formatPrecio(item.cantidad * item.costoUnitario * (1 - (item.bonificacion || 0) / 100))}
        </div>
        <div className="col-span-1 text-right">
          {!ver && papelera}
        </div>
      </div>
      {condDifiere && (
        <p className="hidden md:block text-xs text-amber-700 dark:text-amber-300 mt-1">
          ⚠ La ficha dice {labelCondicionIva(condicionDelProducto!)}: el cambio aplica sólo a esta compra, el producto no se toca.
        </p>
      )}
      {/* Al pie de la card y fuera de los dos layouts: así aparece UNA sola vez
          en mobile y en desktop, en vez de duplicarse. */}
      {ver ? (
        // Los lotes que cargó esta compra (migs 223/224), como texto.
        ver.vencimientosPorProducto.get(String(item.productoId))?.length ? (
          <p className="mt-1 text-xs text-indigo-700 dark:text-indigo-300">
            Vence: {ver.vencimientosPorProducto.get(String(item.productoId))!.join(' · ')}
          </p>
        ) : null
      ) : (
        <VencimientosLineaCompra
          cantidadLinea={item.cantidad}
          vencimientos={item.vencimientos ?? []}
          onChange={(v) => onVencimientosItem(index, v)}
        />
      )}
    </div>
  )
}

/**
 * Proveedor y líneas del escaneo contra el catálogo (utils/matchEscaneo). La
 * misma cuenta para la vista previa y para "Aplicar datos", así lo que la
 * vista previa promete es lo que pasa.
 *
 * El proveedor se toma sólo por CUIT (vinculado): uno parecido por nombre no
 * se elige solo, queda como nombre tipeado, igual que antes.
 */
function resolverEscaneo(
  scan: FacturaEscaneada,
  productos: ProductoDB[],
  proveedores: ProveedorDBExtended[],
  candidatos: CandidatosEscaneo,
): { proveedorIdMatch: string; resultados: ResultadoMatchLinea[] } {
  const prov = matchProveedor({ nombre: scan.proveedorNombre, cuit: scan.proveedorCuit }, proveedores)
  const proveedorIdMatch = prov.estado === 'vinculado' && prov.proveedorId ? prov.proveedorId : ''
  const resultados = matchEscaneo({
    lineas: scan.items.map(i => ({
      codigo: i.codigo, descripcion: i.descripcion, cantidad: i.cantidad, precioUnitarioNeto: i.costoUnitario,
    })),
    proveedorId: proveedorIdMatch || null,
    catalogo: productos,
    equivalencias: candidatos.equivalencias,
    comprados: candidatos.comprados,
  })
  return { proveedorIdMatch, resultados }
}

/** Preview del resultado del escaneo de factura */
function ScanPreview({ resultado, productos, proveedores, onAplicar, onDescartar }: {
  resultado: FacturaEscaneada;
  productos: ProductoDB[];
  proveedores: ProveedorDBExtended[];
  onAplicar: (candidatos: CandidatosEscaneo) => void;
  onDescartar: () => void;
}) {
  const proveedorCuit = matchProveedor({ nombre: resultado.proveedorNombre, cuit: resultado.proveedorCuit }, proveedores)
  const proveedorMatchId = proveedorCuit.estado === 'vinculado' ? proveedorCuit.proveedorId ?? null : null
  // Si la consulta falla, se sigue con el catálogo solo: el escaneo no se
  // traba porque no se pudo leer lo aprendido.
  const candidatosQuery = useCandidatosEscaneoQuery(proveedorMatchId)
  const candidatos = candidatosQuery.data ?? CANDIDATOS_VACIOS
  const cargandoCandidatos = !!proveedorMatchId && candidatosQuery.isLoading

  const { resultados } = useMemo(
    () => resolverEscaneo(resultado, productos, proveedores, candidatos),
    [resultado, productos, proveedores, candidatos],
  )
  const itemsMatcheados = resultados.filter(r => r.estado === 'vinculado').length
  const itemsSugeridos = resultados.filter(r => r.estado === 'sugerido').length
  const itemsPendientes = resultados.length - itemsMatcheados - itemsSugeridos
  const proveedorMatch = proveedorMatchId !== null

  // Primero lo que no cierra, después los avisos.
  const advertencias = [...(resultado.advertencias ?? [])].sort(
    (a, b) => (a.nivel === b.nivel ? 0 : a.nivel === 'error' ? -1 : 1)
  )
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
        <Button onClick={onDescartar} variant="ghost" size="iconSm" className="text-purple-400 hover:text-purple-600 dark:text-purple-400 dark:hover:text-purple-600">
          <X className="w-4 h-4" />
        </Button>
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
        {itemsSugeridos > 0 && ` · ${itemsSugeridos} con sugerencia para confirmar`}
        {itemsPendientes > 0 && ` · ${itemsPendientes} requerirán tu revisión`}
        {resultado.tipoFactura && ` · se carga como ${resultado.tipoFactura}`}
      </p>

      {advertencias.length > 0 && (
        <div className="mb-3 rounded-md border border-amber-200 dark:border-amber-800 bg-amber-50 dark:bg-amber-900/20 p-2">
          <p className="flex items-center gap-1.5 text-xs font-medium text-amber-800 dark:text-amber-200 mb-1">
            <AlertTriangle className="w-3.5 h-3.5 shrink-0" />
            Revisá contra el papel antes de aplicar
          </p>
          <ul className="space-y-0.5 text-xs" aria-label="Advertencias del escaneo">
            {advertencias.map((a, i) => (
              <li
                key={`${a.codigo}-${a.linea ?? 0}-${i}`}
                className={a.nivel === 'error' ? 'text-red-700 dark:text-red-300' : 'text-amber-800 dark:text-amber-200'}
              >
                {a.mensaje}
              </li>
            ))}
          </ul>
        </div>
      )}

      <div className="flex gap-2">
        <Button
          onClick={() => onAplicar(candidatos)}
          variant="primary"
          size="sm"
          className="flex-1"
          disabled={cargandoCandidatos}
          loading={cargandoCandidatos}
        >
          Aplicar datos
        </Button>
        <Button
          onClick={onDescartar}
          variant="ghost"
          size="sm"
          className="border border-purple-300 dark:border-purple-600 text-purple-700 dark:text-purple-300 hover:bg-purple-100 dark:hover:bg-purple-900/30"
        >
          Descartar
        </Button>
      </div>
    </div>
  )
}

interface ItemsPendientesScanPanelProps {
  pendientes: ItemPendienteScan[];
  productos: ProductoDB[];
  catalogo: CatalogoAltaRapida;
  puedeCrear: boolean;
  onVincular: (index: number, producto: ProductoDB) => void;
  onCrearNuevo: (index: number, datos: ProductoRapidoInput) => Promise<void>;
  onOmitir: (index: number) => void;
  onDescartarTodos: () => void;
}

type PendienteRowMode = 'idle' | 'vincular' | 'crear'

function ItemsPendientesScanPanel({
  pendientes,
  productos,
  catalogo,
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
        <Button
          type="button"
          onClick={onDescartarTodos}
          variant="ghost"
          size="sm"
          className="text-amber-600 hover:text-amber-800 dark:text-amber-400 dark:hover:text-amber-200 text-xs font-medium underline"
          title="Descartar todos los pendientes"
        >
          Descartar todo
        </Button>
      </div>

      <div className="space-y-2">
        {pendientes.map((scanItem, index) => (
          <ItemPendienteRow
            key={`${index}-${scanItem.codigo || ''}-${scanItem.descripcion}`}
            index={index}
            scanItem={scanItem}
            productos={productos}
            catalogo={catalogo}
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
  scanItem: ItemPendienteScan;
  productos: ProductoDB[];
  catalogo: CatalogoAltaRapida;
  puedeCrear: boolean;
  onVincular: (index: number, producto: ProductoDB) => void;
  onCrearNuevo: (index: number, datos: ProductoRapidoInput) => Promise<void>;
  onOmitir: (index: number) => void;
}

function ItemPendienteRow({
  index,
  scanItem,
  productos,
  catalogo,
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
  const [clasificacion, setClasificacion] = useState<ClasificacionRapida>(CLASIFICACION_VACIA)
  const [creando, setCreando] = useState(false)

  // Lo que propuso el matcher, si sigue en el catálogo.
  const sugerencia = scanItem.sugerencia
  const productoSugerido = sugerencia?.productoId
    ? productos.find(p => String(p.id) === sugerencia.productoId)
    : undefined
  const parecidos = useMemo(() => {
    const ids = [sugerencia?.productoId, ...(sugerencia?.alternativas ?? [])].filter((id): id is string => !!id)
    return ids
      .map(id => productos.find(p => String(p.id) === id))
      .filter((p): p is ProductoDB => !!p)
  }, [productos, sugerencia])

  const productosFiltrados = useMemo(() => {
    const termino = busqueda.trim().toLowerCase()
    // Sin búsqueda, primero los parecidos que encontró el matcher.
    if (!termino) {
      const ids = new Set(parecidos.map(p => p.id))
      return [...parecidos, ...productos.filter(p => !ids.has(p.id))].slice(0, 8)
    }
    return productos
      .filter(p =>
        p.nombre?.toLowerCase().includes(termino) ||
        p.codigo?.toLowerCase().includes(termino)
      )
      .slice(0, 8)
  }, [productos, busqueda, parecidos])

  const handleCrear = async () => {
    if (!nombreNuevo.trim()) return
    setCreando(true)
    try {
      await onCrearNuevo(index, {
        nombre: nombreNuevo.trim(),
        codigo: codigoNuevo.trim(),
        costoSinIva: costoNuevo,
        ...datosClasificacion(clasificacion, catalogo.proveedorFactura),
      })
      // El reducer remueve la fila; este componente se desmonta.
    } catch {
      // El toast lo tira el container. La fila queda pendiente a propósito: si
      // el alta falló, el ítem de la factura sigue sin producto al que apuntar.
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
            {scanItem.iva != null && scanItem.iva > 0 && (
              <>
                <span className="mx-1.5">·</span>
                <span>IVA: <span className="font-semibold">{scanItem.iva}%</span></span>
              </>
            )}
          </p>
        </div>
      </div>

      {/* Sugerencia del matcher: preseleccionada, la confirma la persona */}
      {modo === 'idle' && productoSugerido && sugerencia && (
        <div className="flex flex-wrap items-center gap-2 rounded-md bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 px-2.5 py-2">
          <div className="min-w-0 flex-1">
            <p className="text-sm text-gray-800 dark:text-white break-words">
              ¿Es <span className="font-semibold">{productoSugerido.nombre}</span>?
            </p>
            <p className="text-xs text-gray-500 dark:text-gray-400">
              {sugerencia.motivo} · {Math.round(sugerencia.confianza * 100)}%
            </p>
          </div>
          <Button
            type="button"
            onClick={() => onVincular(index, productoSugerido)}
            variant="primary"
            size="sm"
            className="gap-1"
          >
            <CheckCircle className="w-3.5 h-3.5" />
            Sí, vincular
          </Button>
        </div>
      )}

      {/* Acciones */}
      {modo === 'idle' && (
        <div className="flex flex-wrap gap-2">
          <Button
            type="button"
            onClick={() => { setModo('vincular'); setBusqueda('') }}
            variant="primary"
            size="sm"
            className="flex-1 min-w-[120px] gap-1"
          >
            <Search className="w-3.5 h-3.5" />
            {productoSugerido ? 'Elegir otro' : 'Vincular existente'}
          </Button>
          {puedeCrear && (
            <Button
              type="button"
              onClick={() => setModo('crear')}
              variant="success"
              size="sm"
              className="flex-1 min-w-[120px] gap-1"
            >
              <Plus className="w-3.5 h-3.5" />
              Crear nuevo
            </Button>
          )}
          <Button
            type="button"
            onClick={() => onOmitir(index)}
            variant="secondary"
            size="sm"
            title="Omitir esta línea"
          >
            Omitir
          </Button>
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
          <Button
            type="button"
            onClick={() => setModo('idle')}
            variant="ghost"
            size="sm"
            className="text-xs underline"
          >
            Cancelar
          </Button>
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
          <CamposClasificacion catalogo={catalogo} valor={clasificacion} onChange={setClasificacion} />
          <div className="flex gap-2 pt-1">
            <Button
              type="button"
              onClick={handleCrear}
              disabled={!nombreNuevo.trim() || creando}
              loading={creando}
              variant="success"
              size="sm"
              className="flex-1 gap-1"
            >
              {!creando && <Plus className="w-3.5 h-3.5" />}
              Crear y vincular
            </Button>
            <Button
              type="button"
              onClick={() => setModo('idle')}
              disabled={creando}
              variant="secondary"
              size="sm"
            >
              Cancelar
            </Button>
          </div>
        </div>
      )}
    </div>
  )
}

/** Bases de reparto ofrecidas, con la ayuda que explica cada una. */
const BASES_PRORRATEO: Array<{ value: BaseProrrateo; label: string; ayuda: string }> = [
  { value: 'monto', label: 'Por monto', ayuda: 'Cada línea pesa lo que vale (neto ya bonificado). Es lo habitual para el flete.' },
  { value: 'cantidad', label: 'Por cantidad', ayuda: 'Cada línea pesa sus unidades.' },
  // mig 278: peso = cantidad / unidades por pallet (o separador, o lugar en el
  // flete), con las unidades de la ficha del producto.
  { value: 'medida', label: 'Por medida', ayuda: 'Cada línea pesa cuántos pallets (o separadores, o lugares del flete) ocupa: cantidad / unidades por medida, de la ficha del producto.' },
  // La mig 192 la llama 'unidades', pero la regla es peso 1 en TODAS las líneas:
  // lo que reparte son partes iguales, no unidades del producto.
  { value: 'unidades', label: 'Partes iguales', ayuda: 'Todas las líneas pesan lo mismo, sin importar monto ni cantidad.' },
]

/** ¿Este peso puede entrar a `prorratearCargo` sin hacerlo lanzar? */
function pesoInvalido(peso: number): boolean {
  return !Number.isFinite(peso) || peso < 0
}

/** "Pallets" para el encabezado de la columna de peso de un cargo por medida. */
function tituloColumnaMedida(medida: MedidaCargo | undefined): string {
  if (!medida) return 'Peso'
  const plural = pluralMedida(medida.unidadSingular, 2)
  return plural.charAt(0).toUpperCase() + plural.slice(1)
}

/**
 * Lo que una línea de un cargo por medida (mig 278) muestra y deja tocar debajo
 * del peso: "2 pallets (120 u/pallet)" y, para cargar o corregir, las unidades
 * por medida con el check "guardar en la ficha".
 *
 * Los pallets se tipean en el campo de peso de la línea (ver GrillaPesos): de
 * ahí sale u/pallet = cantidad / pallets. Acá se tipean las u/pallet directas.
 */
function MedidaDeLinea({ cargo, item, lineaId, medidas, catalogo, dispatch }: {
  cargo: CargoCompraForm;
  item: CompraItemForm;
  lineaId: number;
  medidas: ContextoMedidas;
  catalogo: MedidaCargo[];
  dispatch: React.Dispatch<CompraActionType>;
}) {
  const ver = useContextoVer()
  if (!cargo.medidaId) return null
  const productoId = String(item.productoId)
  const peso = cargo.pesos[lineaId] ?? 0
  const medidaPorId = (id: string | null | undefined) => catalogo.find(m => m.id === id)
  const propia = medidaPorId(cargo.medidaId)

  if (!lineaEnAlcance(cargo, productoId)) {
    return (
      <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
        No estaba en la última compra del proveedor con este cargo: queda afuera. Si lleva, poné el peso a mano.
      </p>
    )
  }

  // En 'ver' no hay ficha ni catálogo de esta sesión que valga: lo guardado es
  // el peso, y las u/medida salen de él.
  if (ver) {
    const unidad = propia?.unidadSingular ?? 'medida'
    return peso > 0 ? (
      <p className="text-xs text-gray-600 dark:text-gray-300 mt-1">{textoMedidaLinea(peso, item.cantidad / peso, unidad)}</p>
    ) : null
  }

  const resuelta = resolverMedida(productoId, cargo.medidaId, medidas)
  const editable = medidaEditable(productoId, cargo.medidaId, medidas)
  const medidaEdit = medidaPorId(editable)
  const unidad = medidaEdit?.unidadSingular ?? propia?.unidadSingular ?? 'medida'
  const manual = !!cargo.pesosManuales[lineaId]
  const deCompra = medidas.compra[productoId]?.[editable]
  const valorMostrado = deCompra?.unidadesPor ?? medidas.ficha[productoId]?.[editable] ?? 0
  const tieneFicha = fichaTieneValor(productoId, editable, medidas)

  const setUnidades = (n: number) =>
    dispatch({ type: 'SET_MEDIDA_LINEA', payload: { productoId, medidaId: editable, unidadesPor: n > 0 ? n : null } })

  return (
    <div className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs">
      {resuelta && !manual ? (
        <span data-testid="medida-linea" className="text-gray-600 dark:text-gray-300">
          {textoMedidaLinea(peso, resuelta.unidadesPor, unidad)}
          {resuelta.porBase && propia ? ` · según ${medidaEdit?.nombre ?? 'la base'}` : ''}
          {resuelta.origen === 'ficha' ? ' · de la ficha' : ''}
        </span>
      ) : manual ? (
        <span className="text-gray-500 dark:text-gray-400">Peso puesto a mano.</span>
      ) : (
        <span data-testid="medida-faltante" className="font-medium text-amber-700 dark:text-amber-300">
          ⚠ Falta cuántas u. entran por {unidad}: cargalas, tipeá los {pluralMedida(unidad, 2)}, o poné 0 para dejarla afuera.
        </span>
      )}
      <label className="flex items-center gap-1 text-gray-600 dark:text-gray-300">
        <NumberInput
          min={0}
          emptyValue={0}
          value={valorMostrado}
          onChange={setUnidades}
          commitOnChange
          aria-label={`Unidades por ${unidad} de ${item.productoNombre}`}
          className="w-20 px-1.5 py-0.5 text-right border dark:border-gray-600 rounded dark:bg-gray-700 dark:text-white"
        />
        u por {unidad}
      </label>
      {deCompra && (
        <label className="flex items-center gap-1 cursor-pointer text-gray-600 dark:text-gray-300">
          <input
            type="checkbox"
            checked={deCompra.guardarEnFicha}
            onChange={(e: ChangeEvent<HTMLInputElement>) =>
              dispatch({ type: 'SET_GUARDAR_EN_FICHA', payload: { productoId, medidaId: editable, guardar: e.target.checked } })}
            className="w-3.5 h-3.5 rounded border-gray-300 text-green-600 focus:ring-green-500"
          />
          guardar en la ficha
          {tieneFicha && (
            <span className="text-gray-400">(la ficha dice {String(medidas.ficha[productoId]?.[editable]).replace('.', ',')})</span>
          )}
        </label>
      )}
    </div>
  )
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
 *
 * Con la base 'medida' (mig 278) el campo de peso SON los pallets: tipear 3
 * deriva u/pallet = cantidad / 3 (y el peso vuelve exacto, ver
 * utils/medidasCargo), y tipear 0 es la exclusión explícita de la línea.
 */
function GrillaPesos({ cargo, items, dispatch, medidas }: GrillaPesosProps) {
  const ver = useContextoVer()
  const { data: catalogoMedidas = [] } = useCargoMedidasQuery()
  const porMedida = cargo.baseProrrateo === 'medida'
  // Sólo las líneas ya numeradas por el reducer; sin id no hay dónde colgar el peso.
  const lineas = items.flatMap(item =>
    item.lineaId === undefined ? [] : [{ item, id: item.lineaId }]
  )

  const pesoDe = (id: number): number => cargo.pesos[id] ?? 0
  const hayInvalidos = lineas.some(l => pesoInvalido(pesoDe(l.id)))
  // Sólo al editar (el cargo trae `cantidadesReferencia`): pesos tipeados
  // contra una cantidad que ya cambió. Se marcan, no se pisan.
  const desactualizados = new Map(pesosDesactualizados(cargo, items).map(d => [d.lineaId, d]))
  const faltantes = porMedida && !ver ? lineasSinMedida(cargo, items, medidas).length : 0

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

  // Base 'medida': el número tipeado son pallets. > 0 deriva las u/pallet de la
  // línea (y el peso sale de ahí, sin marca de manual); 0 excluye la línea a
  // mano. Fuera del alcance de la plantilla, o con la cantidad en 0, es un peso
  // a mano como en cualquier otra base.
  const onPeso = (item: CompraItemForm, id: number, n: number) => {
    if (porMedida && cargo.medidaId && n > 0 && lineaEnAlcance(cargo, item.productoId)) {
      const unidadesPor = unidadesPorDesdeCantidadDeMedidas(item.cantidad, n)
      if (unidadesPor !== null) {
        dispatch({
          type: 'SET_MEDIDA_LINEA',
          payload: {
            productoId: String(item.productoId),
            medidaId: medidaEditable(item.productoId, cargo.medidaId, medidas),
            unidadesPor,
          },
        })
        return
      }
    }
    setPeso(id, n)
  }

  const medidaDelCargo = catalogoMedidas.find(m => m.id === cargo.medidaId)
  const tituloPeso = porMedida ? tituloColumnaMedida(medidaDelCargo) : 'Peso'

  const inputPeso = (item: CompraItemForm, id: number, invalida: boolean) => (
    <NumberInput
      min={0}
      emptyValue={0}
      value={invalida ? 0 : pesoDe(id)}
      onChange={(n) => onPeso(item, id, n)}
      commitOnChange
      title="0 excluye la línea de este cargo"
      aria-label={`${tituloPeso} de ${item.productoNombre}`}
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
        <div className="col-span-3 text-right">{tituloPeso}</div>
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
                  <label className="block text-xs text-gray-500 mb-1">{tituloPeso}</label>
                  {inputPeso(item, id, invalida)}
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
              <div className="col-span-3">{inputPeso(item, id, invalida)}</div>
              <div className="col-span-3 text-right text-sm font-medium text-gray-800 dark:text-white">
                {asignado === null ? '—' : formatPrecio(asignado)}
              </div>
            </div>

            {porMedida && (
              <MedidaDeLinea cargo={cargo} item={item} lineaId={id} medidas={medidas}
                             catalogo={catalogoMedidas} dispatch={dispatch} />
            )}

            {invalida && (
              <p className="text-xs text-red-600 dark:text-red-400 mt-1">
                Peso inválido ({String(pesoDe(id))}): tiene que ser un número mayor o igual a 0. El 0 excluye la línea.
              </p>
            )}
            {desactualizados.has(id) && (
              <p data-testid="peso-desactualizado" className="text-xs text-amber-700 dark:text-amber-300 mt-1">
                ⚠ Peso desactualizado: se fijó para {desactualizados.get(id)!.cantidadReferencia} u. y la línea ahora tiene{' '}
                {desactualizados.get(id)!.cantidadActual}. Recalculado daría{' '}
                {String(desactualizados.get(id)!.pesoRecalculado).replace('.', ',')}.
              </p>
            )}
          </div>
        )
      })}

      {desactualizados.size > 0 && (
        <Button
          type="button"
          onClick={() => dispatch({ type: 'RECALCULAR_PESOS_DESACTUALIZADOS', payload: { cargoId: cargo.id } })}
          variant="ghost"
          size="sm"
          className="gap-1 border border-amber-500 text-amber-800 dark:text-amber-300 hover:bg-amber-50 dark:hover:bg-amber-900/30"
          title="Lleva cada peso desactualizado a la cantidad nueva de su línea, en proporción"
        >
          <RefreshCw className="w-4 h-4" />
          Recalcular {desactualizados.size === 1 ? 'el peso desactualizado' : `los ${desactualizados.size} pesos desactualizados`}
        </Button>
      )}

      <div className="flex justify-between items-center text-sm pt-2 border-t dark:border-gray-600">
        <span className="text-gray-600 dark:text-gray-400">Suma repartida</span>
        <span className={`font-medium ${cuadra ? 'text-gray-800 dark:text-white' : 'text-red-600'}`}>
          {reparto === null ? '—' : formatPrecio(sumaRepartida)}
          <span className="text-gray-500 font-normal"> / {formatPrecio(cargo.monto)}</span>
        </span>
      </div>

      {faltantes > 0 && (
        <p className="text-xs text-amber-700 dark:text-amber-300">
          ⚠ {faltantes === 1 ? 'Una línea no tiene' : `${faltantes} líneas no tienen`} unidades por {medidaDelCargo?.unidadSingular ?? 'medida'}: no se puede registrar hasta cargarlas o dejarlas en 0.
        </p>
      )}
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

/**
 * Un cargo de la factura: concepto, monto y las tres decisiones fiscales.
 *
 * El concepto se elige del catálogo (mig 278) y elegirlo PRECARGA sus defaults
 * —signo, IVA, en factura, al costo, base y medida—; todo sigue editable y lo
 * que se guarda es la foto del renglón. Si no existe, "+ Crear 'X'" lo da de
 * alta al guardar la compra, con los valores que tenga el renglón.
 *
 * El signo vive en un toggle y no en el campo, porque NumberInput no deja
 * tipear el "-" (sanitiza a dígitos). Tipear -500 y que quede 500 en silencio
 * sería peor que pedir el gesto explícito.
 */
function CargoRow({ cargo, items, dispatch, resolucion, medidas }: CargoRowProps) {
  const ver = useContextoVer()
  const { data: conceptos = [] } = useCargoConceptosQuery()
  const { data: catalogoMedidas = [] } = useCargoMedidasQuery()
  // El signo es estado de la fila y no `cargo.monto < 0`: con monto en 0 el
  // toggle volvería solo a "Cargo" apenas se elige "Bonificación".
  const [esBonificacion, setEsBonificacion] = useState(cargo.monto < 0)
  // En 'ver' el reparto se muestra siempre: es la mitad de lo que hay para ver.
  const [mostrarPesos, setMostrarPesos] = useState(!!ver)
  // Al editar, un peso que quedó viejo tiene que verse aunque el reparto esté
  // plegado: si no, el aviso queda escondido detrás de un click.
  const hayDesactualizados = pesosDesactualizados(cargo, items).length > 0
  // Ídem una línea sin unidades por medida: traba el guardado, tiene que verse.
  const hayFaltantes = !ver && lineasSinMedida(cargo, items, medidas).length > 0
  // Y una vez abierto por eso queda abierto: si se plegara apenas se carga el
  // dato, el check "guardar en la ficha" desaparecería debajo del cursor.
  if (hayFaltantes && !mostrarPesos) setMostrarPesos(true)
  const set = (cambios: CambiosCargo) =>
    dispatch({ type: 'ACTUALIZAR_CARGO', payload: { id: cargo.id, cambios } })

  const cambiarSigno = (bonificacion: boolean) => {
    setEsBonificacion(bonificacion)
    const magnitud = Math.abs(cargo.monto)
    set({ monto: bonificacion ? -magnitud : magnitud })
  }

  const cambiarBase = (base: BaseProrrateo) => {
    if (base !== 'medida') {
      set({ baseProrrateo: base })
      return
    }
    // Sin medida no hay qué pre-llenar: arranca con la del concepto, o la
    // primera activa (Pallet). Se cambia en el select de al lado.
    const delConcepto = conceptos.find(c => c.id === cargo.conceptoId)?.medidaId
    const medidaId = cargo.medidaId ?? delConcepto ?? catalogoMedidas.find(m => m.activo)?.id ?? null
    set({ baseProrrateo: 'medida', medidaId })
  }

  const baseElegida = BASES_PRORRATEO.find(b => b.value === cargo.baseProrrateo)
  const leyenda = leyendaBaseII(cargo, resolucion)
  // Inactivos fuera de la lista, salvo el que ya tiene el renglón.
  const opcionesConcepto = conceptos.filter(c => c.activo || c.id === cargo.conceptoId)
  const opcionesMedida = catalogoMedidas.filter(m => m.activo || m.id === cargo.medidaId)
  // Sin catálogo (la mig 278 todavía no aplicada) 'medida' no tiene con qué.
  const bases = catalogoMedidas.length > 0 || cargo.baseProrrateo === 'medida'
    ? BASES_PRORRATEO
    : BASES_PRORRATEO.filter(b => b.value !== 'medida')

  return (
    <div className="bg-white dark:bg-gray-800 p-3 rounded-lg border dark:border-gray-600 space-y-3">
      <div className="flex items-start gap-2">
        <div className="flex-1 min-w-0">
          <label className="block text-xs text-gray-500 mb-1">Concepto</label>
          <Combobox
            opciones={opcionesConcepto}
            getKey={c => c.id}
            getLabel={c => c.nombre}
            renderOpcion={c => (
              <span className="flex items-center justify-between gap-2">
                <span>{c.nombre}</span>
                <span className="text-xs text-gray-500">{c.signo < 0 ? 'resta' : 'suma'}</span>
              </span>
            )}
            valor={cargo.conceptoId ?? null}
            textoSinOpcion={cargo.concepto}
            onSeleccionar={c => {
              setEsBonificacion(c.signo < 0)
              dispatch({ type: 'ELEGIR_CONCEPTO', payload: { id: cargo.id, concepto: c } })
            }}
            onCrear={texto => dispatch({ type: 'CREAR_CONCEPTO', payload: { id: cargo.id, nombre: texto } })}
            textoCrear={t => `+ Crear "${t}"`}
            placeholder="Flete, pallets, separadores, bonificación..."
            aria-label="Concepto del cargo"
            textoSinResultados="Ningún concepto coincide"
            inputClassName="py-1.5 text-sm sm:text-sm"
          />
          {cargo.conceptoNuevo && !cargo.conceptoId && !ver && (
            <p className="text-xs text-gray-500 mt-1">Concepto nuevo: se agrega al catálogo al registrar la compra.</p>
          )}
        </div>
        {!ver && (
        <button
          type="button"
          onClick={() => dispatch({ type: 'ELIMINAR_CARGO', payload: cargo.id })}
          className="mt-5 p-1 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded shrink-0"
          title="Quitar este cargo"
        >
          <Trash2 className="w-4 h-4" />
        </button>
        )}
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
                  aria-pressed={esBonificacion === bonif}
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
              aria-label={`Monto de ${cargo.concepto || 'el cargo'}`}
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
          <div className="flex gap-1">
            <select
              value={cargo.baseProrrateo}
              onChange={(e: ChangeEvent<HTMLSelectElement>) => cambiarBase(e.target.value as BaseProrrateo)}
              title={baseElegida?.ayuda}
              aria-label="Base de reparto"
              className="w-full min-w-0 px-2 py-1.5 text-sm border dark:border-gray-600 rounded focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
            >
              {bases.map(b => (
                <option key={b.value} value={b.value}>{b.label}</option>
              ))}
            </select>
            {cargo.baseProrrateo === 'medida' && (
              <select
                value={cargo.medidaId ?? ''}
                onChange={(e: ChangeEvent<HTMLSelectElement>) => set({ medidaId: e.target.value || null })}
                aria-label="Medida del reparto"
                className="w-full min-w-0 px-2 py-1.5 text-sm border dark:border-gray-600 rounded focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
              >
                {!cargo.medidaId && <option value="">Elegí la medida</option>}
                {opcionesMedida.map(m => (
                  <option key={m.id} value={m.id}>{m.nombre}</option>
                ))}
              </select>
            )}
          </div>
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

      {/* mig 281 (#866): un cargo gravado que NO viene en la factura del
          proveedor (el flete del transportista) puede traer factura propia.
          Su IVA es crédito fiscal, no costo: el monto sigue siendo neto. */}
      {aplicaComprobanteTercero(cargo) && (
        <ComprobanteTercero cargo={cargo} set={set} />
      )}

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
        {ver ? (
          <p className="text-xs font-medium text-gray-500 uppercase">Reparto por línea</p>
        ) : (
        <Button
          type="button"
          onClick={() => setMostrarPesos(v => !v)}
          variant="ghost"
          size="sm"
          className="text-blue-600 hover:underline dark:text-blue-400"
        >
          {mostrarPesos
            ? 'Ocultar reparto'
            : `Ver reparto entre ${items.length} ${items.length === 1 ? 'línea' : 'líneas'} ▸`}
        </Button>
        )}
        {(mostrarPesos || hayDesactualizados || hayFaltantes) && (
          <GrillaPesos cargo={cargo} items={items} dispatch={dispatch} medidas={medidas} />
        )}
      </div>
    </div>
  )
}

/**
 * "¿Viene con factura del transportista?" de un cargo gravado fuera de la
 * factura del proveedor (mig 281). El IVA arranca en el 21% del monto y lo
 * sigue hasta que se lo tipea; transportista y N° de comprobante son texto.
 * En 'ver' el fieldset deshabilitado lo muestra tal cual se guardó.
 */
function ComprobanteTercero({ cargo, set }: { cargo: CargoCompraForm; set: (c: CambiosCargo) => void }) {
  const id = useId()
  const clase = 'w-full px-2 py-1.5 text-sm border dark:border-gray-600 rounded focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white'
  return (
    <div className="space-y-2 rounded border border-dashed border-gray-300 dark:border-gray-600 p-2">
      <label className="flex items-start gap-2 cursor-pointer">
        <input
          type="checkbox"
          checked={!!cargo.comprobanteTercero}
          onChange={(e: ChangeEvent<HTMLInputElement>) => set({ comprobanteTercero: e.target.checked })}
          className="mt-0.5 w-4 h-4 rounded border-gray-300 text-green-600 focus:ring-green-500"
        />
        <span className="text-sm dark:text-gray-200">
          ¿Viene con factura del transportista?
          <span className="block text-xs text-gray-500 dark:text-gray-400">
            Su IVA va al crédito fiscal del mes de la compra; no suma al costo.
          </span>
        </span>
      </label>
      {cargo.comprobanteTercero && (
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-2">
          <div>
            <label htmlFor={`${id}-iva`} className="block text-xs text-gray-500 mb-1">IVA de la factura</label>
            <NumberInput
              id={`${id}-iva`}
              min={0}
              emptyValue={0}
              commitOnChange
              value={ivaTerceroEfectivo(cargo)}
              onChange={(n) => set({ ivaTercero: n })}
              className={`${clase} text-right`}
            />
          </div>
          <div>
            <label htmlFor={`${id}-nombre`} className="block text-xs text-gray-500 mb-1">Transportista</label>
            <input
              id={`${id}-nombre`}
              type="text"
              value={cargo.terceroNombre ?? ''}
              onChange={(e: ChangeEvent<HTMLInputElement>) => set({ terceroNombre: e.target.value })}
              className={clase}
            />
          </div>
          <div>
            <label htmlFor={`${id}-comprobante`} className="block text-xs text-gray-500 mb-1">N° de comprobante</label>
            <input
              id={`${id}-comprobante`}
              type="text"
              value={cargo.terceroComprobante ?? ''}
              onChange={(e: ChangeEvent<HTMLInputElement>) => set({ terceroComprobante: e.target.value })}
              className={clase}
            />
          </div>
        </div>
      )}
    </div>
  )
}

const SIN_SUGERENCIAS: SugerenciaBonificacion[] = []

/** "8.6957" -> "8,6957". */
const tasaConComa = (tasa: number) => String(tasa).replace('.', ',')

/**
 * #908 · La sugerencia de una bonificación que el proveedor no descontó de la
 * base del impuesto interno. No bloquea nada y no se aplica sola: agrega el
 * cargo sólo con el clic, y "Descartar" la oculta para esa alícuota.
 */
function SugerenciaBonificacionCard({ sugerencia, items, onAgregar, onDescartar }: {
  sugerencia: SugerenciaBonificacion;
  items: CompraItemForm[];
  onAgregar: () => void;
  onDescartar: () => void;
}) {
  const nombres = items
    .filter(i => i.lineaId !== undefined && sugerencia.lineaIds.includes(i.lineaId))
    .map(i => i.productoNombre)
  const lista = nombres.slice(0, 3).join(', ') + (nombres.length > 3 ? ` y ${nombres.length - 3} más` : '')
  const tasa = sugerencia.tasa === null ? null : tasaConComa(sugerencia.tasa)
  const sobre = sugerencia.alcance === 'sin_alcance'
    ? ', pero no se puede saber sobre qué productos: elegilos en el reparto del cargo'
    : ` sobre ${lista}`
  return (
    <div role="status" aria-label={tasa ? `Bonificación no descontada al ${tasa}%` : 'Bonificación no descontada'}
         className="p-3 rounded-lg border border-amber-300 dark:border-amber-700 bg-amber-50 dark:bg-amber-900/20 space-y-2">
      <p className="text-sm text-amber-900 dark:text-amber-100">
        {sugerencia.caso === 'impuesto_interno'
          ? <>La factura liquida II sobre {formatPrecio(sugerencia.baseImplicita)} más de neto en la tasa {tasa}%:
              parece una bonificación no descontada de {formatPrecio(sugerencia.monto)}{sobre}. ¿Agregarla?</>
          : <>El gravado de la factura es {formatPrecio(sugerencia.monto)} menor que el de las líneas y el II declarado
              cierra sin descontarlo: parece una bonificación no descontada de la base del II
              de {formatPrecio(sugerencia.monto)}{sobre}. ¿Agregarla?</>}
      </p>
      <p className="text-xs text-amber-800 dark:text-amber-300">
        {sugerencia.origenMonto === 'gravado'
          ? 'El monto sale de la diferencia con el gravado que dice la factura.'
          : sugerencia.origenMonto === 'total'
            ? 'El monto sale de la diferencia con el total que dice la factura, sin el IVA.'
            : 'El monto sale del impuesto interno declarado; cargá el gravado de la factura para confirmarlo.'}
        {sugerencia.alcance === 'compra_anterior' ? ' Se reparte entre los productos que tocaba en la compra anterior.' : ''}
        {sugerencia.caso === 'papel'
          ? ' Si la diferencia es otra cosa (un renglón mal cargado), descartala.'
          : ' Si las líneas ya tienen la bonificación aplicada, descartala.'}
      </p>
      <div className="flex flex-wrap gap-2">
        <Button type="button" onClick={onAgregar} variant="success" size="sm">Agregar bonificación</Button>
        <Button type="button" onClick={onDescartar} variant="ghost" size="sm">Descartar</Button>
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
 *
 * Los cargos de la última compra del proveedor llegan SOLOS al elegirlo (mig
 * 278, ver ModalCompraCarga): ya no hay un botón "Traer cargos". Se pueden
 * quitar uno por uno, y al guardar se pregunta por los que quedaron sin monto.
 */
function CargosSection({
  state, dispatch, plantilla, resolucion, abiertaInicial = false, sugerencias = SIN_SUGERENCIAS, conceptoBonificacion = null,
}: CargosSectionProps) {
  const ver = useContextoVer()
  const { cargos } = state
  const deLaPlantilla = cargos.filter(c => c.plantilla)
  const hayFaltantes = !ver && cargos.some(c => lineasSinMedida(c, state.items, state.medidas).length > 0)
  // En 'ver' arranca abierta: lo que se vino a mirar es justamente esto. Y si
  // llegaron cargos de la plantilla, también: hay que ponerles el monto.
  const [abierta, setAbierta] = useState(!!ver || abiertaInicial)
  // Una línea sin unidades por medida traba el guardado: la sección se abre
  // sola y queda abierta (plegarla al cargar el dato escondería lo que se está
  // tocando).
  if (hayFaltantes && !abierta) setAbierta(true)
  // La sugerencia de bonificación (#908) vive acá adentro: plegada no se vería.
  const visibles = ver ? SIN_SUGERENCIAS : sugerencias
  if (visibles.length > 0 && !abierta) setAbierta(true)
  const abiertaEfectiva = abierta
  const totalAlCosto = cargos.filter(c => c.prorrateaAlCosto).reduce((acc, c) => acc + c.monto, 0)
  const totalEnFactura = cargos.filter(c => c.enFactura).reduce((acc, c) => acc + c.monto, 0)
  const facturaPlantilla = plantilla?.numeroFactura ? `la factura ${plantilla.numeroFactura}` : 'la última compra del proveedor'

  return (
    <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-3 sm:p-4">
      <button
        type="button"
        onClick={() => setAbierta(v => !v)}
        className="w-full flex items-center justify-between gap-2 text-left"
      >
        <div className="flex items-center gap-2 min-w-0">
          {abiertaEfectiva
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
        {!abiertaEfectiva && (
          <span className="text-xs text-gray-500 text-right shrink-0">
            {cargos.some(c => pesosDesactualizados(c, state.items).length > 0)
              ? '⚠ hay pesos desactualizados'
              : cargos.length === 0
                ? 'Flete, pallets, bonificaciones'
                : deLaPlantilla.some(c => !c.monto)
                  ? `${deLaPlantilla.length} de la última compra: falta el monto`
                  : `${formatPrecio(totalAlCosto)} al costo`}
          </span>
        )}
      </button>

      {abiertaEfectiva && (
        <div className="mt-3 space-y-3">
          {!ver && deLaPlantilla.length > 0 && (
            <p className="text-xs text-gray-600 dark:text-gray-400">
              Precargados de {facturaPlantilla}: {deLaPlantilla.map(c => c.concepto).join(', ')}. Poneles el monto de esta
              factura o quitalos; cada uno se reparte sólo entre los productos que tocaba.
            </p>
          )}
          {visibles.map(s => (
            <SugerenciaBonificacionCard key={s.clave} sugerencia={s} items={state.items}
              onAgregar={() => dispatch({ type: 'AGREGAR_BONIFICACION_SUGERIDA', payload: { sugerencia: s, concepto: conceptoBonificacion } })}
              onDescartar={() => dispatch({ type: 'DESCARTAR_BONIFICACION_SUGERIDA', payload: { clave: s.clave } })} />
          ))}
          {cargos.length === 0 && ver ? (
            <p className="text-sm text-gray-500">Esta compra no tiene cargos.</p>
          ) : cargos.length === 0 ? (
            <p className="text-sm text-gray-500">
              Conceptos de la factura que no son renglones de producto: flete, pallets,
              separadores, bonificaciones. Se reparten entre las líneas y entran al costo.
            </p>
          ) : (
            cargos.map(cargo => (
              <CargoRow key={cargo.id} cargo={cargo} items={state.items} dispatch={dispatch}
                        resolucion={resolucion} medidas={state.medidas} />
            ))
          )}

          {!ver && (
          <div className="flex flex-wrap items-center gap-2">
            <Button
              type="button"
              onClick={() => dispatch({ type: 'AGREGAR_CARGO' })}
              variant="success"
              size="sm"
              className="gap-1"
            >
              <Plus className="w-4 h-4" /> Agregar cargo
            </Button>
          </div>
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
function VistaPreviaCostosSection({ state, anteriores }: VistaPreviaCostosProps) {
  const ver = useContextoVer()
  const [abierta, setAbierta] = useState(!!ver)

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
                <div className="col-span-2 text-right">Costo unit. neto</div>
              </div>

              <div className="space-y-2">
                {state.items.map((item, index) => {
                  const c = item.lineaId === undefined ? undefined : porLinea.get(item.lineaId)
                  // El costo final de la línea. En 'ver' es el GUARDADO
                  // (compra_items.costo_real_unitario), no el recalculado: es el
                  // que entró al costo promedio. En 'nueva', el que va a guardar
                  // la RPC (mismo motor, misma base: FC sin IVA, ZZ con).
                  const guardado = ver && item.lineaId !== undefined ? ver.costoGuardadoPorLinea.get(item.lineaId) : undefined
                  const costoFinal = guardado ?? c?.costoRealUnitario
                  const variacion = (
                    <VariacionCosto
                      actual={costoFinal}
                      anterior={anteriores?.get(String(item.productoId))}
                      tipoFactura={state.tipoFactura}
                    />
                  )
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
                          <span className="text-xs text-gray-500">Costo unit. neto</span>
                          <span className="text-sm font-semibold text-gray-800 dark:text-white">{celda(costoFinal ?? undefined)}{variacion}</span>
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
                        <span className="col-span-2 text-right font-semibold text-gray-800 dark:text-white">{celda(costoFinal ?? undefined)}{variacion}</span>
                      </div>
                    </div>
                  )
                })}
              </div>

              <p className="text-xs text-gray-500">
                Todos los importes son por unidad.
                {ver && ' El costo final es el que quedó registrado en la compra.'}
                {anteriores && anteriores.size > 0 && ' El porcentaje compara el costo final contra la compra anterior del producto.'}
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
  const { cargado, diff, ok } = cuadreContraFactura(calculado, impreso)
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

function ResumenSection({ totales, state, dispatch, resolucion, percepcionesFijas = false }: ResumenSectionProps) {
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
  // #908. Las alícuotas cuya diferencia la explica una bonificación cargada que
  // no baja la base: ahí el declarado ES mayor que el calculado por diseño (el
  // proveedor liquidó el II antes de descontarla) y el factor proporcional del
  // motor lo lleva al declarado sobre la base completa, que es lo correcto. El
  // solver no puede cerrar esa ecuación con ninguna combinación de banderas, así
  // que su "sin solución" no significa "falta un cargo". No se toca la cuenta:
  // sólo se deja de avisar algo que no es cierto, y se dice lo que sí pasa.
  const iiExplicadas = alicuotasIIExplicadas(state)
  const ajusteII = (cuadreII ?? [])
    .filter(c => !iiExplicadas.includes(c.tasa))
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
          <Button
            type="button"
            onClick={() => dispatch({ type: 'APLICAR_BONIF_GLOBAL', payload: bonifGlobal })}
            variant="success"
            size="sm"
          >
            Aplicar
          </Button>
        </div>
      </div>

      {esFC && (
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
          {percepcionesFijas ? (
            <>
              <div>
                <span className="block text-xs text-gray-500 mb-1">Percepción IVA (sin cambio)</span>
                <p className="px-2 py-1.5 text-sm tabular-nums text-gray-800 dark:text-white">{formatPrecio(state.percepcionIva)}</p>
              </div>
              <div>
                <span className="block text-xs text-gray-500 mb-1">Percepción IIBB (sin cambio)</span>
                <p className="px-2 py-1.5 text-sm tabular-nums text-gray-800 dark:text-white">{formatPrecio(state.percepcionIibb)}</p>
              </div>
            </>
          ) : (
          <>
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
          </>
          )}
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
        {/* Sólo al editar una compra vieja que lo tenga: la carga no lo ofrece. */}
        {totales.otrosImpuestos > 0 && (
          <div className="flex justify-between text-sm">
            <span className="text-gray-600 dark:text-gray-400">Otros impuestos (sin cambio):</span>
            <span className="font-medium text-gray-800 dark:text-white">{formatPrecio(totales.otrosImpuestos)}</span>
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
          <Button
            type="button"
            onClick={() => setMostrarControl(v => !v)}
            variant="ghost"
            size="sm"
            className="text-blue-600 hover:underline dark:text-blue-400"
          >
            {mostrarControl ? 'Ocultar control contra factura' : 'Control contra factura ▸'}
          </Button>
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
                      : Math.abs(c.desvio) > DESVIO_II_TOLERADO && !iiExplicadas.includes(c.tasa) ? 'text-amber-600' : 'text-green-600'
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
                .filter(c => iiExplicadas.includes(c.tasa) && c.declarado !== undefined)
                .map(c => (
                  <p key={`bonif-${c.tasa}`} className="text-xs text-green-700 dark:text-green-400 pl-3">
                    ✓ El impuesto interno declarado al {c.tasa}% supera al calculado en{' '}
                    {formatPrecio((c.declarado ?? 0) - c.calculado)}: es el de la bonificación cargada que no
                    baja la base (el proveedor liquidó el II antes de descontarla). El costo toma lo declarado.
                  </p>
                ))}
              {(cuadreII ?? [])
                .filter(c => Math.abs(c.desvio) > DESVIO_II_TOLERADO && !iiExplicadas.includes(c.tasa))
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
