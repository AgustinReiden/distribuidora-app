// /misclientes — cartera del preventista. Soporta args opcionales:
//   - "deuda"          → solo clientes con saldo > 0
//   - "rotacion <N>"   → solo clientes sin pedidos en los últimos N días (1-365)
//   - "rotación <N>"   → idem (alias castellano con tilde)
//
// Sin args, lista los primeros 20 clientes asignados.

import { invokeTool } from "../../_shared/tools/registry.ts";
import { sendMessage, sendMessageMarkdownSafe } from "../../_shared/telegram.ts";
import { formatMisClientesResult } from "../formatters/misclientes.ts";
import type {
  MisClientesParams,
  MisClientesResult,
} from "../../_shared/tools/preventista/mis_clientes.ts";
import type { CommandSpec } from "./types.ts";

export const misClientesCommand: CommandSpec = {
  name: "/misclientes",
  description: "Tu cartera de clientes asignados (preventista).",
  scope: ["preventista"],
  async handler({ chatId, rawArgs, toolCtx }) {
    if (!toolCtx) {
      // No debería pasar — el router valida scope antes de llamar al handler.
      await sendMessage(chatId, "Error: contexto de usuario no disponible.");
      return;
    }

    const args = rawArgs.trim().toLowerCase();
    const params: MisClientesParams = { limit: 20 };

    if (args === "deuda") {
      params.con_deuda = true;
    } else if (args.startsWith("rotacion ") || args.startsWith("rotación ")) {
      const parts = args.split(/\s+/);
      const n = parseInt(parts[1] ?? "", 10);
      if (Number.isInteger(n) && n >= 1 && n <= 365) {
        params.sin_pedidos_dias = n;
      } else {
        await sendMessage(
          chatId,
          "Uso: /misclientes rotacion \\<N\\>\nN debe ser entero entre 1 y 365\\.",
          { parse_mode: "MarkdownV2" },
        );
        return;
      }
    } else if (args !== "") {
      await sendMessage(
        chatId,
        "Uso:\n/misclientes \\(lista completa\\)\n/misclientes deuda \\(solo con saldo\\)\n" +
          "/misclientes rotacion \\<N\\> \\(sin pedidos hace N días\\)",
        { parse_mode: "MarkdownV2" },
      );
      return;
    }

    const result = await invokeTool<MisClientesResult>(
      "mis_clientes",
      params,
      toolCtx,
    );
    if (!result.ok) {
      await sendMessage(chatId, `❌ ${result.error}`);
      return;
    }

    await sendMessageMarkdownSafe(chatId, formatMisClientesResult(result.data));
  },
};
