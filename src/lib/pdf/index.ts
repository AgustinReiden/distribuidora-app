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
export { generarHojaRutaOptimizada, type InfoRuta } from './hojaRutaOptimizada'
export { generarReciboPedido, generarComandasMultiples } from './reciboPedido'
