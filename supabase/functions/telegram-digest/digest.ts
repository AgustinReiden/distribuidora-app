// Lógica del digest ejecutivo diario por admin.
//
// Para cada (admin, sucursal) al que le toca el flujo es:
//   1. Tomar la marca ANTES de mandar (marca.ts, #1309): si otra corrida ya la
//      tiene, o ya salió, skip. Es la idempotencia y lo que evita el doble envío.
//   2. Llamar RPC bot_metricas_admin_dia(p_fecha, p_sucursal_id) → JSON.
//   3. Armar el texto con plantilla (admin.ts, #1041): sin modelo, cero costo
//      y ningún número reescrito. Antes lo redactaba Gemini 2.5 Flash, que
//      Google está retirando.
//   4. Enviar el mensaje a Telegram (plain text, sin Markdown: un nombre con
//      un guión bajo no puede tirar el envío entero).
//   5. Cerrar la marca con status='ok'/'error'/'skipped' y error_meta con
//      `stage` para distinguir si falló la RPC o Telegram.
//   6. Audit log (best-effort) en bot_audit_log.
//
// Cualquier error en el flujo se persiste en bot_digests_enviados con
// status='error' y un objeto error_meta con `{stage, error}` para post-mortem.
// El error NO se propaga al caller — runDigestForAdmin retorna un DigestResult
// para que el index.ts pueda hacer el resumen sin que un admin con problema
// pinche al resto.

import type { SupabaseClient } from "@supabase/supabase-js";
import { sendMessage } from "../_shared/telegram.ts";
import { logEvent } from "../_shared/audit.ts";
import { formatMetricasAdmin } from "./admin.ts";
import { fetchLotesCriticos, formatVencimientosTexto } from "./vencimientos.ts";
import {
  filtrarMetricas,
  incluyeRiesgoPreventistas,
  incluyeVencimientos,
  tieneSeccionesDeMetricas,
} from "./secciones.ts";
import { fetchRiesgoPorPreventista, formatRiesgoTexto } from "./riesgo.ts";
import {
  esChatInaccesible,
  type MarcaDigest,
  registrarDigest,
  reservarDigest,
} from "./marca.ts";

export interface DigestArgs {
  telegram_user_id: number;
  perfil_id: string;
  /**
   * La sucursal que se resume (#1309): una de las asignadas al perfil, no la
   * de /sucursal. `bot_digest_pendientes` nunca la manda en NULL; NULL no es
   * "la Red" y no se resume nada.
   */
  sucursal_id: number | null;
  /** Para el encabezado: el resumen dice de qué sucursal es. */
  sucursal_nombre?: string | null;
  /** YYYY-MM-DD — fecha del día a resumir (típicamente "ayer" en ART). */
  fecha: string;
  /**
   * Secciones que este admin eligió recibir (`bot_digest_config.secciones`,
   * #691).
   * Ver `secciones.ts`. Si no viene, el default reproduce el digest previo a
   * que la configuración existiera — para que un caller viejo no cambie de
   * comportamiento por omisión.
   */
  secciones?: readonly string[];
}

export interface DigestResult {
  status: "ok" | "skipped" | "error";
  reason?: string;
}

/**
 * Ejecuta el digest para un admin: idempotencia + RPC + plantilla + Telegram +
 * registro en bot_digests_enviados. Nunca lanza — retorna DigestResult.
 */
export async function runDigestForAdmin(
  sb: SupabaseClient,
  args: DigestArgs,
): Promise<DigestResult> {
  const { telegram_user_id, perfil_id, sucursal_id, fecha } = args;
  // Default = el juego de secciones que armaba el prompt antes de que la
  // configuración existiera. Mismo default que la tabla y que las RPCs, para
  // que "sin fila de config" signifique lo mismo en los tres lados.
  const secciones = args.secciones ??
    ["ventas", "top_clientes", "stock_critico", "deuda", "vencimientos"];

  if (sucursal_id == null) {
    // bot_digest_pendientes no los manda; esto es por si alguien llama directo.
    // Sin sucursal no hay resumen: NULL no es la Red (#1309).
    return { status: "skipped", reason: "sin_sucursal" };
  }

  // 0. La marca, antes de mandar (#1309). Si ya salió, o la tiene otra corrida,
  //    skip. Una marca en 'error' se retoma.
  const marca: MarcaDigest = { perfil_id, sucursal_id, fecha, telegram_user_id };
  if (!(await reservarDigest(sb, marca))) {
    return { status: "skipped", reason: "already_sent" };
  }

  // 1. Métricas via RPC + 2. plantilla.
  //
  // Condicional: un admin que dejó prendida sólo la sección de vencimientos no
  // necesita las métricas del día. El bloque de lotes se arma abajo aparte.
  let texto = "";
  if (tieneSeccionesDeMetricas(secciones)) {
    const { data: metricas, error: errMetricas } = await sb.rpc(
      "bot_metricas_admin_dia",
      { p_fecha: fecha, p_sucursal_id: sucursal_id },
    );

    if (errMetricas) {
      await registrarDigest(sb, marca, "error", {
        stage: "metricas",
        error: errMetricas.message,
      });
      return { status: "error", reason: errMetricas.message };
    }

    // Sólo las claves de las secciones prendidas: la plantilla no nombra lo
    // que no recibe.
    texto = formatMetricasAdmin(filtrarMetricas(metricas, secciones));
  }

  // 3a. Plata en riesgo por preventista (mig 311). Mismo trato que la de
  // lotes: best-effort, y si no hay atrasados no aparece.
  let riesgoSuffix = "";
  if (incluyeRiesgoPreventistas(secciones)) {
    try {
      const textoRiesgo = formatRiesgoTexto(await fetchRiesgoPorPreventista(sb, sucursal_id));
      if (textoRiesgo) riesgoSuffix = `\n\n${textoRiesgo}`;
    } catch (err) {
      console.error(
        "[digest] riesgo por preventista failed (non-fatal):",
        err instanceof Error ? err.message : String(err),
      );
    }
  }

  // 3b. Sección de lotes críticos (#565), best-effort: si falla la lectura
  // no rompemos el digest — el admin igual recibe su resumen. Se pega al
  // final.
  let vencimientosSuffix = "";
  if (incluyeVencimientos(secciones)) {
    try {
      const lotes = await fetchLotesCriticos(sb, sucursal_id);
      const textoVencimientos = formatVencimientosTexto(lotes);
      if (textoVencimientos) {
        vencimientosSuffix = `\n\n${textoVencimientos}`;
      }
    } catch (err) {
      console.error(
        "[digest] fetchLotesCriticos failed (non-fatal):",
        err instanceof Error ? err.message : String(err),
      );
    }
  }

  // 3c. Si no quedo nada que contar, no mandamos un mensaje con solo el
  // header. Pasa cuando la unica seccion prendida es `vencimientos` y ese
  // dia no hay ningun lote por vencer. Se cierra la marca como 'skipped': el
  // resumen de ese dia ya se evaluo, y el gate lo cuenta como hecho.
  const cuerpo = `${texto}${riesgoSuffix}${vencimientosSuffix}`.trim();
  if (!cuerpo) {
    await registrarDigest(sb, marca, "skipped", { motivo: "sin_contenido" });
    return { status: "skipped", reason: "sin_contenido" };
  }

  // 4. Telegram (plain text, sin parse_mode).
  // Header con emoji + fecha legible ("lun 27/04/2026" en vez de
  // "2026-04-27"), después divider, después las métricas, después (si
  // hay) la sección de vencimientos críticos. El header nombra la sucursal
  // (#1309): el admin con dos sucursales recibe dos resúmenes.
  const mensaje = `${encabezadoDigest(fecha, args.sucursal_nombre)}\n` +
    `━━━━━━━━━━━━━━\n\n${cuerpo}`;
  try {
    await sendMessage(telegram_user_id, mensaje);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    // Un 403 (bloqueó el bot) no se reintenta: ver esChatInaccesible.
    await registrarDigest(sb, marca, esChatInaccesible(err) ? "skipped" : "error", {
      stage: "telegram",
      error: msg,
    });
    return { status: "error", reason: msg };
  }

  // 5. Registrar OK.
  await registrarDigest(sb, marca, "ok");

  // 6. Audit log (best-effort: si falla no rompemos el digest).
  try {
    await logEvent({
      telegram_user_id,
      perfil_id,
      rol: "admin",
      tipo: "respuesta",
      texto_bot: texto,
      resultado_meta: { digest: true, fecha, sucursal_id },
    });
  } catch (auditErr) {
    console.error(
      "[digest] audit log failed (non-fatal):",
      auditErr instanceof Error ? auditErr.message : String(auditErr),
    );
  }

  return { status: "ok" };
}

/**
 * "🌅 Resumen lun 27/04/2026 · Tucumán" (#1309: el resumen dice de qué
 * sucursal es). Sin nombre, sólo la fecha.
 */
export function encabezadoDigest(fecha: string, sucursalNombre?: string | null): string {
  const nombre = sucursalNombre?.trim();
  return `🌅 Resumen ${formatFechaLegible(fecha)}${nombre ? ` · ${nombre}` : ""}`;
}

/**
 * Formatea YYYY-MM-DD como "lun 27/04/2026" para el header del digest.
 * Si la fecha no parsea, devuelve la string original (defensivo: nunca
 * queremos que un fallo de Date parsing dropee el mensaje entero).
 *
 * Usamos `Intl.DateTimeFormat` con timeZone explícita ART para evitar que
 * el runtime del Edge interprete YYYY-MM-DD como UTC y devuelva el día
 * anterior en zonas con offset negativo.
 */
function formatFechaLegible(fecha: string): string {
  // Construimos la fecha como UTC mediodía para sortear bordes de TZ —
  // el día calendario es el mismo en cualquier TZ razonable.
  const d = new Date(`${fecha}T12:00:00Z`);
  if (Number.isNaN(d.getTime())) return fecha;
  const fmt = new Intl.DateTimeFormat("es-AR", {
    weekday: "short",
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    timeZone: "America/Argentina/Buenos_Aires",
  });
  // Salida: "lun., 27/04/2026" — limpiamos el punto del weekday corto y la
  // coma para que quede "lun 27/04/2026".
  return fmt.format(d).replace(/\./g, "").replace(",", "");
}
