/**
 * El origen del precio de las líneas de un pedido editado (C4b v2 de #1603).
 *
 * `actualizar_pedido_items` borra y reinserta las líneas, y el origen del precio que se registró en
 * el alta (mig 148/149: de qué escala o regla salió) se repone después con
 * `registrar_origen_precio_items`, en otra llamada. Si esa segunda falla, los productos ya
 * quedaron guardados y la venta se comisiona con la regla general. Antes sólo quedaba en la
 * consola; ahora se avisa (persistente) y se ofrece reintentar.
 *
 * Hacerlo atómico (que el origen viaje dentro de `actualizar_pedido_items`) va con la decisión
 * SEG-03 / VTA-09 de la ola 3: si el origen lo calcula el server en vez de mandarlo el front, la
 * segunda llamada desaparece; si sigue llegando del front, la función tiene que recibirlo. Esa
 * función es de otra tarjeta y su parte de regalos está en revisión.
 */

type Rpc = (fn: string, args: Record<string, unknown>) => PromiseLike<{ error: unknown }>

export async function registrarOrigenPrecios(
  rpc: Rpc,
  pedidoId: number | string,
  origenes: readonly unknown[],
): Promise<{ ok: true } | { ok: false; error: unknown }> {
  try {
    const { error } = await rpc('registrar_origen_precio_items', { p_pedido_id: pedidoId, p_origenes: origenes })
    return error ? { ok: false, error } : { ok: true }
  } catch (error) {
    return { ok: false, error }
  }
}

export function mensajeOrigenPendiente(pedidoId: number | string): string {
  return `Los productos del pedido #${pedidoId} se guardaron, pero no se pudo registrar de dónde salió el precio de cada línea: así la comisión se calcula con la regla general. Reintentalo cuando haya señal.`
}
