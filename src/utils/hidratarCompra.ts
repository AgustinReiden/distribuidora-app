/**
 * El estado del modal de compra armado desde una compra GUARDADA: cabezal,
 * `compra_items` y `compra_cargos` con sus repartos.
 *
 * Es la puerta de entrada de 'ver' y de 'editar'. Lo que hace
 * no es una traducción de nombres: es decidir qué es DATO y qué es PRE-LLENADO.
 * El reducer pre-llena tres cosas solas —los pesos de un cargo según su base, el
 * `afectaBaseII` que deduce el solver y el no gravado de cabecera— y en una
 * compra guardada ninguna de las tres es pre-llenado: es lo que quedó. Si se las
 * dejara "automáticas", la primera vez que el wrapper del reducer corriera las
 * recalcularía y el costo de la pantalla dejaría de ser el que se guardó, sin
 * que nada lo avise. Por eso:
 *
 *  - todos los pesos de todos los cargos van marcados como MANUALES, los ceros
 *    incluidos (el 0 es la exclusión: perderlo cambia el alcance del cargo). Una
 *    línea sin fila de reparto es un 0, no "sin dato";
 *  - `afectaBaseIIManual = true` en todos los cargos;
 *  - `noGravadoManual` sólo si lo guardado difiere de lo que suman los cargos:
 *    si coincide, seguir al automático da el mismo número y no hay nada que
 *    proteger.
 *
 * Y lo fiscal de cada línea (II, IVA, condición, bonificación, costo) sale del
 * SNAPSHOT de `compra_items`, nunca de la ficha ni del encuadre vigentes: la
 * ficha cambia después de la compra y la compra no.
 *
 * Puro y sin supabase: lo testea `hidratarCompra.test.ts`.
 */
import { redondearSQL } from './calculations'
import { initialState, noGravadoDeCargos } from '../components/modals/ModalCompra.reducer'
import type { CargoCompraForm, CompraItemForm, CompraState } from '../components/modals/ModalCompra.reducer'
import type { BaseProrrateoCompra, CompraCargoDBExtended, CompraDBExtended, CompraItemDBExtended, CondicionIva } from '../types'

const CONDICIONES: CondicionIva[] = ['gravado', 'exento', 'no_gravado']
const BASES: BaseProrrateoCompra[] = ['monto', 'cantidad', 'unidades', 'medida']

/** Lo que devuelve la hidratación: el estado y el puente línea ↔ compra_items. */
export interface CompraHidratada {
  estado: CompraState
  /** lineaId local → la fila de `compra_items` de la que salió. */
  itemPorLinea: Map<number, CompraItemDBExtended>
  /** lineaId local → `compra_items.costo_real_unitario` guardado (null = la línea no lo tiene). */
  costoGuardadoPorLinea: Map<number, number | null>
  /**
   * `true` si la compra vino sin líneas: o no tiene (no debería pasar) o la RLS
   * no dejó leerlas. La vista lo dice en vez de mostrar una tabla vacía.
   */
  sinLineas: boolean
}

const numero = (v: unknown, porDefecto = 0): number => {
  const n = Number(v)
  return Number.isFinite(n) ? n : porDefecto
}

/** Orden estable: por id numérico. El embed de PostgREST no garantiza ninguno. */
const porId = (a: { id: string | number }, b: { id: string | number }) => numero(a.id) - numero(b.id)

function lineaDesdeItem(item: CompraItemDBExtended, lineaId: number): CompraItemForm {
  const condicionIva: CondicionIva = CONDICIONES.includes(item.condicion_iva as CondicionIva)
    ? (item.condicion_iva as CondicionIva)
    : 'gravado'
  return {
    productoId: String(item.producto_id),
    productoNombre: item.producto?.nombre ?? `Producto #${item.producto_id}`,
    productoCodigo: item.producto?.codigo ?? null,
    cantidad: numero(item.cantidad),
    bonificacion: numero(item.bonificacion),
    costoUnitario: numero(item.costo_unitario),
    // Snapshot de la línea (mig 113). Una línea anterior a esa migración lo trae
    // NULL: se toma 0 y no la tasa de la ficha, que es de hoy.
    impuestosInternos: numero(item.impuestos_internos),
    // Sin snapshot de alícuota, 21 para gravado (el default de la columna) y 0
    // para lo que no tributa. Tampoco acá se mira la ficha.
    porcentajeIva: item.porcentaje_iva == null
      ? (condicionIva === 'gravado' ? 21 : 0)
      : numero(item.porcentaje_iva),
    condicionIva,
    // El stock de esa compra (antes → después) lo muestra la vista con la fila
    // original; este campo es el "stock actual" de la carga y no aplica.
    stockActual: numero(item.stock_nuevo),
    lineaId,
  }
}

function cargoDesdeFila(
  fila: CompraCargoDBExtended,
  id: number,
  lineaPorItem: Map<string, number>,
  cantidadPorLinea: Map<number, number>,
): CargoCompraForm {
  const pesos: Record<number, number> = {}
  const pesosManuales: Record<number, true> = {}
  // La cantidad contra la que se fijó cada peso: si al editar cambia, el peso
  // se marca desactualizado (utils/pesosDesactualizados) en vez de recalcularse.
  const cantidadesReferencia: Record<number, number> = {}
  // Todas las líneas arrancan en 0 y marcadas: la que no tiene fila de reparto
  // quedó excluida del cargo, y eso también es lo que se guardó.
  for (const lineaId of lineaPorItem.values()) {
    pesos[lineaId] = 0
    pesosManuales[lineaId] = true
    cantidadesReferencia[lineaId] = cantidadPorLinea.get(lineaId) ?? 0
  }
  for (const r of fila.repartos ?? []) {
    const lineaId = lineaPorItem.get(String(r.compra_item_id))
    if (lineaId === undefined) continue
    pesos[lineaId] = numero(r.peso)
  }
  const condicionIva: CondicionIva = CONDICIONES.includes(fila.condicion_iva as CondicionIva)
    ? (fila.condicion_iva as CondicionIva)
    : 'no_gravado'
  return {
    id,
    concepto: fila.concepto ?? '',
    monto: numero(fila.monto),
    condicionIva,
    enFactura: fila.en_factura ?? true,
    prorrateaAlCosto: fila.prorratea_al_costo ?? true,
    afectaBaseII: fila.afecta_base_ii ?? false,
    afectaBaseIIManual: true,
    baseProrrateo: BASES.includes(fila.base_prorrateo as BaseProrrateoCompra)
      ? (fila.base_prorrateo as BaseProrrateoCompra)
      : 'unidades',
    pesos,
    pesosManuales,
    cantidadesReferencia,
    // mig 278. Una fila anterior a la migración no los trae: null.
    conceptoId: fila.concepto_id == null ? null : String(fila.concepto_id),
    medidaId: fila.medida_id == null ? null : String(fila.medida_id),
  }
}

/** `{ "8.6956": 123 }` de la base → `Record<number, number>` del motor. */
function iiDeclaradoDesdeFila(valor: CompraDBExtended['ii_declarado']): Record<number, number> {
  const salida: Record<number, number> = {}
  for (const [tasa, monto] of Object.entries(valor ?? {})) {
    const t = Number(tasa)
    const m = Number(monto)
    if (Number.isFinite(t) && Number.isFinite(m)) salida[t] = m
  }
  return salida
}

export function hidratarCompraGuardada(compra: CompraDBExtended): CompraHidratada {
  const items = [...(compra.items ?? [])].sort(porId)
  const lineaPorItem = new Map<string, number>()
  const itemPorLinea = new Map<number, CompraItemDBExtended>()
  const costoGuardadoPorLinea = new Map<number, number | null>()
  const lineas = items.map((item, i) => {
    const lineaId = i + 1
    lineaPorItem.set(String(item.id), lineaId)
    itemPorLinea.set(lineaId, item)
    costoGuardadoPorLinea.set(
      lineaId,
      item.costo_real_unitario == null ? null : numero(item.costo_real_unitario),
    )
    return lineaDesdeItem(item, lineaId)
  })

  const filasCargos = [...(compra.cargos ?? [])].sort(
    (a, b) => numero(a.orden) - numero(b.orden) || porId(a, b),
  )
  const cantidadPorLinea = new Map(lineas.map(l => [l.lineaId as number, l.cantidad]))
  const cargos = filasCargos.map((fila, i) => cargoDesdeFila(fila, i + 1, lineaPorItem, cantidadPorLinea))

  const tipoFactura: 'ZZ' | 'FC' = compra.tipo_factura === 'ZZ' ? 'ZZ' : 'FC'
  const noGravado = numero(compra.no_gravado)
  // Al centavo: lo guardado es numeric(12,2) y la suma de los cargos también.
  const noGravadoManual = redondearSQL(noGravado, 2) !== noGravadoDeCargos(cargos)

  const estado: CompraState = {
    ...initialState,
    percepcionIva: numero(compra.percepcion_iva),
    percepcionIibb: numero(compra.percepcion_iibb),
    noGravado,
    noGravadoManual,
    // El total guardado queda como "lo que dice la factura": al editar (B2) el
    // cuadre compara contra el total original de la compra.
    controlFactura: { ...initialState.controlFactura, total: numero(compra.total) },
    cargos,
    iiDeclarado: iiDeclaradoDesdeFila(compra.ii_declarado),
    proveedorId: compra.proveedor_id ? String(compra.proveedor_id) : '',
    proveedorNombre: compra.proveedor?.nombre ?? compra.proveedor_nombre ?? '',
    usarProveedorNuevo: !compra.proveedor_id && !!compra.proveedor_nombre,
    numeroFactura: compra.numero_factura ?? '',
    fechaCompra: compra.fecha_compra ?? initialState.fechaCompra,
    formaPago: compra.forma_pago ?? initialState.formaPago,
    tipoFactura,
    notas: compra.notas ?? '',
    items: lineas,
  }

  return { estado, itemPorLinea, costoGuardadoPorLinea, sinLineas: lineas.length === 0 }
}
