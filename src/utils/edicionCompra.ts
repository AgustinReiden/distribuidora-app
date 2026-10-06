/**
 * Lo puro del modo 'editar' de ModalCompra: qué se valida, qué cuenta como
 * cambio sin guardar y qué viaja a `actualizar_compra_items`.
 *
 * Reemplaza la lógica propia que tenía ModalEditarCompra. Lo que se porta de
 * ahí, cada cosa con su test en `edicionCompra.test.ts`:
 *
 *  - `cargos: null` cuando el embed de cargos no llegó, que NO es `[]`: el null
 *    es lo único que activa el guard de la mig 194, y un `[]` sobre una compra
 *    con cargos los borraría en silencio. En ese caso las bonificaciones se
 *    reenvían las guardadas (no hay cargos con qué recalcularlas) y entran al
 *    total, como antes.
 *  - `iiDeclarado: null` = "no la conozco", `{}` = "esta compra no tiene
 *    apertura". Un declarado tipeado viaja; uno borrado viaja como `{}`.
 *  - Percepciones (IVA e IIBB): se editan y viajan siempre (salvo ZZ). Sin
 *    tocarlas viajan las hidratadas, que son las guardadas, así que abrir y
 *    guardar sin cambios manda lo mismo que la compra tenía.
 *  - Otros impuestos NO viajan (undefined): no hay dónde editarlos y la RPC
 *    conserva lo que tenía. Sí entran al total.
 *  - La letra del comprobante (mig 293) no se edita ni viaja: la RPC usa la
 *    guardada para decidir si el IVA es crédito (A/M) o costo (B/C).
 *  - Bonificaciones: RECALCULADAS (`totales.bonificaciones`), no reenviadas,
 *    porque ahora los cargos se editan. El no gravado viaja también: sigue a
 *    los cargos salvo que esté tipeado (`noGravadoManual`, que la hidratación
 *    prende sólo si lo guardado no coincidía con los cargos).
 *  - Validaciones: al menos una línea, cantidad entera > 0, costo ≥ 0,
 *    bonificación en [0, 100], cargo huérfano (sin ninguna línea con peso,
 *    típicamente porque se borró la única línea donde pesaba), vencimientos que
 *    exceden la línea.
 *  - Los vencimientos van en cada item; el hook llama a
 *    `sincronizarLotesDeCompra(..., forzar=true)` aunque la lista esté vacía.
 */
import { validarCargos, cargosParaRPC, iiDeclaradoParaMotor, validarMedidasCargos } from '../components/modals/ModalCompra.reducer'
import { medidasParaFicha } from './medidasCargo'
import type { CompraItemForm, CompraState, CargoCompraForm, VencimientoLinea } from '../components/modals/ModalCompra.reducer'
import { validarVencimientosLineas } from './vencimientos'
import type { ActualizarCompraItemsInput } from '../hooks/queries/useComprasQuery'
import type { TotalesCompra } from './prorrateoCompra'
import type { CompraDBExtended } from '../types'
import { tipoParaCosto } from './letraComprobante'

// =============================================================================
// VENCIMIENTOS PRECARGADOS
// =============================================================================

/** Un lote de la compra, como lo trae useLotesCompraQuery. */
export interface LoteDeCompra {
  producto_id: number | string
  fecha_vencimiento: string
  cantidad: number
}

/**
 * Los vencimientos de cada producto, de los lotes que la compra ya tiene.
 *
 * `cantidad` y no `cantidad_restante`: lo que la compra cargó, no lo que queda.
 * El contador lo lleva la base y se preserva del lado del servidor cuando la
 * clave (producto, fecha) sobrevive a la edición. Los lotes son del PRODUCTO
 * (UNIQUE de la mig 223), no de la línea.
 */
export function vencimientosPorProducto(lotes: LoteDeCompra[]): Map<string, VencimientoLinea[]> {
  const mapa = new Map<string, VencimientoLinea[]>()
  for (const l of lotes) {
    const clave = String(l.producto_id)
    mapa.set(clave, [...(mapa.get(clave) ?? []), { fecha: l.fecha_vencimiento, cantidad: Number(l.cantidad) }])
  }
  return mapa
}

/** Las líneas con sus vencimientos precargados (las que no tienen lote quedan con `[]`). */
export function itemsConVencimientos(items: CompraItemForm[], lotes: LoteDeCompra[]): CompraItemForm[] {
  const porProducto = vencimientosPorProducto(lotes)
  return items.map(it => ({ ...it, vencimientos: porProducto.get(String(it.productoId)) ?? [] }))
}

// =============================================================================
// CAMBIOS SIN GUARDAR
// =============================================================================

function vencimientosDistintos(a: VencimientoLinea[] | undefined, b: VencimientoLinea[] | undefined): boolean {
  const x = a ?? []
  const y = b ?? []
  if (x.length !== y.length) return true
  return x.some((v, i) => v.fecha !== y[i].fecha || Number(v.cantidad) !== Number(y[i].cantidad))
}

function lineaDistinta(a: CompraItemForm, b: CompraItemForm): boolean {
  return (
    a.lineaId !== b.lineaId ||
    String(a.productoId) !== String(b.productoId) ||
    a.cantidad !== b.cantidad ||
    a.costoUnitario !== b.costoUnitario ||
    a.bonificacion !== b.bonificacion ||
    a.porcentajeIva !== b.porcentajeIva ||
    a.condicionIva !== b.condicionIva ||
    a.impuestosInternos !== b.impuestosInternos ||
    vencimientosDistintos(a.vencimientos, b.vencimientos)
  )
}

function pesosDistintos(a: Record<number, number>, b: Record<number, number>): boolean {
  const claves = new Set([...Object.keys(a), ...Object.keys(b)])
  for (const k of claves) {
    if ((a[Number(k)] ?? 0) !== (b[Number(k)] ?? 0)) return true
  }
  return false
}

function cargoDistinto(a: CargoCompraForm, b: CargoCompraForm): boolean {
  return (
    a.id !== b.id ||
    a.concepto !== b.concepto ||
    a.monto !== b.monto ||
    a.condicionIva !== b.condicionIva ||
    a.enFactura !== b.enFactura ||
    a.prorrateaAlCosto !== b.prorrateaAlCosto ||
    a.afectaBaseII !== b.afectaBaseII ||
    a.baseProrrateo !== b.baseProrrateo ||
    (a.conceptoId ?? null) !== (b.conceptoId ?? null) ||
    (a.medidaId ?? null) !== (b.medidaId ?? null) ||
    (a.comprobanteTercero ?? false) !== (b.comprobanteTercero ?? false) ||
    (a.ivaTercero ?? null) !== (b.ivaTercero ?? null) ||
    (a.terceroNombre ?? null) !== (b.terceroNombre ?? null) ||
    (a.terceroComprobante ?? null) !== (b.terceroComprobante ?? null) ||
    pesosDistintos(a.pesos, b.pesos)
  )
}

function iiDistinto(a: Record<number, number>, b: Record<number, number>): boolean {
  return pesosDistintos(a, b)
}

/**
 * ¿La edición tiene algo sin guardar respecto de cómo se abrió?
 *
 * Traba "Cambiar proveedor": ese flujo clona la compra DE LA BASE, no la del
 * modal, así que con cambios sin guardar recrearía la compra sin ellos. Cuenta
 * las líneas (vencimientos incluidos: son lo único de la línea que no vive en
 * `compra_items`), los CARGOS —ahora se editan, y un flete tocado se perdería
 * igual que una cantidad—, el no gravado y el II declarado.
 *
 * `referencia` es el estado hidratado con los vencimientos ya precargados:
 * precargar los lotes de la compra no es una edición del usuario.
 */
export function edicionCompraTieneCambios(referencia: CompraState, actual: CompraState): boolean {
  if (referencia.items.length !== actual.items.length) return true
  if (referencia.items.some((it, i) => lineaDistinta(it, actual.items[i]))) return true
  if (referencia.cargos.length !== actual.cargos.length) return true
  if (referencia.cargos.some((c, i) => cargoDistinto(c, actual.cargos[i]))) return true
  if (referencia.noGravado !== actual.noGravado) return true
  if (referencia.percepcionIva !== actual.percepcionIva || referencia.percepcionIibb !== actual.percepcionIibb) return true
  return iiDistinto(referencia.iiDeclarado, actual.iiDeclarado)
}

// =============================================================================
// VALIDACIÓN
// =============================================================================

/**
 * Lo que frena el guardado, dicho antes de salir a la red. La RPC valida lo
 * suyo igual (mig 194); esto es para leer el problema al lado de lo que lo
 * causó.
 */
export function validarEdicionCompra(state: CompraState): string | null {
  if (state.items.length === 0) {
    return 'La compra debe tener al menos un item. Si querés vaciarla, anulala desde la lista.'
  }
  for (const it of state.items) {
    if (!Number.isInteger(it.cantidad) || it.cantidad <= 0) {
      return `Cantidad inválida en "${it.productoNombre}". Debe ser un entero mayor a 0.`
    }
    if (!Number.isFinite(it.costoUnitario) || it.costoUnitario < 0) {
      return `Costo inválido en "${it.productoNombre}".`
    }
    if (!Number.isFinite(it.bonificacion) || it.bonificacion < 0 || it.bonificacion > 100) {
      return `Bonificación fuera de rango en "${it.productoNombre}" (0 a 100).`
    }
  }
  // El cargo huérfano, con un texto que nombra la causa típica al editar: se
  // borró la única línea donde pesaba. `validarCargos` lo atrapa igual, pero
  // hablando de carga.
  const huerfano = state.cargos.find(
    c => c.prorrateaAlCosto && Object.values(c.pesos).reduce((acc, p) => acc + (Number(p) || 0), 0) === 0,
  )
  if (huerfano) {
    const nombre = huerfano.concepto.trim() || '(sin concepto)'
    return `El cargo "${nombre}" se quedaría sin ninguna línea donde repartirse y ese importe desaparecería del costo. Asignale un peso en "Cargos y prorrateo", restaurá la línea que borraste o quitá el cargo.`
  }
  const errorCargos = validarCargos(state.cargos)
  if (errorCargos) return errorCargos
  // mig 278: una línea nueva (o recalculada) de un cargo por medida sin unidades
  // por medida bloquea, igual que al cargar.
  const errorMedidas = validarMedidasCargos(state.cargos, state.items, state.medidas)
  if (errorMedidas) return errorMedidas
  // Etiquetar menos que la línea es legal (el resto queda sin vencimiento);
  // etiquetar más no, y del lado del servidor nadie lo ve.
  return validarVencimientosLineas(
    state.items.map(it => ({ nombre: it.productoNombre, cantidad: it.cantidad, vencimientos: it.vencimientos })),
  )
}

// =============================================================================
// PAYLOAD
// =============================================================================

export interface ArmarEdicionInput {
  compra: CompraDBExtended
  state: CompraState
  /** Los totales del motor sobre `state` (con percepciones y otros impuestos). */
  totales: Pick<TotalesCompra, 'subtotal' | 'iva' | 'impuestosInternos' | 'total' | 'bonificaciones'>
  usuarioId: string | null
}

/** ¿Llegó el embed de cargos? `undefined` = no se pudo leer (o un select viejo). */
export function cargosLeidos(compra: CompraDBExtended): boolean {
  return compra.cargos !== undefined && compra.cargos !== null
}

/**
 * Los totales que se muestran y se guardan. Sin el embed de cargos no hay con
 * qué recalcular las bonificaciones de cabecera, y dejarlas en 0 bajaría el
 * total por un dato que no llegó: se usa la guardada, como hacía
 * ModalEditarCompra. (Guardar en ese estado lo rechaza igual el guard de la
 * mig 194 si la compra tiene cargos.)
 */
export function totalesDeEdicion<T extends Pick<TotalesCompra, 'total' | 'bonificaciones'>>(
  compra: CompraDBExtended,
  totales: T,
): T {
  if (cargosLeidos(compra)) return totales
  const guardadas = Number(compra.bonificaciones ?? 0)
  return { ...totales, bonificaciones: guardadas, total: totales.total + guardadas }
}

/** El input de `useActualizarCompraMutation` para esta edición. */
export function armarEdicionCompra({ compra, state, totales, usuarioId }: ArmarEdicionInput): ActualizarCompraItemsInput {
  const esZZ = state.tipoFactura === 'ZZ'
  // mig 293: en ZZ, B y C la línea va sin IVA ni II discriminados (la RPC lo
  // normaliza igual con la letra guardada). La letra no se edita.
  const tipoCosto = tipoParaCosto(state.tipoFactura, state.letraComprobante)
  const sinCredito = tipoCosto === 'ZZ'
  const leidos = cargosLeidos(compra)

  const items = state.items.map(it => {
    const neto = (it.costoUnitario || 0) * (1 - (it.bonificacion || 0) / 100)
    return {
      productoId: String(it.productoId),
      cantidad: it.cantidad,
      costoUnitario: it.costoUnitario || 0,
      subtotal: it.cantidad * neto,
      bonificacion: it.bonificacion || 0,
      // En ZZ no se discrimina: la RPC lo normaliza igual, mandarlo así deja a
      // las dos puntas diciendo lo mismo.
      porcentajeIva: sinCredito ? 0 : (it.porcentajeIva ?? 21),
      condicionIva: sinCredito ? 'gravado' as const : (it.condicionIva ?? 'gravado'),
      // Del snapshot de la línea (o de la ficha, si la línea se agregó acá).
      // No se tipea: sale del encuadre (mig 277).
      impuestosInternos: sinCredito ? 0 : (it.impuestosInternos ?? 0),
      vencimientos: it.vencimientos ?? [],
    }
  })

  // Apertura del II: lo que haya en el estado; si no hay nada, la misma
  // distinción null/{} de antes según lo que la compra tenía guardado.
  const declarado = iiDeclaradoParaMotor(state.iiDeclarado, tipoCosto)
  const iiDeclarado: Record<number, number> | null = Object.keys(declarado).length > 0
    ? declarado
    : (compra.ii_declarado == null ? null : {})

  return {
    compraId: String(compra.id),
    usuarioId,
    subtotal: totales.subtotal,
    iva: totales.iva,
    total: totales.total,
    impuestosInternos: totales.impuestosInternos,
    // Percepciones: se editan como en 'nueva'. Sin tocarlas viajan las
    // hidratadas, que son las guardadas: abrir y guardar manda lo mismo que hay.
    // En ZZ no hay percepciones: undefined y la RPC deja su 0.
    percepcionIva: esZZ ? undefined : state.percepcionIva,
    percepcionIibb: esZZ ? undefined : state.percepcionIibb,
    noGravado: esZZ ? 0 : state.noGravado,
    items,
    // Los pesos van por ÍNDICE de `items`, que sale de `state.items` en el mismo
    // orden: `cargosParaRPC` traduce contra ese mismo array.
    cargos: leidos ? cargosParaRPC(state.items, state.cargos) : null,
    iiDeclarado,
    bonificaciones: leidos ? totales.bonificaciones : (compra.bonificaciones ?? null),
    // Las u/pallet tipeadas con "guardar en la ficha" (mig 278): van después
    // de la RPC, sin bloquear.
    medidasFicha: medidasParaFicha(state.medidas, state.items.map(it => String(it.productoId))),
  }
}
