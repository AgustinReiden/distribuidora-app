// /recorrido [YYYY-MM-DD] — recorrido del transportista. Por defecto "hoy"
// en TZ America/Argentina/Buenos_Aires (lo resuelve el tool).

import { invokeTool } from "../../_shared/tools/registry.ts";
import { sendMessage, sendMessageMarkdownSafe } from "../../_shared/telegram.ts";
import { formatMiRecorridoResult } from "../formatters/recorrido.ts";
import type {
  MiRecorridoHoyParams,
  MiRecorridoHoyResult,
} from "../../_shared/tools/transportista/mi_recorrido_hoy.ts";
import type { CommandSpec } from "./types.ts";

export const recorridoCommand: CommandSpec = {
  name: "/recorrido",
  description: "Tu recorrido del día (transportista). Uso: /recorrido [YYYY-MM-DD]",
  scope: ["transportista"],
  async handler({ chatId, rawArgs, toolCtx }) {
    if (!toolCtx) {
      await sendMessage(chatId, "Error: contexto de usuario no disponible.");
      return;
    }

    const fecha = rawArgs.trim();
    // Solo pasamos `fecha` al tool si vino — para que el tool use su default
    // (hoy en TZ ART). El tool valida formato YYYY-MM-DD.
    const params: MiRecorridoHoyParams = fecha ? { fecha } : {};

    const result = await invokeTool<MiRecorridoHoyResult>(
      "mi_recorrido_hoy",
      params,
      toolCtx,
    );
    if (!result.ok) {
      await sendMessage(chatId, `❌ ${result.error}`);
      return;
    }

    await sendMessageMarkdownSafe(chatId, formatMiRecorridoResult(result.data));
  },
};
