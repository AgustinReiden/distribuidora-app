// /sucursal — para admins multi-sucursal (vinculados a >1 sucursal vía
// usuario_sucursales). Permite listar las sucursales asignadas y switchear
// la activa del bot (bot_usuarios.sucursal_id).
//
// Uso:
//   /sucursal                  → lista con la activa marcada + inline keyboard
//   /sucursal <id>             → switch directo por id
//   /sucursal <nombre>         → switch directo por nombre exacto (case-insens)
//
// El switch es persistente — UPDATE bot_usuarios. Se valida que la sucursal
// destino esté en usuario_sucursales para el perfil_id del caller (si no,
// se rechaza con error claro).

import { sendMessage } from "../../_shared/telegram.ts";
import { getServiceRoleClient } from "../../_shared/supabase.ts";
import { logEvent } from "../../_shared/audit.ts";
import type { CommandSpec } from "./types.ts";

interface SucursalRow {
  id: number;
  nombre: string;
}

/** Lista las sucursales asignadas al usuario vía usuario_sucursales JOIN sucursales. */
async function listSucursalesAsignadas(perfil_id: string): Promise<SucursalRow[]> {
  const sb = getServiceRoleClient();
  // Inner join: solo activas. Ordenado por nombre para consistencia.
  const { data, error } = await sb
    .from("usuario_sucursales")
    .select("sucursal_id, sucursales!inner(id, nombre, activa)")
    .eq("usuario_id", perfil_id);
  if (error) {
    throw new Error(`No pude leer tus sucursales: ${error.message}`);
  }
  type Row = {
    sucursal_id: number;
    sucursales: { id: number; nombre: string; activa: boolean } | null;
  };
  const rows = (data as unknown as Row[]) ?? [];
  return rows
    .filter((r) => r.sucursales?.activa)
    .map((r) => ({
      id: r.sucursales!.id,
      nombre: r.sucursales!.nombre,
    }))
    .sort((a, b) => a.nombre.localeCompare(b.nombre, "es"));
}

/** UPDATE bot_usuarios.sucursal_id. No valida — lo hace el caller. */
async function updateBotSucursal(
  telegram_user_id: number,
  sucursal_id: number,
): Promise<void> {
  const sb = getServiceRoleClient();
  const { error } = await sb
    .from("bot_usuarios")
    .update({ sucursal_id })
    .eq("telegram_user_id", telegram_user_id);
  if (error) {
    throw new Error(`No pude cambiar la sucursal: ${error.message}`);
  }
}

/**
 * Resuelve el switch end-to-end:
 *  1. Lista las asignadas.
 *  2. Si la lista tiene 0/1, mensaje informativo (no hay nada que switchear).
 *  3. Sin args: lista con activa marcada + inline keyboard.
 *  4. Con arg numérico: matchea id contra asignadas; switch o error.
 *  5. Con arg texto: matchea nombre case-insens contra asignadas.
 *
 * Visible para reuso desde el callback handler (sucursal_switch:<id>).
 */
export async function handleSucursalSwitch(opts: {
  telegram_user_id: number;
  perfil_id: string;
  current_sucursal_id: number | null;
  /** "id" forzado por callback; el handler de slash command lo arma desde rawArgs. */
  target_id: number;
}): Promise<{ ok: true; nombre: string } | { ok: false; error: string }> {
  const asignadas = await listSucursalesAsignadas(opts.perfil_id);
  const match = asignadas.find((s) => s.id === opts.target_id);
  if (!match) {
    return {
      ok: false,
      error: "Esa sucursal no está asignada a tu cuenta.",
    };
  }
  if (opts.current_sucursal_id === match.id) {
    return { ok: true, nombre: match.nombre };
  }
  await updateBotSucursal(opts.telegram_user_id, match.id);
  return { ok: true, nombre: match.nombre };
}

export const sucursalCommand: CommandSpec = {
  name: "/sucursal",
  description: "Listar/cambiar la sucursal activa del bot (admins multi-sucursal).",
  scope: ["admin"],
  async handler({ chatId, user, tgUser, rawArgs }) {
    if (!user) {
      await sendMessage(
        chatId,
        "Necesitás vincularte primero. Mandá /vincular CODIGO.",
      );
      return;
    }

    let asignadas: SucursalRow[];
    try {
      asignadas = await listSucursalesAsignadas(user.perfil_id);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error("[sucursal] list failed:", msg);
      await sendMessage(chatId, `❌ ${msg}`);
      return;
    }

    if (asignadas.length === 0) {
      await sendMessage(
        chatId,
        "No tenés sucursales asignadas en la app. Pedile a un admin que te asigne.",
      );
      return;
    }
    if (asignadas.length === 1) {
      const only = asignadas[0];
      const isActive = user.sucursal_id === only.id;
      await sendMessage(
        chatId,
        isActive
          ? `🏪 Tu única sucursal asignada es ${only.nombre}. Ya es la activa.`
          : `🏪 Tu única sucursal asignada es ${only.nombre} — la pongo como activa.`,
      );
      if (!isActive) {
        try {
          await updateBotSucursal(tgUser.id, only.id);
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          await sendMessage(chatId, `❌ ${msg}`);
        }
      }
      return;
    }

    const arg = rawArgs.trim();

    // Sin args → lista + inline keyboard.
    if (arg.length === 0) {
      const lines = ["🏪 Sucursales asignadas:"];
      for (const s of asignadas) {
        const marker = s.id === user.sucursal_id ? "✓ " : "  ";
        lines.push(`${marker}${s.nombre}`);
      }
      lines.push("");
      lines.push("Tocá una para cambiar la activa, o escribí /sucursal <nombre|id>.");
      const reply_markup = {
        inline_keyboard: asignadas.map((s) => [{
          text: s.id === user.sucursal_id ? `✓ ${s.nombre}` : s.nombre,
          callback_data: `v1:sucursal_switch:${s.id}`,
        }]),
      };
      await sendMessage(chatId, lines.join("\n"), { reply_markup });
      return;
    }

    // Con arg: numérico → id; texto → nombre case-insens.
    let target_id: number | null = null;
    if (/^\d+$/.test(arg)) {
      target_id = parseInt(arg, 10);
    } else {
      const argLower = arg.toLowerCase();
      const byName = asignadas.find((s) => s.nombre.toLowerCase() === argLower);
      target_id = byName ? byName.id : null;
    }

    if (target_id == null) {
      await sendMessage(
        chatId,
        `❌ No encontré una sucursal con "${arg}". Usá /sucursal sin argumentos para ver la lista.`,
      );
      return;
    }

    const result = await handleSucursalSwitch({
      telegram_user_id: tgUser.id,
      perfil_id: user.perfil_id,
      current_sucursal_id: user.sucursal_id,
      target_id,
    });

    if (!result.ok) {
      await sendMessage(chatId, `❌ ${result.error}`);
      await logEvent({
        telegram_user_id: tgUser.id,
        perfil_id: user.perfil_id,
        rol: user.rol,
        tipo: "error",
        tool_name: "sucursal",
        resultado_meta: { error: result.error, target_id },
      }).catch(() => {});
      return;
    }

    await sendMessage(
      chatId,
      `✅ Sucursal activa: ${result.nombre}.\n\n` +
        `Las próximas consultas (ventas, deuda, etc.) van a ser de esa sucursal.`,
    );
  },
};
