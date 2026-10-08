// Tools de productos en lista (mig 308):
//
//   * productos_sin_venta_con_stock (admin/encargado): lo que está parado.
//   * stock_y_ventas (todos): stock, ventas de 30 días y cobertura de un grupo
//     de productos filtrado por proveedor, categoría o texto. Reemplaza el
//     desparramo de `ficha_producto` producto por producto (16 llamadas en una
//     tarde en el registro). Para quien no es admin ni encargado, sin ventas:
//     el volumen de la sucursal no lo ve en la app (mig 296).

import type { Tool } from "../base.ts";

// ---------------------------------------------------------------------------
// productos_sin_venta_con_stock
// ---------------------------------------------------------------------------

export interface SinVentaParams {
  /** Ventana en días (default 30, 7 a 180). */
  dias?: number;
  /** Default 30, max 100. */
  limit?: number;
}

export interface SinVentaResult {
  dias: number;
  criterio: string | null;
  productos_count: number;
  valor_total_a_precio_venta: number;
  productos: Array<{
    id: number;
    codigo: string | null;
    nombre: string;
    categoria: string | null;
    proveedor: string | null;
    stock: number;
    precio: number;
    valor_a_precio_venta: number;
    ultima_venta: string | null;
  }>;
}

export const productosSinVentaConStockTool: Tool<SinVentaParams, SinVentaResult> = {
  name: "productos_sin_venta_con_stock",
  description:
    "Productos activos con stock que no tuvieron ninguna venta (entregada, sin " +
    "regalos) en los últimos N días: la mercadería parada. Ordenado por valor a " +
    "precio de venta. Para 'qué no se vende', 'qué tengo parado', 'productos " +
    "sin movimiento'. Admin/encargado.",
  parameters: {
    type: "object",
    properties: {
      dias: { type: "integer", minimum: 7, maximum: 180, description: "Ventana en días (default 30)." },
      limit: { type: "integer", minimum: 1, maximum: 100, description: "Default 30, max 100." },
    },
    required: [],
  },
  allowedRoles: ["admin", "encargado"],
  handler: async ({ dias = 30, limit = 30 }, ctx) => {
    if (!Number.isInteger(dias) || dias < 7 || dias > 180) {
      throw new Error("dias fuera de rango (7-180)");
    }
    if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
      throw new Error("limit fuera de rango (1-100)");
    }
    if (ctx.sucursal_id == null) {
      throw new Error("Sucursal no asignada — contactá al administrador");
    }
    const { data, error } = await ctx.supabase.rpc("bot_productos_sin_venta_con_stock", {
      p_sucursal_id: ctx.sucursal_id,
      p_dias: dias,
      p_limit: limit,
    });
    if (error) {
      throw new Error(`productos_sin_venta_con_stock: ${error.message}`);
    }
    const r = (data ?? {}) as Record<string, unknown>;
    const filas = (Array.isArray(r.productos) ? r.productos : []) as Array<Record<string, unknown>>;
    return {
      dias: Number(r.dias ?? dias),
      criterio: (r.criterio as string | null) ?? null,
      productos_count: Number(r.productos_count ?? 0),
      valor_total_a_precio_venta: Number(r.valor_total_a_precio_venta ?? 0),
      productos: filas.map((p) => ({
        id: Number(p.id),
        codigo: (p.codigo as string | null) ?? null,
        nombre: String(p.nombre ?? ""),
        categoria: (p.categoria as string | null) ?? null,
        proveedor: (p.proveedor as string | null) ?? null,
        stock: Number(p.stock ?? 0),
        precio: Number(p.precio ?? 0),
        valor_a_precio_venta: Number(p.valor_a_precio_venta ?? 0),
        ultima_venta: (p.ultima_venta as string | null) ?? null,
      })),
    };
  },
};

// ---------------------------------------------------------------------------
// stock_y_ventas
// ---------------------------------------------------------------------------

export interface StockYVentasParams {
  texto?: string;
  proveedor?: string;
  categoria?: string;
  /** Default 30, max 60. */
  limit?: number;
}

export interface StockYVentasResult {
  ventas_visibles: boolean;
  criterio: string | null;
  productos_count: number;
  productos: Array<{
    id: number;
    codigo: string | null;
    nombre: string;
    categoria: string | null;
    proveedor: string | null;
    stock: number;
    stock_minimo: number | null;
    precio: number;
    /** null si el rol no ve ventas de la sucursal. */
    vendidas_30d: number | null;
    regaladas_30d: number | null;
    cobertura_dias: number | null;
  }>;
}

export const stockYVentasTool: Tool<StockYVentasParams, StockYVentasResult> = {
  name: "stock_y_ventas",
  description:
    "Stock (y, para admin/encargado, ventas de 30 días y días de cobertura) de un " +
    "grupo de productos filtrado por `proveedor` (ej. 'Zingaras'), `categoria` o " +
    "`texto` del nombre. Usala en vez de llamar a ficha_producto producto por " +
    "producto cuando preguntan por una marca, proveedor o familia. Si el usuario " +
    "nombra algo y no sabés si es proveedor o producto, probá primero como " +
    "proveedor y si no trae nada, como texto. Para preventista/transportista/" +
    "depósito vienen sólo stock y precio. Para listar el catálogo de una " +
    "categoría sin stock ni ventas, productos_por_categoria.",
  parameters: {
    type: "object",
    properties: {
      texto: { type: "string", description: "Parte del nombre o código del producto." },
      proveedor: { type: "string", description: "Parte del nombre del proveedor." },
      categoria: { type: "string", description: "Parte del nombre de la categoría." },
      limit: { type: "integer", minimum: 1, maximum: 60, description: "Default 30, max 60." },
    },
    required: [],
  },
  allowedRoles: ["admin", "encargado", "preventista", "transportista", "deposito"],
  handler: async ({ texto, proveedor, categoria, limit = 30 }, ctx) => {
    const limpio = (v?: string) => (v && v.trim().length >= 2 ? v.trim() : null);
    const t = limpio(texto), pv = limpio(proveedor), ca = limpio(categoria);
    if (!t && !pv && !ca) {
      throw new Error("Decime un proveedor, una categoría o parte del nombre (2 letras o más).");
    }
    if (!Number.isInteger(limit) || limit < 1 || limit > 60) {
      throw new Error("limit fuera de rango (1-60)");
    }
    if (ctx.sucursal_id == null) {
      throw new Error("Sucursal no asignada — contactá al administrador");
    }
    const { data, error } = await ctx.supabase.rpc("bot_stock_y_ventas", {
      p_sucursal_id: ctx.sucursal_id,
      p_rol: ctx.rol,
      p_texto: t,
      p_proveedor: pv,
      p_categoria: ca,
      p_limit: limit,
    });
    if (error) {
      throw new Error(`stock_y_ventas: ${error.message}`);
    }
    const r = (data ?? {}) as Record<string, unknown>;
    const filas = (Array.isArray(r.productos) ? r.productos : []) as Array<Record<string, unknown>>;
    // Guarda propia, no la bandera de la RPC: si el SQL se rompiera, igual no salen.
    const veVentas = (ctx.rol === "admin" || ctx.rol === "encargado") && r.ventas_visibles === true;
    const num = (v: unknown) => (v == null ? null : Number(v));
    return {
      ventas_visibles: veVentas,
      criterio: (r.criterio as string | null) ?? null,
      productos_count: Number(r.productos_count ?? 0),
      productos: filas.map((p) => ({
        id: Number(p.id),
        codigo: (p.codigo as string | null) ?? null,
        nombre: String(p.nombre ?? ""),
        categoria: (p.categoria as string | null) ?? null,
        proveedor: (p.proveedor as string | null) ?? null,
        stock: Number(p.stock ?? 0),
        stock_minimo: num(p.stock_minimo),
        precio: Number(p.precio ?? 0),
        // Doble guarda: aunque la RPC los mande, sin permiso no salen.
        vendidas_30d: veVentas ? num(p.vendidas_30d) : null,
        regaladas_30d: veVentas ? num(p.regaladas_30d) : null,
        cobertura_dias: veVentas ? num(p.cobertura_dias) : null,
      })),
    };
  },
};
