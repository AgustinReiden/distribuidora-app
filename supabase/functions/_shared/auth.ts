// Auth del bot: lookup de telegram_user_id → perfil y canjeo de OTP.
//
// Toda la lógica transaccional vive en SQL (RPC `canjear_codigo_vinculacion_bot`,
// migración 014). Acá solo orquestamos la llamada y mapeamos el jsonb de
// vuelta a tipos TS estables.

import { getServiceRoleClient } from "./supabase.ts";
import type {
  BotRol,
  BotUser,
  CanjearCodigoFail,
  CanjearCodigoResult,
} from "./types.ts";

/**
 * SELECT en bot_usuarios. Retorna null si el chat no está vinculado o si el
 * registro está desactivado (admin pudo haber cortado acceso sin borrar).
 */
export async function resolveUserByTelegramId(
  telegram_user_id: number,
): Promise<BotUser | null> {
  const supabase = getServiceRoleClient();

  const { data, error } = await supabase
    .from("bot_usuarios")
    .select("telegram_user_id, perfil_id, rol, sucursal_id, activo")
    .eq("telegram_user_id", telegram_user_id)
    .eq("activo", true)
    .maybeSingle();

  if (error) {
    throw new Error(`resolveUserByTelegramId failed: ${error.message}`);
  }
  if (!data) return null;

  return {
    telegram_user_id: data.telegram_user_id,
    perfil_id: data.perfil_id,
    rol: data.rol as BotRol,
    sucursal_id: data.sucursal_id ?? null,
    activo: data.activo,
  };
}

export interface CanjearCodigoOpts {
  codigo: string;
  telegram_user_id: number;
  telegram_username?: string;
}

const KNOWN_RPC_ERRORS = new Set([
  "no_encontrado",
  "expirado",
  "ya_usado",
  "perfil_invalido",
]);

/**
 * Canjea un OTP llamando a la RPC SQL atómica. Mapea el jsonb a un Result
 * discriminado para que los handlers no tengan que adivinar shapes.
 */
export async function canjearCodigo(
  opts: CanjearCodigoOpts,
): Promise<CanjearCodigoResult> {
  const supabase = getServiceRoleClient();

  const { data, error } = await supabase.rpc("canjear_codigo_vinculacion_bot", {
    p_codigo: opts.codigo,
    p_telegram_user_id: opts.telegram_user_id,
    p_telegram_username: opts.telegram_username ?? null,
  });

  if (error) {
    return { ok: false, error: "rpc_error" };
  }

  if (!data || typeof data !== "object") {
    return { ok: false, error: "rpc_error" };
  }

  const payload = data as Record<string, unknown>;

  if (payload.success === true) {
    return {
      ok: true,
      user: {
        telegram_user_id: opts.telegram_user_id,
        perfil_id: String(payload.perfil_id),
        rol: payload.rol as BotRol,
        sucursal_id: payload.sucursal_id == null ? null : Number(payload.sucursal_id),
        activo: true,
        nombre: typeof payload.nombre === "string" ? payload.nombre : "",
      },
    };
  }

  const errCode = typeof payload.error === "string" ? payload.error : "rpc_error";
  const safeError: CanjearCodigoFail["error"] = KNOWN_RPC_ERRORS.has(errCode)
    ? (errCode as CanjearCodigoFail["error"])
    : "rpc_error";
  return { ok: false, error: safeError };
}
