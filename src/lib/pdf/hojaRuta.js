/**
 * Genera PDF de Hoja de Ruta para el transportista.
 * Reusa el layout A4 horizontal con 3 columnas de hojaRutaOptimizada.
 */
import { generarHojaRutaOptimizada } from './hojaRutaOptimizada'

/**
 * @param {Object} transportista - Datos del transportista
 * @param {Array} pedidos - Lista de pedidos asignados
 * @returns {void}
 */
export function generarHojaRuta(transportista, pedidos) {
  generarHojaRutaOptimizada(transportista, pedidos, {})
}
