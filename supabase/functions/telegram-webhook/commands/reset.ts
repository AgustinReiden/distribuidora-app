// /reset — borra la conversación del usuario actual de bot_conversaciones.
// El bot tiene memoria conversacional (historial de turnos previos) que
// puede llevar al LLM a responder desde caché en vez de re-invocar tools
// (ej: "Ya busqué eso y no encontré"). /reset corta ese historial sin
// afectar la vinculación.

import { sendMessage } from "../../_shared/telegram.ts";
import { getServiceRoleClient } from "../../_shared/supabase.ts";
import { logEvent } from "../../_shared/audit.ts";
import type { CommandSpec } from "./types.ts";

export const resetCommand: CommandSpec = {
  name: "/reset",
  description: "Borra la memoria de la conversación actual con el bot.",
  scope: "any",
  async handler({ chatId, user, tgUser }) {
    if (!user) {
      await sendMessage(
        chatId,
        "Necesitás vincularte primero. Mandá /vincular CODIGO.",
      );
      return;
    }

    const sb = getServiceRoleClient();
    const { error } = await sb
      .from("bot_conversaciones")
      .delete()
      .eq("telegram_user_id", tgUser.id);

    if (error) {
      console.error("[reset] delete failed:", error.message);
      await sendMessage(
        chatId,
        "❌ No pude borrar la conversación. Probá de nuevo en un momento.",
      );
      await logEvent({
        telegram_user_id: tgUser.id,
        perfil_id: user.perfil_id,
        rol: user.rol,
        tipo: "error",
        tool_name: "reset",
        resultado_meta: { error: error.message },
      }).catch(() => {});
      return;
    }

    await sendMessage(
      chatId,
      "✅ Listo, borré la memoria de la conversación.\n\n" +
        "El próximo mensaje libre arranca sin contexto previo. Tu " +
        "vinculación sigue activa.",
    );
    // El logEvent del 'comando' lo hace el router antes de invocarnos —
    // no auditamos doble.
  },
};
