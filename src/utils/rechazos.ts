/**
 * Reporte de rechazos (#1198): lo puro, espejado del RPC `reporte_rechazos`.
 *
 * El RPC decide qué es un rechazo y calcula los montos; acá viven el mismo
 * clasificador y la misma tasa para que un test pueda afirmar que no se
 * separaron, más lo que la pantalla hace con el detalle (etiquetas, filtros y
 * el resumen de lo filtrado).
 *
 * El reporte muestra CAUSAS, no culpas (decisión del dueño, 2026-10-15): no hay
 * responsable por motivo ni por rol. Dice qué pasó, dónde y con quién, y el
 * gerente decide.
 * Excepción pedida por el dueño (2026-10-26, #1199): el corte por armador
 * atribuye los errores de armado a la persona que marcó el pedido en
 * preparación.
 */
import { MOTIVOS_ADMINISTRATIVOS } from '../constants/desenlacePedido'
import { LABEL_MOTIVO } from '../constants/motivosNoEntrega'
import { MOTIVOS_SALVEDAD_LABELS } from '../lib/schemas'

/** Rechazo total = un pedido entero cancelado; parcial = una línea con salvedad. */
export type TipoRechazo = 'total' | 'parcial'

/**
 * Qué pasó con la mercadería rechazada:
 *  - devuelto: volvió al stock (es venta perdida, a precio de venta);
 *  - mermado: se dio de baja (dañado, vencido, faltante: pérdida real, a costo);
 *  - sin_movimiento: no movió stock (una salvedad "Otro" vieja, un regalo que
 *    no mueve stock). Sólo cuenta en el monto rechazado.
 */
export type DestinoRechazo = 'devuelto' | 'mermado' | 'sin_movimiento'

const ADMINISTRATIVOS: ReadonlySet<string> = new Set(MOTIVOS_ADMINISTRATIVOS)

/**
 * ¿Un pedido cancelado con este motivo es un rechazo? Espejo del filtro del
 * RPC: todo lo que no es administrativo, incluido el cancelado sin motivo.
 */
export function esRechazoTotal(motivoCancelacionTipo: string | null | undefined): boolean {
  if (motivoCancelacionTipo == null || motivoCancelacionTipo === '') return true
  return !ADMINISTRATIVOS.has(motivoCancelacionTipo)
}

/**
 * Los motivos que son un error de ARMADO (decisión del dueño, #1199): lo que
 * faltó, lo que se cargó mal y lo que se rompió al armar. Espejo de
 * `v_motivos_armado` en `reporte_rechazos` (mig 391); un test lee el SQL.
 */
export const MOTIVOS_ERROR_DE_ARMADO = ['faltante_stock', 'error_pedido', 'producto_danado'] as const

/** ¿Este motivo cuenta como error de armado en el corte por armador? */
export function esErrorDeArmado(motivo: string | null | undefined): boolean {
  return motivo != null && (MOTIVOS_ERROR_DE_ARMADO as readonly string[]).includes(motivo)
}

/**
 * Tasa de error de armado = pedidos con algún error de armado / pedidos que
 * salieron armados por esa persona, a 4 decimales como el RPC. Sin pedidos,
 * `null`.
 */
export function tasaErrorArmado(c: { pedidos_con_error_armado: number; pedidos_salieron: number }): number | null {
  if (!c.pedidos_salieron) return null
  return redondear4(c.pedidos_con_error_armado / c.pedidos_salieron)
}

export interface ConteoTasa {
  pedidos_salieron: number
  rechazos_totales: number
  pedidos_con_salvedad: number
}

function redondear4(n: number): number {
  return Math.round(n * 10000) / 10000
}

/**
 * Tasa de rechazo = (rechazos totales + entregados con salvedad) / pedidos que
 * salieron, redondeada a 4 decimales como el RPC. Sin pedidos, `null` (no 0:
 * no hay tasa que mostrar).
 */
export function tasaRechazo(c: ConteoTasa): number | null {
  if (!c.pedidos_salieron) return null
  return redondear4((c.rechazos_totales + c.pedidos_con_salvedad) / c.pedidos_salieron)
}

/** La tasa partida: sólo los pedidos rechazados enteros. */
export function tasaRechazoTotal(c: ConteoTasa): number | null {
  if (!c.pedidos_salieron) return null
  return redondear4(c.rechazos_totales / c.pedidos_salieron)
}

/** La tasa partida: sólo los entregados con alguna salvedad. */
export function tasaConSalvedad(c: ConteoTasa): number | null {
  if (!c.pedidos_salieron) return null
  return redondear4(c.pedidos_con_salvedad / c.pedidos_salieron)
}

/** "8,5 %" o "—" sin tasa. */
export function formatTasa(t: number | null | undefined): string {
  if (t == null) return '—'
  return `${(t * 100).toLocaleString('es-AR', { maximumFractionDigits: 1 })} %`
}

export const LABEL_TIPO_RECHAZO: Record<TipoRechazo, string> = {
  total: 'Pedido entero',
  parcial: 'Línea (salvedad)',
}

export const LABEL_DESTINO: Record<DestinoRechazo, string> = {
  devuelto: 'Volvió al stock',
  mermado: 'Mermado',
  sin_movimiento: 'No movió stock',
}

/** Etiqueta del motivo: de cancelación para el pedido entero, de salvedad para la línea. */
export function labelMotivoRechazo(tipo: TipoRechazo, motivo: string): string {
  if (tipo === 'total') {
    if (motivo === 'sin_motivo') return 'Sin motivo'
    return LABEL_MOTIVO[motivo] ?? motivo
  }
  return (MOTIVOS_SALVEDAD_LABELS as Record<string, string>)[motivo] ?? motivo
}

/** Una fila del detalle del RPC: un pedido entero o una línea con salvedad. */
export interface FilaRechazo {
  tipo: TipoRechazo
  pedido_id: number | string
  salvedad_id: number | string | null
  fecha: string
  sucursal_id: number | string
  sucursal_nombre: string | null
  cliente_id: number | string | null
  cliente_nombre: string | null
  cliente_activo: boolean | null
  usuario_id: string | null
  preventista_nombre: string | null
  transportista_id: string | null
  chofer_nombre: string | null
  motivo: string
  descripcion: string | null
  producto_id: number | string | null
  producto_nombre: string | null
  producto_codigo: string | null
  lineas: number
  unidades: number
  monto: number
  venta_perdida: number
  perdida_real: number
  mermas_sin_costo: number
  destino: DestinoRechazo
  estado_resolucion: string | null
}

/**
 * Filtros de la lista en pantalla. No mueven los totales del reporte, que son
 * del período completo: sólo achican la lista y su resumen.
 * `''` = todos; `'__sin__'` = sin preventista / sin chofer.
 */
export interface FiltrosDetalleRechazos {
  tipo: TipoRechazo | ''
  /** `tipo|motivo`, porque el mismo valor (p. ej. 'cliente_rechaza' u 'otro') existe en los dos. */
  motivo: string
  preventista: string
  chofer: string
  busqueda: string
}

export const FILTROS_DETALLE_VACIOS: FiltrosDetalleRechazos = {
  tipo: '',
  motivo: '',
  preventista: '',
  chofer: '',
  busqueda: '',
}

export const SIN_ASIGNAR = '__sin__'

function coincidePersona(filtro: string, id: string | null): boolean {
  if (!filtro) return true
  if (filtro === SIN_ASIGNAR) return id == null
  return id === filtro
}

export function claveMotivo(tipo: TipoRechazo, motivo: string): string {
  return `${tipo}|${motivo}`
}

export function filtrarDetalleRechazos(filas: FilaRechazo[], f: FiltrosDetalleRechazos): FilaRechazo[] {
  const q = f.busqueda.trim().toLowerCase()
  return filas.filter((r) => {
    if (f.tipo && r.tipo !== f.tipo) return false
    if (f.motivo && claveMotivo(r.tipo, r.motivo) !== f.motivo) return false
    if (!coincidePersona(f.preventista, r.usuario_id)) return false
    if (!coincidePersona(f.chofer, r.transportista_id)) return false
    if (q) {
      const texto = [r.cliente_nombre, r.producto_nombre, r.producto_codigo, r.descripcion, String(r.pedido_id)]
        .filter(Boolean)
        .join(' ')
        .toLowerCase()
      if (!texto.includes(q)) return false
    }
    return true
  })
}

export interface ResumenRechazos {
  casos: number
  pedidos_enteros: number
  lineas: number
  monto: number
  venta_perdida: number
  perdida_real: number
}

/** Suma de lo que se está mirando. Los montos llegan de la base: acá sólo se suman. */
export function resumirRechazos(filas: FilaRechazo[]): ResumenRechazos {
  const r: ResumenRechazos = { casos: 0, pedidos_enteros: 0, lineas: 0, monto: 0, venta_perdida: 0, perdida_real: 0 }
  for (const f of filas) {
    r.casos += 1
    if (f.tipo === 'total') r.pedidos_enteros += 1
    else r.lineas += 1
    r.monto += Number(f.monto) || 0
    r.venta_perdida += Number(f.venta_perdida) || 0
    r.perdida_real += Number(f.perdida_real) || 0
  }
  return r
}
