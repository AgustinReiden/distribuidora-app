// Qué productos puede OFRECER el bot para vender. Misma regla que el front:
//
//   mostrable = activo AND (stock > 0 OR mostrar_sin_stock)
//
// `activo` es la baja lógica de `productos` y `mostrar_sin_stock` es un
// parámetro por sucursal de `politicas_comerciales` (una fila por sucursal).
// Sin fila, o con sucursal null (admin sin sucursal asignada), rige el default
// de la columna: true (se muestran los productos sin stock).
//
// Las tools que listan filtran EN LA QUERY (aplicarFiltroCatalogo), no en
// memoria: con `count: "exact"` y `limit`, filtrar después del limit haría que
// el total y la página mintieran. `esProductoMostrable` es la misma regla como
// función pura, para filtrar filas ya en memoria y para testearla.

import type { SupabaseClient } from "@supabase/supabase-js";

/** Default de `politicas_comerciales.mostrar_sin_stock`. */
export const MOSTRAR_SIN_STOCK_DEFAULT = true;

export function esProductoMostrable(
  p: { activo: boolean | null | undefined; stock: number | string | null | undefined },
  mostrarSinStock: boolean,
): boolean {
  if (p.activo !== true) return false;
  return mostrarSinStock || Number(p.stock ?? 0) > 0;
}

/**
 * Lee `mostrar_sin_stock` de la política de la sucursal. Sin sucursal o sin
 * fila devuelve el default (true). Lanza si falla la lectura: ocultar o
 * mostrar stock a ciegas sería peor que avisar del error.
 */
export async function fetchMostrarSinStock(
  sb: SupabaseClient,
  sucursalId: number | null,
): Promise<boolean> {
  if (sucursalId == null) return MOSTRAR_SIN_STOCK_DEFAULT;
  const { data, error } = await sb
    .from("politicas_comerciales")
    .select("mostrar_sin_stock")
    .eq("sucursal_id", sucursalId)
    .maybeSingle();
  if (error) {
    throw new Error(`politicas_comerciales lookup failed: ${error.message}`);
  }
  const row = data as { mostrar_sin_stock?: boolean | null } | null;
  return row?.mostrar_sin_stock ?? MOSTRAR_SIN_STOCK_DEFAULT;
}

// Subconjunto del query builder de PostgREST que usamos (eq / gt).
interface FiltrableQuery<T> {
  eq(column: string, value: unknown): T;
  gt(column: string, value: unknown): T;
}

/** Aplica la regla de catálogo a una query sobre `productos`. */
export function aplicarFiltroCatalogo<T extends FiltrableQuery<T>>(
  query: T,
  mostrarSinStock: boolean,
): T {
  const q = query.eq("activo", true);
  return mostrarSinStock ? q : q.gt("stock", 0);
}
