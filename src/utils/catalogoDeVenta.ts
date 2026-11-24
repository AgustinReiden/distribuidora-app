/**
 * Cuándo el catálogo que ve quien vende ya es viejo (INF-1, tanda 6 de #1603).
 *
 * La publicación de Realtime (`supabase_realtime`) sólo tiene `pedidos`: ni `productos` ni
 * `pedido_items` mandan eventos, así que nada refresca el stock de una pantalla que se queda
 * abierta (`staleTime` de 10 minutos y `refetchOnWindowFocus` apagado). Un producto sin stock
 * cacheado queda en gris y no se puede elegir aunque el server ya tenga stock; y al revés, uno
 * con stock cacheado se ofrece cuando ya no hay.
 *
 * Sin migración: al abrir «Nuevo pedido» o editar un pedido se relee el catálogo si su copia
 * tiene más de un minuto. Es lo que tarda en cambiar lo que importa y no recarga el catálogo
 * entero en cada apertura de un alta hecha de corrido.
 */
export const CATALOGO_VIEJO_MS = 60 * 1000

/**
 * `dataUpdatedAt` es 0 mientras la consulta no trajo nada (está cargando: no hay copia que
 * releer) y puede faltar cuando quien llama no lo sabe: en los dos casos no se relee.
 */
export function catalogoDebeRelerse(dataUpdatedAt: number | undefined, ahora: number): boolean {
  if (!dataUpdatedAt) return false
  return ahora - dataUpdatedAt > CATALOGO_VIEJO_MS
}
