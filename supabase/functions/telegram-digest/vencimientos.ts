// Aviso de lotes en vencimiento crítico (#565).
//
// Es una lista operativa (producto, cantidad restante, fecha, días), no una
// narrativa: NO pasa por Gemini. Responsabilidades:
//   - fetchLotesCriticos: lee el umbral de `politicas_comerciales` y llama a
//     `bot_reporte_vencimientos` (mig 255, service_role-only) con ese horizonte.
//   - formatVencimientosTexto: función pura, arma el texto a partir de las
//     filas. Sin I/O — así se testea sin mockear Supabase.
//   - runAvisosVencimiento: resuelve destinatarios (encargado/depósito
//     vinculados y activos, uno por sucursal asignada EN VIVO) y les manda el
//     aviso con idempotencia en `bot_avisos_vencimiento_enviados`.
//
// Vive separado de `index.ts` por lo mismo que `digest.ts`: `index.ts` llama
// `serve()` al importarse, así que todo lo que necesite un test con un
// cliente mockeado tiene que vivir en un módulo que no dispare eso.

import type { SupabaseClient } from "@supabase/supabase-js";
import { sendMessage } from "../_shared/telegram.ts";

export interface VencimientoRow {
  producto_nombre: string;
  producto_codigo: string;
  cantidad_restante: number;
  /** YYYY-MM-DD */
  fecha_vencimiento: string;
  dias_restantes: number;
}

// Mismo default que la columna (mig 223): sin fila en politicas_comerciales
// para la sucursal, "sin política" es el default de la columna, no 0 —0
// sería "todo es crítico" y silenciaría el aviso a fuerza de ruido.
const DIAS_CRITICO_DEFAULT = 15;

/**
 * Lee `dias_critico_vencimiento` de `politicas_comerciales` para la sucursal
 * y llama a `bot_reporte_vencimientos` con ese horizonte. Devuelve las filas
 * tal como las ordena la RPC (fecha_vencimiento ASC, producto_nombre ASC).
 * Lanza si falla la lectura de la política o la RPC — el caller decide si
 * es best-effort.
 */
export async function fetchLotesCriticos(
  sb: SupabaseClient,
  sucursal_id: number,
): Promise<VencimientoRow[]> {
  const { data: politica, error: errPolitica } = await sb
    .from("politicas_comerciales")
    .select("dias_critico_vencimiento")
    .eq("sucursal_id", sucursal_id)
    .maybeSingle();

  if (errPolitica) {
    throw new Error(`politicas_comerciales lookup failed: ${errPolitica.message}`);
  }

  const row = politica as { dias_critico_vencimiento?: number } | null;
  const dias_horizonte = row?.dias_critico_vencimiento ?? DIAS_CRITICO_DEFAULT;

  const { data, error } = await sb.rpc("bot_reporte_vencimientos", {
    p_sucursal_id: sucursal_id,
    p_dias_horizonte: dias_horizonte,
  });

  if (error) {
    throw new Error(`bot_reporte_vencimientos failed: ${error.message}`);
  }

  return (data ?? []) as VencimientoRow[];
}

/**
 * Arma el texto del aviso a partir de las filas de `bot_reporte_vencimientos`.
 * null si no hay lotes: "sin críticos" es "no hay nada que avisar", no un
 * mensaje vacío.
 */
export function formatVencimientosTexto(rows: VencimientoRow[]): string | null {
  if (rows.length === 0) return null;

  const ordenadas = [...rows].sort((a, b) =>
    a.fecha_vencimiento === b.fecha_vencimiento
      ? a.producto_nombre.localeCompare(b.producto_nombre, "es")
      : a.fecha_vencimiento.localeCompare(b.fecha_vencimiento)
  );

  const lineas = ordenadas.map((r) => {
    const dias = r.dias_restantes < 0
      ? `vencido hace ${Math.abs(r.dias_restantes)}d`
      : r.dias_restantes === 0
      ? "vence hoy"
      : `vence en ${r.dias_restantes}d`;
    return `• ${r.producto_nombre} (${r.producto_codigo}) — ${r.cantidad_restante} u. — ${
      formatFechaLegible(r.fecha_vencimiento)
    } (${dias})`;
  });

  return `⚠️ Lotes en vencimiento crítico\n━━━━━━━━━━━━━━\n\n${lineas.join("\n")}`;
}

/** YYYY-MM-DD → dd/mm/yyyy en TZ ART. Defensivo: si no parsea, devuelve la string original. */
function formatFechaLegible(fecha: string): string {
  const d = new Date(`${fecha}T12:00:00Z`);
  if (Number.isNaN(d.getTime())) return fecha;
  const fmt = new Intl.DateTimeFormat("es-AR", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    timeZone: "America/Argentina/Buenos_Aires",
  });
  return fmt.format(d);
}

// ============================================================================
// Destinatarios operativos (encargado/depósito) + envío con idempotencia
// ============================================================================

export interface OperativoDestinatario {
  telegram_user_id: number;
  perfil_id: string;
  sucursal_id: number;
}

export interface AvisoVencimientoResult {
  perfil_id: string;
  sucursal_id: number;
  status: "sent" | "skipped" | "error";
  reason?: string;
}

/**
 * Resuelve los destinatarios operativos (encargado/depósito) vinculados y
 * activos al bot, uno por cada sucursal que tengan asignada EN VIVO en
 * `usuario_sucursales` — no el snapshot `bot_usuarios.sucursal_id`, que es
 * una sola sucursal "activa" pensada para el switch de /sucursal, no para
 * enumerar todas las asignaciones (igual que `resolveUserByTelegramId` en
 * `_shared/auth.ts`, que tampoco confía en el snapshot).
 */
export async function resolverDestinatariosOperativos(
  sb: SupabaseClient,
): Promise<OperativoDestinatario[]> {
  const { data: usuarios, error } = await sb
    .from("bot_usuarios")
    .select("telegram_user_id, perfil_id, perfiles!inner(rol, activo)")
    .eq("activo", true)
    .in("perfiles.rol", ["encargado", "deposito"])
    .eq("perfiles.activo", true);

  if (error) {
    throw new Error(`resolverDestinatariosOperativos: bot_usuarios lookup failed: ${error.message}`);
  }

  const destinatarios: OperativoDestinatario[] = [];
  for (const raw of usuarios ?? []) {
    const row = raw as Record<string, unknown>;
    const perfil_id = String(row.perfil_id);
    const telegram_user_id = Number(row.telegram_user_id);

    const { data: asignadas, error: errAsignadas } = await sb
      .from("usuario_sucursales")
      .select("sucursal_id, sucursales!inner(id, activa)")
      .eq("usuario_id", perfil_id);

    if (errAsignadas) {
      throw new Error(
        `resolverDestinatariosOperativos: usuario_sucursales lookup failed (perfil_id=${perfil_id}): ${errAsignadas.message}`,
      );
    }

    type AsignadaRow = { sucursal_id: number; sucursales: { id: number; activa: boolean } | null };
    for (const a of (asignadas ?? []) as unknown as AsignadaRow[]) {
      if (!a.sucursales?.activa) continue;
      destinatarios.push({ telegram_user_id, perfil_id, sucursal_id: a.sucursales.id });
    }
  }
  return destinatarios;
}

/**
 * Manda el aviso de vencimiento crítico a cada destinatario operativo, una
 * vez por (perfil, sucursal, fecha). Nunca lanza — cada destinatario se
 * procesa con Promise.allSettled, igual que los admins del digest, para que
 * el fallo de uno no pinche al resto.
 */
export async function runAvisosVencimiento(
  sb: SupabaseClient,
  fecha: string,
): Promise<AvisoVencimientoResult[]> {
  let destinatarios: OperativoDestinatario[];
  try {
    destinatarios = await resolverDestinatariosOperativos(sb);
  } catch (err) {
    console.error(
      "[digest] resolverDestinatariosOperativos failed:",
      err instanceof Error ? err.message : String(err),
    );
    return [];
  }

  const tasks = destinatarios.map((d) => enviarAvisoVencimiento(sb, d, fecha));
  const results = await Promise.allSettled(tasks);

  return results.map((r, i) => {
    const d = destinatarios[i];
    if (r.status === "fulfilled") return r.value;
    return {
      perfil_id: d.perfil_id,
      sucursal_id: d.sucursal_id,
      status: "error" as const,
      reason: r.reason instanceof Error ? r.reason.message : String(r.reason),
    };
  });
}

/**
 * Idempotencia (select contra `bot_avisos_vencimiento_enviados`) + fetch de
 * lotes críticos + envío + registro. Sin lotes críticos no manda nada y NO
 * registra: no hubo envío que deduplicar, y un lote que aparezca más tarde
 * el mismo día todavía puede avisar en un reintento manual.
 */
export async function enviarAvisoVencimiento(
  sb: SupabaseClient,
  destinatario: OperativoDestinatario,
  fecha: string,
): Promise<AvisoVencimientoResult> {
  const { telegram_user_id, perfil_id, sucursal_id } = destinatario;
  const base = { perfil_id, sucursal_id };

  const { data: existente, error: errExistente } = await sb
    .from("bot_avisos_vencimiento_enviados")
    .select("perfil_id")
    .eq("perfil_id", perfil_id)
    .eq("sucursal_id", sucursal_id)
    .eq("fecha", fecha)
    .maybeSingle();

  if (errExistente) {
    return { ...base, status: "error", reason: errExistente.message };
  }
  if (existente) {
    return { ...base, status: "skipped", reason: "already_sent" };
  }

  let lotes: VencimientoRow[];
  try {
    lotes = await fetchLotesCriticos(sb, sucursal_id);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return { ...base, status: "error", reason: msg };
  }

  const texto = formatVencimientosTexto(lotes);
  if (!texto) {
    return { ...base, status: "skipped", reason: "sin_lotes_criticos" };
  }

  try {
    await sendMessage(telegram_user_id, texto);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return { ...base, status: "error", reason: msg };
  }

  const { error: errInsert } = await sb.from("bot_avisos_vencimiento_enviados").insert({
    perfil_id,
    sucursal_id,
    fecha,
  });
  if (errInsert) {
    console.error(
      `[digest] bot_avisos_vencimiento_enviados insert failed (perfil_id=${perfil_id}, sucursal_id=${sucursal_id}, fecha=${fecha}):`,
      errInsert.message,
    );
  }

  return { ...base, status: "sent" };
}
