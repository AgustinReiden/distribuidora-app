// /sugerencias [N] — clientes atrasados de la cartera, priorizados por la plata
// en riesgo (mig 305: antes era la RFM). Sin args usa 10; con un entero 1..25
// usa ese límite. No pasa por el modelo: cuesta cero.
// Alias: /sugerirvisitas, /atrasados.

import { invokeTool } from "../../_shared/tools/registry.ts";
import { sendMessage, sendMessageMarkdownSafe } from "../../_shared/telegram.ts";
import { buildSugerenciasKeyboard } from "../../_shared/telegram-keyboards.ts";
import { formatSugerenciasResult } from "../formatters/sugerencias.ts";
import type {
  ClientesAtrasadosParams,
  ClientesAtrasadosResult,
} from "../../_shared/tools/common/clientes_atrasados.ts";
import type { CommandSpec } from "./types.ts";

export const sugerenciasCommand: CommandSpec = {
  name: "/sugerencias",
  aliases: ["/sugerirvisitas", "/atrasados"],
  description: "Clientes atrasados (tu cartera, o la sucursal si sos admin/encargado).",
  scope: ["preventista", "admin", "encargado"],
  async handler({ chatId, rawArgs, toolCtx }) {
    if (!toolCtx) {
      // No debería pasar — el router valida scope antes de llamar al handler.
      await sendMessage(chatId, "Error: contexto de usuario no disponible.");
      return;
    }

    const args = rawArgs.trim();
    const params: ClientesAtrasadosParams = { limit: 10 };
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

    const result = await invokeTool<ClientesAtrasadosResult>(
      "clientes_atrasados",
      params,
      toolCtx,
    );
    if (!result.ok) {
      await sendMessage(chatId, `❌ ${result.error}`);
      return;
    }

    const reply_markup = result.data.clientes.length > 0
      ? buildSugerenciasKeyboard(
        result.data.clientes.map((c) => ({ cliente_id: c.cliente_id, nombre: c.nombre })),
      )
      : undefined;
    await sendMessageMarkdownSafe(chatId, formatSugerenciasResult(result.data), { reply_markup });
  },
};
