// /saldo <id> — ficha financiera completa del cliente con ese ID.
//
// El `id` es el PK numérico de `clientes.id`, NO el campo `codigo`. El
// preventista lo obtiene típicamente con `/cliente <texto>` (que lo muestra
// en monospace para copiar/pegar).
//
// Scope: solo admin, preventista y encargado. Transportista y deposito no
// tienen razón de ver la ficha financiera (saldo, límite de crédito, deudas)
// del cliente — el router los bloquea con el mensaje estándar de scope.
// El filtrado a nivel tool (`ficha_cliente`) sigue aplicando: preventista
// solo ve sus clientes asignados, encargado/admin filtran por sucursal.

import { invokeTool } from "../../_shared/tools/registry.ts";
import { sendMessage, sendMessageMarkdownSafe } from "../../_shared/telegram.ts";
import { formatFichaCliente } from "../formatters/cliente.ts";
import type {
  FichaClienteParams,
  FichaClienteResult,
} from "../../_shared/tools/common/ficha_cliente.ts";
import type { CommandSpec } from "./types.ts";

export const saldoCommand: CommandSpec = {
  name: "/saldo",
  description: "Ficha del cliente por ID. Uso: /saldo <id>",
  scope: ["admin", "preventista", "encargado"],
  async handler({ chatId, rawArgs, user, toolCtx }) {
    if (!user || !toolCtx) {
      await sendMessage(
        chatId,
        "Necesitás vincularte primero. Mandá /vincular CODIGO.",
      );
      return;
    }

    const q = rawArgs.trim();
    const id = parseInt(q, 10);
    if (!Number.isInteger(id) || id <= 0 || String(id) !== q) {
      await sendMessage(
        chatId,
        "Uso: /saldo \\<id\\>\nEl id es el número del cliente \\(usá /cliente para buscar\\)\\.",
        { parse_mode: "MarkdownV2" },
      );
      return;
    }

    const params: FichaClienteParams = { cliente_id: id };
    const result = await invokeTool<FichaClienteResult>(
      "ficha_cliente",
      params,
      toolCtx,
    );

    if (!result.ok) {
      await sendMessage(chatId, `❌ ${result.error}`);
      return;
    }

    const text = formatFichaCliente(result.data);
    await sendMessageMarkdownSafe(chatId, text);
  },
};
