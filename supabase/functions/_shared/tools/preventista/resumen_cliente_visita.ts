// Tool: resumen_cliente_visita
//
// Lo que el preventista necesita saber antes de entrar al comercio, en una sola
// llamada (mig 308): ritmo de compra y si está atrasado, lo que más lleva, lo
// que dejó de llevar, saldo y el último pedido. Antes eran 3 o 4 herramientas y
// otras tantas vueltas del modelo.
//
// Mismo gate que historico/recurrentes: un preventista sólo ve sus clientes
// (asignados o huérfanos, nunca un reservado al que no le vendió). Montos y
// último pedido, propios.

import type { Tool } from "../base.ts";

export interface ResumenClienteVisitaParams {
  cliente_id: number;
}

export interface ResumenClienteVisitaResult {
  cliente: {
    id: number;
    codigo: number | null;
    nombre: string;
    direccion: string | null;
    telefono: string | null;
    es_comodin: boolean;
  } | null;
  saldo: number | null;
  limite_credito: number | null;
  ritmo: {
    ultima_compra: string | null;
    dias_sin_comprar: number | null;
    frecuencia_dias: number | null;
    estado: string;
  } | null;
  montos: "todos" | "propios";
  top_productos: Array<{ id: number; nombre: string; pedidos_con_producto: number; unidades_totales: number }>;
  dejados: Array<{ producto_id: number; nombre: string; ultima_vez: string | null }>;
  ultimo_pedido: { fecha: string; total: number; estado: string | null; estado_pago: string | null } | null;
  error?: string;
}

export const resumenClienteVisitaTool: Tool<ResumenClienteVisitaParams, ResumenClienteVisitaResult> = {
  name: "resumen_cliente_visita",
  description:
    "Resumen de un cliente para antes de visitarlo: si está al día o atrasado " +
    "según su ritmo, lo que más lleva, lo que DEJÓ de llevar (para ofrecerle), " +
    "saldo y último pedido. Una sola llamada en vez de ficha + historial + " +
    "recurrentes. Para 'qué le ofrezco a X', 'voy a ver a X', 'contame de X'. " +
    "Para preventistas, montos y último pedido son los propios.",
  parameters: {
    type: "object",
    properties: {
      cliente_id: { type: "integer", description: "ID del cliente (buscalo antes con buscar_cliente)." },
    },
    required: ["cliente_id"],
  },
  allowedRoles: ["admin", "encargado", "preventista"],
  handler: async ({ cliente_id }, ctx) => {
    if (!Number.isInteger(cliente_id) || cliente_id <= 0) {
      throw new Error("cliente_id debe ser entero positivo");
    }
    if (ctx.sucursal_id == null) {
      throw new Error("Sucursal no asignada — contactá al administrador");
    }
    const { data, error } = await ctx.supabase.rpc("bot_resumen_cliente_visita", {
      p_cliente_id: cliente_id,
      p_perfil_id: ctx.perfil_id,
      p_rol: ctx.rol,
      p_sucursal_id: ctx.sucursal_id,
    });
    if (error) {
      throw new Error(`resumen_cliente_visita: ${error.message}`);
    }
    const r = (data ?? {}) as Record<string, unknown>;
    const montos = r.montos === "todos" ? "todos" : "propios";
    if (typeof r.error === "string") {
      return {
        cliente: null, saldo: null, limite_credito: null, ritmo: null, montos,
        top_productos: [], dejados: [], ultimo_pedido: null, error: r.error,
      };
    }
    const c = (r.cliente ?? {}) as Record<string, unknown>;
    const ritmo = r.ritmo as Record<string, unknown> | null;
    const ult = r.ultimo_pedido as Record<string, unknown> | null;
    const num = (v: unknown) => (v == null ? null : Number(v));
    return {
      cliente: {
        id: Number(c.id),
        codigo: num(c.codigo),
        nombre: String(c.nombre ?? "(sin nombre)"),
        direccion: (c.direccion as string | null) ?? null,
        telefono: (c.telefono as string | null) ?? null,
        es_comodin: c.es_comodin === true,
      },
      saldo: num(r.saldo),
      limite_credito: num(r.limite_credito),
      ritmo: ritmo
        ? {
          ultima_compra: (ritmo.ultima_compra as string | null) ?? null,
          dias_sin_comprar: num(ritmo.dias_sin_comprar),
          frecuencia_dias: num(ritmo.frecuencia_dias),
          estado: String(ritmo.estado ?? ""),
        }
        : null,
      montos,
      top_productos: ((Array.isArray(r.top_productos) ? r.top_productos : []) as Array<Record<string, unknown>>)
        .map((p) => ({
          id: Number(p.id),
          nombre: String(p.nombre ?? ""),
          pedidos_con_producto: Number(p.pedidos_con_producto ?? 0),
          unidades_totales: Number(p.unidades_totales ?? 0),
        })),
      dejados: ((Array.isArray(r.dejados) ? r.dejados : []) as Array<Record<string, unknown>>)
        .map((p) => ({
          producto_id: Number(p.producto_id),
          nombre: String(p.nombre ?? ""),
          ultima_vez: (p.ultima_vez as string | null) ?? null,
        })),
      ultimo_pedido: ult
        ? {
          fecha: String(ult.fecha),
          total: Number(ult.total ?? 0),
          estado: (ult.estado as string | null) ?? null,
          estado_pago: (ult.estado_pago as string | null) ?? null,
        }
        : null,
    };
  },
};
