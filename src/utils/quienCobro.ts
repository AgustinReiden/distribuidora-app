/**
 * T4 (#1710, D1 de #1507) · De qué caja es un cobro.
 *
 * Cada cobro va a la rendición de quien lo cobró (`pagos.cobrado_por`, lo pone el server al
 * cobrar y no sigue a la boleta). Lo que cobra el chofer es suyo; lo que cobra la oficina, de quien
 * lo carga; lo que la oficina carga al marcar una entrega con un chofer es del chofer. El admin
 * elige a cualquiera; el encargado, sólo al chofer de la boleta (`_cobrador_de_cobro`).
 */
import type { EleccionChofer } from './choferDeEntrega'

/**
 * Quién cobró en «Entregar y registrar pago» desde la oficina.
 *
 * - `elegido` es lo que eligió el admin en «Quién cobró»: `null` es él mismo, y `undefined` es
 *   que no eligió (o no puede elegir).
 * - Sin elegir: el chofer de la entrega (el elegido en «Quién repartió» o el de la boleta). Un
 *   retiro en depósito no tiene chofer: es de quien lo carga.
 */
export function cobradorDeLaEntrega(
  elegido: string | null | undefined,
  eleccion: EleccionChofer | null | undefined,
  transportistaDelPedido: string | null | undefined,
): string | null {
  if (elegido !== undefined) return elegido
  if (eleccion?.tipo === 'retiro') return null
  if (eleccion?.tipo === 'chofer') return eleccion.transportistaId
  return transportistaDelPedido || null
}

/**
 * ¿Puede quien mira corregir un cobro de esta rendición (`corregir_cobro_rendicion`)?
 * El admin, en una abierta o en disconformidad. El encargado, sólo en una abierta que no es de un
 * encargado (tampoco la suya). Una cerrada no se corrige: se reabre.
 */
export function puedeCorregirCobro(args: {
  esAdmin: boolean
  esEncargado: boolean
  estado: string
  /** La rendición es de un encargado (también la de quien mira, si lo es). */
  esDeEncargado: boolean
}): boolean {
  const { esAdmin, esEncargado, estado, esDeEncargado } = args
  if (esAdmin) return estado === 'pendiente' || estado === 'disconformidad'
  if (!esEncargado) return false
  return estado === 'pendiente' && !esDeEncargado
}

/** Lo que queda de un faltante a cargo de un empleado, descontado lo que el cliente ya pagó. */
export function pendienteDelFaltante(f: { causal: string; monto: number; recuperado?: number | null }): number {
  if (f.causal !== 'empleado') return 0
  return Math.max(0, Math.round((Number(f.monto) - Number(f.recuperado ?? 0)) * 100) / 100)
}

/**
 * Los faltantes de una rendición vienen netos (`total_faltantes_empleados`): lo cobrado contra un
 * faltante de otro entra en la caja de quien lo recibió y deja ese total en negativo. Para decirlo.
 */
export function faltantesParaMostrar(totalFaltantes: number): { cargados: number; cobradosContraFaltantes: number } {
  return totalFaltantes >= 0
    ? { cargados: totalFaltantes, cobradosContraFaltantes: 0 }
    : { cargados: 0, cobradosContraFaltantes: -totalFaltantes }
}

/**
 * Quién cobró, como lo piden las RPC de cobro: sólo si se eligió (T4, #1710). Sin elegir no se
 * manda: el server lo pone en quien llama, y el llamado es el de siempre.
 */
export function argQuienCobro(cobradoPor: string | null | undefined): { p_cobrado_por?: string } {
  return cobradoPor ? { p_cobrado_por: cobradoPor } : {}
}

/**
 * A quién puede poner el admin en «Quién cobró»: los usuarios activos que no son del depósito
 * (el server además pide que sean de la sucursal).
 */
export function quienesCobranDe(
  usuarios: ReadonlyArray<{ id: string; nombre?: string | null; rol?: string | null; activo?: boolean | null }>,
): Array<{ id: string; nombre: string }> {
  return usuarios
    .filter(u => u.activo !== false && u.rol !== 'deposito')
    .map(u => ({ id: u.id, nombre: u.nombre ?? '' }))
}
