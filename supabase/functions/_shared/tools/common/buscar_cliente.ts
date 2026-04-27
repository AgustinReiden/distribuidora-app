// Tool: buscar_cliente
//
// Busca clientes por nombre fantasía, razón social o código numérico.
// Edge function corre con service_role (bypass RLS), así que filtramos
// manualmente por:
//   - sucursal_id (cuando el bot user tiene una asignada)
//   - cliente_preventistas (cuando el rol es "preventista", para limitar
//     a sus clientes asignados — replicando la regla N-N de la app)
//
// Nota: la regla de visibilidad full de preventistas en la app web también
// permite ver clientes "sin ningún preventista asignado". Acá adoptamos la
// regla más conservadora pedida en el spec de Phase 2: SOLO los explícitamente
// asignados. Si más adelante queremos relajar, se hace en una segunda query
// y merge — no sumemos complejidad antes de tiempo.

import type { Tool } from "../base.ts";

interface BuscarClienteParams {
  q: string;
  limit?: number;
}

interface BuscarClienteResult {
  total: number;
  clientes: Array<{
    id: number;
    codigo: number | null;
    nombre: string;
    saldo_cuenta: number;
    direccion: string | null;
    zona: string | null;
  }>;
}

interface ClienteRow {
  id: number;
  codigo: number | null;
  nombre_fantasia: string | null;
  razon_social: string | null;
  saldo_cuenta: number | string | null;
  direccion: string | null;
  zona: string | null;
}

export const buscarClienteTool: Tool<BuscarClienteParams, BuscarClienteResult> = {
  name: "buscar_cliente",
  description:
    "Busca clientes por nombre fantasía, razón social o código numérico. " +
    "Para preventistas, solo retorna clientes asignados al preventista que invoca. " +
    "Filtra por sucursal del bot user cuando aplica.",
  parameters: {
    type: "object",
    properties: {
      q: {
        type: "string",
        description: "Texto o número a buscar. Mínimo 2 caracteres.",
      },
      limit: {
        type: "integer",
        minimum: 1,
        maximum: 25,
        description: "Cantidad máxima de resultados (default 10, máx 25).",
      },
    },
    required: ["q"],
  },
  allowedRoles: ["admin", "preventista", "transportista", "encargado", "deposito"],
  handler: async ({ q, limit = 10 }, ctx) => {
    if (typeof q !== "string") {
      throw new Error("Parámetro 'q' debe ser texto");
    }
    const trimmed = q.trim();
    if (trimmed.length < 2) {
      throw new Error("Búsqueda muy corta (mínimo 2 caracteres)");
    }
    if (!Number.isFinite(limit) || limit < 1 || limit > 25) {
      throw new Error("Límite fuera de rango (1-25)");
    }

    const sb = ctx.supabase;
    const isPreventista = ctx.rol === "preventista";

    // Si es preventista, hacemos !inner para que el filtro por preventista_id
    // actúe como WHERE EXISTS. Si no, sin join.
    const selectCols = isPreventista
      ? "id, codigo, nombre_fantasia, razon_social, saldo_cuenta, direccion, zona, sucursal_id, cliente_preventistas!inner(preventista_id)"
      : "id, codigo, nombre_fantasia, razon_social, saldo_cuenta, direccion, zona, sucursal_id";

    let query = sb.from("clientes")
      .select(selectCols, { count: "exact" })
      .eq("activo", true)
      .order("nombre_fantasia", { ascending: true })
      .limit(limit);

    if (ctx.sucursal_id != null) {
      query = query.eq("sucursal_id", ctx.sucursal_id);
    }

    if (isPreventista) {
      query = query.eq("cliente_preventistas.preventista_id", ctx.perfil_id);
    }

    // Búsqueda: si q es exclusivamente dígitos, lo tratamos como código
    // exacto OR como substring del nombre (raro pero útil — ej: "Casa 24").
    // Si tiene caracteres no numéricos, ILIKE en nombre y razón social.
    const codigoNum = /^\d+$/.test(trimmed) ? parseInt(trimmed, 10) : null;
    if (codigoNum !== null) {
      const escaped = trimmed.replace(/[%_,()]/g, "\\$&");
      query = query.or(
        `codigo.eq.${codigoNum},nombre_fantasia.ilike.%${escaped}%,razon_social.ilike.%${escaped}%`,
      );
    } else {
      // Escape PostgREST OR-syntax separators y wildcards SQL.
      const escaped = trimmed.replace(/[%_,()]/g, "\\$&");
      query = query.or(
        `nombre_fantasia.ilike.%${escaped}%,razon_social.ilike.%${escaped}%`,
      );
    }

    const { data, error, count } = await query;
    if (error) {
      throw new Error(`buscar_cliente: ${error.message}`);
    }

    const rows = (data ?? []) as unknown as ClienteRow[];

    return {
      total: count ?? rows.length,
      clientes: rows.map((c) => ({
        id: Number(c.id),
        codigo: c.codigo === null || c.codigo === undefined ? null : Number(c.codigo),
        nombre: c.nombre_fantasia || c.razon_social || "(sin nombre)",
        saldo_cuenta: Number(c.saldo_cuenta ?? 0),
        direccion: c.direccion ?? null,
        zona: c.zona ?? null,
      })),
    };
  },
};
