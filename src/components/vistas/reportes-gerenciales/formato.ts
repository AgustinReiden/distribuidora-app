// Helpers de formato compartidos por la vista de Reportes Gerenciales.

import { margenSobreConCosto } from '../../../utils/margenSobreConCosto'

const F = new Intl.NumberFormat('es-AR', {
  style: 'currency',
  currency: 'ARS',
  maximumFractionDigits: 0,
})

export const N = new Intl.NumberFormat('es-AR')

/** Monto completo en pesos: $1.234.567 */
export const money = (x: number): string => F.format(Math.round(x || 0))

/**
 * Porcentaje a partir de un ratio (0.31 -> "31,0%"). Un ratio sobre una base 0 (bonificaciones
 * con venta 0) llega como ±Infinity: no es un porcentaje, va «—» (#1544, 1544-b8).
 */
export const pct = (x: number): string => {
  if (x === Infinity || x === -Infinity) return '—'
  return ((x || 0) * 100).toFixed(1).replace('.', ',') + '%'
}

/**
 * Porcentaje de `parte` sobre `base`, o «—» si la base no es un número mayor que 0. Con la venta
 * neta de notas de crédito un mes, un vendedor o una categoría puede tener venta 0 o NEGATIVA, y ahí
 * un margen sobre venta no significa nada (un 175,8 % «bueno» por dividir negativo con negativo).
 * No cambia ninguna cuenta: sólo cómo se muestra un porcentaje sin sentido.
 */
export const pctSobre = (parte: number, base: number): string =>
  Number.isFinite(base) && base > 0 ? pct(parte / base) : '—'

/** Compacto inteligente: millones con 2 decimales, miles con K, sin "$0 M". */
export function moneyC(x: number): string {
  const a = Math.abs(x || 0)
  const sg = x < 0 ? '−' : ''
  if (a >= 1e6) return sg + '$' + (a / 1e6).toLocaleString('es-AR', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + ' M'
  if (a >= 1e3) return sg + '$' + Math.round(a / 1e3).toLocaleString('es-AR') + ' K'
  return sg + '$' + Math.round(a)
}

/** Etiqueta legible del rol del vendedor. */
export function rolLabel(rol: string): string {
  switch (rol) {
    case 'preventista':
      return 'Prev'
    case 'encargado':
      return 'Encarg'
    case 'admin':
      return 'Admin'
    default:
      return rol
  }
}

/**
 * Margen neto % de un mes de la evolución, como el de la card del período
 * (`margenSobreConCosto`, D42): (venta − sin costo − CMV − bonif. + descuentos de proveedores) /
 * (venta − sin costo). Lo vendido sin costo no es margen (el server lo deja fuera) ni entra al
 * denominador; `sinCosto` es lo que el RPC dejó fuera de ese mes (`mensual[].ingreso_sin_costo`, vía
 * `sinCostoFueraDelMargen`; 0 con un RPC anterior, que lo contaba como margen). Los descuentos (notas
 * de crédito de compra sin mercadería, mig 280) restan del lado del costo, igual que en los kpis.
 *
 * Con una base 0 o negativa (un mes cuyas notas de crédito superan la venta) devuelve null: la tabla
 * muestra «—» y el gráfico no dibuja el punto.
 */
export function margenNetoMesPct(
  m: { venta: number; cmv: number; bonif: number; descuentos_proveedores?: number },
  sinCosto = 0,
): number | null {
  return margenSobreConCosto(m.venta - sinCosto - m.cmv - m.bonif + (m.descuentos_proveedores ?? 0), m.venta, sinCosto)
}

const DIA_ISO = /^(\d{4})-(\d{2})-(\d{2})$/

/**
 * Etiqueta de un día de la serie diaria (REP-10). El RPC lo manda ISO
 * (`YYYY-MM-DD`): `DD/MM`, o `DD/MM/AA` si la serie cruza más de un año (sin
 * el año, el 05/01 de 2026 y el de 2027 se leen iguales). Un valor que no es
 * ISO —el `DD/MM` viejo de un caché o de un PWA viejo— se devuelve tal cual.
 */
export function etiquetaDiaSerie(dia: string, conAnio: boolean): string {
  const m = DIA_ISO.exec(dia)
  if (!m) return dia
  return conAnio ? `${m[3]}/${m[2]}/${m[1].slice(2)}` : `${m[3]}/${m[2]}`
}

/** La serie tiene días de más de un año (sólo cuenta los que vienen ISO). */
export function serieCruzaAnios(dias: readonly string[]): boolean {
  const anios = new Set<string>()
  for (const d of dias) {
    const m = DIA_ISO.exec(d)
    if (m) anios.add(m[1])
  }
  return anios.size > 1
}
