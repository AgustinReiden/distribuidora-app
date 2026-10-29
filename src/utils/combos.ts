/**
 * Combos (#1190, #1191): varios productos que ya existen, comprados juntos, a un
 * precio fijo. No hay un producto "combo": un combo en un pedido son líneas
 * comunes de cada producto, con el total del combo repartido en proporción al
 * precio que cada unidad tendría sin el combo. El stock, el costo y la venta por
 * producto siguen el camino de siempre.
 *
 * Con las escalas mayoristas, cada combo elige (`combinaEscalas`):
 *   - excluyente (default): la unidad del combo no toma escala ni cuenta para su
 *     mínimo. Su referencia es el precio sin escalas. El total es k × precio.
 *   - acumulable: la unidad cuenta para el mínimo, su referencia es el precio con
 *     escala, y el descuento del combo (sin escalas − precio) se suma al de la
 *     escala: total = k × precio − Σ q × (sin escala − con escala).
 *
 * Este módulo es puro. Tres piezas tienen espejo en SQL con gate de paridad
 * (`combos.espejo.json`, `scripts/espejo-combos.mjs`), porque el server las
 * recalcula para validar lo que manda el front y una diferencia rechazaría
 * pedidos honestos:
 *   - `prorratearTotal`   ↔ `public._combo_prorrateo`
 *   - `totalDelCombo`     ↔ `public._combo_total`
 *   - `cantidadDeCombos`  ↔ `public._combo_cantidad`
 * Si cambiás una, cambiá la otra y sumá el caso al fixture.
 *
 * `armarCombos` (qué combos conviene armar) es sólo del front: el server no lo
 * repite, valida que lo armado sea legítimo (combo vigente, estructura, total y
 * reparto exactos, referencias dentro de la política de precio).
 */

export interface ComboComponente {
  componente: number
  cantidad: number
  /** Productos que pueden ocupar este lugar del combo (alternativas, como un fardo surtido). */
  productos: string[]
}

export interface ComboVigente {
  id: string
  nombre: string
  precio: number
  /** true: las unidades del combo cuentan para las escalas y el descuento se suma. */
  combinaEscalas: boolean
  prioridad: number
  componentes: ComboComponente[]
  /** Combos que todavía se pueden vender (tope − vendidos). null = sin tope. */
  topeRestante: number | null
}

export interface LineaProrrateo {
  productoId: string
  cantidad: number
  /** Precio unitario de referencia: lo que la unidad costaría sin el combo. */
  ref: number
}

export interface LineaTotal extends LineaProrrateo {
  /** Sólo en un combo acumulable: el precio sin escalas de la unidad. */
  sinEscala?: number | null
}

/**
 * Lo que el front sabe de precios sin combos. `excluidas` son las unidades que
 * están en combos excluyentes: no cuentan para el mínimo de las escalas.
 */
export interface OraculoPrecios {
  /** Precio unitario de una unidad suelta del producto, sin contar `excluidas` para las escalas. */
  precioLibre(productoId: string, excluidas: ReadonlyMap<string, number>): number
  /** Precio unitario sin escalas (lista con el descuento del cliente). */
  precioSinEscala(productoId: string): number
}

export interface LineaCombo {
  productoId: string
  cantidad: number
  precioUnitario: number
  /** Lo que la unidad costaría sin el combo (con escala si el combo es acumulable). */
  precioSinCombo: number
  /** Sólo en un combo acumulable: el precio sin escalas, del que sale el descuento del combo. */
  precioSinEscala: number | null
}

export interface ComboAplicado {
  comboId: string
  nombre: string
  cantidadCombos: number
  combinaEscalas: boolean
  lineas: LineaCombo[]
  /** Σ (precio sin combo − precio en combo) × cantidad. */
  ahorro: number
}

export interface ResultadoCombos {
  aplicados: ComboAplicado[]
  /** Unidades que no entraron en ningún combo, por producto. */
  sueltas: Map<string, number>
  /** Unidades en combos excluyentes, por producto: no cuentan para las escalas. */
  excluidas: Map<string, number>
}

// ---------------------------------------------------------------------------
// Aritmética en centavos
// ---------------------------------------------------------------------------

/** Centavos de un precio en pesos. El empujoncito evita que 1,005 × 100 dé 100,4999… */
export function centavos(v: number): number {
  return Math.round(v * 100 + (v >= 0 ? 1e-6 : -1e-6))
}

export function redondear2(v: number): number {
  return centavos(v) / 100
}

/** Orden de ids como bigint, el mismo que un ORDER BY del server. */
function compararIds(a: string, b: string): number {
  const x = BigInt(a)
  const y = BigInt(b)
  return x < y ? -1 : x > y ? 1 : 0
}

function mcd(a: bigint, b: bigint): bigint {
  let x = a < 0n ? -a : a
  let y = b < 0n ? -b : b
  while (y !== 0n) [x, y] = [y, x % y]
  return x
}

const abs = (n: bigint) => (n < 0n ? -n : n)

/**
 * Si un combo de este precio se puede repartir exacto entre sus líneas, para
 * cualquier cantidad de combos y cualquier mezcla de alternativas: el máximo
 * común divisor de las cantidades de los lugares tiene que dividir el precio en
 * centavos. "2 por $999,99" no se puede (dos unidades al mismo precio dan un
 * total par); "2 por $999,98", sí. `guardar_combo` aplica la misma regla.
 */
export function precioRepartible(precio: number, cantidades: readonly number[]): boolean {
  const g = cantidades.reduce((m, q) => mcd(m, BigInt(q)), 0n)
  return g > 0n && BigInt(centavos(precio)) % g === 0n
}

// ---------------------------------------------------------------------------
// Total (espejo: public._combo_total)
// ---------------------------------------------------------------------------

/**
 * Total en pesos de `k` combos. Excluyente: k × precio. Acumulable: menos lo que
 * la escala ya bajó en cada unidad (Σ q × (sin escala − referencia)). Las
 * líneas sin `sinEscala` (o de un excluyente) no restan nada.
 */
export function totalDelCombo(precio: number, k: number, lineas: readonly LineaTotal[]): number {
  let t = BigInt(centavos(precio)) * BigInt(k)
  for (const l of lineas) {
    if (l.sinEscala == null) continue
    t -= BigInt(l.cantidad) * (BigInt(centavos(l.sinEscala)) - BigInt(centavos(l.ref)))
  }
  return Number(t) / 100
}

// ---------------------------------------------------------------------------
// Prorrateo (espejo: public._combo_prorrateo)
// ---------------------------------------------------------------------------

/**
 * Reparte el total de un combo entre sus líneas, en proporción a cantidad ×
 * referencia. Devuelve el precio unitario de cada producto.
 *
 * En centavos enteros: u = redondeo(T·c / R), con R = Σ q·c. Lo que sobra (o
 * falta) de T va entero a la línea más cara cuya cantidad lo divide —con un
 * componente de cantidad 1 y un solo producto por lugar siempre hay una—.
 *
 * Si ninguna lo divide (un 2 + 3, o un lugar partido entre alternativas), el
 * total igual cierra exacto (#1259): la que absorbe es la de menor cantidad, y
 * antes cada una de las otras —de la más cara a la más barata— toma el precio
 * más cercano a su proporción que deja el resto divisible por el máximo común
 * divisor de las cantidades que faltan (a igual distancia, el mayor). La última
 * toma el resto, que entonces la divide.
 *
 * Tira si el máximo común divisor de todas las cantidades no divide T: ahí no
 * hay precios unitarios que den el total ("2 por $999,99"). `precioRepartible`
 * evita armar esos combos y `guardar_combo` evita crearlos.
 */
export function prorratearTotal(total: number, lineas: readonly LineaProrrateo[]): Map<string, number> {
  const T = BigInt(centavos(total))
  if (T <= 0n) throw new Error('El total del combo tiene que ser positivo')
  const ls = lineas.map(l => ({ id: String(l.productoId), q: BigInt(l.cantidad), c: BigInt(centavos(l.ref)) }))
  if (ls.some(l => l.q <= 0n || l.c <= 0n)) throw new Error('Cada línea del combo necesita cantidad y referencia positivas')
  const R = ls.reduce((s, l) => s + l.q * l.c, 0n)
  if (R <= 0n) throw new Error('El combo no tiene precio de referencia')
  if (T % ls.reduce((g, l) => mcd(g, l.q), 0n) !== 0n) {
    throw new Error('El total del combo no se puede repartir exacto entre sus líneas')
  }

  const u = new Map<string, bigint>()
  for (const l of ls) u.set(l.id, (2n * T * l.c + R) / (2n * R))

  const suma = ls.reduce((s, l) => s + l.q * (u.get(l.id) as bigint), 0n)
  const resto = T - suma
  if (resto !== 0n) {
    const divisibles = ls
      .filter(l => resto % l.q === 0n)
      .sort((a, b) => (a.c === b.c ? compararIds(a.id, b.id) : a.c > b.c ? -1 : 1))
    if (divisibles.length > 0) {
      const l = divisibles[0]
      u.set(l.id, (u.get(l.id) as bigint) + resto / l.q)
    } else {
      const ultima = [...ls].sort((a, b) =>
        a.q !== b.q ? (a.q < b.q ? -1 : 1) : a.c !== b.c ? (a.c > b.c ? -1 : 1) : compararIds(a.id, b.id))[0]
      const otras = ls
        .filter(l => l !== ultima)
        .sort((a, b) => (a.c === b.c ? compararIds(a.id, b.id) : a.c > b.c ? -1 : 1))
      let falta = T
      otras.forEach((l, i) => {
        // El resto tiene que quedar divisible por el mcd de las que vienen después.
        const g = [...otras.slice(i + 1), ultima].reduce((m, x) => mcd(m, x.q), 0n)
        let x = u.get(l.id) as bigint
        while ((falta - l.q * x) % g !== 0n) x++
        const y = x - g / mcd(l.q, g)
        const elegido = abs(y * R - T * l.c) < abs(x * R - T * l.c) ? y : x
        u.set(l.id, elegido)
        falta -= l.q * elegido
      })
      u.set(ultima.id, falta / ultima.q)
    }
  }

  const out = new Map<string, number>()
  for (const l of ls) out.set(l.id, Number(u.get(l.id) as bigint) / 100)
  return out
}

/** Atajo de `prorratearTotal` para un combo excluyente: k × precio. */
export function prorratearCombo(precio: number, k: number, lineas: readonly LineaProrrateo[]): Map<string, number> {
  if (!Number.isInteger(k) || k <= 0) throw new Error('La cantidad de combos tiene que ser un entero positivo')
  return prorratearTotal(totalDelCombo(precio, k, []), lineas)
}

// ---------------------------------------------------------------------------
// Estructura (espejo: public._combo_cantidad)
// ---------------------------------------------------------------------------

/**
 * Cuántos combos forman estas líneas: cada producto tiene que estar en un lugar
 * del combo y cada lugar sumar k × su cantidad, con el mismo k ≥ 1 en todos.
 * null si no forman un número entero de combos.
 */
export function cantidadDeCombos(
  componentes: readonly ComboComponente[],
  lineas: ReadonlyMap<string, number>,
): number | null {
  if (componentes.length === 0 || lineas.size === 0) return null
  const lugarDe = new Map<string, number>()
  for (const c of componentes) {
    if (!Number.isInteger(c.cantidad) || c.cantidad <= 0) return null
    for (const p of c.productos) lugarDe.set(String(p), c.componente)
  }
  const porLugar = new Map<number, number>()
  for (const [p, q] of lineas) {
    const lugar = lugarDe.get(String(p))
    if (lugar === undefined || !Number.isInteger(q) || q <= 0) return null
    porLugar.set(lugar, (porLugar.get(lugar) ?? 0) + q)
  }
  let k: number | null = null
  for (const c of componentes) {
    const suma = porLugar.get(c.componente) ?? 0
    if (suma % c.cantidad !== 0) return null
    const kc = suma / c.cantidad
    if (kc <= 0) return null
    if (k === null) k = kc
    else if (k !== kc) return null
  }
  return k
}

// ---------------------------------------------------------------------------
// Armado (sólo front)
// ---------------------------------------------------------------------------

function sumar(m: Map<string, number>, p: string, q: number) {
  const v = (m.get(p) ?? 0) + q
  if (v === 0) m.delete(p)
  else m.set(p, v)
}

function ahorroEstimado(combo: ComboVigente, disponibles: ReadonlyMap<string, number>, oraculo: OraculoPrecios): number {
  let suma = 0
  for (const c of combo.componentes) {
    const refs = c.productos
      .filter(p => (disponibles.get(String(p)) ?? 0) > 0)
      .map(p => oraculo.precioSinEscala(String(p)))
    if (refs.length === 0) return -Infinity
    suma += c.cantidad * Math.max(...refs)
  }
  return suma - combo.precio
}

interface Uso {
  combo: ComboVigente
  k: number
  unidades: Map<string, number>
}

/**
 * Qué combos armar con el carrito. Los combos se recorren por prioridad (mayor
 * primero), después por ahorro estimado y después por id. De cada uno se arman
 * instancias de a una —cada lugar con las unidades más caras disponibles— hasta
 * donde alcancen el carrito y el tope, y queda la cantidad de instancias que
 * deja el pedido más barato; si ninguna lo abarata, el combo no se arma. Así se
 * resuelve la escala excluyente: si sacar unidades del conteo hace perder el
 * mayorista a las que quedan, el combo conviene sólo si con las instancias que
 * entran el ahorro supera esa pérdida. Un combo cuyo precio no se puede
 * repartir exacto (`precioRepartible`) no se arma.
 *
 * `cantidades`: unidades de venta del carrito por producto (sin regalos ni
 * líneas con precio manual).
 */
export function armarCombos(
  cantidades: ReadonlyMap<string, number>,
  combos: readonly ComboVigente[],
  oraculo: OraculoPrecios,
): ResultadoCombos {
  const disponibles = new Map<string, number>()
  for (const [p, q] of cantidades) if (q > 0) disponibles.set(String(p), q)
  const excluidas = new Map<string, number>()

  const validos = combos.filter(c =>
    c.precio > 0 && c.componentes.length > 0
    && c.componentes.every(x => Number.isInteger(x.cantidad) && x.cantidad > 0 && x.productos.length > 0)
    && precioRepartible(c.precio, c.componentes.map(x => x.cantidad))
    && (c.topeRestante === null || c.topeRestante > 0))
  const estimado = new Map(validos.map(c => [c.id, ahorroEstimado(c, disponibles, oraculo)]))
  const orden = [...validos].sort((a, b) =>
    b.prioridad - a.prioridad
    || (estimado.get(b.id) as number) - (estimado.get(a.id) as number)
    || compararIds(a.id, b.id))

  const libre = (p: string, excl: ReadonlyMap<string, number>) => redondear2(oraculo.precioLibre(p, excl))
  const sinEscala = (p: string) => redondear2(oraculo.precioSinEscala(p))
  const refDe = (combo: ComboVigente, p: string, excl: ReadonlyMap<string, number>) =>
    combo.combinaEscalas ? libre(p, excl) : sinEscala(p)
  const lineasDe = (u: Uso, excl: ReadonlyMap<string, number>): LineaTotal[] =>
    [...u.unidades.keys()].sort(compararIds).map(p => ({
      productoId: p,
      cantidad: u.unidades.get(p) as number,
      ref: refDe(u.combo, p, excl),
      sinEscala: u.combo.combinaEscalas ? sinEscala(p) : null,
    }))
  const costo = (usos: readonly Uso[], disp: ReadonlyMap<string, number>, excl: ReadonlyMap<string, number>) => {
    let total = 0
    for (const u of usos) total += totalDelCombo(u.combo.precio, u.k, lineasDe(u, excl))
    for (const [p, q] of disp) total += q * libre(p, excl)
    return total
  }

  const usos: Uso[] = []

  for (const combo of orden) {
    // Se arman todas las instancias que se puedan y queda la cantidad que deja
    // el pedido más barato (a igual costo, la menor). No alcanza con cortar en
    // la primera que no baja el total (#1259): en un excluyente, la primera
    // unidad que sale del conteo puede hacerle perder la escala a todas las que
    // quedan —un costo que se paga una vez—, mientras que el ahorro crece con
    // cada instancia.
    let uso: Uso = { combo, k: 0, unidades: new Map() }
    let disp = new Map(disponibles)
    let excl = new Map(excluidas)
    let mejor = { costo: costo(usos, disp, excl), uso, disp, excl }
    while (combo.topeRestante === null || uso.k < combo.topeRestante) {
      const instancia = new Map<string, number>()
      let completa = true
      for (const comp of combo.componentes) {
        let falta = comp.cantidad
        const candidatos = comp.productos
          .map(String)
          .filter(p => (disp.get(p) ?? 0) - (instancia.get(p) ?? 0) > 0)
          .sort((a, b) => refDe(combo, b, excl) - refDe(combo, a, excl) || compararIds(a, b))
        for (const p of candidatos) {
          const toma = Math.min(falta, (disp.get(p) ?? 0) - (instancia.get(p) ?? 0))
          sumar(instancia, p, toma)
          falta -= toma
          if (falta === 0) break
        }
        if (falta > 0) { completa = false; break }
      }
      if (!completa) break

      const disp2 = new Map(disp)
      const excl2 = new Map(excl)
      const uso2: Uso = { combo, k: uso.k + 1, unidades: new Map(uso.unidades) }
      for (const [p, q] of instancia) {
        sumar(disp2, p, -q)
        sumar(uso2.unidades, p, q)
        if (!combo.combinaEscalas) sumar(excl2, p, q)
      }
      // El total del combo tiene que quedar positivo (un acumulable sobre una
      // escala muy baja podría no dejar nada que repartir).
      if (totalDelCombo(combo.precio, uso2.k, lineasDe(uso2, excl2)) <= 0) break

      uso = uso2
      disp = disp2
      excl = excl2
      const c = costo([...usos, uso], disp, excl)
      if (c < mejor.costo - 0.005) mejor = { costo: c, uso, disp, excl }
    }
    if (mejor.uso.k > 0) {
      usos.push(mejor.uso)
      disponibles.clear()
      for (const [p, q] of mejor.disp) disponibles.set(p, q)
      excluidas.clear()
      for (const [p, q] of mejor.excl) excluidas.set(p, q)
    }
  }

  const aplicados: ComboAplicado[] = usos.map(u => {
    const lineasTotal = lineasDe(u, excluidas)
    const precios = prorratearTotal(totalDelCombo(u.combo.precio, u.k, lineasTotal), lineasTotal)
    const lineas: LineaCombo[] = lineasTotal.map(l => ({
      productoId: l.productoId,
      cantidad: l.cantidad,
      precioUnitario: precios.get(l.productoId) as number,
      precioSinCombo: l.ref,
      precioSinEscala: l.sinEscala ?? null,
    }))
    const ahorro = redondear2(lineas.reduce((s, l) => s + (l.precioSinCombo - l.precioUnitario) * l.cantidad, 0))
    return { comboId: u.combo.id, nombre: u.combo.nombre, cantidadCombos: u.k, combinaEscalas: u.combo.combinaEscalas, lineas, ahorro }
  })

  return { aplicados, sueltas: disponibles, excluidas }
}
