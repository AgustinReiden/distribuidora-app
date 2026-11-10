/**
 * Tipos del módulo de gastos (entrega 1: vehículos, rubros y gastos).
 * Los ids son bigint en la base y llegan como `number` en runtime.
 */

export type GrupoGasto =
  | 'vehiculos'
  | 'inmueble'
  | 'impuestos'
  | 'administracion'
  | 'bienes_de_uso'
  | 'otros'

export type ComprobanteGasto =
  | 'factura_a'
  | 'factura_m'
  | 'factura_b'
  | 'factura_c'
  | 'recibo'
  | 'ticket'
  | 'ninguno'

export type OrigenPagoGasto = 'oficina' | 'rendicion' | 'empleado'

export interface RubroGasto {
  id: number
  nombre: string
  grupo: GrupoGasto
  palabras_busqueda: string | null
  pide_litros_km: boolean
  reparto_sugerido_meses: number | null
  sugiere_mes_anterior: boolean
  activo: boolean
  /**
   * Rubro que usa el sistema (`faltantes_caja` lo busca `resolver_rendicion`). Se renombra pero no se da
   * de baja: el server lo rechaza (#1521). `null` en los demás.
   */
  clave?: string | null
}

export interface Vehiculo {
  id: number
  sucursal_id: number
  patente: string
  descripcion: string
  activo: boolean
}

export interface Gasto {
  id: number
  sucursal_id: number
  compartido: boolean
  fecha: string
  rubro_id: number
  monto_total: number
  comprobante: ComprobanteGasto
  comprobante_numero: string | null
  alicuota_iva: number | null
  iva: number
  percepcion_iva: number
  percepcion_iibb: number
  otros_impuestos: number
  neto: number
  costo: number
  vehiculo_id: number | null
  litros: number | null
  mes_imputado: string
  repartir_meses: number
  mes_fin: string
  origen_pago: OrigenPagoGasto
  /** Con `origen_pago = 'rendicion'`: de qué rendición (transportista y día) salió la plata. */
  rendicion_transportista_id: string | null
  rendicion_fecha: string | null
  /** Con `origen_pago = 'empleado'`: quién puso la plata de su bolsillo (queda a su favor en su cuenta). */
  empleado_id: number | null
  observacion: string | null
  creado_por: string
  anulado_at: string | null
  created_at: string
  /** `pide_litros_km` viaja en el embed: un rubro dado de baja no está en la lista de activos. */
  rubro?: Pick<RubroGasto, 'id' | 'nombre' | 'grupo'> & { pide_litros_km?: boolean }
  vehiculo?: Pick<Vehiculo, 'id' | 'patente' | 'descripcion'> | null
}

/** Lo que recibe guardar_gasto(p_gasto jsonb). */
export interface GuardarGastoPayload {
  id?: number
  fecha: string
  rubro_id: number
  monto_total: number
  comprobante: ComprobanteGasto
  comprobante_numero?: string | null
  alicuota_iva?: number | null
  iva?: number
  percepcion_iva?: number
  percepcion_iibb?: number
  otros_impuestos?: number
  sucursal_id: number
  compartido: boolean
  vehiculo_id?: number | null
  /** En una edición, la clave ausente es «sin cambios»; `null` explícito borra el valor guardado. */
  litros?: number | null
  km_tablero?: number | null
  mes_imputado: string
  repartir_meses: number
  origen_pago: 'oficina' | 'rendicion' | 'empleado'
  rendicion_transportista_id?: string | null
  rendicion_fecha?: string | null
  empleado_id?: number | null
  observacion?: string | null
}

/** Un elemento de `obtener_gastos_rendiciones`: siempre trae rubro y vehículo, los km del tablero y `updated_at`. */
export interface GastoDeRendicion extends Gasto {
  km_tablero: number | null
  updated_at: string
}

/** Un gasto tal como lo vio el modal de cierre: el server compara `(id, updated_at)`. */
export interface GastoVisto {
  id: number
  updated_at: string
}

/** Lo que recibe `confirmar_rendicion` en `p_gastos_rendicion`. */
export interface CambiosGastosRendicion {
  /** Los gastos vivos que mostró el modal, con su `updated_at` tal como llegó. */
  vistos: GastoVisto[]
  guardar: GuardarGastoPayload[]
  quitar: number[]
  /**
   * Lo pagado al personal con la plata de esta rendición al abrir el modal (0 si no hay): el server
   * lo compara con lo vivo, como los gastos, y rechaza si cambió. Sin nombres: sólo el total.
   */
  pagos_personal_visto: number
  /** Lo imputado a empleados (faltantes de rendición) al abrir el modal: se compara igual que los pagos. */
  faltantes_visto: number
}

/** Por qué faltó plata en una rendición: a dónde se imputa. */
export type CausalFaltante = 'empleado' | 'robo_perdida' | 'gasto_no_cargado'

/** Una línea viva de la diferencia imputada al resolver una rendición (`obtener_faltantes_rendiciones`). */
export interface FaltanteDeRendicion {
  id: number
  transportista_id: string
  fecha: string
  causal: CausalFaltante
  monto: number
  observacion: string | null
  empleado: { id: number; nombre: string } | null
  gasto_id: number | null
  rubro_nombre: string | null
  creado_por_nombre: string | null
  created_at: string
}

/** Una línea de lo que manda `resolver_rendicion` en `p_resolucion`. */
export type LineaResolucion =
  | { causal: 'empleado'; monto: number; empleado_id: number; observacion: string | null }
  | { causal: 'robo_perdida'; monto: number; observacion: string | null }
  | { causal: 'gasto_no_cargado'; monto: number; gasto: GuardarGastoPayload }

/** Lo que recibe `resolver_rendicion` en `p_resolucion`: las líneas y lo que vio el modal al abrirse. */
export interface ResolucionRendicion {
  lineas: LineaResolucion[]
  vistos: GastoVisto[]
  pagos_personal_visto: number
}
