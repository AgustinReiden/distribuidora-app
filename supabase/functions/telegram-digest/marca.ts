// La marca de "ya se mandó" del resumen diario (#1309, BOT-10).
//
// Se toma ANTES de mandar, con `bot_digest_reservar` (INSERT … ON CONFLICT …
// RETURNING): si dos corridas del workflow coinciden —el cron y un
// workflow_dispatch—, una sola gana y la otra no manda nada. Antes se miraba
// si había fila y se escribía después de mandar, y las dos corridas mandaban.
//
// Una por (perfil, fecha resumida, sucursal): el admin con dos sucursales
// recibe dos resúmenes, cada uno con su nombre.
//
// Los estados:
//   * enviando — la tomó una corrida y todavía no terminó. No se retoma: si la
//                corrida murió en el medio, preferimos perder ese resumen (el
//                gate de integridad.yml lo ve) a mandarlo dos veces.
//   * ok / skipped — terminado. `skipped` es "no había nada que contar".
//   * error   — se retoma en la próxima corrida.

import type { SupabaseClient } from "@supabase/supabase-js";

export interface MarcaDigest {
  perfil_id: string;
  sucursal_id: number;
  /** YYYY-MM-DD — el día resumido. */
  fecha: string;
  telegram_user_id: number;
}

/**
 * TRUE si esta corrida se queda con el resumen. Si la base no contesta, FALSE:
 * sin marca no se manda, porque mandar sin poder registrarlo es la receta del
 * doble envío. El resumen sale en la corrida siguiente.
 */
export async function reservarDigest(sb: SupabaseClient, m: MarcaDigest): Promise<boolean> {
  const { data, error } = await sb.rpc("bot_digest_reservar", {
    p_perfil_id: m.perfil_id,
    p_sucursal_id: m.sucursal_id,
    p_fecha: m.fecha,
    p_telegram_user_id: m.telegram_user_id,
  });
  if (error) {
    console.error(
      `[digest] no pude reservar (perfil_id=${m.perfil_id}, sucursal_id=${m.sucursal_id}, fecha=${m.fecha}):`,
      error.message,
    );
    return false;
  }
  return data === true;
}

/**
 * ¿Telegram contestó 403? Es "el usuario bloqueó el bot" (o borró la cuenta, o
 * nunca abrió el chat): reintentar no cambia nada. Se cierra como 'skipped' y no
 * como 'error', que se retomaría en cada corrida del día y dejaría el gate rojo
 * para siempre. Lo vuelve a intentar el resumen del día siguiente.
 */
export function esChatInaccesible(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : String(err);
  return /status 403\b/.test(msg);
}

/** Cierra la marca. Nunca lanza: el mensaje ya salió (o no) y eso no cambia. */
export async function registrarDigest(
  sb: SupabaseClient,
  m: MarcaDigest,
  status: "ok" | "error" | "skipped",
  error_meta?: Record<string, unknown>,
): Promise<void> {
  const { error } = await sb.rpc("bot_digest_registrar", {
    p_perfil_id: m.perfil_id,
    p_sucursal_id: m.sucursal_id,
    p_fecha: m.fecha,
    p_status: status,
    p_error_meta: error_meta ?? null,
  });
  if (error) {
    console.error(
      `[digest] no pude registrar ${status} (perfil_id=${m.perfil_id}, sucursal_id=${m.sucursal_id}, fecha=${m.fecha}):`,
      error.message,
    );
  }
}
