// Tool: ficha_producto
//
// Devuelve detalle de un producto + métricas básicas (cantidad vendida en
// los últimos 30 días, fecha de última venta). Pensada para alimentar el
// callback `v1:producto:<id>` de los inline keyboards y para que el LLM
// pueda responder consultas de detalle ("dame los datos del producto X").
//
// Delega 100% al RPC bot_ficha_producto (migration 021). El gate de
// sucursal lo hace el RPC (filtra por sucursal_id), igual que ficha_cliente.

import type { Tool } from "../base.ts";

export interface FichaProductoParams {
  producto_id: number;
}

export interface FichaProductoResult {
  producto: {
    id: number;
    codigo: string | null;
    nombre: string;
    precio: number;
    precio_sin_iva: number | null;
    stock: number;
    stock_minimo: number;
    bajo_stock: boolean;
    categoria: string | null;
    proveedor_id: number | null;
  };
  ventas_30d_cantidad: number;
  ultima_venta: string | null;
}

interface RpcRow {
  producto: {
    id: number;
    codigo: string | null;
    nombre: string;
    precio: number | string | null;
    precio_sin_iva: number | string | null;
    stock: number | null;
    stock_minimo: number | null;
    categoria: string | null;
    proveedor_id: number | null;
  };
  ventas_30d_cantidad: number;
  ultima_venta: string | null;
}

export const fichaProductoTool: Tool<FichaProductoParams, FichaProductoResult> = {
  name: "ficha_producto",
  description:
    "Devuelve el detalle completo de un producto: precio, stock, stock " +
    "mínimo, categoría, proveedor + métricas (cantidad vendida en los " +
    "últimos 30 días, fecha de última venta). Filtra por sucursal del " +
    "bot user.",
  parameters: {
    type: "object",
    properties: {
      producto_id: {
        type: "integer",
        description: "ID del producto (entero positivo).",
      },
    },
    required: ["producto_id"],
  },
  allowedRoles: ["admin", "preventista", "transportista", "encargado", "deposito"],
  handler: async ({ producto_id }, ctx) => {
    if (!Number.isInteger(producto_id) || producto_id <= 0) {
      throw new Error("producto_id debe ser un entero positivo");
    }
    if (ctx.sucursal_id == null && ctx.rol !== "admin") {
      throw new Error(
        "Sucursal no asignada en bot_usuarios — contactá al administrador",
      );
    }
    if (ctx.sucursal_id == null) {
      // Admin sin sucursal default — necesitamos una. Hoy no hay forma de
      // pasar la sucursal explícitamente; rechazamos hasta que el plan de
      // multi-sucursal switch (próxima iter) la resuelva.
      throw new Error(
        "Sucursal no resuelta para esta consulta. Mencionale al admin que " +
          "te asigne una sucursal default en bot_usuarios.",
      );
    }

    const { data, error } = await ctx.supabase.rpc("bot_ficha_producto", {
      p_producto_id: producto_id,
      p_sucursal_id: ctx.sucursal_id,
    });

    if (error) {
      throw new Error(`ficha_producto: ${error.message}`);
    }
    if (data === null || data === undefined) {
      throw new Error("Producto no encontrado o de otra sucursal");
    }

    const row = data as RpcRow;
    const stock = Number(row.producto.stock ?? 0);
    const stockMin = Number(row.producto.stock_minimo ?? 0);

    return {
      producto: {
        id: Number(row.producto.id),
        codigo: row.producto.codigo ?? null,
        nombre: row.producto.nombre,
        precio: Number(row.producto.precio ?? 0),
        precio_sin_iva: row.producto.precio_sin_iva == null
          ? null
          : Number(row.producto.precio_sin_iva),
        stock,
        stock_minimo: stockMin,
        bajo_stock: stock <= stockMin,
        categoria: row.producto.categoria ?? null,
        proveedor_id: row.producto.proveedor_id ?? null,
      },
      ventas_30d_cantidad: Number(row.ventas_30d_cantidad ?? 0),
      ultima_venta: row.ultima_venta ?? null,
    };
  },
};
