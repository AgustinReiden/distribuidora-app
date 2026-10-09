// Aviso semanal de clientes atrasados para preventistas (mig 325).
//
// Pedido del gerente: "quién dejó de comprar" es un dato que el preventista no
// sale a consultar, así que se le empuja. Un mensaje propio, aparte del
// resumen diario:
//   * SIN modelo: la lista de `bot_clientes_atrasados` (su cartera, montos
//     propios) con el formato del resumen diario y un botón por cliente que
//     abre el resumen de visita. Cuesta cero de IA.
//   * ACTIVADO POR DEFECTO para todo preventista vinculado: lunes a las 8:00.
//     Día y hora por persona en el panel; `bot_aviso_atrasados_destinatarios`
//     decide a quién le toca en cada hora.
//   * Sin clientes atrasados no se manda nada: no hay novedad que avisar.
//
// Idempotencia en `bot_avisos_atrasados_enviados` (perfil, fecha): el cron
// corre cada hora y una corrida repetida no duplica el mensaje.

import type { SupabaseClient } from "@supabase/supabase-js";
import { sendMessage } from "../_shared/telegram.ts";
import { logEvent } from "../_shared/audit.ts";
import { buildVisitaKeyboard } from "../_shared/telegram-keyboards.ts";
import { formatListaAtrasados, normalizarDatos } from "./preventista.ts";

export interface DestinatarioAviso {
  telegram_user_id: number;
  perfil_id: string;
  sucursal_id: number;
}

export interface ResultadoAviso {
  perfil_id: string;
  status: "ok" | "skipped" | "error";
  reason?: string;
}

/** Cuántos clientes van con botón en el mensaje (el resto: "…y N más"). */
const LIMITE_LISTA = 10;

export async function runAvisosAtrasados(
  sb: SupabaseClient,
  hora: number,
  dow: number,
  fecha: string,
): Promise<ResultadoAviso[]> {
  const { data, error } = await sb.rpc("bot_aviso_atrasados_destinatarios", {
    p_hora: hora,
    p_dow: dow,
  });
  if (error) {
    console.error("[aviso atrasados] destinatarios failed:", error.message);
    return [];
  }
  const destinatarios = ((data ?? []) as Array<Record<string, unknown>>).map((d) => ({
    telegram_user_id: Number(d.telegram_user_id),
    perfil_id: String(d.perfil_id),
    sucursal_id: Number(d.sucursal_id),
  }));
  const resultados = await Promise.allSettled(
    destinatarios.map((d) => runAvisoAtrasados(sb, d, fecha)),
  );
  return resultados.map((r, i) =>
    r.status === "fulfilled" ? r.value : {
      perfil_id: destinatarios[i].perfil_id,
      status: "error" as const,
      reason: r.reason instanceof Error ? r.reason.message : String(r.reason),
    }
  );
}

export async function runAvisoAtrasados(
  sb: SupabaseClient,
  d: DestinatarioAviso,
  fecha: string,
): Promise<ResultadoAviso> {
  const { data: previo } = await sb
    .from("bot_avisos_atrasados_enviados")
    .select("status")
    .eq("perfil_id", d.perfil_id)
    .eq("fecha", fecha)
    .maybeSingle();
  const statusPrevio = (previo as { status?: string } | null)?.status;
  if (statusPrevio === "ok" || statusPrevio === "skipped") {
    return { perfil_id: d.perfil_id, status: "skipped", reason: "ya_procesado" };
  }

  const { data, error } = await sb.rpc("bot_clientes_atrasados", {
    p_sucursal_id: d.sucursal_id,
    p_rol: "preventista",
    p_perfil_id: d.perfil_id,
    p_preventista_id: null,
    p_incluir_por_vencer: false,
    p_incluir_inactivos: false,
    p_limit: LIMITE_LISTA,
  });
  if (error) {
    await registrar(sb, d, fecha, "error", { stage: "datos", error: error.message });
    return { perfil_id: d.perfil_id, status: "error", reason: error.message };
  }

  // Mismo normalizador que el resumen diario: la RPC devuelve la forma de
  // `mis_atrasados`.
  const lista = normalizarDatos({ mis_atrasados: data }).mis_atrasados;
  if (lista.atrasados === 0) {
    await registrar(sb, d, fecha, "skipped", { motivo: "sin_atrasados" });
    return { perfil_id: d.perfil_id, status: "skipped", reason: "sin_atrasados" };
  }

  const texto = formatAvisoAtrasados(lista);
  const reply_markup = lista.clientes.length > 0
    ? buildVisitaKeyboard(lista.clientes.map((c) => ({ cliente_id: c.cliente_id, nombre: c.nombre })))
    : undefined;

  try {
    // Texto plano, como el resumen: un "_" en un nombre no tira el envío.
    await sendMessage(d.telegram_user_id, texto, reply_markup ? { reply_markup } : {});
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    await registrar(sb, d, fecha, "error", { stage: "telegram", error: msg });
    return { perfil_id: d.perfil_id, status: "error", reason: msg };
  }

  await registrar(sb, d, fecha, "ok");
  try {
    await logEvent({
      telegram_user_id: d.telegram_user_id,
      perfil_id: d.perfil_id,
      rol: "preventista",
      tipo: "respuesta",
      texto_bot: texto,
      resultado_meta: { aviso_atrasados: true, fecha, atrasados: lista.atrasados },
    });
  } catch (err) {
    console.error("[aviso atrasados] audit failed (non-fatal):", err instanceof Error ? err.message : err);
  }
  return { perfil_id: d.perfil_id, status: "ok" };
}

export function formatAvisoAtrasados(
  lista: ReturnType<typeof normalizarDatos>["mis_atrasados"],
): string {
  return `📋 Clientes que dejaron de comprar\n━━━━━━━━━━━━━━\n\n` +
    `Son los de tu cartera que llevan el doble de lo que suelen tardar en comprarte.\n\n` +
    formatListaAtrasados(lista);
}

async function registrar(
  sb: SupabaseClient,
  d: DestinatarioAviso,
  fecha: string,
  status: "ok" | "skipped" | "error",
  error_meta?: Record<string, unknown>,
): Promise<void> {
  const { error } = await sb.from("bot_avisos_atrasados_enviados").upsert(
    {
      perfil_id: d.perfil_id,
      fecha,
      telegram_user_id: d.telegram_user_id,
      status,
      error_meta: error_meta ?? null,
      sent_at: new Date().toISOString(),
    },
    { onConflict: "perfil_id,fecha" },
  );
  if (error) {
    console.error(`[aviso atrasados] registro failed (${d.perfil_id}, ${fecha}):`, error.message);
  }
}
