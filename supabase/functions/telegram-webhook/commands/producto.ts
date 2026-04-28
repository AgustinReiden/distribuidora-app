// /producto <texto> — busca productos por nombre o código y devuelve hasta 10.

import { invokeTool } from "../../_shared/tools/registry.ts";
import { sendMessage, sendMessageMarkdownSafe } from "../../_shared/telegram.ts";
import { buildProductoListKeyboard } from "../../_shared/telegram-keyboards.ts";
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
    // Inline keyboard "Ver detalle" — callback v1:producto:<id> está reservado
    // pero responde con placeholder hasta que se implemente la tool de
    // detalle (Fase futura). Igual ofrecemos el botón para que el preventista
    // se acostumbre al patrón.
    const reply_markup = result.data.productos.length > 0
      ? buildProductoListKeyboard(
        result.data.productos.map((p) => ({ id: p.id, nombre: p.nombre })),
      )
      : undefined;
    await sendMessageMarkdownSafe(chatId, text, { reply_markup });
  },
};
