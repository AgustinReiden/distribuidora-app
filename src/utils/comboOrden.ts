/**
 * La prioridad de los combos como ORDEN (#1213). `combos.prioridad` sigue
 * siendo lo que lee `armarCombos` (mayor primero), pero el admin no ve un
 * número: ve, en el formulario, con qué combos compite éste y en qué orden, y
 * lo mueve con flechas.
 *
 * - Dos combos compiten si comparten algún producto (resuelto, contando
 *   categorías) y los dos están en juego: activos y no vencidos.
 * - El orden se guarda por GRUPO: el conjunto conexo de combos que compiten
 *   (A con B y B con C ponen a A, B y C en el mismo grupo aunque A y C no
 *   compitan). `guardar_combo` reescribe la prioridad del grupo entero con
 *   `orden`, para que quede coherente.
 * - Regla automática (al crear, al cambiarle los lugares o al reactivarlo):
 *   el combo va arriba de los competidores directos que llevan menos unidades,
 *   y a igual cantidad, arriba de los más viejos. Los demás no se mueven.
 */

import { resolverLugares, type LugarCombo, type ProductoCatalogo } from './comboCategorias'

/** Un combo que todavía no tiene id. Es el más nuevo de todos. */
export const ID_NUEVO = 'nuevo'

export interface ComboOrdenable {
  id: string
  prioridad: number
  activo: boolean
  fechaFin: string | null
  /** Unidades que junta una instancia del combo (suma de las cantidades). */
  unidades: number
  /** Productos que vende hoy, todos los lugares juntos. */
  productos: ReadonlySet<string>
}

export function enJuego(c: Pick<ComboOrdenable, 'activo' | 'fechaFin'>, hoy: string): boolean {
  return c.activo && (!c.fechaFin || c.fechaFin >= hoy)
}

export function compiten(a: ComboOrdenable, b: ComboOrdenable): boolean {
  if (a.id === b.id) return false
  for (const p of a.productos) if (b.productos.has(p)) return true
  return false
}

/** Comparación de antigüedad: positivo si `a` es más nuevo que `b`. */
function masNuevo(a: string, b: string): number {
  if (a === b) return 0
  if (a === ID_NUEVO) return 1
  if (b === ID_NUEVO) return -1
  return Number(a) - Number(b)
}

/** `a` gana sobre `b` por la regla automática. */
export function ganaPorRegla(a: ComboOrdenable, b: ComboOrdenable): boolean {
  return a.unidades > b.unidades || (a.unidades === b.unidades && masNuevo(a.id, b.id) > 0)
}

/** Los combos en juego que compiten directamente con `combo`. */
export function competidoresDirectos(
  combo: ComboOrdenable,
  otros: readonly ComboOrdenable[],
  hoy: string,
): ComboOrdenable[] {
  return otros.filter(o => o.id !== combo.id && enJuego(o, hoy) && compiten(combo, o))
}

/**
 * El grupo de `combo` (él y todos los conectados por competencia), ordenado
 * por la prioridad guardada. Un combo fuera de juego no tiene grupo.
 */
export function grupoDe(combo: ComboOrdenable, otros: readonly ComboOrdenable[], hoy: string): ComboOrdenable[] {
  const enJuegoOtros = otros.filter(o => o.id !== combo.id && enJuego(o, hoy))
  const grupo = [combo]
  const vistos = new Set([combo.id])
  for (let i = 0; i < grupo.length; i++) {
    for (const o of enJuegoOtros) {
      if (!vistos.has(o.id) && compiten(grupo[i], o)) {
        vistos.add(o.id)
        grupo.push(o)
      }
    }
  }
  return grupo.sort((a, b) =>
    b.prioridad - a.prioridad || b.unidades - a.unidades || masNuevo(b.id, a.id))
}

/**
 * Saca `combo` del orden y lo vuelve a poner por la regla automática, relativa
 * a sus competidores directos: justo arriba del primero al que le gana, o
 * debajo del último si no le gana a ninguno. El resto conserva su orden.
 */
export function ubicarEnOrden(orden: readonly string[], combo: ComboOrdenable, porId: ReadonlyMap<string, ComboOrdenable>): string[] {
  const resto = orden.filter(id => id !== combo.id)
  const directo = (id: string) => {
    const o = porId.get(id)
    return o ? compiten(combo, o) : false
  }
  const primeroQueGana = resto.findIndex(id => directo(id) && ganaPorRegla(combo, porId.get(id) as ComboOrdenable))
  if (primeroQueGana >= 0) return [...resto.slice(0, primeroQueGana), combo.id, ...resto.slice(primeroQueGana)]
  let ultimo = -1
  resto.forEach((id, i) => { if (directo(id)) ultimo = i })
  return [...resto.slice(0, ultimo + 1), combo.id, ...resto.slice(ultimo + 1)]
}

/**
 * Mueve `combo` una posición entre sus competidores directos: arriba del
 * competidor directo que tiene inmediatamente arriba, o abajo del que tiene
 * inmediatamente abajo. Sin competidor en esa dirección, no cambia nada.
 */
export function moverEnOrden(
  orden: readonly string[],
  combo: ComboOrdenable,
  direccion: 'arriba' | 'abajo',
  porId: ReadonlyMap<string, ComboOrdenable>,
): string[] {
  const i = orden.indexOf(combo.id)
  if (i < 0) return [...orden]
  const directo = (id: string) => {
    const o = porId.get(id)
    return o ? compiten(combo, o) : false
  }
  const resto = orden.filter(id => id !== combo.id)
  if (direccion === 'arriba') {
    let j = -1
    for (let k = i - 1; k >= 0; k--) if (directo(orden[k])) { j = k; break }
    if (j < 0) return [...orden]
    const pos = resto.indexOf(orden[j])
    return [...resto.slice(0, pos), combo.id, ...resto.slice(pos)]
  }
  let j = -1
  for (let k = i + 1; k < orden.length; k++) if (directo(orden[k])) { j = k; break }
  if (j < 0) return [...orden]
  const pos = resto.indexOf(orden[j])
  return [...resto.slice(0, pos + 1), combo.id, ...resto.slice(pos + 1)]
}

/**
 * El orden del grupo de `actual`, de arriba a abajo, para mostrar y guardar.
 * - `manual`: lo que el admin acomodó con las flechas; vale si sigue siendo el
 *   mismo grupo (si cambió con quién compite, se vuelve a la regla).
 * - `reubicar`: el combo es nuevo, cambió sus lugares o se reactiva; va por la
 *   regla automática. Si no, conserva la posición que tiene guardada.
 * Fuera de juego (inactivo o vencido) no tiene orden: devuelve null.
 */
export function ordenDelGrupo(
  actual: ComboOrdenable,
  otros: readonly ComboOrdenable[],
  hoy: string,
  opciones: { reubicar: boolean; manual?: readonly string[] | null },
): string[] | null {
  if (!enJuego(actual, hoy)) return null
  const grupo = grupoDe(actual, otros, hoy)
  const base = grupo.map(c => c.id)
  const { manual, reubicar } = opciones
  if (manual && manual.length === base.length && base.every(id => manual.includes(id))) return [...manual]
  return reubicar ? ubicarEnOrden(base, actual, new Map(grupo.map(c => [c.id, c]))) : base
}

/** El orden para `guardar_combo`: ids numéricos, 0 para el combo nuevo. */
export function ordenParaGuardar(orden: readonly string[]): number[] {
  return orden.map(id => (id === ID_NUEVO ? 0 : Number(id)))
}

export interface LugarParaTapado {
  cantidad: number
  productos: readonly string[]
}

export interface ComboConLugares extends ComboOrdenable {
  lugares: readonly LugarParaTapado[]
}

export interface Tapado {
  /** El que gana siempre. */
  arriba: string
  /** El que nunca se arma. */
  abajo: string
}

/**
 * `arriba` cabe en `abajo`: a cada lugar de `arriba` le corresponde un lugar
 * distinto de `abajo` cuyos productos están todos en el de `arriba` y que pide
 * una cantidad igual o mayor. Entonces todo carrito que arma `abajo` arma antes
 * `arriba`, y como `armarCombos` repite el de arriba mientras pueda, al de
 * abajo nunca le alcanza. Conservador: ignora topes y escalas.
 */
export function cabeEn(arriba: readonly LugarParaTapado[], abajo: readonly LugarParaTapado[]): boolean {
  if (arriba.length === 0 || arriba.length > abajo.length) return false
  const sirve = (u: LugarParaTapado, l: LugarParaTapado) =>
    l.productos.length > 0 && u.cantidad <= l.cantidad && l.productos.every(p => u.productos.includes(p))
  const usado = new Array<boolean>(abajo.length).fill(false)
  const asignar = (i: number): boolean => {
    if (i === arriba.length) return true
    for (let j = 0; j < abajo.length; j++) {
      if (!usado[j] && sirve(arriba[i], abajo[j])) {
        usado[j] = true
        if (asignar(i + 1)) return true
        usado[j] = false
      }
    }
    return false
  }
  return asignar(0)
}

/** Un combo del panel, con sus lugares resueltos contra el catálogo de hoy. */
export function ordenableDe(
  combo: { id: string; prioridad: number; activo: boolean; fechaFin: string | null; componentes: readonly LugarCombo[] },
  catalogo: readonly ProductoCatalogo[],
): ComboConLugares {
  const lugares = resolverLugares(combo.componentes, catalogo)
  return {
    id: combo.id,
    prioridad: combo.prioridad,
    activo: combo.activo,
    fechaFin: combo.fechaFin,
    unidades: combo.componentes.reduce((s, l) => s + l.cantidad, 0),
    productos: new Set(lugares.flatMap(l => l.productos)),
    lugares,
  }
}

/** Los pares de combos en juego donde el de abajo nunca se arma. */
export function combosTapados(combos: readonly ComboConLugares[], hoy: string): Tapado[] {
  const vivos = combos.filter(c => enJuego(c, hoy))
  const out: Tapado[] = []
  for (const u of vivos) {
    for (const l of vivos) {
      if (u.id !== l.id && u.prioridad > l.prioridad && compiten(u, l) && cabeEn(u.lugares, l.lugares)) {
        out.push({ arriba: u.id, abajo: l.id })
      }
    }
  }
  return out
}
