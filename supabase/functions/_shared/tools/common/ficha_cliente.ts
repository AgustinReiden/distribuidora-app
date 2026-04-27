// Tool: ficha_cliente
//
// Obtiene la ficha financiera completa de un cliente reusando la RPC SQL
// `obtener_resumen_cuenta_cliente_bot` (definida en migrations/015_bot_rpcs_phase2.sql).
//
// La RPC `_bot` es una copia de `obtener_resumen_cuenta_cliente` SIN la check
// `auth.uid() IS NULL` — necesaria porque la edge function corre con
// service_role (sin JWT de usuario) y la RPC original siempre devolvería
// `{error: 'No autenticado'}`. El control de acceso al cliente lo hace esta
// tool antes de invocar el RPC (lookup en `clientes` con join opcional a
// `cliente_preventistas` y filtro de sucursal).
//
// Antes de invocar la RPC, validamos que el cliente exista Y, si el rol es
// "preventista", que esté asignado al preventista que invoca. Como las edge
// functions usan service_role (bypass RLS), este filtrado server-side es
// crítico — si lo saltamos, un preventista podría leer cualquier cliente.
//
// Sobre el shape de ultimo_pedido/ultimo_pago: la RPC actual retorna sólo
// la timestamp (MAX(created_at)). Acá soportamos AMBOS shapes — string o
// objeto {fecha, monto} — por si una migración futura enriquece la RPC
// y para que esta tool no rompa.

import type { Tool } from "../base.ts";

export interface FichaClienteParams {
  cliente_id: number;
}

export interface UltimoMov {
  fecha: string;
  monto: number;
}

export interface FichaClienteResult {
  cliente: {
    id: number;
    codigo: number | null;
    nombre: string;
    direccion: string | null;
    telefono: string | null;
    zona: string | null;
  };
  saldo_actual: number;
  limite_credito: number;
  credito_disponible: number;
  total_pedidos: number;
  total_compras: number;
  total_pagos: number;
  pedidos_pendientes_pago: number;
  ultimo_pedido: UltimoMov | null;
  ultimo_pago: UltimoMov | null;
}

interface ClienteLookupRow {
  id: number;
  codigo: number | null;
  nombre_fantasia: string | null;
  razon_social: string | null;
  direccion: string | null;
  telefono: string | null;
  zona: string | null;
}

/**
 * Normaliza el shape de ultimo_pedido / ultimo_pago. La RPC actual devuelve
 * un timestamp string; futuras versiones pueden devolver {fecha, monto}.
 */
function parseUltimoMov(value: unknown): UltimoMov | null {
  if (value === null || value === undefined) return null;
  if (typeof value === "string") {
    if (value === "") return null;
    return { fecha: value, monto: 0 };
  }
  if (typeof value === "object") {
    const obj = value as Record<string, unknown>;
    const fecha = typeof obj.fecha === "string" ? obj.fecha : null;
    if (!fecha) return null;
    const monto = Number(obj.monto ?? 0);
    return { fecha, monto: Number.isFinite(monto) ? monto : 0 };
  }
  return null;
}

export const fichaClienteTool: Tool<FichaClienteParams, FichaClienteResult> = {
  name: "ficha_cliente",
  description:
    "Obtiene la ficha financiera completa de un cliente: saldo actual, " +
    "límite de crédito, total comprado/pagado, último pedido y último pago. " +
    "Para preventistas valida que el cliente esté asignado a ellos.",
  parameters: {
    type: "object",
    properties: {
      cliente_id: {
        type: "integer",
        minimum: 1,
        description: "ID numérico del cliente (no el campo 'codigo').",
      },
    },
    required: ["cliente_id"],
  },
  allowedRoles: ["admin", "preventista", "transportista", "encargado", "deposito"],
  handler: async ({ cliente_id }, ctx) => {
    if (!Number.isInteger(cliente_id) || cliente_id <= 0) {
      throw new Error("cliente_id inválido");
    }

    // Multi-tenancy guardrail: solo admin puede operar sin sucursal asignada
    // (multi-sucursal). Cualquier otro rol con sucursal_id NULL es un data
    // error y NO debe ver datos cross-sucursal.
    if (ctx.sucursal_id == null && ctx.rol !== "admin") {
      throw new Error("Sucursal no asignada en bot_usuarios — contactá al administrador");
    }

    const sb = ctx.supabase;
    const isPreventista = ctx.rol === "preventista";

    const selectCols = isPreventista
      ? "id, codigo, nombre_fantasia, razon_social, direccion, telefono, zona, sucursal_id, cliente_preventistas!inner(preventista_id)"
      : "id, codigo, nombre_fantasia, razon_social, direccion, telefono, zona, sucursal_id";

    // Importante: aplicamos TODOS los .eq() ANTES de .maybeSingle(), porque
    // maybeSingle() retorna un thenable que ya no soporta más filtros.
    let clienteQuery = sb.from("clientes")
      .select(selectCols)
      .eq("id", cliente_id)
      .eq("activo", true);

    if (ctx.sucursal_id != null) {
      clienteQuery = clienteQuery.eq("sucursal_id", ctx.sucursal_id);
    }
    if (isPreventista) {
      clienteQuery = clienteQuery.eq("cliente_preventistas.preventista_id", ctx.perfil_id);
    }

    const { data: clienteData, error: cErr } = await clienteQuery.maybeSingle();
    if (cErr) {
      throw new Error(`ficha_cliente: cliente lookup: ${cErr.message}`);
    }
    if (!clienteData) {
      throw new Error("Cliente no encontrado o sin permiso");
    }

    const cliente = clienteData as unknown as ClienteLookupRow;

    const { data: resumen, error: rErr } = await sb.rpc(
      "obtener_resumen_cuenta_cliente_bot",
      { p_cliente_id: cliente_id },
    );
    if (rErr) {
      throw new Error(`ficha_cliente: rpc: ${rErr.message}`);
    }

    // La RPC `_bot` no chequea auth.uid() (service_role-only), pero
    // mantenemos el guard por si una futura migración cambia el shape.
    const r = (resumen ?? {}) as Record<string, unknown>;
    if (typeof r.error === "string") {
      throw new Error(`ficha_cliente: ${r.error}`);
    }

    return {
      cliente: {
        id: Number(cliente.id),
        codigo: cliente.codigo === null || cliente.codigo === undefined
          ? null
          : Number(cliente.codigo),
        nombre: cliente.nombre_fantasia || cliente.razon_social || "(sin nombre)",
        direccion: cliente.direccion ?? null,
        telefono: cliente.telefono ?? null,
        zona: cliente.zona ?? null,
      },
      saldo_actual: Number(r.saldo_actual ?? 0),
      limite_credito: Number(r.limite_credito ?? 0),
      credito_disponible: Number(r.credito_disponible ?? 0),
      total_pedidos: Number(r.total_pedidos ?? 0),
      total_compras: Number(r.total_compras ?? 0),
      total_pagos: Number(r.total_pagos ?? 0),
      pedidos_pendientes_pago: Number(r.pedidos_pendientes_pago ?? 0),
      ultimo_pedido: parseUltimoMov(r.ultimo_pedido),
      ultimo_pago: parseUltimoMov(r.ultimo_pago),
    };
  },
};
