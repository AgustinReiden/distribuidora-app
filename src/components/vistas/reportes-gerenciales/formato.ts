// Helpers de formato compartidos por la vista de Reportes Gerenciales.

const F = new Intl.NumberFormat('es-AR', {
  style: 'currency',
  currency: 'ARS',
  maximumFractionDigits: 0,
})

export const N = new Intl.NumberFormat('es-AR')

/** Monto completo en pesos: $1.234.567 */
export const money = (x: number): string => F.format(Math.round(x || 0))

/** Porcentaje a partir de un ratio (0.31 -> "31,0%"). */
export const pct = (x: number): string => ((x || 0) * 100).toFixed(1).replace('.', ',') + '%'

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
 * Margen neto % de un mes de la evolución: (venta − CMV − bonif. + descuentos
 * de proveedores) / venta. Los descuentos (notas de crédito de compra sin
 * mercadería, mig 280) restan del lado del costo, igual que en los kpis.
 */
export function margenNetoMesPct(m: { venta: number; cmv: number; bonif: number; descuentos_proveedores?: number }): number {
  if (!m.venta) return 0
  return (m.venta - m.cmv - m.bonif + (m.descuentos_proveedores ?? 0)) / m.venta
}
