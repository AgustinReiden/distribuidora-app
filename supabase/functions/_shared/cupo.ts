// Cupo de uso por chat (mig 296).
//
// Cada mensaje que llega al modelo —texto libre o nota de voz— cuesta plata.
// Sin tope, un usuario vinculado (o un script con su chat) puede disparar
// llamadas sin límite. Los comandos y botones no pasan por el modelo y no
// cuentan.
//
// Los límites son constantes técnicas, no política comercial: por eso viven
// acá y no en `politicas_comerciales`. Alcanzan holgado para el uso real
// (unas 15 consultas por día por persona en el escenario alto).

import type { SupabaseClient } from "@supabase/supabase-js";

export const CUPO_POR_MINUTO = 10;
export const CUPO_POR_DIA = 150;

export type ResultadoCupo =
  | { ok: true }
  | { ok: false; motivo: "por_minuto" | "por_dia" };

/**
 * Consume una unidad del cupo del chat. Si la RPC falla, deja pasar: el
 * cupo protege el costo, no la seguridad, y no vale la pena dejar al usuario
 * sin respuesta por un error de infraestructura. El error queda en el log.
 */
export async function consumirCupo(
  supabase: SupabaseClient,
  telegram_user_id: number,
): Promise<ResultadoCupo> {
  const { data, error } = await supabase.rpc("bot_consumir_cupo", {
    p_telegram_user_id: telegram_user_id,
    p_max_por_minuto: CUPO_POR_MINUTO,
    p_max_por_dia: CUPO_POR_DIA,
  });
  if (error) {
    console.error("[cupo] bot_consumir_cupo falló, se deja pasar:", error.message);
    return { ok: true };
  }
  const r = (data ?? {}) as { ok?: unknown; motivo?: unknown };
  if (r.ok === false) {
    return { ok: false, motivo: r.motivo === "por_dia" ? "por_dia" : "por_minuto" };
  }
  return { ok: true };
}

export function mensajeCupoAgotado(motivo: "por_minuto" | "por_dia"): string {
  return motivo === "por_dia"
    ? `Llegaste al máximo de ${CUPO_POR_DIA} consultas por hoy. Mañana se renueva. ` +
      "Los comandos y botones (/ayuda) siguen funcionando."
    : "Vas muy rápido: esperá un minuto y volvé a preguntar.";
}
