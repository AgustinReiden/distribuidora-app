// /producto <texto> — busca productos por nombre o código y devuelve hasta 10.

import { invokeTool } from "../../_shared/tools/registry.ts";
import { sendMessage } from "../../_shared/telegram.ts";
import { formatBuscarProductoResult } from "../formatters/producto.ts";
import type {
  BuscarProductoParams,
  BuscarProductoResult,
} from "../../_shared/tools/common/buscar_producto.ts";
import type { CommandSpec } from "./types.ts";

export const productoCommand: CommandSpec = {
  name: "/producto",
  description: "Buscar producto por nombre o código. Uso: /producto <texto>",
  scope: "any",
  async handler({ chatId, rawArgs, user, toolCtx }) {
    if (!user || !toolCtx) {
      await sendMessage(
        chatId,
        "Necesitás vincularte primero. Mandá /vincular CODIGO.",
      );
      return;
    }

    const q = rawArgs.trim();
    if (q.length < 2) {
      await sendMessage(
        chatId,
        "Uso: /producto \\<texto\\>\n_Mínimo 2 caracteres\\._",
        { parse_mode: "MarkdownV2" },
      );
      return;
    }

    const params: BuscarProductoParams = { q, limit: 10 };
    const result = await invokeTool<BuscarProductoResult>(
      "buscar_producto",
      params,
      toolCtx,
    );

    if (!result.ok) {
      await sendMessage(chatId, `❌ ${result.error}`);
      return;
    }

    const text = formatBuscarProductoResult(result.data);
    await sendMessage(chatId, text, { parse_mode: "MarkdownV2" });
  },
};
