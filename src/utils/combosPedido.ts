/**
 * Los combos sobre un pedido ya cotizado (#1191).
 *
 * `orquestarPrecios` resuelve promo → mayorista → descuento del cliente y está
 * sincronizado byte a byte con el bot, que no arma combos. Por eso los combos
 * van en una capa aparte, encima de su resultado: el carrito sigue siendo una
 * línea por producto, y acá se parte cada producto en la parte que entra en un
 * combo y la que queda suelta.
 *
 * El precio "sin combo" que necesita el armado lo calcula un oráculo con las
 * mismas piezas que la orquestación (`resolverPreciosMayorista` sobre los
 * productos que no reclamó una promo, y `aplicarDescuentoClienteItems`). Sin
 * unidades excluidas devuelve exactamente el precio que ya resolvió la
 * orquestación; con unidades en un combo excluyente, recalcula la escala sin
 * contarlas. Los regalos no se tocan: las unidades del combo siguen contando
 * para ellos (#1190).
 */
import { resolverPreciosMayorista, type ItemPedido, type PricingMap } from './precioMayorista'
import { aplicarDescuentoClienteItems, type ClienteConDescuentos, type ProductoConCategoria } from './descuentoCliente'
import type { ItemResuelto } from './orquestacionPrecios'
import { armarCombos, redondear2, type ComboAplicado, type ComboVigente, type OraculoPrecios } from './combos'

/** Línea del pedido con, si es de un combo, su combo y su precio sin combo. */
export interface LineaConCombo extends ItemResuelto {
  comboId?: string
  comboNombre?: string
  /** Lo que la unidad costaría sin el combo. Va a `pedido_items.precio_sin_combo_unitario`. */
  precioSinCombo?: number
  /** Sólo en un combo acumulable: el precio sin escalas. Lo valida el server; no se guarda. */
  precioSinEscala?: number | null
}

export interface EntradaCombosPedido {
  /** El carrito como entra a la orquestación: precio de lista (o el manual) por producto. */
  itemsBase: readonly ItemPedido[]
  /** Lo que devolvió la orquestación (compra y regalos), con el descuento del cliente si corresponde. */
  lineas: readonly ItemResuelto[]
  /** Productos que reclamó una promo de regalo: no toman escala (igual que en la orquestación). */
  productosConPromo: ReadonlySet<string>
  pricingMap?: PricingMap | null
  productos?: ProductoConCategoria[]
  cliente?: ClienteConDescuentos | null
  combos: readonly ComboVigente[]
}

export interface ResultadoCombosPedido {
  /** Las líneas a guardar: las de compra partidas en combo y suelta, y los regalos tal cual. */
  lineas: LineaConCombo[]
  aplicados: ComboAplicado[]
  /** Total de las líneas de compra, con los combos. */
  total: number
  /** Cuánto bajaron los combos el total. */
  ahorro: number
}

/** Los campos de combo de una línea, como viajan en el front (alta, cola offline, edición). */
export interface CamposCombo {
  comboId?: string
  precioSinCombo?: number
  precioSinEscala?: number | null
}

/** Copia los campos de combo de una línea (nada si no es de un combo). */
export function camposCombo(l: CamposCombo): CamposCombo {
  if (!l.comboId) return {}
  return {
    comboId: String(l.comboId),
    precioSinCombo: l.precioSinCombo,
    ...(l.precioSinEscala != null ? { precioSinEscala: l.precioSinEscala } : {}),
  }
}

/**
 * Los campos de combo como los lee el server (`crear_pedido_completo`,
 * `actualizar_pedido_items`). `precio_sin_escala_unitario` sólo en un combo
 * acumulable: lo valida el server y no se guarda.
 */
export function camposComboRPC(l: CamposCombo): Record<string, number> {
  if (!l.comboId) return {}
  return {
    combo_id: Number(l.comboId),
    precio_sin_combo_unitario: Number(l.precioSinCombo),
    ...(l.precioSinEscala != null ? { precio_sin_escala_unitario: Number(l.precioSinEscala) } : {}),
  }
}

function totalCompra(lineas: readonly ItemResuelto[]): number {
  return lineas.reduce((s, l) => (l.esBonificacion ? s : s + l.precioUnitario * l.cantidad), 0)
}

export function crearOraculoPrecios(e: Omit<EntradaCombosPedido, 'combos'>): OraculoPrecios {
  const productos = e.productos ?? []
  const cliente = e.cliente ?? null
  const base = new Map(e.itemsBase.map(i => [String(i.productoId), i]))
  const resuelto = new Map<string, number>()
  for (const l of e.lineas) if (!l.esBonificacion) resuelto.set(String(l.productoId), l.precioUnitario)

  const conDescuento = (productoId: string, precio: number) =>
    aplicarDescuentoClienteItems([{ productoId, cantidad: 1, precioUnitario: precio }], productos, cliente).items[0].precioUnitario

  const precioSinEscala = (productoId: string) => {
    const item = base.get(productoId)
    return item ? conDescuento(productoId, item.precioUnitario) : (resuelto.get(productoId) ?? 0)
  }

  const cache = new Map<string, Map<string, number>>()
  const precioLibre = (productoId: string, excluidas: ReadonlyMap<string, number>) => {
    const sinExclusiones = [...excluidas.values()].every(q => q <= 0)
    if (sinExclusiones || e.productosConPromo.has(productoId) || !e.pricingMap || e.pricingMap.size === 0) {
      return resuelto.get(productoId) ?? precioSinEscala(productoId)
    }
    const clave = [...excluidas].filter(([, q]) => q > 0).sort(([a], [b]) => (a < b ? -1 : 1)).map(([p, q]) => `${p}:${q}`).join(',')
    let precios = cache.get(clave)
    if (!precios) {
      const itemsSinPromo = e.itemsBase
        .filter(i => !e.productosConPromo.has(String(i.productoId)))
        .map(i => ({ ...i, cantidad: i.cantidad - (excluidas.get(String(i.productoId)) ?? 0) }))
        .filter(i => i.cantidad > 0)
      const mayorista = resolverPreciosMayorista(itemsSinPromo, e.pricingMap)
      precios = new Map()
      for (const i of e.itemsBase) {
        const pid = String(i.productoId)
        const m = mayorista.get(pid)
        const precio = m && m.esMayorista && !i.precioOverride ? m.precioResuelto : i.precioUnitario
        precios.set(pid, conDescuento(pid, precio))
      }
      cache.set(clave, precios)
    }
    return precios.get(productoId) ?? precioSinEscala(productoId)
  }

  return { precioLibre, precioSinEscala }
}

/**
 * Aplica los combos a un pedido ya cotizado. Las líneas con precio manual no
 * entran en combos (el precio lo decidió una persona). Sin combos que armar,
 * devuelve las líneas tal cual.
 */
export function aplicarCombosAlPedido(e: EntradaCombosPedido): ResultadoCombosPedido {
  const totalSin = totalCompra(e.lineas)
  const sinCambios: ResultadoCombosPedido = { lineas: e.lineas.map(l => ({ ...l })), aplicados: [], total: totalSin, ahorro: 0 }
  if (e.combos.length === 0) return sinCambios

  const manuales = new Set(e.itemsBase.filter(i => i.precioOverride).map(i => String(i.productoId)))
  const cantidades = new Map<string, number>()
  for (const l of e.lineas) {
    const pid = String(l.productoId)
    if (l.esBonificacion || l.precioOverride || manuales.has(pid) || l.cantidad <= 0) continue
    cantidades.set(pid, (cantidades.get(pid) ?? 0) + l.cantidad)
  }
  if (cantidades.size === 0) return sinCambios

  const oraculo = crearOraculoPrecios(e)
  const r = armarCombos(cantidades, e.combos, oraculo)
  if (r.aplicados.length === 0) return sinCambios

  const enCombo = new Map<string, { combo: ComboAplicado; linea: ComboAplicado['lineas'][number] }[]>()
  for (const combo of r.aplicados) {
    for (const linea of combo.lineas) {
      const lista = enCombo.get(linea.productoId) ?? []
      lista.push({ combo, linea })
      enCombo.set(linea.productoId, lista)
    }
  }

  const lineas: LineaConCombo[] = []
  const vistos = new Set<string>()
  for (const l of e.lineas) {
    if (l.esBonificacion) continue
    const pid = String(l.productoId)
    if (!cantidades.has(pid)) {
      lineas.push({ ...l })
      continue
    }
    // El carrito tiene una línea por producto; si vinieran dos, se parte una vez.
    if (vistos.has(pid)) continue
    vistos.add(pid)
    for (const { combo, linea } of enCombo.get(pid) ?? []) {
      lineas.push({
        ...l,
        cantidad: linea.cantidad,
        precioUnitario: linea.precioUnitario,
        comboId: combo.comboId,
        comboNombre: combo.nombre,
        precioSinCombo: linea.precioSinCombo,
        precioSinEscala: linea.precioSinEscala,
      })
    }
    const sueltas = r.sueltas.get(pid) ?? 0
    if (sueltas > 0) {
      lineas.push({ ...l, cantidad: sueltas, precioUnitario: redondear2(oraculo.precioLibre(pid, r.excluidas)) })
    }
  }
  for (const l of e.lineas) if (l.esBonificacion) lineas.push({ ...l })

  const total = totalCompra(lineas)
  return { lineas, aplicados: r.aplicados, total, ahorro: redondear2(totalSin - total) }
}

/**
 * Los combos de una edición: los vigentes y, encima, la foto de los que el
 * pedido ya tiene (pedido_combos). Un combo que ya tiene se mide contra su foto
 * (precio, lugares, escalas), como lo valida el server. Si ya no está vigente
 * se conserva, pero no crece: su tope es la cantidad que el pedido ya tenía.
 */
export function combinarCombosConFotos(
  vigentes: readonly ComboVigente[],
  fotos: readonly (ComboVigente & { cantidadCombos: number })[],
): ComboVigente[] {
  const porId = new Map(vigentes.map(c => [c.id, c]))
  const out: ComboVigente[] = vigentes.filter(c => !fotos.some(f => f.id === c.id))
  for (const f of fotos) {
    const vigente = porId.get(f.id)
    out.push({
      id: f.id,
      nombre: f.nombre,
      precio: f.precio,
      combinaEscalas: f.combinaEscalas,
      componentes: f.componentes,
      prioridad: vigente?.prioridad ?? f.prioridad,
      topeRestante: vigente ? vigente.topeRestante : f.cantidadCombos,
    })
  }
  return out
}
