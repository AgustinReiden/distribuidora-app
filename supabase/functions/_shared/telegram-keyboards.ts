// Builders de inline keyboards. Funciones puras que toman los mismos arrays
// que reciben los formatters de slash commands y devuelven un
// `InlineKeyboardMarkup` listo para adjuntar a `sendMessage` via la opción
// `reply_markup`.
//
// Decisiones:
//   * Una fila por item, un botón por fila — cabe bien en mobile y deja
//     espacio si en el futuro agregamos un segundo botón ("marcar visitado",
//     "llamar", etc.) sin reflowing.
//   * Texto del botón truncado a un visualmente legible (~28 chars max).
//     El callback_data sí tiene un hard cap de 64 bytes UTF-8 (Telegram), pero
//     el formato `v1:<action>:<id>` con un id numérico nunca lo supera.
//   * Versión `v1` en el callback_data por si el protocolo cambia. handleCallbackQuery
//     valida el prefijo y rechaza otras versiones.

import type {
  InlineKeyboardButton,
  InlineKeyboardMarkup,
} from "./telegram.ts";
import type { BotRol } from "./types.ts";

// ----------------------------------------------------------------------------
// Constantes
// ----------------------------------------------------------------------------

/** Máximo visual de texto en un botón. Telegram acepta hasta 64 bytes
 *  pero textos largos se ven feo en mobile — truncamos antes. */
const BUTTON_TEXT_MAX = 28;

/** Versión del protocolo de callback_data. Match con handleCallbackQuery. */
const CALLBACK_VERSION = "v1";

// ----------------------------------------------------------------------------
// Helpers internos
// ----------------------------------------------------------------------------

function truncate(text: string, max = BUTTON_TEXT_MAX): string {
  if (text.length <= max) return text;
  return text.slice(0, max - 1).trimEnd() + "…";
}

function callbackData(action: string, ...args: Array<string | number>): string {
  return [CALLBACK_VERSION, action, ...args.map(String)].join(":");
}

function rowsFromButtons(buttons: InlineKeyboardButton[]): InlineKeyboardButton[][] {
  // Una fila por botón. Patrón: builders más complejos pueden usar layouts
  // multi-columna (ej. main menu) — esos pasan su propio shape directo.
  return buttons.map((b) => [b]);
}

// ----------------------------------------------------------------------------
// Builders
// ----------------------------------------------------------------------------

export interface ClienteListItem {
  id: number;
  nombre: string;
}

/**
 * "Ver ficha — <nombre>" por cada cliente. callback_data: `v1:cliente:<id>`.
 * Útil después de /cliente, /sugerencias y /misclientes — la acción siempre
 * abre la ficha, sin distinción del comando que originó la lista.
 */
export function buildClienteListKeyboard(
  items: ClienteListItem[],
): InlineKeyboardMarkup {
  const buttons: InlineKeyboardButton[] = items.map((c) => ({
    text: truncate(`👤 Ver ficha — ${c.nombre}`),
    callback_data: callbackData("cliente", c.id),
  }));
  return { inline_keyboard: rowsFromButtons(buttons) };
}

export interface ProductoListItem {
  id: number;
  nombre: string;
}

/**
 * "Ver detalle — <nombre>" por cada producto. callback_data: `v1:producto:<id>`.
 * En Fase 1 el callback responde con placeholder ("acción no disponible") —
 * el wiring se reserva para no requerir cambios cuando se implemente la
 * tool de detalle.
 */
export function buildProductoListKeyboard(
  items: ProductoListItem[],
): InlineKeyboardMarkup {
  const buttons: InlineKeyboardButton[] = items.map((p) => ({
    text: truncate(`📦 Ver detalle — ${p.nombre}`),
    callback_data: callbackData("producto", p.id),
  }));
  return { inline_keyboard: rowsFromButtons(buttons) };
}

export interface SugerenciaItem {
  cliente_id: number;
  nombre: string;
}

/**
 * "Ver ficha" por cada sugerencia (preventista). callback_data va al mismo
 * action 'cliente' que el de buildClienteListKeyboard — la ficha es la misma
 * vista, no necesitamos un action separado.
 */
export function buildSugerenciasKeyboard(
  items: SugerenciaItem[],
): InlineKeyboardMarkup {
  const buttons: InlineKeyboardButton[] = items.map((s) => ({
    text: truncate(`👤 Ver ficha — ${s.nombre}`),
    callback_data: callbackData("cliente", s.cliente_id),
  }));
  return { inline_keyboard: rowsFromButtons(buttons) };
}

export interface MisClientesItem {
  id: number;
  nombre: string;
}

/**
 * "Ver ficha" por cada cliente del preventista. Misma action que las otras
 * dos: routea a la ficha.
 */
export function buildMisClientesKeyboard(
  items: MisClientesItem[],
): InlineKeyboardMarkup {
  const buttons: InlineKeyboardButton[] = items.map((c) => ({
    text: truncate(`👤 Ver ficha — ${c.nombre}`),
    callback_data: callbackData("cliente", c.id),
  }));
  return { inline_keyboard: rowsFromButtons(buttons) };
}

// ----------------------------------------------------------------------------
// Main menu (Fase 3)
// ----------------------------------------------------------------------------

/**
 * Tipo de cada entrada del main menu. La `key` viaja como argumento del
 * callback (`v1:menu:<key>`) y el handler decide cómo materializarla.
 */
interface MainMenuEntry {
  text: string;
  /** Key del callback. Sin chars `:` ni espacios. */
  key: string;
}

/**
 * Construye el main menu apropiado para el rol del usuario. Layout 2 cols
 * por fila — cabe bien en mobile, es lo que el GauchOs Bot usa de
 * referencia. Cada rol ve solo las opciones que sus tools permiten.
 *
 *   admin / encargado:   [👥 Buscar cliente] [📦 Buscar producto]
 *                         [❓ Ayuda]
 *
 *   preventista:         [👥 Mis clientes]   [💡 Sugerencias]
 *                         [📦 Buscar producto] [❓ Ayuda]
 *
 *   transportista:       [🚚 Recorrido hoy]  [📦 Buscar producto]
 *                         [❓ Ayuda]
 *
 *   deposito:            [📦 Buscar producto] [❓ Ayuda]
 *
 * El key del callback se interpreta en handleCallbackMenu — algunos disparan
 * un slash command sin args (mis clientes, sugerencias, recorrido, ayuda),
 * otros piden al usuario que tipee qué buscar (cliente, producto).
 */
export function buildMainMenuKeyboard(rol: BotRol): InlineKeyboardMarkup {
  const entries = mainMenuEntriesForRol(rol);
  // Pareamos en filas de 2 cols. Si la cantidad es impar, la última fila
  // queda con 1 botón solo (visualmente OK).
  const rows: InlineKeyboardButton[][] = [];
  for (let i = 0; i < entries.length; i += 2) {
    const row: InlineKeyboardButton[] = [];
    for (let j = i; j < Math.min(i + 2, entries.length); j++) {
      const e = entries[j];
      row.push({
        text: truncate(e.text),
        callback_data: callbackData("menu", e.key),
      });
    }
    rows.push(row);
  }
  return { inline_keyboard: rows };
}

function mainMenuEntriesForRol(rol: BotRol): MainMenuEntry[] {
  switch (rol) {
    case "admin":
    case "encargado":
      return [
        { text: "👥 Buscar cliente", key: "buscar_cliente" },
        { text: "📦 Buscar producto", key: "buscar_producto" },
        { text: "❓ Ayuda", key: "ayuda" },
      ];
    case "preventista":
      return [
        { text: "👥 Mis clientes", key: "mis_clientes" },
        { text: "💡 Sugerencias", key: "sugerencias" },
        { text: "📦 Buscar producto", key: "buscar_producto" },
        { text: "❓ Ayuda", key: "ayuda" },
      ];
    case "transportista":
      return [
        { text: "🚚 Recorrido de hoy", key: "recorrido" },
        { text: "📦 Buscar producto", key: "buscar_producto" },
        { text: "❓ Ayuda", key: "ayuda" },
      ];
    case "deposito":
      return [
        { text: "📦 Buscar producto", key: "buscar_producto" },
        { text: "❓ Ayuda", key: "ayuda" },
      ];
  }
}

// ----------------------------------------------------------------------------
// Exports auxiliares para tests
// ----------------------------------------------------------------------------

export const _internal = {
  truncate,
  callbackData,
  BUTTON_TEXT_MAX,
  CALLBACK_VERSION,
  mainMenuEntriesForRol,
};
