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
  promocion_id: string | number | null;
  producto_original_id: string | number;
  producto_sustituto_id: string | number;
  cantidad_sustituta: number | string;
  reparto_id?: string | null;
}

/**
 * `(promo|producto original) → sustituto vigente`, con la misma regla que
 * `regalo_sustituto_vigente()` en el server (mig 272): las filas vienen de la
 * más nueva a la más vieja y, una vez que aparece un reparto de la promo, las
 * sustituciones anteriores de esa promo ya no valen — el reparto es la última
 * decisión sobre la composición del regalo. Las filas del reparto mismo no
 * entran: sus líneas se conservan tal cual (ver `conservarRepartos`).
 */
export function mapaSustitucionesVigentes(
  sustitucionesDesc: SustitucionRegistrada[],
): Map<string, { productoSustitutoId: string; cantidadSustituta: number }> {
  const mapa = new Map<string, { productoSustitutoId: string; cantidadSustituta: number }>()
  const promosRepartidas = new Set<string>()
  for (const s of sustitucionesDesc) {
    const promo = String(s.promocion_id ?? 'null')
    if (s.reparto_id) {
      promosRepartidas.add(promo)
      continue
    }
    if (promosRepartidas.has(promo)) continue
    const key = `${promo}|${s.producto_original_id}`
    if (!mapa.has(key)) {
      mapa.set(key, {
        productoSustitutoId: String(s.producto_sustituto_id),
        cantidadSustituta: Number(s.cantidad_sustituta),
      })
    }
  }
  return mapa
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
 * cambiado. Es el espejo de lo que hace `actualizar_pedido_items` (mig 272):
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
