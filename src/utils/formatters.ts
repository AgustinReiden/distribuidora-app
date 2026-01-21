/**
 * Funciones de formateo unificadas para toda la aplicacion
 *
 * Centraliza el formateo de: CUIT/DNI, moneda, fechas, tiempo relativo, etc.
 */

import type { EstadoPedido, EstadoPago, FormaPago, RolUsuario } from '@/types';

// ============================================
// FORMATEO DE MONEDA
// ============================================

export const formatPrecio = (p: number | null | undefined): string =>
  new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS' }).format(p || 0);

/**
 * Formatea un monto como moneda argentina
 */
export function formatCurrency(amount: number | null | undefined, showSymbol = true): string {
  if (amount === null || amount === undefined || isNaN(amount)) {
    return showSymbol ? '$0,00' : '0,00'
  }

  const formatted = new Intl.NumberFormat('es-AR', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
  }).format(amount)

  return showSymbol ? `$${formatted}` : formatted
}

/**
 * Formatea un monto de forma compacta (1.5K, 2.3M, etc.)
 */
export function formatCurrencyCompact(amount: number | null | undefined): string {
  if (amount === null || amount === undefined || isNaN(amount)) {
    return '$0'
  }

  if (amount >= 1000000) {
    return `$${(amount / 1000000).toFixed(1)}M`
  } else if (amount >= 1000) {
    return `$${(amount / 1000).toFixed(1)}K`
  }

  return formatCurrency(amount)
}

// ============================================
// FORMATEO DE FECHAS
// ============================================

export const formatFecha = (f: string | Date | null | undefined): string =>
  f ? new Date(f).toLocaleDateString('es-AR', {
    day: '2-digit',
    month: '2-digit',
    hour: '2-digit',
    minute: '2-digit'
  }) : '';

/**
 * Formatea una fecha en formato local
 */
export function formatDate(date: string | Date | null | undefined, options: Intl.DateTimeFormatOptions = {}): string {
  if (!date) return ''

  const dateObj = typeof date === 'string' ? new Date(date) : date

  if (isNaN(dateObj.getTime())) return ''

  const defaultOptions: Intl.DateTimeFormatOptions = {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
    ...options
  }

  return dateObj.toLocaleDateString('es-AR', defaultOptions)
}

/**
 * Formatea fecha y hora
 */
export function formatDateTime(date: string | Date | null | undefined): string {
  if (!date) return ''

  const dateObj = typeof date === 'string' ? new Date(date) : date

  if (isNaN(dateObj.getTime())) return ''

  return dateObj.toLocaleString('es-AR', {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit'
  })
}

/**
 * Formatea tiempo relativo ("hace 5 minutos", "hace 2 horas", etc.)
 */
export function formatTimeAgo(date: string | Date | null | undefined): string {
  if (!date) return ''

  const dateObj = typeof date === 'string' ? new Date(date) : date

  if (isNaN(dateObj.getTime())) return ''

  const now = new Date()
  const diffMs = now.getTime() - dateObj.getTime()
  const diffSecs = Math.floor(diffMs / 1000)
  const diffMins = Math.floor(diffSecs / 60)
  const diffHours = Math.floor(diffMins / 60)
  const diffDays = Math.floor(diffHours / 24)

  if (diffSecs < 60) {
    return 'hace un momento'
  } else if (diffMins < 60) {
    return `hace ${diffMins} ${diffMins === 1 ? 'minuto' : 'minutos'}`
  } else if (diffHours < 24) {
    return `hace ${diffHours} ${diffHours === 1 ? 'hora' : 'horas'}`
  } else if (diffDays < 7) {
    return `hace ${diffDays} ${diffDays === 1 ? 'dia' : 'dias'}`
  } else {
    return formatDate(dateObj)
  }
}

// ============================================
// FORMATEO DE DOCUMENTOS (CUIT/DNI)
// ============================================

/**
 * Formatea un CUIT con guiones (XX-XXXXXXXX-X)
 */
export function formatCuit(value: string | number | null | undefined): string {
  if (!value) return ''

  // Remover todo excepto numeros
  const numbers = String(value).replace(/\D/g, '')

  // Aplicar formato XX-XXXXXXXX-X
  if (numbers.length <= 2) {
    return numbers
  } else if (numbers.length <= 10) {
    return `${numbers.slice(0, 2)}-${numbers.slice(2)}`
  } else {
    return `${numbers.slice(0, 2)}-${numbers.slice(2, 10)}-${numbers.slice(10, 11)}`
  }
}

/**
 * Remueve formato de CUIT (solo numeros)
 */
export function unformatCuit(value: string | null | undefined): string {
  if (!value) return ''
  return String(value).replace(/\D/g, '')
}

/**
 * Valida formato de CUIT (11 digitos)
 */
export function isValidCuit(cuit: string | null | undefined): boolean {
  const numbers = unformatCuit(cuit)
  return numbers.length === 11
}

/**
 * Formatea un DNI con puntos (XX.XXX.XXX)
 */
export function formatDni(value: string | number | null | undefined): string {
  if (!value) return ''

  const numbers = String(value).replace(/\D/g, '')

  if (numbers.length <= 2) {
    return numbers
  } else if (numbers.length <= 5) {
    return `${numbers.slice(0, -3)}.${numbers.slice(-3)}`
  } else {
    return `${numbers.slice(0, -6)}.${numbers.slice(-6, -3)}.${numbers.slice(-3)}`
  }
}

/**
 * Formatea un numero de telefono
 */
export function formatTelefono(value: string | number | null | undefined): string {
  if (!value) return ''

  const numbers = String(value).replace(/\D/g, '')

  // Formato argentino: (XXX) XXXX-XXXX o similar
  if (numbers.length <= 3) {
    return numbers
  } else if (numbers.length <= 7) {
    return `(${numbers.slice(0, 3)}) ${numbers.slice(3)}`
  } else {
    return `(${numbers.slice(0, 3)}) ${numbers.slice(3, 7)}-${numbers.slice(7, 11)}`
  }
}

// ============================================
// ESTADOS Y LABELS
// ============================================

export const getEstadoColor = (e: EstadoPedido | string | null | undefined): string =>
  e === 'pendiente' ? 'bg-yellow-100 text-yellow-800' :
  e === 'en_preparacion' ? 'bg-orange-100 text-orange-800' :
  e === 'asignado' ? 'bg-blue-100 text-blue-800' :
  e === 'en_camino' ? 'bg-blue-100 text-blue-800' :
  e === 'entregado' ? 'bg-green-100 text-green-800' :
  e === 'cancelado' ? 'bg-red-100 text-red-800' :
  'bg-gray-100 text-gray-800';

export const getEstadoLabel = (e: EstadoPedido | string | null | undefined): string =>
  e === 'pendiente' ? 'Pendiente' :
  e === 'en_preparacion' ? 'En preparación' :
  e === 'asignado' ? 'Asignado' :
  e === 'en_camino' ? 'En camino' :
  e === 'entregado' ? 'Entregado' :
  e === 'cancelado' ? 'Cancelado' :
  e || '';

export const getRolColor = (r: RolUsuario | string | null | undefined): string =>
  r === 'admin' ? 'bg-purple-100 text-purple-700' :
  r === 'transportista' ? 'bg-orange-100 text-orange-700' :
  'bg-blue-100 text-blue-700';

export const getRolLabel = (r: RolUsuario | string | null | undefined): string =>
  r === 'admin' ? 'Admin' :
  r === 'transportista' ? 'Transportista' :
  'Preventista';

export const getEstadoPagoColor = (estado: EstadoPago | string | null | undefined): string =>
  estado === 'pagado' ? 'bg-green-100 text-green-800' :
  estado === 'parcial' ? 'bg-yellow-100 text-yellow-800' :
  'bg-red-100 text-red-800';

export const getEstadoPagoLabel = (estado: EstadoPago | string | null | undefined): string =>
  estado === 'pagado' ? 'Pagado' :
  estado === 'parcial' ? 'Pago Parcial' :
  'Pago Pendiente';

export const getFormaPagoLabel = (forma: FormaPago | string | null | undefined): string =>
  forma === 'efectivo' ? 'Efectivo' :
  forma === 'transferencia' ? 'Transferencia' :
  forma === 'cheque' ? 'Cheque' :
  forma === 'cuenta_corriente' ? 'Cta. Cte.' :
  forma === 'tarjeta' ? 'Tarjeta' :
  forma || '';

// ============================================
// UTILIDADES GENERALES
// ============================================

/**
 * Trunca un string a una longitud maxima
 */
export function truncate(str: string | null | undefined, maxLength: number, suffix = '...'): string {
  if (!str) return ''
  if (str.length <= maxLength) return str
  return str.slice(0, maxLength - suffix.length) + suffix
}

/**
 * Capitaliza la primera letra de un string
 */
export function capitalize(str: string | null | undefined): string {
  if (!str) return ''
  return str.charAt(0).toUpperCase() + str.slice(1).toLowerCase()
}

/**
 * Formatea un porcentaje
 */
export function formatPercent(value: number | null | undefined, decimals = 1): string {
  if (value === null || value === undefined || isNaN(value)) return '0%'
  return `${(value * 100).toFixed(decimals)}%`
}

/**
 * Formatea un numero con separador de miles
 */
export function formatNumber(value: number | null | undefined): string {
  if (value === null || value === undefined || isNaN(value)) return '0'
  return new Intl.NumberFormat('es-AR').format(value)
}

/**
 * Valida un email
 */
export function isValidEmail(email: string | null | undefined): boolean {
  if (!email) return false
  const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
  return emailRegex.test(email)
}

// ============================================
// CONSTANTES
// ============================================

export const ITEMS_PER_PAGE = 10;

// ============================================
// EXPORT DEFAULT
// ============================================

export default {
  formatPrecio,
  formatCurrency,
  formatCurrencyCompact,
  formatFecha,
  formatDate,
  formatDateTime,
  formatTimeAgo,
  formatCuit,
  unformatCuit,
  isValidCuit,
  formatDni,
  formatTelefono,
  getEstadoColor,
  getEstadoLabel,
  getRolColor,
  getRolLabel,
  getEstadoPagoColor,
  getEstadoPagoLabel,
  getFormaPagoLabel,
  truncate,
  capitalize,
  formatPercent,
  formatNumber,
  isValidEmail,
  ITEMS_PER_PAGE
}
