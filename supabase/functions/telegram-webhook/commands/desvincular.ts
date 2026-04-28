// /desvincular — desactiva el bot_usuarios del que invoca, dejándolo como
// no-vinculado. Soft delete (activo=false) en vez de DELETE para preservar
// el audit histórico y permitir reactivar fácilmente.
//
// `resolveUserByTelegramId` ya filtra por `activo = true`, así que el efecto
// inmediato del soft delete es que el siguiente mensaje cae al flow de "no
// vinculado" y le pide /vincular CODIGO.
//
// La conversación (bot_conversaciones) NO se borra acá — si el usuario
// quiere también limpiarla, hay /reset. Lo dejamos separado porque
// desvincular es "salirme del bot" y reset es "olvidate de mi última
// charla pero seguí siendo yo".

import { sendMessage } from "../../_shared/telegram.ts";
import { getServiceRoleClient } from "../../_shared/supabase.ts";
import { logEvent } from "../../_shared/audit.ts";
import type { CommandSpec } from "./types.ts";

export const desvincularCommand: CommandSpec = {
  name: "/desvincular",
  description: "Desvincula tu cuenta de Telegram del sistema.",
  scope: "any",
  async handler({ chatId, user, tgUser }) {
    if (!user) {
      await sendMessage(chatId, "No estás vinculado, no hay nada que desvincular.");
      return;
    }

    const sb = getServiceRoleClient();
    const { error } = await sb
      .from("bot_usuarios")
      .update({ activo: false })
      .eq("telegram_user_id", tgUser.id);

    if (error) {
      console.error("[desvincular] update failed:", error.message);
      await sendMessage(
        chatId,
        "❌ No pude desvincular tu cuenta. Probá de nuevo en un momento.",
      );
      await logEvent({
        telegram_user_id: tgUser.id,
        perfil_id: user.perfil_id,
        rol: user.rol,
        tipo: "error",
        tool_name: "desvincular",
        resultado_meta: { error: error.message },
      }).catch(() => {});
      return;
    }

    await sendMessage(
      chatId,
      "✅ Te desvinculé del bot.\n\n" +
        "Si querés volver a usarlo, generá un nuevo código en la app web " +
        "(Perfil > Vincular Telegram) y mandalo así:\n" +
        "/vincular ABC123",
    );
  },
};
