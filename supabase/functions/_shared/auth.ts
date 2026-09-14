// Auth del bot: lookup de telegram_user_id → perfil y canjeo de OTP.
//
// Toda la lógica transaccional vive en SQL (RPCs `bot_resolver_usuario` y
// `canjear_codigo_vinculacion_bot`, migraciones 014 y 237). Acá solo
// orquestamos la llamada y mapeamos el jsonb de vuelta a tipos TS estables.

import { getServiceRoleClient } from "./supabase.ts";
import type {
  BotRol,
  BotUser,
  CanjearCodigoFail,
  CanjearCodigoResult,
} from "./types.ts";

/**
 * Resuelve el chat a un usuario del bot. Retorna null si el chat no está
 * vinculado, si un admin lo desactivó en el panel del bot, o si el empleado
 * está dado de baja en la app.
 *
 * El rol, el alta/baja y la sucursal salen de `perfiles` / `usuario_sucursales`
 * EN VIVO, no del snapshot que `bot_usuarios` guardó al vincular (mig 237):
 * bajar a alguien de admin a preventista, o darlo de baja, tiene que cortarle
 * o cambiarle el acceso por Telegram en el mensaje siguiente, sin que nadie se
 * acuerde de tocar también el panel del bot.
 */
export async function resolveUserByTelegramId(
  telegram_user_id: number,
): Promise<BotUser | null> {
  const supabase = getServiceRoleClient();

  const { data, error } = await supabase.rpc("bot_resolver_usuario", {
    p_telegram_user_id: telegram_user_id,
  });

  if (error) {
    throw new Error(`resolveUserByTelegramId failed: ${error.message}`);
  }
  if (!data || typeof data !== "object") return null;

  const payload = data as Record<string, unknown>;

  if (payload.ok !== true) {
    // `no_vinculado` es el caso normal de cualquiera que le escriba al bot por
    // primera vez; los otros tres significan que alguien tenía acceso y lo
    // perdió, que sí vale la pena poder rastrear en los logs.
    const motivo = typeof payload.motivo === "string" ? payload.motivo : "desconocido";
    if (motivo !== "no_vinculado") {
      console.info(`[auth] ${telegram_user_id} no resuelve: ${motivo}`);
    }
    return null;
  }

  return {
    telegram_user_id,
    perfil_id: String(payload.perfil_id),
    rol: payload.rol as BotRol,
    sucursal_id: payload.sucursal_id == null ? null : Number(payload.sucursal_id),
    activo: true,
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
  "bloqueado",
]);

/**
 * Canjea un OTP llamando a la RPC SQL atómica. Mapea el jsonb a un Result
 * discriminado para que los handlers no tengan que adivinar shapes.
 *
 * `bloqueado` es el lockout del canje (5 fallos en 15 minutos, mig 237): viene
 * con `segundos_restantes` para poder decirle al usuario cuánto falta.
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

  const segundos = Number(payload.segundos_restantes);
  return {
    ok: false,
    error: safeError,
    segundos_restantes: Number.isFinite(segundos) && segundos > 0 ? segundos : undefined,
  };
}
