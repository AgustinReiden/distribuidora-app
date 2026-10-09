// Resumen de la mañana del PREVENTISTA (mig 311).
//
// A diferencia del del admin, éste no pasa por ningún modelo: lo arma un
// formatter con lo que devuelve `bot_digest_preventista` (que a su vez consume
// `bot_mis_ventas` y `bot_clientes_atrasados`, las mismas que contestan en el
// chat). Cuesta cero de IA y no puede inventar un número.
//
// Qué lleva, según las secciones que tenga prendidas:
//   * mis_ventas    — los pedidos que tomó ayer (todavía no son venta: la
//                     mayoría se entrega al día siguiente) y lo vendido en el
//                     mes (la venta de la 241: entregado, sin canjes, por fecha).
//   * mis_atrasados — sus clientes atrasados con la plata en juego, y un botón
//                     por cliente que abre el resumen de visita (tampoco usa IA).
//
// Sólo lo suyo: su cartera y sus montos. Nada de la sucursal.
//
// Idempotencia y registro en `bot_digests_enviados`, igual que el del admin
// (la PK es (perfil, fecha); la columna se llama admin_perfil_id por historia).

import type { SupabaseClient } from "@supabase/supabase-js";
import { sendMessage } from "../_shared/telegram.ts";
import { logEvent } from "../_shared/audit.ts";
import { formatCurrency } from "../_shared/format.ts";
import { buildVisitaKeyboard } from "../_shared/telegram-keyboards.ts";

export interface DigestPreventistaArgs {
  telegram_user_id: number;
  perfil_id: string;
  sucursal_id: number | null;
  /** YYYY-MM-DD — el día a resumir ("ayer" en ART). */
  fecha: string;
  secciones: readonly string[];
}

export interface DigestPreventistaResult {
  status: "ok" | "skipped" | "error";
  reason?: string;
}

export interface AtrasadoDigest {
  cliente_id: number;
  nombre: string;
  dias_sin_comprar: number | null;
  frecuencia_dias: number | null;
  monto_mensual: number;
}

export interface DatosDigestPreventista {
  mis_ventas: {
    dia_tomados_pedidos: number;
    dia_tomados_total: number;
    mes_total: number;
    mes_pedidos: number;
    mes_clientes: number;
  };
  mis_atrasados: {
    clientes_en_cartera: number;
    atrasados: number;
    monto_mensual_en_riesgo: number;
    clientes: AtrasadoDigest[];
  };
}

export async function runDigestForPreventista(
  sb: SupabaseClient,
  args: DigestPreventistaArgs,
): Promise<DigestPreventistaResult> {
  const { telegram_user_id, perfil_id, sucursal_id, fecha, secciones } = args;

  if (sucursal_id == null) {
    // bot_digest_destinatarios ya los filtra; esto es por si alguien llama
    // directo. Sin sucursal no hay cartera que contar.
    return { status: "skipped", reason: "sin_sucursal" };
  }

  const { data: existente } = await sb
    .from("bot_digests_enviados")
    .select("status")
    .eq("admin_perfil_id", perfil_id)
    .eq("fecha", fecha)
    .maybeSingle();
  if ((existente as { status?: string } | null)?.status === "ok") {
    return { status: "skipped", reason: "already_sent" };
  }

  const { data, error } = await sb.rpc("bot_digest_preventista", {
    p_perfil_id: perfil_id,
    p_sucursal_id: sucursal_id,
    p_fecha: fecha,
  });
  if (error) {
    await registrarEnvio(sb, perfil_id, fecha, telegram_user_id, "error", {
      stage: "datos",
      error: error.message,
    });
    return { status: "error", reason: error.message };
  }

  const datos = normalizarDatos(data);
  const texto = formatDigestPreventista(fecha, datos, secciones);
  if (!texto) {
    return { status: "skipped", reason: "sin_contenido" };
  }

  const clientes = secciones.includes("mis_atrasados") ? datos.mis_atrasados.clientes : [];
  const reply_markup = clientes.length > 0
    ? buildVisitaKeyboard(clientes.map((c) => ({ cliente_id: c.cliente_id, nombre: c.nombre })))
    : undefined;

  try {
    await sendMessage(telegram_user_id, texto, reply_markup ? { reply_markup } : {});
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    await registrarEnvio(sb, perfil_id, fecha, telegram_user_id, "error", {
      stage: "telegram",
      error: msg,
    });
    return { status: "error", reason: msg };
  }

  await registrarEnvio(sb, perfil_id, fecha, telegram_user_id, "ok");

  try {
    await logEvent({
      telegram_user_id,
      perfil_id,
      rol: "preventista",
      tipo: "respuesta",
      texto_bot: texto,
      resultado_meta: { digest: true, fecha, sucursal_id, secciones: [...secciones] },
    });
  } catch (auditErr) {
    console.error(
      "[digest preventista] audit log failed (non-fatal):",
      auditErr instanceof Error ? auditErr.message : String(auditErr),
    );
  }

  return { status: "ok" };
}

export function normalizarDatos(data: unknown): DatosDigestPreventista {
  const r = (data ?? {}) as Record<string, unknown>;
  const v = (r.mis_ventas ?? {}) as Record<string, unknown>;
  const a = (r.mis_atrasados ?? {}) as Record<string, unknown>;
  const filas = (Array.isArray(a.clientes) ? a.clientes : []) as Array<Record<string, unknown>>;
  const num = (x: unknown) => (x == null ? null : Number(x));
  return {
    mis_ventas: {
      dia_tomados_pedidos: Number(v.dia_tomados_pedidos ?? 0),
      dia_tomados_total: Number(v.dia_tomados_total ?? 0),
      mes_total: Number(v.mes_total ?? 0),
      mes_pedidos: Number(v.mes_pedidos ?? 0),
      mes_clientes: Number(v.mes_clientes ?? 0),
    },
    mis_atrasados: {
      clientes_en_cartera: Number(a.clientes_en_cartera ?? 0),
      atrasados: Number(a.atrasados ?? 0),
      monto_mensual_en_riesgo: Number(a.monto_mensual_en_riesgo ?? 0),
      clientes: filas.map((c) => ({
        cliente_id: Number(c.cliente_id),
        nombre: String(c.nombre ?? "(sin nombre)"),
        dias_sin_comprar: num(c.dias_sin_comprar),
        frecuencia_dias: num(c.frecuencia_dias),
        monto_mensual: Number(c.monto_mensual ?? 0),
      })),
    },
  };
}

/**
 * El mensaje en texto plano (sin parse_mode, como el del admin: un nombre de
 * cliente con un guión bajo no puede tirar el envío entero). Devuelve null si
 * no quedó ninguna sección que mostrar.
 */
export function formatDigestPreventista(
  fecha: string,
  d: DatosDigestPreventista,
  secciones: readonly string[],
): string | null {
  const bloques: string[] = [];

  if (secciones.includes("mis_ventas")) {
    const v = d.mis_ventas;
    const ayer = v.dia_tomados_pedidos > 0
      ? `Ayer tomaste ${v.dia_tomados_pedidos} ${v.dia_tomados_pedidos === 1 ? "pedido" : "pedidos"} por ${
        formatCurrency(v.dia_tomados_total)
      }.`
      : "Ayer no tomaste pedidos.";
    // El mes de AYER, con nombre: el 1° el resumen habla del mes anterior y
    // "en el mes" se leería como el que recién empieza.
    const mes = `Vendido en ${nombreMes(fecha)} (entregado): ${formatCurrency(v.mes_total)} en ${v.mes_pedidos} ${
      v.mes_pedidos === 1 ? "pedido" : "pedidos"
    } a ${v.mes_clientes} ${v.mes_clientes === 1 ? "cliente" : "clientes"}.`;
    bloques.push(`💵 Tus ventas\n${ayer}\n${mes}`);
  }

  if (secciones.includes("mis_atrasados")) {
    const a = d.mis_atrasados;
    if (a.atrasados === 0) {
      bloques.push(`✅ Ningún cliente atrasado en tu cartera (${a.clientes_en_cartera} clientes).`);
    } else {
      bloques.push(formatListaAtrasados(a));
    }
  }

  if (bloques.length === 0) return null;
  return `🌅 Tu resumen ${formatFechaLegible(fecha)}\n━━━━━━━━━━━━━━\n\n${bloques.join("\n\n")}`;
}

/**
 * La lista de clientes atrasados con la plata en juego. La comparten el
 * resumen diario (sección mis_atrasados) y el aviso semanal (atrasados.ts):
 * un solo formato para el mismo dato.
 */
export function formatListaAtrasados(a: DatosDigestPreventista["mis_atrasados"]): string {
  const lineas = a.clientes.map((c, i) => {
    const ritmo = c.dias_sin_comprar == null
      ? "sin compras en el año"
      : c.frecuencia_dias
      ? `${c.dias_sin_comprar} días sin comprar (compraba cada ~${Math.round(c.frecuencia_dias)})`
      : `${c.dias_sin_comprar} días sin comprar`;
    const plata = c.monto_mensual > 0 ? ` — ${formatCurrency(c.monto_mensual)}/mes` : "";
    return `${i + 1}. ${c.nombre}: ${ritmo}${plata}`;
  });
  const mas = a.atrasados > a.clientes.length
    ? `\n…y ${a.atrasados - a.clientes.length} más: /atrasados`
    : "";
  return `🔴 ${a.atrasados} ${a.atrasados === 1 ? "cliente atrasado" : "clientes atrasados"}` +
    ` — te compraban ${formatCurrency(a.monto_mensual_en_riesgo)} por mes\n` +
    `${lineas.join("\n")}${mas}\n\nTocá un cliente para ver qué ofrecerle.`;
}

async function registrarEnvio(
  sb: SupabaseClient,
  perfil_id: string,
  fecha: string,
  telegram_user_id: number,
  status: "ok" | "error",
  error_meta?: Record<string, unknown>,
): Promise<void> {
  const { error } = await sb.from("bot_digests_enviados").upsert(
    {
      admin_perfil_id: perfil_id,
      fecha,
      sent_at: new Date().toISOString(),
      telegram_user_id,
      status,
      error_meta: error_meta ?? null,
    },
    { onConflict: "admin_perfil_id,fecha" },
  );
  if (error) {
    console.error(
      `[digest preventista] bot_digests_enviados upsert failed (perfil_id=${perfil_id}, fecha=${fecha}):`,
      error.message,
    );
  }
}

/** "octubre" para una fecha YYYY-MM-DD (el mes del día resumido). */
function nombreMes(fecha: string): string {
  const d = new Date(`${fecha}T12:00:00Z`);
  if (Number.isNaN(d.getTime())) return "el mes";
  return new Intl.DateTimeFormat("es-AR", { month: "long", timeZone: "America/Argentina/Buenos_Aires" })
    .format(d);
}

/** "lun 27/04/2026", en TZ Argentina. Mismo formato que el resumen del admin. */
function formatFechaLegible(fecha: string): string {
  const d = new Date(`${fecha}T12:00:00Z`);
  if (Number.isNaN(d.getTime())) return fecha;
  const fmt = new Intl.DateTimeFormat("es-AR", {
    weekday: "short",
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    timeZone: "America/Argentina/Buenos_Aires",
  });
  return fmt.format(d).replace(/\./g, "").replace(",", "");
}
