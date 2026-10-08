// Resuelve "Marcelo" → perfil_id para las herramientas donde un admin o
// encargado filtra por vendedor (mig 308). Un preventista nunca filtra: su
// cartera es la suya, y la RPC ignora el parámetro igual.
//
// Dos universos distintos, a propósito:
//   * "cartera" (clientes_atrasados): preventistas ACTIVOS asignados a la
//     sucursal. Una cartera es de alguien que hoy sale a vender.
//   * "vendedor" (ranking_clientes): cualquiera que haya vendido en la sucursal
//     en el último año, de cualquier rol y aunque esté dado de baja. Es como el
//     desplegable de vendedores de Reportes: en Taco Pozo la mayor parte de lo
//     vendido lo cargaron un preventista ya inactivo y el encargado.

import type { ToolContext } from "../base.ts";

export interface PreventistaResuelto {
  id: string;
  nombre: string;
}

export type UniversoVendedor = "cartera" | "vendedor";

function sinComodines(s: string): string {
  return s.replace(/[%_\\]/g, "");
}

/**
 * Devuelve el perfil cuyo nombre contiene `nombre` (sin distinguir
 * mayúsculas). Si uno coincide exacto, gana aunque haya otros parecidos
 * ("Juan" frente a "Juan Carlos"). Lanza con un mensaje para el usuario si no
 * hay ninguno o si hay más de uno.
 */
export async function resolverPreventista(
  ctx: ToolContext,
  nombre: string,
  universo: UniversoVendedor = "cartera",
): Promise<PreventistaResuelto> {
  const buscado = nombre.trim();
  if (buscado.length < 2) {
    throw new Error("Decime el nombre del vendedor (al menos 2 letras).");
  }
  if (ctx.sucursal_id == null) {
    throw new Error("Sucursal no asignada — contactá al administrador");
  }

  // Dos consultas y no un embed: un embed de PostgREST mal resuelto rompe en
  // runtime y no lo ve ningún test (CLAUDE.md, trampa 5).
  let ids: string[];
  if (universo === "cartera") {
    const { data, error } = await ctx.supabase
      .from("usuario_sucursales")
      .select("usuario_id")
      .eq("sucursal_id", ctx.sucursal_id);
    if (error) throw new Error(`resolver_preventista: ${error.message}`);
    ids = ((data ?? []) as Array<{ usuario_id: string }>).map((a) => a.usuario_id);
  } else {
    const desde = new Date(Date.now() - 365 * 86_400_000).toISOString().slice(0, 10);
    const { data, error } = await ctx.supabase
      .from("pedidos")
      .select("usuario_id")
      .eq("sucursal_id", ctx.sucursal_id)
      .eq("estado", "entregado")
      .gte("fecha", desde)
      .not("usuario_id", "is", null)
      .limit(20000);
    if (error) throw new Error(`resolver_preventista: ${error.message}`);
    ids = [...new Set(((data ?? []) as Array<{ usuario_id: string }>).map((p) => p.usuario_id))];
  }
  if (ids.length === 0) {
    throw new Error(`No encontré a "${buscado}" en esta sucursal.`);
  }

  let consulta = ctx.supabase
    .from("perfiles")
    .select("id, nombre")
    .in("id", ids)
    .ilike("nombre", `%${sinComodines(buscado)}%`)
    .limit(10);
  if (universo === "cartera") {
    consulta = consulta.eq("rol", "preventista").eq("activo", true);
  }
  const { data, error } = await consulta;
  if (error) {
    throw new Error(`resolver_preventista: ${error.message}`);
  }
  const filas = (data ?? []) as Array<{ id: string; nombre: string | null }>;
  if (filas.length === 0) {
    throw new Error(
      universo === "cartera"
        ? `No encontré un preventista activo "${buscado}" en esta sucursal.`
        : `No encontré a nadie llamado "${buscado}" que haya vendido en esta sucursal en el último año.`,
    );
  }
  const exactos = filas.filter((f) => (f.nombre ?? "").trim().toLowerCase() === buscado.toLowerCase());
  const elegido = exactos.length === 1 ? exactos[0] : filas.length === 1 ? filas[0] : null;
  if (!elegido) {
    const nombres = filas.map((f) => f.nombre ?? "(sin nombre)").join(", ");
    throw new Error(`Hay más de uno que coincide con "${buscado}": ${nombres}. ¿Cuál?`);
  }
  return { id: elegido.id, nombre: elegido.nombre ?? buscado };
}
