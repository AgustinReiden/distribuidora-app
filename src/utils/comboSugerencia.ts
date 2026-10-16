/**
 * La sugerencia de combos en el pedido (#1194): la mitad que faltaba del
 * "automático + sugerencia" (#1190). Si al carrito le falta poco para un combo
 * vigente —tiene el Fernet pero no la Coca—, se ofrece agregar lo que falta,
 * con la cantidad justa, y se dice cuánto ahorra el cliente.
 *
 * El ahorro no se estima: se cotiza. `cotizar` es la misma cuenta que arma el
 * pedido (orquestación + `aplicarCombosAlPedido`), corrida sobre el carrito con
 * lo agregado. Así la sugerencia sale del mismo cálculo que `armarCombos` y no
 * puede prometer un combo que después no se arma: si con lo agregado el combo
 * no crece (no baja el total, llegó al tope, una escala excluyente lo hace
 * perder), no se sugiere.
 */
import type { ItemPedido } from './precioMayorista'
import type { ComboVigente } from './combos'
import { redondear2 } from './combos'
import type { ResultadoCombosPedido } from './combosPedido'

export interface AgregadoSugerido {
  productoId: string
  /** Unidades a sumar a lo que el carrito ya tiene del producto. */
  cantidad: number
}

export interface SugerenciaCombo {
  comboId: string
  nombre: string
  agregar: AgregadoSugerido[]
  /** Cuánto más ahorra el cliente con el combo una vez agregado lo que falta. */
  ahorro: number
}

export interface EntradaSugerencias {
  /** El carrito como entra a la cotización. */
  items: readonly ItemPedido[]
  combos: readonly ComboVigente[]
  /** La cotización del carrito tal como está. */
  actual: ResultadoCombosPedido
  /** La misma cotización que arma el pedido, sobre otro carrito. */
  cotizar: (items: ItemPedido[]) => ResultadoCombosPedido
  /** Precio de lista del producto, para sumarlo al carrito si no está. 0 o menos: no se ofrece. */
  precioDe: (productoId: string) => number
  /**
   * Si se pueden sumar `agregar` unidades del producto cuando el carrito
   * quedaría con `total`: activo, mostrable según `mostrar_sin_stock` y con
   * stock. Lo decide quien llama, porque en la edición el pedido ya tiene
   * reservadas sus unidades.
   */
  puedeAgregar: (productoId: string, agregar: number, total: number) => boolean
  /** Combos que el usuario descartó para este pedido. */
  descartados?: ReadonlySet<string>
}

function compararIds(a: string, b: string): number {
  const x = BigInt(a)
  const y = BigInt(b)
  return x < y ? -1 : x > y ? 1 : 0
}

/** Unidades del carrito que pueden entrar en un combo: sin precio manual. */
function cantidadesElegibles(items: readonly ItemPedido[]): Map<string, number> {
  const manuales = new Set(items.filter(i => i.precioOverride).map(i => String(i.productoId)))
  const m = new Map<string, number>()
  for (const i of items) {
    const pid = String(i.productoId)
    if (manuales.has(pid) || i.cantidad <= 0) continue
    m.set(pid, (m.get(pid) ?? 0) + i.cantidad)
  }
  return m
}

function combosArmados(r: ResultadoCombosPedido, comboId: string): { k: number; ahorro: number } {
  const a = r.aplicados.find(x => x.comboId === comboId)
  return { k: a?.cantidadCombos ?? 0, ahorro: a?.ahorro ?? 0 }
}

/** El carrito con lo agregado: suma a la línea que ya está o agrega una nueva a precio de lista. */
export function carritoConAgregados(
  items: readonly ItemPedido[],
  agregar: readonly AgregadoSugerido[],
  precioDe: (productoId: string) => number,
): ItemPedido[] {
  const out = items.map(i => ({ ...i }))
  for (const a of agregar) {
    const existente = out.find(i => String(i.productoId) === a.productoId && !i.precioOverride)
    if (existente) existente.cantidad += a.cantidad
    else out.push({ productoId: a.productoId, cantidad: a.cantidad, precioUnitario: precioDe(a.productoId) })
  }
  return out
}

/**
 * Las sugerencias del carrito, una por combo, de mayor a menor ahorro.
 *
 * Un combo se sugiere si el carrito tiene suelta (fuera de un combo) al menos
 * una unidad de alguno de sus lugares y le falta completar otro. Para cada
 * lugar incompleto se elige el producto que ya está en el carrito (el de más
 * unidades sueltas) y, si no hay, la alternativa más barata que se pueda
 * agregar: la sugerencia es "sumá lo mínimo". Se descarta si un lugar no tiene
 * ninguna alternativa agregable (sin stock, inactiva, sin precio o con precio
 * manual en el carrito).
 */
export function sugerirCombos(e: EntradaSugerencias): SugerenciaCombo[] {
  if (e.combos.length === 0) return []
  const elegibles = cantidadesElegibles(e.items)
  const conPrecioManual = new Set(e.items.filter(i => i.precioOverride).map(i => String(i.productoId)))
  const enCombo = new Map<string, number>()
  for (const l of e.actual.lineas) {
    if (!l.comboId || l.esBonificacion) continue
    const pid = String(l.productoId)
    enCombo.set(pid, (enCombo.get(pid) ?? 0) + l.cantidad)
  }
  const sueltas = (p: string) => Math.max(0, (elegibles.get(p) ?? 0) - (enCombo.get(p) ?? 0))
  const enCarrito = (p: string) => e.items.reduce((s, i) => (String(i.productoId) === p ? s + i.cantidad : s), 0)

  const out: SugerenciaCombo[] = []
  for (const combo of e.combos) {
    if (e.descartados?.has(combo.id)) continue
    const antes = combosArmados(e.actual, combo.id)
    if (combo.topeRestante !== null && antes.k >= combo.topeRestante) continue
    if (combo.precio <= 0 || combo.componentes.length === 0) continue

    let algunoPresente = false
    let imposible = false
    const agregar: AgregadoSugerido[] = []
    for (const comp of combo.componentes) {
      const productos = comp.productos.map(String)
      const tiene = productos.reduce((s, p) => s + sueltas(p), 0)
      if (tiene > 0) algunoPresente = true
      const falta = comp.cantidad - tiene
      if (falta <= 0) continue
      const candidatos = productos.filter(p =>
        !conPrecioManual.has(p)
        && e.precioDe(p) > 0
        && e.puedeAgregar(p, falta, enCarrito(p) + falta))
      if (candidatos.length === 0) { imposible = true; break }
      const yaEsta = candidatos.filter(p => sueltas(p) > 0)
      const elegido = (yaEsta.length > 0
        ? yaEsta.sort((a, b) => sueltas(b) - sueltas(a) || compararIds(a, b))
        : candidatos.sort((a, b) => e.precioDe(a) - e.precioDe(b) || compararIds(a, b)))[0]
      agregar.push({ productoId: elegido, cantidad: falta })
    }
    if (imposible || !algunoPresente || agregar.length === 0) continue

    const despues = combosArmados(e.cotizar(carritoConAgregados(e.items, agregar, e.precioDe)), combo.id)
    const ahorro = redondear2(despues.ahorro - antes.ahorro)
    if (despues.k <= antes.k || ahorro <= 0) continue
    out.push({ comboId: combo.id, nombre: combo.nombre, agregar, ahorro })
  }
  return out.sort((a, b) => b.ahorro - a.ahorro || compararIds(a.comboId, b.comboId))
}
