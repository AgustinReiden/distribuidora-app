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
  observacion: string | null
  creado_por: string
  anulado_at: string | null
  created_at: string
  rubro?: Pick<RubroGasto, 'id' | 'nombre' | 'grupo'>
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
  litros?: number | null
  km_tablero?: number | null
  mes_imputado: string
  repartir_meses: number
  origen_pago: 'oficina' | 'rendicion'
  rendicion_transportista_id?: string | null
  rendicion_fecha?: string | null
  observacion?: string | null
}

/** Un elemento de `obtener_gastos_rendiciones`: siempre trae rubro y vehículo, y los km del tablero. */
export interface GastoDeRendicion extends Gasto {
  km_tablero: number | null
}

/** Lo que recibe `confirmar_rendicion` en `p_gastos_rendicion`. */
export interface CambiosGastosRendicion {
  vistos: number[]
  guardar: GuardarGastoPayload[]
  quitar: number[]
}
