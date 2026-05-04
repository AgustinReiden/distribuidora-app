// Tool: crear_pedido (WRITE)
//
// Toma un confirmacion_id (UUID) generado por previsualizar_pedido, valida
// que pertenezca al usuario que llama, y persiste el pedido vía la RPC
// crear_pedido_completo_bot (migration 030). El RPC hace el re-check de
// stock atómico, INSERTa pedido + items, descuenta stock, aplica auto-ajuste
// de promos, y marca el pendiente como consumido.
//
// IMPORTANTE: el LLM no debe llamar a esta tool directamente. El flujo es:
//   1. previsualizar_pedido → muestra resumen al usuario con keyboard
//   2. usuario tap "Confirmar" → callback v1:pedido_confirmar:<UUID>
//   3. handler del callback invoca crear_pedido con el confirmacion_id
//
// El LLM no puede inventar UUIDs válidos (no aparecen en su contexto), así
// que aún si "alucina" llamar crear_pedido sin haber pasado por preview,
// el RPC va a rechazar con "Confirmación inválida".

import type { Tool } from "../base.ts";

export interface CrearPedidoParams {
  /** UUID generado por previsualizar_pedido. */
  confirmacion_id: string;
}

export interface CrearPedidoResult {
  pedido_id: number;
  total: number;
}

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const crearPedidoTool: Tool<CrearPedidoParams, CrearPedidoResult> = {
  name: "crear_pedido",
  description:
    "Crea un pedido REAL a partir de un confirmacion_id que generó " +
    "previsualizar_pedido. Esta es una operación de ESCRITURA — NO la " +
    "invoques sin haber pasado antes por previsualizar_pedido y sin que el " +
    "usuario haya tapeado 'Confirmar' en el keyboard inline. El callback " +
    "del botón es lo que dispara esta tool, no el LLM directamente. Si vos " +
    "(LLM) llamás esta tool con un confirmacion_id que inventaste, va a fallar.",
  parameters: {
    type: "object",
    properties: {
      confirmacion_id: {
        type: "string",
        description: "UUID v4 generado por previsualizar_pedido (TTL 10 minutos).",
      },
    },
    required: ["confirmacion_id"],
  },
  allowedRoles: ["admin", "encargado", "preventista"],
  handler: async ({ confirmacion_id }, ctx) => {
    if (!UUID_REGEX.test(confirmacion_id)) {
      throw new Error("confirmacion_id no es un UUID válido");
    }
    if (ctx.sucursal_id == null) {
      throw new Error("Sucursal no asignada — contactá al administrador");
    }

    const { data, error } = await ctx.supabase.rpc(
      "crear_pedido_completo_bot",
      {
        p_perfil_id: ctx.perfil_id,
        p_confirmacion_id: confirmacion_id,
      },
    );

    if (error) {
      throw new Error(`crear_pedido: ${error.message}`);
    }

    const r = (data ?? {}) as {
      success: boolean;
      pedido_id?: number;
      total?: number;
      error?: string;
      errores?: string[];
    };

    if (!r.success) {
      // Errores de stock vienen como array
      if (r.errores && r.errores.length > 0) {
        throw new Error(`Stock insuficiente: ${r.errores.join("; ")}`);
      }
      throw new Error(r.error ?? "No pude crear el pedido");
    }

    return {
      pedido_id: Number(r.pedido_id),
      total: Number(r.total ?? 0),
    };
  },
};
