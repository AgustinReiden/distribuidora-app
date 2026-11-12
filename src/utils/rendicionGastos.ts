/**
 * Reglas puras de los gastos de una rendición: el efectivo a entregar y los cambios
 * que el cierre le manda al server (`confirmar_rendicion`, `p_gastos_rendicion`).
 */
import type {
  CambiosGastosRendicion,
  CobrosVistos,
  Gasto,
  GastoDeRendicion,
  GastoVisto,
  GuardarGastoPayload,
} from '../types/gastos'

const round2 = (n: number): number => Math.round((n + Number.EPSILON) * 100) / 100

export function claveRendicion(transportistaId: string, fecha: string): string {
  return `${transportistaId}|${fecha}`
}

/**
 * Lo que el transportista entrega: el efectivo cobrado menos lo que se pagó con esa plata, sea un
 * gasto o un pago al personal (sueldo, liquidación), y menos los faltantes que se le cargaron a
 * empleados al resolver la rendición.
 */
export function efectivoAEntregar(
  efectivoCobrado: number,
  gastos: number,
  pagosPersonal = 0,
  faltantesEmpleados = 0,
): number {
  return round2(efectivoCobrado - gastos - pagosPersonal - faltantesEmpleados)
}

export function payloadDeGasto(g: Gasto & { km_tablero?: number | null }): GuardarGastoPayload {
  return {
    id: g.id,
    fecha: g.fecha,
    rubro_id: g.rubro_id,
    monto_total: g.monto_total,
    comprobante: g.comprobante,
    comprobante_numero: g.comprobante_numero,
    alicuota_iva: g.alicuota_iva,
    iva: g.iva,
    percepcion_iva: g.percepcion_iva,
    percepcion_iibb: g.percepcion_iibb,
    otros_impuestos: g.otros_impuestos,
    sucursal_id: g.sucursal_id,
    compartido: g.compartido,
    vehiculo_id: g.vehiculo_id,
    litros: g.litros,
    km_tablero: g.km_tablero ?? null,
    mes_imputado: g.mes_imputado,
    repartir_meses: g.repartir_meses,
    origen_pago: g.origen_pago,
    rendicion_transportista_id: g.rendicion_transportista_id,
    rendicion_fecha: g.rendicion_fecha,
    // Sólo un gasto de un empleado lleva su id: los demás viajan como siempre.
    ...(g.origen_pago === 'empleado' ? { empleado_id: g.empleado_id } : {}),
    observacion: g.observacion,
  }
}

/** Los gastos de una rendición tal como llegaron: el `updated_at` va sin reformatear. */
export function gastosVistos(gastos: GastoDeRendicion[]): GastoVisto[] {
  return gastos.map(g => ({ id: g.id, updated_at: g.updated_at }))
}

/** Un gasto del modal de cierre: lo guardado (`original`) y lo que se va a mandar (`payload`). */
export interface ItemCierre {
  clave: string
  original: GastoDeRendicion | null
  payload: GuardarGastoPayload
  editado: boolean
  quitado: boolean
}

export function itemsDelCierre(gastos: GastoDeRendicion[]): ItemCierre[] {
  return gastos.map(g => ({
    clave: `g${g.id}`,
    original: g,
    payload: payloadDeGasto(g),
    editado: false,
    quitado: false,
  }))
}

export function totalDelCierre(items: ItemCierre[]): { cantidad: number; total: number } {
  const vivos = items.filter(i => !i.quitado)
  return { cantidad: vivos.length, total: round2(vivos.reduce((s, i) => s + i.payload.monto_total, 0)) }
}

/**
 * Lo que manda el cierre: sólo lo nuevo, lo editado y lo quitado. Lo que el modal no tocó
 * no viaja, así un encargado reconfirma sin tocar los gastos que cargó un admin.
 */
export function cambiosDelCierre(
  items: ItemCierre[],
  vistos: GastoVisto[],
  pagosPersonalVisto: number,
  faltantesVisto = 0,
  cobrosVisto?: CobrosVistos,
): CambiosGastosRendicion {
  return {
    vistos,
    pagos_personal_visto: pagosPersonalVisto,
    faltantes_visto: faltantesVisto,
    ...(cobrosVisto ? { cobros_visto: cobrosVisto } : {}),
    guardar: items.filter(i => !i.quitado && (i.original === null || i.editado)).map(i => i.payload),
    quitar: items.filter(i => i.quitado && i.original !== null).map(i => i.original!.id),
  }
}

/**
 * Lo cobrado que muestra la tarjeta de una rendición, como lo compara `confirmar_rendicion` (#1547): por
 * forma de pago (sin el adelanto de sueldo, que no es plata de la rendición) y lo de entregas del día.
 */
export function cobrosVistosDe(r: {
  total_efectivo: number
  total_transferencia: number
  total_cheque: number
  total_cuenta_corriente: number
  total_tarjeta: number
  total_otros: number
  total_entregas: number
}): CobrosVistos {
  return {
    efectivo: r.total_efectivo,
    transferencia: r.total_transferencia,
    cheque: r.total_cheque,
    cuenta_corriente: r.total_cuenta_corriente,
    tarjeta: r.total_tarjeta,
    otros: r.total_otros,
    entregas: r.total_entregas,
  }
}

/** El nombre del transportista de una rendición; "otro usuario" si ya no está en la lista. */
export function nombreDeTransportista(
  id: string | null,
  transportistas: Array<{ id: string; nombre: string }>,
): string {
  return transportistas.find(t => t.id === id)?.nombre ?? 'otro usuario'
}
