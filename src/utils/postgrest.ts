/**
 * Escapa caracteres especiales de PostgREST para uso seguro en filtros .or() / .ilike()
 *
 * Previene inyección PostgREST eliminando caracteres que forman parte de la
 * sintaxis de filtros (, . () []) y wildcards manuales (%).
 * Limita longitud a 100 caracteres para prevenir abuso.
 *
 * @example
 * // Input malicioso: "%a%,razon_social.ilike.%"
 * escapePostgrestFilter("%a%,razon_social.ilike.%") // "arazon_socialilike"
 */
export function escapePostgrestFilter(input: string | null | undefined): string {
  if (input == null || !input) return ''
  return String(input)
    .replace(/[,.()[\]]/g, '') // Eliminar sintaxis PostgREST
    .replace(/%/g, '')          // Eliminar wildcards manuales (ya agregamos % en el filtro)
    .trim()
    .slice(0, 100)              // Limitar longitud
}
