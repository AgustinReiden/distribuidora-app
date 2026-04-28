// /menu — muestra el main menu del bot con keyboards según el rol del
// usuario. Cada botón dispara un callback v1:menu:<key> que handleCallbackMenu
// resuelve en handlers.ts.

import { sendMessage, sendMessageMarkdownSafe } from "../../_shared/telegram.ts";
import { buildMainMenuKeyboard } from "../../_shared/telegram-keyboards.ts";
import type { CommandSpec } from "./types.ts";

export const menuCommand: CommandSpec = {
  name: "/menu",
  description: "Menú principal del bot.",
  scope: "any",
  async handler({ chatId, user }) {
    if (!user) {
      // Defensa-en-profundidad: el router ya bloquea esto, pero no asumimos.
      await sendMessage(
        chatId,
        "Necesitás vincularte primero. Mandá /vincular CODIGO.",
      );
      return;
    }
    const reply_markup = buildMainMenuKeyboard(user.rol);
    await sendMessageMarkdownSafe(
      chatId,
      "*¿Qué querés hacer?*",
      { reply_markup },
    );
  },
};
