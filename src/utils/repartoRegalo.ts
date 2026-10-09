/**
 * Reparto de un regalo de promo en varios sabores (#831, caso Munay).
 *
 * Una línea bonificada de 15 fardos se puede repartir en N productos cuya suma
 * sea EXACTAMENTE la cantidad original, en la misma unidad de la línea: si la
 * línea está en subunidades (promo Fracción), las partes también. Con una sola
 * fila es una sustitución común (`sustituir_regalo_pedido`), que conserva su
 * comportamiento de siempre: cualquier cantidad mayor a 0 y un producto
 * distinto del actual.
 *
 * Y la otra mitad: al reabrir el pedido para editarlo, el resolver de promos
 * vuelve a calcular UNA bonificación por promo. Si el pedido ya tenía la promo
 * repartida y la cantidad no cambió, hay que mandar las líneas que estaban;
 * si no, el guardado colapsaba el reparto al último sabor.
 */

export interface ParteReparto {
  productoId: string;
  cantidad: number;
}

export interface ValidacionReparto {
  ok: boolean;
  /** Suma de las cantidades cargadas. */
  asignado: number;
  /** Lo que falta asignar (negativo si se pasó). Sólo importa con 2+ filas. */
  faltante: number;
  /** true cuando hay 2+ filas: se llama a dividir_regalo_pedido. */
  esReparto: boolean;
  errores: string[];
}

/**
 * Valida las filas del modal. `productoActualId` es el producto que tiene hoy
 * la línea: en una sustitución simple elegirlo no cambia nada; en un reparto
 * es válido (el cliente se queda con parte del sabor original).
 */
export function validarRepartoRegalo(
  partes: ParteReparto[],
  cantidadOriginal: number,
  productoActualId: string,
): ValidacionReparto {
  const errores: string[] = []
  const asignado = partes.reduce((acc, p) => acc + (Number(p.cantidad) || 0), 0)
  const esReparto = partes.length > 1
  const faltante = cantidadOriginal - asignado

  if (partes.length === 0) {
    errores.push('Agregá al menos un producto')
  }
  if (partes.some(p => !p.productoId)) {
    errores.push('Elegí un producto en cada fila')
  }
  if (partes.some(p => !(Number(p.cantidad) > 0))) {
    errores.push('Cada fila necesita una cantidad mayor a 0')
  }
  if (esReparto && partes.some(p => !Number.isInteger(Number(p.cantidad)))) {
    errores.push('Las cantidades del reparto tienen que ser enteras')
  }
  const elegidos = partes.map(p => String(p.productoId)).filter(Boolean)
  if (new Set(elegidos).size !== elegidos.length) {
    errores.push('Hay un producto repetido')
  }
  if (esReparto) {
    if (faltante !== 0) {
      errores.push(faltante > 0
        ? `Faltan asignar ${faltante} de ${cantidadOriginal}`
        : `Te pasaste por ${-faltante}: el total tiene que ser ${cantidadOriginal}`)
    }
  } else if (partes.length === 1 && String(partes[0].productoId) === String(productoActualId)) {
    errores.push('Elegí un producto distinto del actual')
  }

  return { ok: errores.length === 0, asignado, faltante, esReparto, errores }
}

/** Fila de `pedido_item_sustituciones` con lo que hace falta acá. */
export interface SustitucionRegistrada {
  id?: string | number;
  created_at?: string;
  promocion_id: string | number | null;
  producto_original_id: string | number;
  producto_sustituto_id: string | number;
  cantidad_original?: number | string;
  cantidad_sustituta: number | string;
  reparto_id?: string | null;
}

/** Un regalo después de aplicarle la cadena de sustituciones. */
export interface RegaloResuelto {
  productoId: string;
  cantidad: number;
  /** Cuántas sustituciones se aplicaron (0 = el regalo queda como vino). */
  pasos: number;
}

/**
 * Los eslabones que cuentan para una promo, del más viejo al más nuevo: los
 * posteriores al último reparto, sin las filas del reparto mismo. Un reparto es
 * la última decisión sobre la composición del regalo y anula lo anterior; sus
 * líneas se conservan tal cual (ver `conservarRepartos`).
 */
function eslabonesVigentes(
  sustitucionesDesc: SustitucionRegistrada[],
  promoId: string | number | null | undefined,
): SustitucionRegistrada[] {
  const promo = String(promoId ?? 'null')
  const asc = sustitucionesDesc
    .filter(s => String(s.promocion_id ?? 'null') === promo)
    .reverse()
  // El server ordena por (created_at, id). La query trae ese orden; esto lo
  // asegura igual (sort es estable: sin fechas, queda el orden que vino).
  asc.sort((a, b) => {
    if (!a.created_at || !b.created_at) return 0
    const t = Date.parse(a.created_at) - Date.parse(b.created_at)
    if (t !== 0) return t
    return a.id != null && b.id != null ? Number(a.id) - Number(b.id) : 0
  })
  let corte = -1
  asc.forEach((s, i) => { if (s.reparto_id) corte = i })
  return asc.slice(corte + 1).filter(s => !s.reparto_id)
}

/**
 * La cantidad que sigue a un eslabón. Espejo de `regalo_sustitucion_resuelta()`:
 * si la venta no cambió va la que eligió el admin; si cambió, proporcional.
 *
 * El server escala sólo si el sustituto es de otra categoría o de otro empaque
 * y, si no, deja la que vino. Acá eso no se sabe sin el factor de la barra, así
 * que se escala siempre que sustituta ≠ original: es lo mismo salvo cuando el
 * admin tipeó otra cantidad para un sustituto del MISMO empaque y después la
 * venta cambió. Ahí la pantalla puede diferir del server, que es el que guarda.
 */
function cantidadTrasEslabon(cantidad: number, s: SustitucionRegistrada): number {
  const original = Number(s.cantidad_original)
  const sustituta = Number(s.cantidad_sustituta)
  if (!(original > 0) || !Number.isFinite(sustituta)) return cantidad
  if (cantidad === original) return sustituta
  if (sustituta === original) return cantidad
  return Math.max(1, Math.round(cantidad * sustituta / original))
}

/**
 * Los eslabones que se le aplican a un regalo, en orden. Espejo EXACTO de
 * `regalo_cadena_pasos()` en el server: el test de paridad
 * (`cadenaSustitucion.espejo.json`) corre las dos sobre los mismos casos.
 *
 * La regla (#1010, decisión del dueño, 2026-10-08): desde el producto que llega,
 * SIEMPRE el siguiente eslabón —el más viejo posterior al último aplicado cuyo
 * original sea el producto actual—, hasta que no haya más. Así se reproduce la
 * historia real de la línea, porque `sustituir_regalo_pedido` anota como
 * original el producto que la línea tiene en ese momento. Tomar el más nuevo
 * salteaba los del medio cuando la cadena volvía a un producto anterior
 * (A→P→Q→P→R): el producto final salía bien y la cantidad no. Como cada paso
 * es posterior al anterior, una vuelta A→P→A se corta sola.
 */
export function pasosDeCadena(
  sustitucionesDesc: SustitucionRegistrada[],
  promoId: string | number | null | undefined,
  productoId: string | number,
): SustitucionRegistrada[] {
  const eslabones = eslabonesVigentes(sustitucionesDesc, promoId)
  const pasos: SustitucionRegistrada[] = []
  let nodo = String(productoId)
  let desde = -1
  for (;;) {
    let idx = -1
    for (let i = desde + 1; i < eslabones.length; i++) {
      if (String(eslabones[i].producto_original_id) === nodo) { idx = i; break }
    }
    if (idx < 0) break
    pasos.push(eslabones[idx])
    nodo = String(eslabones[idx].producto_sustituto_id)
    desde = idx
  }
  return pasos
}

/**
 * Aplica la cadena de sustituciones a un regalo, con la misma regla que
 * `regalo_sustitucion_resuelta()` en el server: los eslabones de
 * `pasosDeCadena`, convirtiendo la cantidad en cada uno.
 */
export function resolverCadenaSustitucion(
  sustitucionesDesc: SustitucionRegistrada[],
  promoId: string | number | null | undefined,
  productoId: string | number,
  cantidad: number,
): RegaloResuelto {
  const pasos = pasosDeCadena(sustitucionesDesc, promoId, productoId)
  let c = cantidad
  for (const s of pasos) c = cantidadTrasEslabon(c, s)
  return {
    productoId: pasos.length ? String(pasos[pasos.length - 1].producto_sustituto_id) : String(productoId),
    cantidad: c,
    pasos: pasos.length,
  }
}

/**
 * El producto con el que arrancó la cadena que terminó en `productoFinal`, o
 * null si `productoFinal` no es el final de ninguna cadena vigente de la promo.
 */
export function raizDeSustitucion(
  sustitucionesDesc: SustitucionRegistrada[],
  promoId: string | number | null | undefined,
  productoFinal: string | number,
): string | null {
  const eslabones = eslabonesVigentes(sustitucionesDesc, promoId)
  let nodo = String(productoFinal)
  let raiz: string | null = null
  let hasta = eslabones.length
  for (;;) {
    let idx = -1
    for (let i = hasta - 1; i >= 0; i--) {
      if (String(eslabones[i].producto_sustituto_id) === nodo) { idx = i; break }
    }
    if (idx < 0) break
    nodo = String(eslabones[idx].producto_original_id)
    raiz = nodo
    hasta = idx
  }
  if (raiz === null || raiz === String(productoFinal)) return null
  // Sólo si la cadena, recorrida hacia adelante como la recorre el server,
  // termina de verdad en este producto.
  return resolverCadenaSustitucion(sustitucionesDesc, promoId, raiz, 0).productoId === String(productoFinal)
    ? raiz
    : null
}

/**
 * Un regalo al editar el pedido: lo que se MUESTRA (y se compara contra lo
 * guardado) y lo que se ENVÍA a `actualizar_pedido_items`.
 *
 * Se envía como lo calcula la promo: el producto con el que arrancó la cadena y
 * la cantidad de la promo, en la unidad de ese producto. El trigger del server
 * aplica la sustitución (producto, cantidad, descripción y costo). Mandar el
 * sustituto ya aplicado hacía que el server no lo reconociera: se perdía la
 * descripción, la cantidad convertida por valor, y el final de una cadena.
 */
export function regaloParaEditar(
  sustitucionesDesc: SustitucionRegistrada[],
  promoId: string | number | null | undefined,
  productoId: string | number,
  cantidad: number,
): { envio: { productoId: string; cantidad: number }; muestra: RegaloResuelto } {
  const pid = String(productoId)
  // El pedido ya tiene el regalo sustituido: la promo lo devuelve con el
  // producto de la línea (el override de la edición), que es el FINAL. Se mira
  // primero: una auto-sustitución al final (P→P, para ajustar la cantidad)
  // hace que P también tenga eslabones para adelante, y tratarlo como origen
  // mandaba P con la cantidad de la promo, que está en unidades de A.
  const raiz = raizDeSustitucion(sustitucionesDesc, promoId, pid)
  if (raiz) {
    return {
      envio: { productoId: raiz, cantidad },
      muestra: resolverCadenaSustitucion(sustitucionesDesc, promoId, raiz, cantidad),
    }
  }
  return { envio: { productoId: pid, cantidad }, muestra: resolverCadenaSustitucion(sustitucionesDesc, promoId, pid, cantidad) }
}

/** Una bonificación tal como la arma el modal de edición. */
export interface BonifCalculada {
  productoId: string;
  cantidad: number;
  promocionId?: string | number | null;
}

/** Una línea bonificada guardada en el pedido. */
export interface RegaloPersistido {
  producto_id: string | number;
  cantidad: number;
  promocion_id?: string | number | null;
}

/**
 * Reemplaza la bonificación recalculada de cada promo repartida por las líneas
 * que ya tenía el pedido, siempre que la cantidad total de la promo no haya
 * cambiado. Es el espejo de lo que hace `actualizar_pedido_items` (mig 275):
 * si el total cambió, el reparto no se puede conservar y va lo recalculado.
 *
 * Devuelve también qué promos perdieron el reparto, para avisarlo.
 */
export function conservarRepartos<T extends BonifCalculada>(
  calculadas: T[],
  persistidos: RegaloPersistido[],
  aLinea: (persistido: RegaloPersistido, plantilla: T) => T,
): { bonificaciones: T[]; repartosPerdidos: string[] } {
  const porPromo = new Map<string, RegaloPersistido[]>()
  for (const p of persistidos) {
    if (p.promocion_id == null) continue
    const key = String(p.promocion_id)
    const lista = porPromo.get(key) ?? []
    lista.push(p)
    porPromo.set(key, lista)
  }

  const resultado: T[] = []
  const repartosPerdidos: string[] = []
  const yaReemplazadas = new Set<string>()
  for (const bonif of calculadas) {
    const key = bonif.promocionId == null ? null : String(bonif.promocionId)
    const lineas = key ? porPromo.get(key) : undefined
    if (!key || !lineas || lineas.length < 2) {
      resultado.push(bonif)
      continue
    }
    if (yaReemplazadas.has(key)) continue
    const totalCalculado = calculadas
      .filter(b => String(b.promocionId) === key)
      .reduce((acc, b) => acc + (Number(b.cantidad) || 0), 0)
    const totalPersistido = lineas.reduce((acc, l) => acc + (Number(l.cantidad) || 0), 0)
    if (totalCalculado === totalPersistido) {
      for (const l of lineas) resultado.push(aLinea(l, bonif))
      yaReemplazadas.add(key)
    } else {
      resultado.push(bonif)
      if (!repartosPerdidos.includes(key)) repartosPerdidos.push(key)
    }
  }
  return { bonificaciones: resultado, repartosPerdidos }
}
