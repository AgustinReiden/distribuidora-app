// Dedup de updates de Telegram por update_id.
//
// Telegram reintenta el webhook cuando no recibe 200 a tiempo, y una respuesta
// lenta del LLM alcanza para llegar al timeout. Sin esto, cada reintento se
// reprocesa entero: el mismo mensaje pasa dos veces por el agente y un callback
// de "confirmar pedido" puede intentar crear el pedido dos veces
// (crear_pedido_completo_bot no es idempotente por update).
//
// La marca vive en la base (tabla bot_updates_procesados, mig 248), NO en
// memoria del isolate: Supabase lo recicla entre invocaciones y un reintento
// puede caer en otro isolate, así que un Set en memoria no dedupea nada.

import { getServiceRoleClient } from "../_shared/supabase.ts";

/**
 * ¿Es la primera vez que vemos este update_id?
 *
 * `true`  → procesalo.
 * `false` → es un reintento de Telegram; respondé 200 y no lo proceses.
 *
 * Fail-OPEN a propósito: si la RPC falla (base caída, red), devolvemos `true`
 * y logueamos. Mejor un duplicado que un mensaje perdido — el duplicado el
 * usuario lo ve y lo puede corregir; el mensaje perdido no deja rastro.
 */
export async function esUpdateNuevo(updateId: number): Promise<boolean> {
  try {
    const supabase = getServiceRoleClient();
    const { data, error } = await supabase.rpc("bot_marcar_update", {
      p_update_id: updateId,
    });
    if (error) {
      console.error("telegram-webhook bot_marcar_update error", error);
      return true;
    }
    return data !== false;
  } catch (err) {
    console.error("telegram-webhook bot_marcar_update threw", err);
    return true;
  }
}
