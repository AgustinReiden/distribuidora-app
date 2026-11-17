/**
 * Los cupos de una promo (`promocionesKeys.cupos`: `['promociones', sucursal, 'cupos', pedido]`)
 * dependen de los pedidos vivos, no sólo de los nuevos. Crear un pedido ya los invalidaba; cancelar,
 * editar, cambiar de cliente o cargar/anular una salvedad también liberan o consumen cupo, y la
 * pantalla seguía con el cupo de antes hasta 30 s (1543-b4).
 *
 * Va por predicado y no por la clave con la sucursal: quien llama (una mutation, o el container
 * que escribe por RPC) no siempre sabe en qué sucursal está parada la caché.
 */
import type { QueryClient } from '@tanstack/react-query'

export function invalidarCuposPromo(queryClient: QueryClient): Promise<void> {
  return queryClient.invalidateQueries({
    queryKey: ['promociones'],
    predicate: query => query.queryKey[0] === 'promociones' && query.queryKey[2] === 'cupos',
  })
}
