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
//     decide a quién le toca: desde su hora en adelante y si todavía no lo
//     recibió hoy (#1309), porque el cron horario de GitHub se saltea horas.
//   * Sin clientes atrasados no se manda nada: no hay novedad que avisar.
//
// Idempotencia en `bot_avisos_atrasados_enviados` (perfil, fecha), con la marca
// tomada antes de mandar (`bot_aviso_atrasados_reservar`): el cron corre cada
// hora y dos corridas a la vez no duplican el mensaje.

import type { SupabaseClient } from "@supabase/supabase-js";
import { sendMessage } from "../_shared/telegram.ts";
import { logEvent } from "../_shared/audit.ts";
import { buildVisitaKeyboard } from "../_shared/telegram-keyboards.ts";
import { formatListaAtrasados, normalizarDatos } from "./preventista.ts";

export interface DestinatarioAviso {
  telegram_user_id: number;
  perfil_id: string;
  sucursal_id: number;
  /**
   * Todas sus sucursales vivas (#1552, B-3). La RPC devuelve una fila por
   * sucursal, como el resumen diario, y la marca es una por perfil y día: las
   * de un mismo perfil van en un solo mensaje. Sin esto, la de `sucursal_id`.
   */
  sucursales?: Array<{ id: number; nombre: string | null }>;
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
  // Una fila por perfil y sucursal viva (#1552, B-3): se juntan por perfil,
  // porque la marca de enviado es por perfil y día.
  const porPerfil = new Map<string, DestinatarioAviso>();
  for (const d of (data ?? []) as Array<Record<string, unknown>>) {
    const perfil_id = String(d.perfil_id);
    const sucursal = {
      id: Number(d.sucursal_id),
      nombre: typeof d.sucursal_nombre === "string" ? d.sucursal_nombre : null,
    };
    const previo = porPerfil.get(perfil_id);
    if (previo) {
      if (!previo.sucursales!.some((s) => s.id === sucursal.id)) previo.sucursales!.push(sucursal);
    } else {
      porPerfil.set(perfil_id, {
        telegram_user_id: Number(d.telegram_user_id),
        perfil_id,
        sucursal_id: sucursal.id,
        sucursales: [sucursal],
      });
    }
  }
  const destinatarios = [...porPerfil.values()];
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
  // La marca se toma antes de mandar (#1309): de dos corridas a la vez, una
  // sola manda. Un 'error' anterior se retoma; 'enviando', 'ok' y 'skipped', no.
  // Si la base no contesta, no se manda: sin marca, la próxima corrida lo haría
  // de nuevo.
  const { data: reservado, error: errReserva } = await sb.rpc("bot_aviso_atrasados_reservar", {
    p_perfil_id: d.perfil_id,
    p_fecha: fecha,
    p_telegram_user_id: d.telegram_user_id,
  });
  if (errReserva) {
    console.error(`[aviso atrasados] reserva failed (${d.perfil_id}, ${fecha}):`, errReserva.message);
    return { perfil_id: d.perfil_id, status: "error", reason: errReserva.message };
  }
  if (reservado !== true) {
    return { perfil_id: d.perfil_id, status: "skipped", reason: "ya_procesado" };
  }

  // Una lista por cada sucursal viva (#1552, B-3), en un solo mensaje.
  const sucursales = d.sucursales?.length ? d.sucursales : [{ id: d.sucursal_id, nombre: null }];
  const secciones: Array<{
    sucursal: { id: number; nombre: string | null };
    lista: ReturnType<typeof normalizarDatos>["mis_atrasados"];
  }> = [];
  for (const sucursal of sucursales) {
    const { data, error } = await sb.rpc("bot_clientes_atrasados", {
      p_sucursal_id: sucursal.id,
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
    if (lista.atrasados > 0) secciones.push({ sucursal, lista });
  }
  if (secciones.length === 0) {
    await registrar(sb, d, fecha, "skipped", { motivo: "sin_atrasados" });
    return { perfil_id: d.perfil_id, status: "skipped", reason: "sin_atrasados" };
  }

  // Con una sola sucursal, el mensaje de siempre. Con varias, cada lista dice
  // de qué sucursal es, como el resumen diario (#1309).
  const conNombre = sucursales.length > 1;
  const textos = secciones.map((s) => {
    const lista = formatListaAtrasados(s.lista);
    return conNombre ? `🏢 ${s.sucursal.nombre ?? `Sucursal ${s.sucursal.id}`}\n${lista}` : lista;
  });
  const texto = encabezadoAviso() + textos.join("\n\n");
  const clientes = secciones.flatMap((s) => s.lista.clientes);
  const reply_markup = clientes.length > 0
    ? buildVisitaKeyboard(clientes.map((c) => ({ cliente_id: c.cliente_id, nombre: c.nombre })))
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
  // Una fila del registro por sucursal, con su sucursal: el panel del bot
  // muestra cada evento a los admins de la sucursal del evento (#1552, B-4).
  for (let i = 0; i < secciones.length; i++) {
    try {
      await logEvent({
        telegram_user_id: d.telegram_user_id,
        perfil_id: d.perfil_id,
        rol: "preventista",
        tipo: "respuesta",
        texto_bot: secciones.length === 1 ? texto : encabezadoAviso() + textos[i],
        resultado_meta: {
          aviso_atrasados: true,
          fecha,
          sucursal_id: secciones[i].sucursal.id,
          atrasados: secciones[i].lista.atrasados,
        },
      });
    } catch (err) {
      console.error("[aviso atrasados] audit failed (non-fatal):", err instanceof Error ? err.message : err);
    }
  }
  return { perfil_id: d.perfil_id, status: "ok" };
}

function encabezadoAviso(): string {
  return `📋 Clientes que dejaron de comprar\n━━━━━━━━━━━━━━\n\n` +
    `Son los de tu cartera que llevan el doble de lo que suelen tardar en comprarte.\n\n`;
}

export function formatAvisoAtrasados(
  lista: ReturnType<typeof normalizarDatos>["mis_atrasados"],
): string {
  return encabezadoAviso() + formatListaAtrasados(lista);
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
