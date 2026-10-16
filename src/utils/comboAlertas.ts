/**
 * Las alertas de un combo (#1194). El combo tiene precio fijo y con inflación
 * queda viejo: si suben las listas crece el descuento, y si suben los costos el
 * margen se achica sin que nadie lo note. "Precio fijo con alerta" (#1190): la
 * alerta avisa, no bloquea nada.
 *
 * Los números son de UN combo y del peor caso de cada lugar con alternativas:
 *   - "Sin combo" suma, por lugar, la cantidad por el precio de lista más caro
 *     (el mismo criterio que la vista previa de ModalCombo).
 *   - El costo suma, por lugar, la cantidad por el costo más alto: el margen
 *     que se muestra es el piso, el de la alternativa que menos deja.
 *   - El costo es la cascada `costo_valuacion` (promedio → real → sin IVA + II,
 *     espejo en `costoCanonico.ts`). Un producto sin ningún término cargado es
 *     "sin costo" —el `IS NULL` de la cascada—, nunca un costo 0 con un margen
 *     calculado encima (#511).
 *   - El margen es sobre la venta sin IVA: el costo canónico no lleva IVA. El
 *     precio del combo se lleva a neto con la proporción neto/final de las
 *     listas de sus productos (la misma proporción del prorrateo). Un producto
 *     sin `precio_sin_iva` cuenta su precio final.
 *
 * Los costos sólo los ven admin y encargado (`costos_productos()`): para el
 * resto no se calcula margen ni se avisa "sin costo".
 */
import { costoCanonicoUnitario, type ProductoCosto } from './costoCanonico'

export interface ProductoParaAlertas extends ProductoCosto {
  id: string | number
  nombre?: string
  precio?: number | string | null
  precio_sin_iva?: number | string | null
}

export interface ComboParaAlertas {
  id: string
  nombre: string
  precio: number
  componentes: readonly { cantidad: number; productos: readonly string[] }[]
}

export interface UmbralesCombo {
  /** Margen mínimo aceptable, en % sobre la venta sin IVA. */
  margenMinimoPct: number
  /** Descuento máximo aceptable contra la suma de precios sin combo, en %. */
  descuentoMaximoPct: number
}

export type TipoAlertaCombo = 'margen_negativo' | 'margen_bajo' | 'sin_costo' | 'descuento_alto' | 'no_conviene'

export interface AlertaCombo {
  tipo: TipoAlertaCombo
  severidad: 'critical' | 'warning'
  texto: string
}

export interface EvaluacionCombo {
  /** Lo que costarían las mismas unidades sin el combo (lista, alternativa más cara). */
  sinCombo: number
  /** 1 − precio / sin combo, en %. null si no hay precios o el combo no conviene. */
  descuentoPct: number | null
  /** El precio fijo no le gana a comprar por separado: el combo no se aplica. */
  noConviene: boolean
  /** Costo de un combo (peor caso). null: sin costo o sin permiso para verlo. */
  costo: number | null
  /** Margen sobre la venta sin IVA, en %. null cuando no hay costo. */
  margenPct: number | null
  /** Productos del combo sin costo cargado (sólo si se ven los costos). */
  sinCosto: string[]
  alertas: AlertaCombo[]
}

function numero(v: unknown): number | null {
  if (v === null || v === undefined || v === '') return null
  const n = Number(v)
  return Number.isFinite(n) ? n : null
}

/** La cascada con su NULL: sin ningún término cargado no hay costo. */
export function costoValuacion(p: ProductoCosto | null | undefined): number | null {
  if (!p) return null
  const hay = [p.costo_promedio, p.costo_real, p.costo_sin_iva].some(v => numero(v) !== null)
  return hay ? costoCanonicoUnitario(null, p) : null
}

const pct = (n: number) => `${n.toLocaleString('es-AR', { maximumFractionDigits: 1 })}%`

export function evaluarCombo(
  combo: ComboParaAlertas,
  productos: ReadonlyMap<string, ProductoParaAlertas>,
  umbrales: UmbralesCombo,
  verCostos: boolean,
): EvaluacionCombo {
  let sinCombo = 0
  let sinComboNeto = 0
  let costo = 0
  const sinCosto: string[] = []

  for (const c of combo.componentes) {
    if (!(c.cantidad > 0) || c.productos.length === 0) continue
    const ps = c.productos.map(id => ({ id: String(id), p: productos.get(String(id)) }))
    let masCaro: { precio: number; neto: number } | null = null
    for (const { p } of ps) {
      const precio = numero(p?.precio) ?? 0
      if (!masCaro || precio > masCaro.precio) {
        masCaro = { precio, neto: numero(p?.precio_sin_iva) ?? precio }
      }
    }
    sinCombo += c.cantidad * (masCaro?.precio ?? 0)
    sinComboNeto += c.cantidad * (masCaro?.neto ?? 0)

    if (verCostos) {
      let peor = 0
      for (const { id, p } of ps) {
        const cu = costoValuacion(p)
        if (cu === null) sinCosto.push(p?.nombre || `Producto #${id}`)
        else peor = Math.max(peor, cu)
      }
      costo += c.cantidad * peor
    }
  }

  const noConviene = combo.precio > 0 && sinCombo > 0 && combo.precio >= sinCombo
  const descuentoPct = combo.precio > 0 && sinCombo > 0 && !noConviene ? (1 - combo.precio / sinCombo) * 100 : null

  const hayCosto = verCostos && sinCosto.length === 0
  const neto = sinCombo > 0 ? combo.precio * (sinComboNeto / sinCombo) : 0
  const margenPct = hayCosto && neto > 0 ? ((neto - costo) / neto) * 100 : null

  const alertas: AlertaCombo[] = []
  if (noConviene) {
    alertas.push({ tipo: 'no_conviene', severidad: 'warning', texto: 'No conviene: comprar por separado sale más barato, el combo no se aplica' })
  }
  if (verCostos && sinCosto.length > 0) {
    alertas.push({ tipo: 'sin_costo', severidad: 'warning', texto: `Sin costo cargado (${sinCosto.join(', ')}): no se puede medir el margen` })
  }
  if (margenPct !== null && margenPct < 0) {
    alertas.push({ tipo: 'margen_negativo', severidad: 'critical', texto: `Margen negativo (${pct(margenPct)}): el combo se vende bajo costo` })
  } else if (margenPct !== null && margenPct < umbrales.margenMinimoPct) {
    alertas.push({ tipo: 'margen_bajo', severidad: 'warning', texto: `Margen bajo: ${pct(margenPct)}, el tope es ${pct(umbrales.margenMinimoPct)}` })
  }
  if (descuentoPct !== null && descuentoPct > umbrales.descuentoMaximoPct) {
    alertas.push({ tipo: 'descuento_alto', severidad: 'warning', texto: `Descuento alto: ${pct(descuentoPct)}, el tope es ${pct(umbrales.descuentoMaximoPct)}` })
  }

  return { sinCombo, descuentoPct, noConviene, costo: hayCosto ? costo : null, margenPct, sinCosto, alertas }
}

/** Una alerta con la forma de las del reporte gerencial (`Alerta`). */
export interface AlertaReporteCombo {
  severidad: 'critical' | 'warning'
  codigo: string
  titulo: string
  detalle: string
  valor: number
  seccion: string
}

/**
 * Las alertas de los combos para el panel "Qué requiere tu atención" del
 * reporte gerencial: una por combo y por tipo, las críticas primero.
 */
export function alertasCombosParaReporte(
  combos: readonly ComboParaAlertas[],
  productos: ReadonlyMap<string, ProductoParaAlertas>,
  umbrales: UmbralesCombo,
  verCostos: boolean,
): AlertaReporteCombo[] {
  const out: AlertaReporteCombo[] = []
  for (const combo of combos) {
    const ev = evaluarCombo(combo, productos, umbrales, verCostos)
    for (const a of ev.alertas) {
      out.push({
        severidad: a.severidad,
        codigo: `combo_${a.tipo}_${combo.id}`,
        titulo: `Combo ${combo.nombre}`,
        detalle: `${a.texto}. Revisalo en Promociones › Combos.`,
        valor: a.tipo === 'descuento_alto' ? (ev.descuentoPct ?? 0) : (ev.margenPct ?? 0),
        seccion: 'combos',
      })
    }
  }
  return out.sort((a, b) => (a.severidad === b.severidad ? 0 : a.severidad === 'critical' ? -1 : 1))
}
