// /sugerencias [N] — sugerencias RFM de clientes a visitar (preventista).
// Sin args usa default 10. Con un entero 1..25 usa ese límite.
// Alias: /sugerirvisitas.

import { invokeTool } from "../../_shared/tools/registry.ts";
import { sendMessage, sendMessageMarkdownSafe } from "../../_shared/telegram.ts";
import { formatSugerenciasResult } from "../formatters/sugerencias.ts";
import type {
  SugerirVisitasRfmParams,
  SugerirVisitasRfmResult,
} from "../../_shared/tools/preventista/sugerir_visitas_rfm.ts";
import type { CommandSpec } from "./types.ts";

export const sugerenciasCommand: CommandSpec = {
  name: "/sugerencias",
  aliases: ["/sugerirvisitas"],
  description: "Sugerencias de clientes a visitar hoy (RFM). Solo preventista.",
  scope: ["preventista"],
  async handler({ chatId, rawArgs, toolCtx }) {
    if (!toolCtx) {
      // No debería pasar — el router valida scope antes de llamar al handler.
      await sendMessage(chatId, "Error: contexto de usuario no disponible.");
      return;
    }

    const args = rawArgs.trim();
    const params: SugerirVisitasRfmParams = { limit: 10 };
    if (args.length > 0) {
      const n = parseInt(args, 10);
      if (Number.isInteger(n) && n >= 1 && n <= 25) {
        params.limit = n;
      } else {
        await sendMessage(
          chatId,
          "Uso: /sugerencias \\[N\\]\nN debe ser entero entre 1 y 25\\.",
          { parse_mode: "MarkdownV2" },
        );
        return;
      }
    }

    const result = await invokeTool<SugerirVisitasRfmResult>(
      "sugerir_visitas_rfm",
      params,
      toolCtx,
    );
    if (!result.ok) {
      await sendMessage(chatId, `❌ ${result.error}`);
      return;
    }

    await sendMessageMarkdownSafe(chatId, formatSugerenciasResult(result.data));
  },
};
