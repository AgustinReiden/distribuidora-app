// Audit log para el bot. Inserta una fila en `bot_audit_log` por cada
// interacción relevante: mensaje entrante, comando, tool call (próxima fase),
// respuesta del bot, error.
//
// Política: FAIL-CLOSED. Si el INSERT falla, este helper LANZA el error.
// El caller (ej: el handler del webhook) decide si abortar el flujo o
// suprimirlo (típico: suprimir auditorías de errores anidados con .catch
// para no enmascarar el error principal).

import { getServiceRoleClient } from "./supabase.ts";
import type { BotAuditTipo } from "./types.ts";

export interface LogEventParams {
  telegram_user_id?: number;
  perfil_id?: string;
  rol?: string;
  tipo: BotAuditTipo;
  tool_name?: string;
  parametros?: Record<string, unknown>;
  resultado_meta?: Record<string, unknown>;
  // Permitimos null explícitamente para casos donde queremos auditar un evento
  // sin texto (ej: update con shape no soportado).
  texto_usuario?: string | null;
  texto_bot?: string | null;
}

export async function logEvent(params: LogEventParams): Promise<void> {
  const supabase = getServiceRoleClient();

  const row: Record<string, unknown> = { tipo: params.tipo };
  if (params.telegram_user_id !== undefined) row.telegram_user_id = params.telegram_user_id;
  if (params.perfil_id !== undefined) row.perfil_id = params.perfil_id;
  if (params.rol !== undefined) row.rol = params.rol;
  if (params.tool_name !== undefined) row.tool_name = params.tool_name;
  if (params.parametros !== undefined) row.parametros = params.parametros;
  if (params.resultado_meta !== undefined) row.resultado_meta = params.resultado_meta;
  if (params.texto_usuario !== undefined) row.texto_usuario = params.texto_usuario;
  if (params.texto_bot !== undefined) row.texto_bot = params.texto_bot;

  const { error } = await supabase.from("bot_audit_log").insert(row);
  if (error) {
    throw new Error(`bot_audit_log insert failed: ${error.message}`);
  }
}
