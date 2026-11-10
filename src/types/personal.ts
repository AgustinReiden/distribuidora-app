/**
 * Tipos del módulo Personal (entrega 3 de gastos): empleados, arreglos de sueldo
 * y su cuenta corriente. Los ids son `number` (bigint en runtime), salvo el del usuario.
 */

export type PuestoEmpleado =
  | 'preventista'
  | 'transportista'
  | 'ayudante'
  | 'deposito'
  | 'administracion'
  | 'encargado'
  | 'otro'

export type FrecuenciaSueldo = 'semanal' | 'mensual'

export type TipoMovimientoEmpleado =
  | 'mercaderia' | 'reintegro' | 'adelanto' | 'ajuste'
  | 'sueldo' | 'comision' | 'ajuste_comision' | 'pago'
  | 'faltante' | 'rotura'

export type FiltroPersonal = 'todos' | 'para_liquidar' | 'con_saldo' | 'inactivos'

export type OrigenPagoEmpleado = 'oficina' | 'rendicion'

export type AvisoLiquidacion = 'comisiona_sin_usuario' | 'arreglo_cambia' | 'periodo_parcial'

export interface PeriodoLiquidacion {
  desde: string
  hasta: string
  frecuencia: FrecuenciaSueldo
}

export interface PeriodoPendiente extends PeriodoLiquidacion {
  /** Períodos terminados sin liquidar, además de éste. */
  mas_vencidos: number
}

/** La rendición de la que salió un pago. El chofer es el de la rendición, no el empleado. */
export interface RendicionDelPago {
  transportista_nombre: string
  fecha: string
}

export interface ArregloEmpleado {
  id: number
  vigente_desde: string
  vigente_hasta: string | null
  sueldo: number
  frecuencia: FrecuenciaSueldo
  comisiona: boolean
}

export interface Empleado {
  id: number
  nombre: string
  puesto: PuestoEmpleado
  sucursal_id: number
  de_las_dos: boolean
  cuil: string | null
  fecha_ingreso: string | null
  telefono: string | null
  activo: boolean
  fecha_baja: string | null
  usuario: { id: string; nombre: string } | null
  cliente: { id: number; nombre_fantasia: string; activo: boolean } | null
  vehiculo: { id: number; patente: string; descripcion: string } | null
  /** El vigente hoy, o el primero si todavía no empezó. */
  arreglo: ArregloEmpleado | null
  /** `vigente_desde` del primer arreglo. */
  arranque: string | null
  saldo: number
  /** `usuario.id` = el que mira. */
  es_propio: boolean
  /** El período más viejo sin liquidar, o `null` si no hay nada para liquidar. */
  periodo: PeriodoPendiente | null
}

export interface MovimientoEmpleado {
  id: number
  fecha: string
  tipo: TipoMovimientoEmpleado
  monto: number
  /** Acumulado, por (fecha, id). */
  saldo: number
  observacion: string | null
  pago_id: number | null
  pedido_id: number | null
  /** La baja de stock o la salvedad de la que salió una `rotura` (exactamente una). */
  merma_id: number | null
  salvedad_id: number | null
  gasto: { id: number; rubro: string; vehiculo: string | null } | null
  revierte_id: number | null
  revertido: boolean
  creado_por_nombre: string | null
  created_at: string
  /** La liquidación que lo generó, o `null` si es un movimiento a mano. */
  liquidacion: (PeriodoLiquidacion & { id: number; pedidos: number; anulada: boolean }) | null
  /** La rendición de la que salió un pago. */
  rendicion: RendicionDelPago | null
}

export interface LiquidacionResumen extends PeriodoLiquidacion {
  id: number
  sueldo: number
  comision: number
  ajuste: number
  a_pagar: number
  pagado: number
  fecha_pago: string
  rendicion: RendicionDelPago | null
  anulada_at: string | null
  motivo_anulacion: string | null
  creado_por_nombre: string | null
  /** La última vigente del empleado: la única que se anula. */
  es_la_ultima: boolean
}

export interface CuentaEmpleado {
  empleado: Empleado
  arreglos: ArregloEmpleado[]
  movimientos: MovimientoEmpleado[]
  liquidaciones: LiquidacionResumen[]
}

export interface PedidoLiquidado {
  pedido_id: number
  fecha: string
  entregado_el: string
  cliente: string
  base: number
  comision: number
}

export interface AjusteLiquidado {
  pedido_id: number
  motivo: string
  base: number
  comision: number
}

export interface MovimientoDelPeriodo {
  id: number
  fecha: string
  tipo: TipoMovimientoEmpleado
  monto: number
  observacion: string | null
  pedido_id: number | null
  gasto: MovimientoEmpleado['gasto']
  revierte_id: number | null
  /** Lo disparó el propio usuario del empleado (rastro de #1354). */
  por_el_mismo: boolean
  /** Como en la cuenta: la liquidación que lo generó (un pago de una anulada sin revertir sigue acá). */
  liquidacion: MovimientoEmpleado['liquidacion']
  /** La rendición de la que salió un pago. */
  rendicion: MovimientoEmpleado['rendicion']
}

export interface VistaPreviaLiquidacion {
  periodo: PeriodoPendiente
  /** `desde <= hoy` y no es la cuenta propia. */
  puede_liquidar: boolean
  /** `hoy <= hasta`: el período todavía no terminó. */
  en_curso: boolean
  sueldo: { propuesto: number; arreglo_desde: string | null }
  comisiones: { total: number; base: number; detalle: PedidoLiquidado[] }
  ajustes: { total: number; detalle: AjusteLiquidado[] }
  movimientos: MovimientoDelPeriodo[]
  saldo_anterior: number
  saldo_actual: number
  /** Con el sueldo propuesto. */
  a_pagar: number
  avisos: AvisoLiquidacion[]
}

export interface DetalleLiquidacion extends LiquidacionResumen {
  sueldo_propuesto: number
  motivo_sueldo: string | null
  pedidos: PedidoLiquidado[]
  ajustes: AjusteLiquidado[]
}

/** De qué plata sale un pago: la oficina o el efectivo de una rendición pendiente. */
export interface PlataDelPago {
  origen_pago: OrigenPagoEmpleado
  rendicion_transportista_id: string | null
  rendicion_fecha: string | null
}

export interface LiquidarPayload extends PlataDelPago {
  desde: string
  hasta: string
  sueldo: number
  /** Obligatorio sólo si `sueldo` difiere del propuesto. */
  motivo_sueldo: string | null
  pago: number
  fecha_pago: string
  /** El `a_pagar` que vio quien confirma: si cambió en el medio, el server rechaza. */
  a_pagar_esperado: number
}

export interface EmpleadoParaElegir {
  id: number
  nombre: string
  usuario_id: string | null
  vehiculo_id: number | null
  activo: boolean
}

/** Una línea de «A cargo de empleados» tal como se edita: el monto es el texto tipeado. */
export interface LineaCargo {
  empleado_id: number | null
  monto: string
}

/** Una línea del `p_cargos` de `registrar_merma_manual` y `resolver_salvedad`: monto > 0. */
export interface CargoRotura {
  empleado_id: number
  monto: number
}

export interface GuardarArregloPayload {
  /** Con `id` se corrige ese arreglo, que tiene que ser el último del empleado, también su fecha (#1521). */
  id?: number
  vigente_desde: string
  sueldo: number
  frecuencia: FrecuenciaSueldo
  comisiona: boolean
}

export interface GuardarEmpleadoPayload {
  id?: number
  nombre: string
  puesto: PuestoEmpleado
  sucursal_id: number
  de_las_dos: boolean
  cuil: string | null
  fecha_ingreso: string | null
  telefono: string | null
  usuario_id: string | null
  cliente_id: number | null
  vehiculo_id: number | null
  /** Sólo en el alta. */
  arreglo?: GuardarArregloPayload
  /** Sólo en el alta; + a su favor, − debe. */
  saldo_inicial?: number | null
}

/**
 * El adelanto y el pago van positivos (el server los guarda negativos); el ajuste, con su signo.
 * Sólo el pago puede salir de una rendición.
 */
export interface MovimientoManualPayload extends Partial<PlataDelPago> {
  tipo: 'adelanto' | 'ajuste' | 'pago'
  monto: number
  fecha: string
  observacion: string | null
}
