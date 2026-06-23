// Pricing module — carga el PricingMap (mayoristas) y PromoMap (promociones)
// desde Supabase para que el bot Telegram calcule precios con la MISMA lógica
// que la app web.
//
// Diseño: port directo de los hooks fetchPricingMap (src/hooks/queries/
// useGruposPrecioQuery.ts:105-160) y fetchPromoMap (usePromocionesQuery.ts:
// 66-138). La React app depende de RLS para scopear por sucursal; acá la
// edge function corre con service_role (bypass RLS) y filtra explícitamente
// por sucursal_id en cada query.
//
// La salida `loadPricingContext()` es alimento directo para los utils
// `resolverPreciosMayorista` y `resolverPromociones` (también compartidos).

import type { SupabaseClient } from "@supabase/supabase-js";
import type { GrupoPrecioInfo, EscalaPrecio, PricingMap } from "../utils/precioMayorista.ts";
import type { PromocionActiva, PromoMap } from "../utils/promociones.ts";

// ----------------------------------------------------------------------------
// Tipos auxiliares (subset de src/types/* — solo los campos que usamos)
// ----------------------------------------------------------------------------

interface GrupoPrecioRow {
  id: number;
  nombre: string;
  activo: boolean;
  sucursal_id: number;
}
interface GrupoPrecioProductoRow {
  grupo_precio_id: number;
  producto_id: number;
  cantidad_minima_pedido: number | null;
}
interface GrupoPrecioEscalaRow {
  id: number;
  grupo_precio_id: number;
  cantidad_minima: number;
  precio_unitario: number;
  etiqueta: string | null;
  min_productos_distintos: number | null;
  activo: boolean;
}
interface GrupoPrecioEscalaMinimoRow {
  escala_id: number;
  producto_id: number;
  cantidad_minima_por_item: number;
  precio_unitario_override: number | null;
}

interface PromocionRow {
  id: number;
  nombre: string;
  tipo: string;
  activo: boolean;
  fecha_inicio: string | null;
  fecha_fin: string | null;
  sucursal_id: number;
  producto_regalo_id: number | null;
  prioridad: number | null;
  regalo_mueve_stock: boolean | null;
  modo_exclusion: string | null;
  ajuste_producto_id: number | null;
  unidades_por_bloque: number | null;
  descripcion_regalo: string | null;
}
interface PromocionProductoRow {
  promocion_id: number;
  producto_id: number;
}
interface PromocionReglaRow {
  promocion_id: number;
  clave: string;
  valor: number;
}

// ----------------------------------------------------------------------------
// loadPricingContext: una sola llamada que devuelve todo lo que necesitan
// los utils. Hace 4 queries para mayoristas + 3 para promos.
// ----------------------------------------------------------------------------

export interface PricingContext {
  pricingMap: PricingMap;
  promoMap: PromoMap;
}

/** Fecha local AR en formato YYYY-MM-DD (para evaluar vigencia de promos). */
function fechaArgentinaISO(): string {
  // Intl con timezone — robusto, no depende del reloj del runtime.
  const fmt = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Argentina/Buenos_Aires",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });
  return fmt.format(new Date());
}

export async function loadPricingContext(
  supabase: SupabaseClient,
  sucursalId: number,
  fechaReferenciaIso?: string,
): Promise<PricingContext> {
  const [pricingMap, promoMap] = await Promise.all([
    loadPricingMap(supabase, sucursalId),
    loadPromoMap(supabase, sucursalId, fechaReferenciaIso ?? fechaArgentinaISO()),
  ]);
  return { pricingMap, promoMap };
}

// ----------------------------------------------------------------------------
// loadPricingMap — port de fetchPricingMap del React app
// ----------------------------------------------------------------------------

async function loadPricingMap(
  supabase: SupabaseClient,
  sucursalId: number,
): Promise<PricingMap> {
  // 1) grupos_precio activos de la sucursal
  const { data: grupos, error: errGrupos } = await supabase
    .from("grupos_precio")
    .select("id, nombre, activo, sucursal_id")
    .eq("sucursal_id", sucursalId)
    .eq("activo", true);
  if (errGrupos && !errGrupos.message.includes("does not exist")) {
    throw new Error(`pricing: grupos_precio: ${errGrupos.message}`);
  }
  const gruposRows = (grupos ?? []) as GrupoPrecioRow[];
  if (gruposRows.length === 0) return new Map();

  const grupoIds = gruposRows.map((g) => g.id);

  // 2) productos de los grupos
  const { data: prodRows, error: errProds } = await supabase
    .from("grupo_precio_productos")
    .select("grupo_precio_id, producto_id, cantidad_minima_pedido")
    .in("grupo_precio_id", grupoIds);
  if (errProds && !errProds.message.includes("does not exist")) {
    throw new Error(`pricing: grupo_precio_productos: ${errProds.message}`);
  }
  const productos = (prodRows ?? []) as GrupoPrecioProductoRow[];

  // 3) escalas activas
  const { data: escRows, error: errEsc } = await supabase
    .from("grupo_precio_escalas")
    .select("id, grupo_precio_id, cantidad_minima, precio_unitario, etiqueta, min_productos_distintos, activo")
    .in("grupo_precio_id", grupoIds)
    .order("cantidad_minima");
  if (errEsc && !errEsc.message.includes("does not exist")) {
    throw new Error(`pricing: grupo_precio_escalas: ${errEsc.message}`);
  }
  const escalas = (escRows ?? []) as GrupoPrecioEscalaRow[];

  // 4) minimos por producto/escala (tabla "combinada")
  const escalaIds = escalas.map((e) => e.id);
  let minimos: GrupoPrecioEscalaMinimoRow[] = [];
  if (escalaIds.length > 0) {
    const { data: minRows, error: errMin } = await supabase
      .from("grupo_precio_escala_minimos")
      .select("escala_id, producto_id, cantidad_minima_por_item, precio_unitario_override")
      .in("escala_id", escalaIds);
    if (errMin && !errMin.message.includes("does not exist")) {
      throw new Error(`pricing: grupo_precio_escala_minimos: ${errMin.message}`);
    }
    minimos = (minRows ?? []) as GrupoPrecioEscalaMinimoRow[];
  }

  // Indexar minimos por escala_id
  const minimosPorEscala = new Map<number, GrupoPrecioEscalaMinimoRow[]>();
  for (const m of minimos) {
    const arr = minimosPorEscala.get(m.escala_id) ?? [];
    arr.push(m);
    minimosPorEscala.set(m.escala_id, arr);
  }

  // Construir el Map producto_id → GrupoPrecioInfo[]
  const map: PricingMap = new Map();
  for (const grupo of gruposRows) {
    const escalasDelGrupo = escalas.filter((e) =>
      e.grupo_precio_id === grupo.id && e.activo !== false
    );
    if (escalasDelGrupo.length === 0) continue;

    const escalasActivas = escalasDelGrupo.map((e): EscalaPrecio => {
      const minimosRows = minimosPorEscala.get(e.id) ?? [];
      const minimosPorProducto = new Map<string, { cantidad: number; precioOverride?: number | null }>();
      for (const m of minimosRows) {
        minimosPorProducto.set(String(m.producto_id), {
          cantidad: Number(m.cantidad_minima_por_item),
          precioOverride: m.precio_unitario_override != null
            ? Number(m.precio_unitario_override)
            : null,
        });
      }
      return {
        cantidadMinima: Number(e.cantidad_minima),
        precioUnitario: Number(e.precio_unitario),
        etiqueta: e.etiqueta || null,
        minProductosDistintos: e.min_productos_distintos ?? 1,
        minimosPorProducto,
      };
    });

    const productosDelGrupo = productos.filter((p) => p.grupo_precio_id === grupo.id);
    const productoIds = productosDelGrupo.map((p) => String(p.producto_id));

    const moqPorProducto = new Map<string, number>();
    for (const p of productosDelGrupo) {
      if (p.cantidad_minima_pedido && p.cantidad_minima_pedido > 0) {
        moqPorProducto.set(String(p.producto_id), p.cantidad_minima_pedido);
      }
    }

    const grupoInfo: GrupoPrecioInfo = {
      grupoId: String(grupo.id),
      grupoNombre: grupo.nombre,
      escalas: escalasActivas,
      productoIds,
      moqPorProducto,
    };

    for (const productoId of productoIds) {
      const existing = map.get(productoId) || [];
      existing.push(grupoInfo);
      map.set(productoId, existing);
    }
  }

  return map;
}

// ----------------------------------------------------------------------------
// loadPromoMap — port de fetchPromoMap del React app
// ----------------------------------------------------------------------------

async function loadPromoMap(
  supabase: SupabaseClient,
  sucursalId: number,
  fechaIso: string,
): Promise<PromoMap> {
  const { data: promos, error: errPromos } = await supabase
    .from("promociones")
    .select(
      "id, nombre, tipo, activo, fecha_inicio, fecha_fin, sucursal_id, producto_regalo_id, prioridad, regalo_mueve_stock, modo_exclusion, ajuste_producto_id, unidades_por_bloque, descripcion_regalo",
    )
    .eq("sucursal_id", sucursalId)
    .eq("activo", true)
    .lte("fecha_inicio", fechaIso)
    .or(`fecha_fin.is.null,fecha_fin.gte.${fechaIso}`);
  if (errPromos && !errPromos.message.includes("does not exist")) {
    throw new Error(`pricing: promociones: ${errPromos.message}`);
  }
  const promosRows = (promos ?? []) as PromocionRow[];
  if (promosRows.length === 0) return new Map();

  const promoIds = promosRows.map((p) => p.id);

  const { data: prodRows, error: errProds } = await supabase
    .from("promocion_productos")
    .select("promocion_id, producto_id")
    .in("promocion_id", promoIds);
  if (errProds && !errProds.message.includes("does not exist")) {
    throw new Error(`pricing: promocion_productos: ${errProds.message}`);
  }
  const promoProductos = (prodRows ?? []) as PromocionProductoRow[];

  const { data: regRows, error: errReg } = await supabase
    .from("promocion_reglas")
    .select("promocion_id, clave, valor")
    .in("promocion_id", promoIds);
  if (errReg && !errReg.message.includes("does not exist")) {
    throw new Error(`pricing: promocion_reglas: ${errReg.message}`);
  }
  const promoReglas = (regRows ?? []) as PromocionReglaRow[];

  const map: PromoMap = new Map();
  for (const promo of promosRows) {
    const productosDePromo = promoProductos
      .filter((p) => p.promocion_id === promo.id)
      .map((p) => String(p.producto_id));
    if (productosDePromo.length === 0) continue;

    const reglas: Record<string, number> = {};
    for (const r of promoReglas) {
      if (r.promocion_id === promo.id) reglas[r.clave] = Number(r.valor);
    }

    const promoActiva: PromocionActiva = {
      id: String(promo.id),
      nombre: promo.nombre,
      tipo: promo.tipo as PromocionActiva["tipo"],
      productoIds: productosDePromo,
      reglas,
      productoRegaloId: promo.producto_regalo_id ? String(promo.producto_regalo_id) : undefined,
      prioridad: promo.prioridad ?? 0,
      regaloMueveStock: promo.regalo_mueve_stock ?? false,
      modoExclusion: (promo.modo_exclusion ?? "acumulable") as PromocionActiva["modoExclusion"],
      ajusteProductoId: promo.ajuste_producto_id ? String(promo.ajuste_producto_id) : undefined,
      unidadesPorBloque: promo.unidades_por_bloque ?? undefined,
      descripcionRegalo: promo.descripcion_regalo ?? undefined,
    };

    for (const productoId of productosDePromo) {
      const existing = map.get(productoId) || [];
      existing.push(promoActiva);
      map.set(productoId, existing);
    }
  }

  return map;
}
