/**
 * Reglas puras de los faltantes de una rendición: la diferencia que el admin imputa al resolverla
 * (gastos 6). Lo que se arma acá es lo que ve el modal de resolver y las listas de lo imputado.
 */
import { formatPrecio } from './formatters'
import type { CausalFaltante, FaltanteDeRendicion } from '../types/gastos'
import type { EmpleadoParaElegir } from '../types/personal'

export const ETIQUETA_CAUSAL: Record<CausalFaltante, string> = {
  empleado: 'A cargo del empleado',
  robo_perdida: 'Robo o pérdida',
  gasto_no_cargado: 'Gasto que no se cargó',
}

export const MENSAJE_SIN_EMPLEADOS = 'Para cargársela a alguien, primero dalo de alta en Personal'
export const MENSAJE_SUPERA = 'Lo imputado supera lo que había para entregar'

const round2 = (n: number): number => Math.round((n + Number.EPSILON) * 100) / 100

export function totalImputado(lineas: ReadonlyArray<{ monto: number }>): number {
  return round2(lineas.reduce((s, l) => s + l.monto, 0))
}

/** Lo que queda para entregar después de imputar; negativo si se imputó de más. */
export function quedaAEntregar(aEntregar: number, lineas: ReadonlyArray<{ monto: number }>): number {
  return round2(aEntregar - totalImputado(lineas))
}

/** A quién se le puede cargar una deuda: los activos, y nunca al propio usuario. Por nombre. */
export function empleadosParaFaltante(
  empleados: EmpleadoParaElegir[],
  usuarioId: string | null,
): EmpleadoParaElegir[] {
  return empleados
    .filter(e => e.activo && (usuarioId === null || e.usuario_id !== usuarioId))
    .sort((a, b) => a.nombre.localeCompare(b.nombre, 'es'))
}

/** El empleado vinculado al usuario de la rendición, si está activo. */
export function empleadoSugerido(empleados: EmpleadoParaElegir[], transportistaId: string): number | null {
  return empleados.find(e => e.activo && e.usuario_id === transportistaId)?.id ?? null
}

/** Los gastos que nacieron de resolver la rendición: no se tocan sueltos. */
export function gastosDeResolucion(faltantes: FaltanteDeRendicion[]): Set<number> {
  const ids = new Set<number>()
  for (const f of faltantes) if (f.gasto_id !== null) ids.add(f.gasto_id)
  return ids
}

export function textoFaltante(f: FaltanteDeRendicion): string {
  const monto = formatPrecio(f.monto)
  let base: string
  if (f.causal === 'empleado') base = `A cargo de ${f.empleado?.nombre ?? 'un empleado'} · ${monto}`
  else if (f.causal === 'robo_perdida') base = `${ETIQUETA_CAUSAL.robo_perdida} · ${monto}`
  else base = `${ETIQUETA_CAUSAL.gasto_no_cargado}${f.rubro_nombre ? `: ${f.rubro_nombre}` : ''} · ${monto}`
  const observacion = f.observacion?.trim()
  return observacion ? `${base} · ${observacion}` : base
}
