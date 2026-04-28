// Tool: buscar_cliente
//
// Busca clientes por nombre fantasía, razón social o código numérico.
// Implementación delega a la RPC `bot_buscar_cliente` (migration 020) que:
//   - Splittea el query en palabras lowercased + accent-folded.
//   - Exige que TODAS las palabras matcheen al menos uno de
//     nombre_fantasia / razon_social / codigo (también accent-folded).
//   - Aplica scoping por sucursal y, si el rol es preventista, por
//     cliente_preventistas (igual regla N-N que la app web).
//
// Razón del cambio (era una chain PostgREST .or().ilike()): ILIKE en Postgres
// es case-insensitive pero NO accent-insensitive — "Almacén Gabriel" no
// matcheaba "almacen gabriel". La RPC usa la extensión `unaccent` (vía un
// wrapper IMMUTABLE) y es indexable.

import type { Tool } from "../base.ts";

export interface BuscarClienteParams {
  q: string;
  limit?: number;
}

export interface BuscarClienteResult {
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
    "Acepta múltiples palabras (ej: 'almacen gabriel') — exige que todas " +
    "aparezcan en al menos uno de los campos del cliente. Es accent-insensitive " +
    "(matchea 'almacen' contra 'Almacén'). Para preventistas, solo retorna " +
    "clientes asignados al preventista que invoca. Filtra por sucursal del " +
    "bot user cuando aplica.",
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

    // Multi-tenancy guardrail: solo admin puede operar sin sucursal asignada.
    // Defense-in-depth: la RPC también requiere sucursal_id no-null para que
    // el filtro `c.sucursal_id = p_sucursal_id` no devuelva todo el universo
    // de la BD (un null = igualdad nunca matchea, así que sería 0 filas
    // accidentalmente — pero el guard explícito da mejor mensaje de error).
    if (ctx.sucursal_id == null && ctx.rol !== "admin") {
      throw new Error("Sucursal no asignada en bot_usuarios — contactá al administrador");
    }

    const { data, error } = await ctx.supabase.rpc("bot_buscar_cliente", {
      p_q: trimmed,
      p_perfil_id: ctx.perfil_id,
      p_rol: ctx.rol,
      p_sucursal_id: ctx.sucursal_id,
      p_limit: limit,
    });

    if (error) {
      throw new Error(`buscar_cliente: ${error.message}`);
    }

    const rows = (data ?? []) as unknown as ClienteRow[];

    // `total` aproximado: cantidad de filas devueltas (sujeto al limit). No
    // hacemos un count(*) separado porque el LLM rara vez necesita el total
    // exacto cuando ya tiene los top N — y dos round-trips a la DB por cada
    // búsqueda no se justifica.
    return {
      total: rows.length,
      clientes: rows.map((c) => ({
        id: Number(c.id),
        codigo: c.codigo === null || c.codigo === undefined ? null : Number(c.codigo),
        // trim() porque varios clientes históricos vienen con trailing
        // whitespace ("Almacén Gabriel " — id=565). Limpiarlo en el output
        // del bot evita que el LLM lo emita y se vea raro en Telegram.
        nombre: (c.nombre_fantasia?.trim() ||
          c.razon_social?.trim() ||
          "(sin nombre)"),
        saldo_cuenta: Number(c.saldo_cuenta ?? 0),
        direccion: c.direccion?.trim() ?? null,
        zona: c.zona?.trim() ?? null,
      })),
    };
  },
};
