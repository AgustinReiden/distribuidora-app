// Carga de system prompts por rol.
//
// Los prompts se embeben como módulos TS (uno por rol) y se importan
// estáticamente. Razón: en el deploy de Supabase Edge Functions el bundler
// solo incluye archivos TS/JS, así que un Deno.readTextFile sobre un .txt
// resuelto via import.meta.url falla con "path not found" en producción.
// Los .ts viajan en el bundle siempre — esto es portable, type-safe y
// elimina permisos de --allow-read en runtime.
//
// API pública (`getSystemPrompt`, `setSystemPromptForTests`,
// `clearSystemPromptCache`) se mantiene compatible con los call sites previos
// para no romper tests ni callers.
//
// Nota — bloque de fecha: anteponemos a cada prompt default un encabezado
// dinámico con la fecha actual en TZ AR. Sin esto Gemini no tiene cómo
// resolver "ayer" / "esta semana" a un YYYY-MM-DD concreto y termina
// emitiendo function calls malformados (finishReason=MALFORMED_FUNCTION_CALL).
// Solo se prepende a los DEFAULTS — los overrides de tests quedan exactos.

import type { BotRol } from "../../types.ts";
import adminPrompt from "./admin.ts";
import preventistaPrompt from "./preventista.ts";
import transportistaPrompt from "./transportista.ts";
import encargadoPrompt from "./encargado.ts";
import depositoPrompt from "./deposito.ts";

const DEFAULTS: Record<BotRol, string> = {
  admin: adminPrompt,
  preventista: preventistaPrompt,
  transportista: transportistaPrompt,
  encargado: encargadoPrompt,
  deposito: depositoPrompt,
};

const TZ = "America/Argentina/Buenos_Aires";

// Overrides aplicables solo desde tests via setSystemPromptForTests.
const OVERRIDES = new Map<BotRol, string>();
// Override de "now" para tests deterministas (evita flakes por reloj).
let NOW_OVERRIDE: Date | null = null;

/**
 * Carga el system prompt para el rol del usuario. Async por compat con la
 * implementación previa basada en FS — el contenido viene de un módulo
 * importado estáticamente, no se va al disco.
 *
 * Para los DEFAULTS antepone un bloque con la fecha actual en TZ AR.
 * Los OVERRIDES de tests se devuelven tal cual (sin prefijo) para no
 * romper assertions exactas.
 */
// deno-lint-ignore require-await
export async function getSystemPrompt(rol: BotRol): Promise<string> {
  const override = OVERRIDES.get(rol);
  if (override !== undefined) return override;
  return buildDateContext() + "\n\n" + DEFAULTS[rol];
}

// ----------------------------------------------------------------------------
// Date context — calculado en TZ AR independientemente del reloj del runtime.
// ----------------------------------------------------------------------------

/**
 * Convierte un Date a {y, m, d, dow} en TZ AR. Usamos `Intl.DateTimeFormat`
 * con `formatToParts` porque Deno/V8 no expone una API directa para
 * "fecha calendario en otra timezone".
 */
function partsInTZ(date: Date): {
  y: number;
  m: number;
  d: number;
  dowEs: string;
} {
  const fmt = new Intl.DateTimeFormat("en-CA", {
    timeZone: TZ,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    weekday: "long",
  });
  const parts = fmt.formatToParts(date);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  const y = parseInt(get("year"), 10);
  const m = parseInt(get("month"), 10);
  const d = parseInt(get("day"), 10);
  const dowEn = get("weekday").toLowerCase();
  const dowMap: Record<string, string> = {
    monday: "lunes",
    tuesday: "martes",
    wednesday: "miércoles",
    thursday: "jueves",
    friday: "viernes",
    saturday: "sábado",
    sunday: "domingo",
  };
  return { y, m, d, dowEs: dowMap[dowEn] ?? dowEn };
}

function pad2(n: number): string {
  return n < 10 ? `0${n}` : String(n);
}

function isoFromYMD(y: number, m: number, d: number): string {
  return `${y}-${pad2(m)}-${pad2(d)}`;
}

function addDaysAR(y: number, m: number, d: number, days: number): {
  y: number;
  m: number;
  d: number;
} {
  // Anclamos al mediodía UTC para evitar saltos por DST cuando AR la tenía
  // (hoy AR no aplica DST, pero defendamos el helper). Mediodía UTC en
  // cualquier offset razonable cae en el mismo día calendario.
  const anchor = new Date(Date.UTC(y, m - 1, d, 12, 0, 0));
  anchor.setUTCDate(anchor.getUTCDate() + days);
  return partsInTZ(anchor);
}

/** Construye el bloque de contexto de fecha. Visible para tests. */
export function buildDateContext(now: Date = NOW_OVERRIDE ?? new Date()): string {
  const today = partsInTZ(now);
  const yesterday = addDaysAR(today.y, today.m, today.d, -1);
  // Lunes de esta semana. Intl day-of-week como número: usamos el nombre
  // y mapeamos.
  const dowIndex: Record<string, number> = {
    lunes: 0,
    martes: 1,
    miércoles: 2,
    jueves: 3,
    viernes: 4,
    sábado: 5,
    domingo: 6,
  };
  const offsetToMonday = -(dowIndex[today.dowEs] ?? 0);
  const monday = addDaysAR(today.y, today.m, today.d, offsetToMonday);

  const todayISO = isoFromYMD(today.y, today.m, today.d);
  const yesterdayISO = isoFromYMD(yesterday.y, yesterday.m, yesterday.d);
  const mondayISO = isoFromYMD(monday.y, monday.m, monday.d);
  const firstOfMonthISO = isoFromYMD(today.y, today.m, 1);
  // Hace 7 / 30 días (ventanas comunes).
  const minus7 = addDaysAR(today.y, today.m, today.d, -7);
  const minus30 = addDaysAR(today.y, today.m, today.d, -30);
  const minus7ISO = isoFromYMD(minus7.y, minus7.m, minus7.d);
  const minus30ISO = isoFromYMD(minus30.y, minus30.m, minus30.d);

  return [
    `CONTEXTO DE FECHA (zona horaria America/Argentina/Buenos_Aires):`,
    `- Hoy es ${today.dowEs}, ${todayISO}.`,
    `- Ayer fue ${yesterdayISO}.`,
    `- Esta semana: ${mondayISO} a ${todayISO} (lunes a hoy).`,
    `- Este mes: ${firstOfMonthISO} a ${todayISO}.`,
    `- Últimos 7 días: ${minus7ISO} a ${todayISO}.`,
    `- Últimos 30 días: ${minus30ISO} a ${todayISO}.`,
    ``,
    `Cuando el usuario use referencias relativas ("ayer", "hoy", "esta semana", "el mes pasado", "últimos N días"), traducí SIEMPRE a fechas ISO YYYY-MM-DD ANTES de armar la tool call. NUNCA pases strings como "ayer" o "esta semana" como argumento — las tools requieren YYYY-MM-DD literal.`,
  ].join("\n");
}

// ----------------------------------------------------------------------------
// Test seams
// ----------------------------------------------------------------------------

/** Override del prompt en memoria. Útil para tests sin tocar el FS. */
export function setSystemPromptForTests(rol: BotRol, text: string): void {
  OVERRIDES.set(rol, text);
}

/**
 * Limpia los overrides de tests. El nombre se mantiene por compat con los
 * tests existentes — ya no hay un "cache" propiamente dicho, los defaults
 * son constantes inmutables del módulo.
 */
export function clearSystemPromptCache(): void {
  OVERRIDES.clear();
  NOW_OVERRIDE = null;
}

/** Override de la fecha "actual" para tests deterministas. */
export function setNowForTests(now: Date | null): void {
  NOW_OVERRIDE = now;
}
