/**
 * Módulo de exportación de PDFs
 *
 * Este archivo re-exporta todas las funciones de generación de PDF
 * desde sus respectivos módulos para mantener compatibilidad con el código existente.
 */

// Utilidades compartidas (para uso interno o extensiones)
export * from './utils'
export * from './constants'

// Funciones de generación de PDF
export { generarOrdenPreparacion } from './ordenPreparacion'
export { generarHojaRuta } from './hojaRuta'
export { generarHojaRutaOptimizada } from './hojaRutaOptimizada'
export { generarReciboPago } from './reciboPago'
export { generarEstadoCuenta } from './estadoCuenta'
export { generarReciboPedido } from './reciboPedido'
