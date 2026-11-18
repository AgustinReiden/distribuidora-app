/**
 * Si el total que guardó el server para un alta es el que mandó el front, con la tolerancia
 * de un centavo del alta (`crear_pedido_completo` acepta `p_total` a un centavo de la suma
 * de las líneas y, desde 1559-b1, guarda la suma). Se compara en centavos enteros: en coma
 * flotante `Math.abs(99.99 - 100)` da 0.010000000000005116 y un `< 0.01` lo dejaba afuera.
 */
export function mismoTotalDelAlta(guardado: number, enviado: number): boolean {
  return Math.abs(Math.round(guardado * 100) - Math.round(enviado * 100)) <= 1
}

/**
 * Lo que dice el aviso cuando un pedido propio ya estaba cargado (entró en un intento anterior) y
 * después cambió. Una sola frase para el replay de la cola y para el alta directa.
 */
export function mensajePedidoQueYaHabiaEntrado(id?: string | number | null): string {
  const numero = id != null ? ` #${id}` : ''
  return `El pedido${numero} ya estaba cargado (entró en un intento anterior) y después cambió, por ejemplo porque ` +
    'se editó o se canceló: no se cargó otro. Miralo en la lista de pedidos.'
}

/** Lo que el alta directa le pregunta a la respuesta del server (`crearPedido`). */
interface RespuestaDelAlta {
  id?: string | number | null
  idempotente?: boolean
  clienteId?: string | number | null
  total?: number | null
  cargoEnvio?: number | null
}

/**
 * El alta directa se reintenta con la misma clave (D56). Si el server contesta el pedido que ya tenía
 * (`idempotente`) y ese pedido es del mismo cliente pero con otro total, es el PROPIO cambiado después
 * (editado, cancelado, con una salvedad): no se creó nada, y decir «Pedido creado» miente. Devuelve el
 * aviso, o null si no aplica: no fue la rama idempotente, el pedido no se pudo leer, es de otro cliente
 * (acá no puede pasar con una clave por intención) o está igual. Un vale blanco no tiene total
 * comparable (lo precia el server a costo) y no entra.
 */
export function avisoAltaQueYaHabiaEntrado(
  respuesta: RespuestaDelAlta | null | undefined,
  enviado: { clienteId: string | number | null | undefined; total: number; tipoFactura?: string | null },
): string | null {
  if (!respuesta || respuesta.idempotente !== true || enviado.tipoFactura === 'VB') return null
  if (respuesta.clienteId == null || typeof respuesta.total !== 'number') return null
  if (String(respuesta.clienteId) !== String(enviado.clienteId)) return null
  if (mismoTotalDelAlta(respuesta.total - (respuesta.cargoEnvio ?? 0), enviado.total)) return null
  return mensajePedidoQueYaHabiaEntrado(respuesta.id)
}
