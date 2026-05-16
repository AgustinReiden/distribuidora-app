/**
 * Helpers para construir URLs de deep-link a apps de navegacion (Google Maps, Waze).
 *
 * El objetivo es que el transportista, en una tablet, inicie navegacion
 * turn-by-turn directa hacia las coordenadas del proximo cliente sin pasos
 * intermedios. Ambas apps son gratuitas y ampliamente conocidas en Argentina.
 *
 * Por que /maps/dir/ y no /maps/search/: search abre la pantalla de busqueda,
 * dir abre navegacion turn-by-turn directa. Ademas usar lat,lng (en vez de
 * direccion textual) evita que Maps mande al chofer a una calle parecida.
 */

/**
 * URL para iniciar navegacion en Google Maps hacia coordenadas exactas.
 * Si el dispositivo tiene la app instalada, se abre nativa; sino, en navegador.
 */
export function googleMapsNavUrl(lat: number, lng: number): string {
  return `https://www.google.com/maps/dir/?api=1&destination=${lat},${lng}&travelmode=driving`
}

/**
 * URL para iniciar navegacion en Waze hacia coordenadas exactas.
 * `navigate=yes` arranca la navegacion automaticamente (sin pedir confirmacion).
 */
export function wazeNavUrl(lat: number, lng: number): string {
  return `https://www.waze.com/ul?ll=${lat},${lng}&navigate=yes`
}

/**
 * Fallback cuando el cliente no tiene coordenadas guardadas: usa la direccion
 * textual con search. Menos preciso pero al menos lleva al chofer a un punto.
 */
export function googleMapsSearchUrl(direccion: string): string {
  return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(direccion)}`
}
