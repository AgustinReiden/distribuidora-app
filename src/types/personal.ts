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

export type TipoMovimientoEmpleado = 'mercaderia' | 'reintegro' | 'adelanto' | 'ajuste'

export type FiltroPersonal = 'todos' | 'con_saldo' | 'inactivos'

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
  gasto: { id: number; rubro: string; vehiculo: string | null } | null
  revierte_id: number | null
  revertido: boolean
  creado_por_nombre: string | null
  created_at: string
}

export interface CuentaEmpleado {
  empleado: Empleado
  arreglos: ArregloEmpleado[]
  movimientos: MovimientoEmpleado[]
}

export interface EmpleadoParaElegir {
  id: number
  nombre: string
  usuario_id: string | null
  vehiculo_id: number | null
  activo: boolean
}

export interface GuardarArregloPayload {
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

/** El adelanto va positivo (el server lo guarda negativo); el ajuste, con su signo. */
export interface MovimientoManualPayload {
  tipo: 'adelanto' | 'ajuste'
  monto: number
  fecha: string
  observacion: string | null
}
