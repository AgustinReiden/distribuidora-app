// Helpers de presentación visual para mensajes MarkdownV2 del bot. Centralizan
// el lenguaje visual del bot (headers con emoji, dividers, bullets, badges)
// para que todos los formatters tengan el mismo look & feel y no haya
// inconsistencia "este comando usa • y el otro -, este pone bold con *X* y
// el otro con _X_".
//
// Convenciones MarkdownV2 a tener en cuenta cuando llamen estos helpers:
//   * Los chars reservados (`_*[]()~\`>#+-=|{}.!\`) deben escaparse en TODO
//     contenido user-supplied o de DB. Este módulo escapa internamente lo que
//     emite — el caller solo escapa lo que pasa como parámetro de texto.
//   * Los chars de los dividers (`━`) y el bullet (`•`) NO son reservados en
//     MV2, así que se pueden emitir tal cual.
//
// Re-exportamos los existentes (formatCurrency, formatFechaCorta,
// formatFechaHora, escapeMarkdownV2) así un formatter solo tiene UN import
// para todo lo de presentación.

import { escapeMarkdownV2 } from "./telegram.ts";
export {
  formatCurrency,
  formatFechaCorta,
  formatFechaHora,
} from "./tools/formatters.ts";
export { escapeMarkdownV2 };

// ----------------------------------------------------------------------------
// Constantes visuales
// ----------------------------------------------------------------------------

/** Caracter para dividers horizontales. U+2501 BOX DRAWINGS HEAVY HORIZONTAL.
 *  No es reservado MV2 — emite tal cual sin escape. */
const DIVIDER_CHAR = "━";
const DIVIDER_LENGTH = 14;

/** Caracter para bullets. U+2022 BULLET. No reservado MV2. */
const BULLET_CHAR = "•";

// ----------------------------------------------------------------------------
// Headers + dividers
// ----------------------------------------------------------------------------

/**
 * Línea de divider visual. Útil para separar secciones dentro de un mismo
 * mensaje (ej. cabecera del cliente / bloque numérico / acciones).
 */
export function divider(): string {
  return DIVIDER_CHAR.repeat(DIVIDER_LENGTH);
}

/**
 * Header de sección: emoji + texto bold + divider debajo. Preserva la
 * casing del texto original (no uppercase automático — el caller decide
 * pasando `.toUpperCase()` si quiere ese efecto). El texto se escapa MV2;
 * el emoji va literal.
 *
 *     header("Ventas", "📊")
 *     →  "📊 *Ventas*\n━━━━━━━━━━━━━━"
 *
 *     header("Pepito SA", "👤")
 *     →  "👤 *Pepito SA*\n━━━━━━━━━━━━━━"
 *
 * Si querés un título en MAYÚSCULAS (típico de "TÍTULO DE SECCIÓN"), pasá
 * el texto en mayúsculas o `text.toUpperCase()`.
 */
export function header(text: string, emoji?: string): string {
  const escaped = escapeMarkdownV2(text);
  const prefix = emoji ? `${emoji} ` : "";
  return `${prefix}*${escaped}*\n${divider()}`;
}

// ----------------------------------------------------------------------------
// Bullets + listas
// ----------------------------------------------------------------------------

/**
 * Bullet con emoji opcional adelante.
 *
 *     bullet("Coca 2L", "📦")  →  "•  📦 Coca 2L"
 *     bullet("Stock bajo")      →  "•  Stock bajo"
 *
 * El texto NO se escapa — el caller decide qué emite. Si pasa un nombre de
 * cliente / producto debe haberlo escapado con `escapeMarkdownV2` antes.
 * Esto da más flexibilidad: el caller puede mezclar texto bold + texto
 * plano en un solo bullet.
 */
export function bullet(text: string, emoji?: string): string {
  const prefix = emoji ? `${emoji} ` : "";
  return `${BULLET_CHAR}  ${prefix}${text}`;
}

// ----------------------------------------------------------------------------
// Status badges
// ----------------------------------------------------------------------------

export type StatusKind = "ok" | "warn" | "err" | "pending" | "info";

/**
 * Emoji semántico según el estado. Útil para indicadores en listas (✅
 * pedido entregado, ⚠️ stock crítico, ❌ no encontrado, ⏳ pendiente).
 */
export function statusBadge(status: StatusKind): string {
  switch (status) {
    case "ok":
      return "✅";
    case "warn":
      return "⚠️";
    case "err":
      return "❌";
    case "pending":
      return "⏳";
    case "info":
      return "💡";
  }
}

// ----------------------------------------------------------------------------
// Pares clave-valor
// ----------------------------------------------------------------------------

/**
 * Una línea con label en bold + value en texto plano.
 *
 *     kvRow("Saldo", "$12.500")  →  "*Saldo:* $12\\.500"
 *
 * Tanto label como value se escapan MV2. El caller pasa los strings tal cual.
 * Si el value ya viene formateado con escape (ej. de otro helper), pasalo a
 * `kvRowRaw` en su lugar para evitar doble-escape.
 */
export function kvRow(label: string, value: string): string {
  return `*${escapeMarkdownV2(label)}:* ${escapeMarkdownV2(value)}`;
}

/**
 * Variante de `kvRow` que NO escapa el value. Úsala cuando el value ya viene
 * con escapes válidos de MV2 (ej. `*$12\\.500*` con bold + escape interno).
 */
export function kvRowRaw(label: string, valueMv2: string): string {
  return `*${escapeMarkdownV2(label)}:* ${valueMv2}`;
}
