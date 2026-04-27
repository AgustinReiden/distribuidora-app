// /cliente <texto> — busca clientes por nombre o código y devuelve hasta 10.

import { invokeTool } from "../../_shared/tools/registry.ts";
import { sendMessage, sendMessageMarkdownSafe } from "../../_shared/telegram.ts";
import { formatBuscarClienteResult } from "../formatters/cliente.ts";
import type {
  BuscarClienteParams,
  BuscarClienteResult,
} from "../../_shared/tools/common/buscar_cliente.ts";
import type { CommandSpec } from "./types.ts";

export const clienteCommand: CommandSpec = {
  name: "/cliente",
  description: "Buscar cliente por nombre o código. Uso: /cliente <texto>",
  scope: "any",
  async handler({ chatId, rawArgs, user, toolCtx }) {
    if (!user || !toolCtx) {
      // Defense in depth: el router ya bloquea esto vía scope, pero por las
      // dudas no asumimos. Usuario no vinculado nunca debería llegar acá.
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
        "Uso: /cliente \\<texto\\>\n_Mínimo 2 caracteres\\._",
        { parse_mode: "MarkdownV2" },
      );
      return;
    }

    const params: BuscarClienteParams = { q, limit: 10 };
    const result = await invokeTool<BuscarClienteResult>(
      "buscar_cliente",
      params,
      toolCtx,
    );

    if (!result.ok) {
      await sendMessage(chatId, `❌ ${result.error}`);
      return;
    }

    const text = formatBuscarClienteResult(result.data);
    await sendMessageMarkdownSafe(chatId, text);
  },
};
