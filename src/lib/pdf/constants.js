/**
 * Constantes compartidas para generación de PDFs
 */

// Dimensiones de ticket comandera (75mm)
export const TICKET = {
  width: 75,
  margin: 3,
  get contentWidth() { return this.width - (this.margin * 2) }
}

// Dimensiones A4
export const A4 = {
  width: 210,
  height: 297,
  margin: 15,
  get contentWidth() { return this.width - (this.margin * 2) }
}

// Colores
export const COLORS = {
  black: [0, 0, 0],
  white: [255, 255, 255],
  gray: {
    50: [248, 249, 250],
    100: [240, 240, 240],
    200: [200, 200, 200],
    300: [150, 150, 150],
    400: [130, 130, 130],
    500: [100, 100, 100],
    600: [80, 80, 80],
    700: [60, 60, 60],
    800: [50, 50, 50],
    900: [33, 37, 41]
  },
  green: {
    50: [240, 253, 244],
    500: [34, 197, 94],
    700: [21, 128, 61]
  },
  yellow: {
    50: [255, 251, 235],
    700: [161, 98, 7]
  },
  red: {
    500: [239, 68, 68],
    700: [185, 28, 28]
  }
}

// Fuentes
export const FONTS = {
  sizes: {
    xs: 6,
    sm: 7,
    md: 8,
    lg: 9,
    xl: 10,
    '2xl': 11,
    '3xl': 12,
    '4xl': 14,
    '5xl': 16,
    '6xl': 18,
    '7xl': 22
  }
}

// Labels de formas de pago
export const FORMAS_PAGO_LABELS = {
  efectivo: 'Efectivo',
  transferencia: 'Transferencia Bancaria',
  cheque: 'Cheque',
  tarjeta: 'Tarjeta',
  cuenta_corriente: 'Cuenta Corriente'
}

export const FORMAS_PAGO_SHORT = {
  efectivo: 'Efvo',
  transferencia: 'Transf',
  cheque: 'Cheque',
  cuenta_corriente: 'Cta.Cte',
  tarjeta: 'Tarjeta'
}

// Estados de pago
export const ESTADOS_PAGO = {
  pagado: { label: 'PAGADO', symbol: '[P]' },
  parcial: { label: 'PARCIAL', symbol: '[*]' },
  pendiente: { label: 'PEND', symbol: '[$]' }
}
