// Techo de gasto del asistente: USD 10 por mes (#979, mig 315).
//
// Antes de cada respuesta el agente pregunta en qué nivel está el mes y,
// después, suma lo que costó. La cuenta y los umbrales viven en SQL
// (`bot_costo_llm_estado` / `bot_costo_llm_sumar`); acá se decide qué hacer:
//   * ok / aviso → el modelo de siempre;
//   * agotado    → el modelo más barato (BOT_LLM_MODEL_FALLBACK) y, si ya se
//                  estaba usando ése, sólo comandos y botones, sin modelo.
// Al cruzar el 80% y el 100%, aviso a los admins vinculados, una vez por mes.
//
// Si la base no contesta, el bot sigue (fail-open): un problema de red no
// puede dejar mudo al asistente, y una respuesta de más cuesta centésimos.

import type { SupabaseClient } from "@supabase/supabase-js";
import { sendMessage } from "../telegram.ts";
import { modeloActivo, modeloFallback } from "./modelo.ts";

export type NivelPresupuesto = "ok" | "aviso" | "agotado";

export interface EstadoPresupuesto {
  usd: number;
  techo: number;
  nivel: NivelPresupuesto;
}

const ESTADO_DESCONOCIDO: EstadoPresupuesto = { usd: 0, techo: 10, nivel: "ok" };

export async function estadoPresupuesto(sb: SupabaseClient): Promise<EstadoPresupuesto> {
  try {
    const { data, error } = await sb.rpc("bot_costo_llm_estado");
    if (error) throw new Error(error.message);
    return normalizar(data);
  } catch (err) {
    console.error("[presupuesto] estado failed (fail-open):", err instanceof Error ? err.message : err);
    return ESTADO_DESCONOCIDO;
  }
}

export type DecisionModelo =
  | { modo: "modelo"; modelo: string; degradado: boolean }
  | { modo: "solo_botones" };

export function decidirModelo(estado: EstadoPresupuesto): DecisionModelo {
  const activo = modeloActivo();
  if (estado.nivel !== "agotado") return { modo: "modelo", modelo: activo, degradado: false };
  const barato = modeloFallback();
  if (barato === activo || barato.toLowerCase() === "ninguno") return { modo: "solo_botones" };
  return { modo: "modelo", modelo: barato, degradado: true };
}

export const MENSAJE_SOLO_BOTONES =
  "Este mes el asistente ya usó todo su presupuesto, así que por ahora no " +
  "puedo contestar preguntas libres. Los comandos siguen andando: /menu, " +
  "/atrasados, /misclientes, /cliente, /producto. El mes que viene vuelvo a " +
  "contestar normalmente.";

/**
 * Suma el costo de un turno. Nunca lanza: perder un registro de costo es
 * mejor que perder la respuesta al usuario.
 */
export async function registrarCosto(
  sb: SupabaseClient,
  usd: number,
  llamadas: number,
): Promise<void> {
  if (!(usd > 0) && llamadas === 0) return;
  try {
    const { data, error } = await sb.rpc("bot_costo_llm_sumar", {
      p_usd: Number(usd.toFixed(6)),
      p_llamadas: llamadas,
    });
    if (error) throw new Error(error.message);
    const avisar = (data as { avisar?: string | null } | null)?.avisar;
    if (avisar === "80" || avisar === "agotado") {
      await avisarAdmins(sb, avisar, normalizar(data));
    }
  } catch (err) {
    console.error("[presupuesto] registrar failed:", err instanceof Error ? err.message : err);
  }
}

export function textoAviso(tipo: "80" | "agotado", e: EstadoPresupuesto): string {
  const gasto = `USD ${e.usd.toFixed(2)} de USD ${e.techo.toFixed(2)}`;
  if (tipo === "80") {
    return `⚠️ El asistente de Telegram ya gastó ${gasto} este mes (80% del presupuesto). ` +
      "Si llega al 100%, pasa al modelo más barato hasta fin de mes.";
  }
  return `🛑 El asistente de Telegram llegó al presupuesto del mes (${gasto}). ` +
    "Hasta fin de mes contesta con el modelo más barato, o sólo con comandos si ya lo estaba usando.";
}

async function avisarAdmins(
  sb: SupabaseClient,
  tipo: "80" | "agotado",
  estado: EstadoPresupuesto,
): Promise<void> {
  // Dos consultas y no un embed: un embed mal resuelto rompe en runtime sin
  // que lo vea ningún test (CLAUDE.md, trampa 5).
  const { data: admins, error: e1 } = await sb
    .from("perfiles").select("id").eq("rol", "admin").eq("activo", true);
  if (e1) {
    console.error("[presupuesto] no pude leer los admins:", e1.message);
    return;
  }
  const ids = ((admins ?? []) as Array<{ id: string }>).map((a) => a.id);
  if (ids.length === 0) return;
  const { data, error } = await sb
    .from("bot_usuarios").select("telegram_user_id").eq("activo", true).in("perfil_id", ids);
  if (error) {
    console.error("[presupuesto] no pude leer los chats de los admins:", error.message);
    return;
  }
  const texto = textoAviso(tipo, estado);
  // En paralelo: esto corre antes de que salga la respuesta de quien cruzó el
  // umbral, y no tiene por qué esperar un envío por admin.
  const envios = await Promise.allSettled(
    ((data ?? []) as Array<{ telegram_user_id: number }>).map((fila) =>
      sendMessage(Number(fila.telegram_user_id), texto)
    ),
  );
  for (const e of envios) {
    if (e.status === "rejected") {
      console.error("[presupuesto] aviso a admin failed:", e.reason instanceof Error ? e.reason.message : e.reason);
    }
  }
}

function normalizar(data: unknown): EstadoPresupuesto {
  const d = (data ?? {}) as Record<string, unknown>;
  const nivel = d.nivel === "agotado" || d.nivel === "aviso" ? d.nivel : "ok";
  return { usd: Number(d.usd ?? 0), techo: Number(d.techo ?? 10), nivel };
}
