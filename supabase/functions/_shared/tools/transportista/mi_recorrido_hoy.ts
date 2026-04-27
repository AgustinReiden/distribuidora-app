// Tool: mi_recorrido_hoy (transportista-only)
//
// Devuelve el recorrido del día (o de la fecha indicada en el override) para
// el transportista que invoca, junto con la lista de pedidos a entregar
// ordenados por orden_entrega. Pensado para "qué tengo que entregar hoy".
//
// Si hay múltiples recorridos para esa fecha (raro pero posible —
// ej: un recorrido cancelado y luego otro nuevo), retornamos el más reciente
// (ORDER BY id DESC LIMIT 1). Si no hay ninguno → recorrido: null, pedidos: [].
//
// La RPC SQL `bot_mi_recorrido` (migrations/015_bot_rpcs_phase2.sql) hace el
// JOIN recorridos ↔ recorrido_pedidos ↔ pedidos ↔ clientes en una sola pasada.
//
// IMPORTANTE — timezone: la fecha "hoy" se resuelve siempre en TZ
// America/Argentina/Buenos_Aires (la distribuidora vive en ART, UTC-3).
// NO confiamos en `CURRENT_DATE` del servidor PostgreSQL (que usa UTC en
// Supabase) ni dejamos que PostgREST mande NULL al RPC — un NULL explícito
// no triggea el `DEFAULT CURRENT_DATE` y rompe el path por defecto.

import type { Tool } from "../base.ts";

export interface MiRecorridoHoyParams {
  /**
   * Override de la fecha (YYYY-MM-DD). Default: hoy en TZ
   * America/Argentina/Buenos_Aires (resuelta en TS, no en SQL).
   */
  fecha?: string;
}

export interface MiRecorridoHoyResult {
  recorrido: {
    id: number;
    fecha: string;
    estado: string;
    total_pedidos: number;
    pedidos_entregados: number;
    total_facturado: number;
    total_cobrado: number;
  } | null;
  pedidos: Array<{
    pedido_id: number;
    orden_entrega: number | null;
    estado_entrega: string;
    cliente_id: number;
    cliente_nombre: string;
    direccion: string | null;
    total: number;
    estado_pago: string;
  }>;
}

interface RpcRecorridoRow {
  id: number;
  fecha: string;
  estado: string;
  total_pedidos: number | string | null;
  pedidos_entregados: number | string | null;
  total_facturado: number | string | null;
  total_cobrado: number | string | null;
}

interface RpcPedidoRow {
  pedido_id: number;
  orden_entrega: number | null;
  estado_entrega: string | null;
  cliente_id: number;
  cliente_nombre: string | null;
  direccion: string | null;
  total: number | string | null;
  estado_pago: string | null;
}

interface RpcResponse {
  recorrido: RpcRecorridoRow | null;
  pedidos: RpcPedidoRow[] | null;
}

const FECHA_RE = /^\d{4}-\d{2}-\d{2}$/;

/**
 * Devuelve "hoy" en TZ America/Argentina/Buenos_Aires como string YYYY-MM-DD.
 * Usamos `Intl.DateTimeFormat` con locale "en-CA" porque ese locale siempre
 * formatea como YYYY-MM-DD (a diferencia de "es-AR" que usa DD/MM/YYYY).
 * El `timeZone` fuerza la conversión desde la hora del proceso (UTC en
 * Supabase Edge) a ART antes de extraer el componente "fecha".
 */
function hoyEnArgentina(): string {
  const fmt = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Argentina/Buenos_Aires",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });
  return fmt.format(new Date());
}

export const miRecorridoHoyTool: Tool<MiRecorridoHoyParams, MiRecorridoHoyResult> = {
  name: "mi_recorrido_hoy",
  description:
    "Devuelve el recorrido del día (o de la fecha indicada) del transportista " +
    "que invoca, con la lista de pedidos a entregar (cliente, dirección, total, " +
    "estado de pago, orden de entrega). Si no hay recorrido para esa fecha, " +
    "retorna recorrido: null y pedidos vacíos.",
  parameters: {
    type: "object",
    properties: {
      fecha: {
        type: "string",
        description:
          "Fecha en formato YYYY-MM-DD. Si no se especifica, usa la fecha " +
          "de hoy en TZ America/Argentina/Buenos_Aires.",
      },
    },
  },
  allowedRoles: ["transportista"],
  handler: async ({ fecha }, ctx) => {
    // Defense-in-depth (allowedRoles ya cubre esto en invokeTool).
    if (ctx.rol !== "transportista") {
      throw new Error("mi_recorrido_hoy solo está disponible para transportistas");
    }

    if (ctx.sucursal_id == null) {
      throw new Error(
        "Sucursal no asignada en bot_usuarios — contactá al administrador",
      );
    }

    // Resolvemos la fecha en TS para no depender del default SQL: PostgREST
    // pasa null verbatim al RPC, lo que NO triggea `DEFAULT CURRENT_DATE`
    // (la query interna haría WHERE fecha = NULL → siempre 0 rows). Además,
    // CURRENT_DATE en Supabase corre en UTC y la distribuidora vive en ART
    // (UTC-3), así que a las 21:00 ART ya estaríamos un día adelantados.
    let p_fecha: string;
    if (fecha !== undefined && fecha !== null && fecha !== "") {
      if (typeof fecha !== "string" || !FECHA_RE.test(fecha)) {
        throw new Error("fecha inválida (formato YYYY-MM-DD)");
      }
      p_fecha = fecha;
    } else {
      p_fecha = hoyEnArgentina();
    }

    const sb = ctx.supabase;
    const { data, error } = await sb.rpc("bot_mi_recorrido", {
      p_transportista_id: ctx.perfil_id,
      p_sucursal_id: ctx.sucursal_id,
      p_fecha,
    });

    if (error) {
      throw new Error(`mi_recorrido_hoy: ${error.message}`);
    }

    const resp = (data ?? { recorrido: null, pedidos: [] }) as RpcResponse;

    const recorrido = resp.recorrido
      ? {
        id: Number(resp.recorrido.id),
        fecha: String(resp.recorrido.fecha),
        estado: String(resp.recorrido.estado ?? ""),
        total_pedidos: Number(resp.recorrido.total_pedidos ?? 0),
        pedidos_entregados: Number(resp.recorrido.pedidos_entregados ?? 0),
        total_facturado: Number(resp.recorrido.total_facturado ?? 0),
        total_cobrado: Number(resp.recorrido.total_cobrado ?? 0),
      }
      : null;

    const pedidosRaw = Array.isArray(resp.pedidos) ? resp.pedidos : [];
    const pedidos = pedidosRaw.map((p) => ({
      pedido_id: Number(p.pedido_id),
      orden_entrega: p.orden_entrega === null || p.orden_entrega === undefined
        ? null
        : Number(p.orden_entrega),
      estado_entrega: String(p.estado_entrega ?? "pendiente"),
      cliente_id: Number(p.cliente_id),
      cliente_nombre: p.cliente_nombre || "(sin nombre)",
      direccion: p.direccion ?? null,
      total: Number(p.total ?? 0),
      estado_pago: String(p.estado_pago ?? "pendiente"),
    }));

    return { recorrido, pedidos };
  },
};
