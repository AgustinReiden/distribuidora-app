/**
 * Borrador local de una compra nueva (localStorage), para no perder la carga
 * de una factura por un cierre, un cambio de sucursal o una pestaña caída.
 *
 * Se guarda el estado COMPLETO del reducer —incluidas las marcas de manual:
 * `pesosManuales`, `afectaBaseIIManual`, `noGravadoManual`, el control contra
 * factura, los vencimientos y los cargos—. Sin las marcas, al retomar el
 * pre-llenado pisaría los pesos tipeados a mano y el flete quedaría repartido
 * distinto de como se lo dejó, sin que nada lo avise.
 *
 * El formato lleva VERSIÓN. Un borrador de otra versión no se carga a ciegas:
 * un campo renombrado entraría como `undefined` y el reducer lo trataría como
 * dato. Se ofrece verlo o descartarlo, nunca se lo tira solo.
 *
 * Todo acceso a localStorage va envuelto: en modo privado (Safari) o con el
 * almacenamiento lleno tira, y un borrador que no se puede guardar no puede
 * romper la carga de la compra.
 */
import { initialState } from '../components/modals/ModalCompra.reducer'
import type { CompraState, CompraItemForm } from '../components/modals/ModalCompra.reducer'
import type { ProductoDB } from '../types'

/**
 * Subila si cambia la forma de `CompraState` (un campo nuevo, renombrado o con
 * otro significado). Un borrador con otra versión se ofrece para ver o
 * descartar, no para cargar.
 */
// 2: mig 278 (medidas, plantilla del proveedor, concepto/medida en los cargos).
export const VERSION_BORRADOR_COMPRA = 2

/** Lo que es pantalla y no carga: no se guarda y se resetea al retomar. */
type CamposDePantalla =
  | 'busquedaProducto' | 'mostrarBuscador' | 'modoItemRapido'
  | 'guardando' | 'error' | 'escaneando' | 'errorEscaneo'

export type EstadoBorradorCompra = Omit<CompraState, CamposDePantalla>

export interface BorradorCompra {
  version: number;
  /** ISO, de cuándo se escribió. */
  guardadoEn: string;
  estado: EstadoBorradorCompra;
}

export type LecturaBorrador =
  | { tipo: 'ninguno' }
  | { tipo: 'ok'; borrador: BorradorCompra }
  /** Otra versión del formato (vieja, o de un bundle más nuevo en otra pestaña). */
  | { tipo: 'otra_version'; version: number | null; guardadoEn: string | null; crudo: string }
  /** No es JSON, o no tiene la forma mínima. */
  | { tipo: 'ilegible'; crudo: string }

/** Una clave por sucursal y usuario: el borrador de Tucumán no aparece en Taco Pozo. */
export function claveBorradorCompra(sucursalId: number | string, usuarioId: string): string {
  return `compra-borrador:${sucursalId}:${usuarioId}`
}

export function estadoParaBorrador(state: CompraState): EstadoBorradorCompra {
  // Desestructurar en vez de copiar campo por campo: un campo nuevo del reducer
  // viaja solo, y el tipo obliga a decidir si es de pantalla.
  const {
    busquedaProducto: _b, mostrarBuscador: _m, modoItemRapido: _r,
    guardando: _g, error: _e, escaneando: _s, errorEscaneo: _x,
    ...persistible
  } = state
  return persistible
}

export function serializarBorrador(state: CompraState, ahora: Date): string {
  const borrador: BorradorCompra = {
    version: VERSION_BORRADOR_COMPRA,
    guardadoEn: ahora.toISOString(),
    estado: estadoParaBorrador(state),
  }
  return JSON.stringify(borrador)
}

const esObjeto = (v: unknown): v is Record<string, unknown> =>
  typeof v === 'object' && v !== null && !Array.isArray(v)

/**
 * Lee lo que haya en la clave. Nunca tira.
 *
 * La validación es de FORMA mínima (versión, fecha, listas donde van listas):
 * contra el mismo bundle que lo escribió, con la misma versión, el contenido es
 * el que el reducer produjo. Lo que cubre es el borrador truncado o pisado por
 * otra cosa.
 */
export function leerBorrador(crudo: string | null): LecturaBorrador {
  if (crudo === null || crudo === '') return { tipo: 'ninguno' }
  let datos: unknown
  try {
    datos = JSON.parse(crudo)
  } catch {
    return { tipo: 'ilegible', crudo }
  }
  if (!esObjeto(datos)) return { tipo: 'ilegible', crudo }
  const version = typeof datos.version === 'number' ? datos.version : null
  const guardadoEn = typeof datos.guardadoEn === 'string' ? datos.guardadoEn : null
  if (version !== VERSION_BORRADOR_COMPRA) {
    return { tipo: 'otra_version', version, guardadoEn, crudo }
  }
  const estado = datos.estado
  if (
    !guardadoEn || !esObjeto(estado) ||
    !Array.isArray(estado.items) || !Array.isArray(estado.cargos) ||
    !esObjeto(estado.controlFactura) || !esObjeto(estado.iiDeclarado)
  ) {
    return { tipo: 'ilegible', crudo }
  }
  return { tipo: 'ok', borrador: { version, guardadoEn, estado: estado as unknown as EstadoBorradorCompra } }
}

/**
 * El estado del reducer armado desde el borrador: lo guardado encima del estado
 * inicial, con lo de pantalla limpio. Encima de `initialState` y no de la nada
 * para que un campo de pantalla nunca quede `undefined`.
 */
export function estadoDesdeBorrador(borrador: BorradorCompra): CompraState {
  return {
    ...initialState,
    ...borrador.estado,
    busquedaProducto: '',
    mostrarBuscador: false,
    modoItemRapido: false,
    guardando: false,
    error: '',
    escaneando: false,
    errorEscaneo: '',
  }
}

/**
 * "03/10 14:20" en hora local, para el "Retomar borrador del ...". Cadena vacía
 * si la fecha no se puede leer.
 */
export function fechaHoraBorrador(iso: string | null | undefined): string {
  const fecha = iso ? new Date(iso) : null
  if (!fecha || Number.isNaN(fecha.getTime())) return ''
  const dos = (n: number) => String(n).padStart(2, '0')
  return `${dos(fecha.getDate())}/${dos(fecha.getMonth() + 1)} ${dos(fecha.getHours())}:${dos(fecha.getMinutes())}`
}

/**
 * Las líneas del borrador cuyo producto ya no se puede comprar: borrado, o
 * dado de baja, desde que se guardó el borrador. Se marcan y no se quitan: qué
 * hacer con ellas lo decide quien carga la factura.
 */
export function lineasSinProductoVigente(items: CompraItemForm[], productos: ProductoDB[]): CompraItemForm[] {
  const vigentes = new Set(productos.filter(p => p.activo !== false).map(p => String(p.id)))
  return items.filter(item => !vigentes.has(String(item.productoId)))
}

// =============================================================================
// localStorage, envuelto
// =============================================================================

function almacenamiento(): Storage | null {
  try {
    return typeof window !== 'undefined' ? window.localStorage : null
  } catch {
    // Acceder a la propiedad ya tira en algunos navegadores con el storage bloqueado.
    return null
  }
}

export function leerStorage(clave: string): string | null {
  try {
    return almacenamiento()?.getItem(clave) ?? null
  } catch {
    return null
  }
}

/** `false` si no se pudo escribir (modo privado, cuota llena). */
export function escribirStorage(clave: string, valor: string): boolean {
  try {
    const s = almacenamiento()
    if (!s) return false
    s.setItem(clave, valor)
    return true
  } catch {
    return false
  }
}

export function borrarStorage(clave: string): void {
  try {
    almacenamiento()?.removeItem(clave)
  } catch {
    // Nada que hacer: si no se puede borrar tampoco se pudo escribir.
  }
}
