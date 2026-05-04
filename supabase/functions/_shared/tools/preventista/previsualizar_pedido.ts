// Tool: previsualizar_pedido (read-only / dry-run)
//
// Calcula el resumen completo de un pedido usando la MISMA lógica que la
// app web (mayorista, promos auto-aplicables) y devuelve un confirmacion_id
// con TTL 10 min que el callback "Confirmar" usa después para crear el
// pedido real.
//
// Diseño:
//   1. Validar inputs (cliente_id, items[]).
//   2. Validar cliente existe + sucursal correcta + scoping (asignado/huérfano para preventista).
//   3. Cargar productos referenciados (precio, stock, IVA).
//   4. Cargar pricingMap + promoMap (../pricing).
//   5. Resolver promos (bonificaciones) + precios mayoristas usando los utils
//      compartidos en _shared/utils/.
//   6. Construir items finales (incluye items "regalo" como es_bonificacion=true).
//   7. Calcular total, alertas (stock por item, crédito).
//   8. INSERT en bot_pedidos_pendientes con items pre-computados (mismo shape
//      que crear_pedido_completo espera).
//   9. Retornar resumen + confirmacion_id.

import type { Tool } from "../base.ts";
import type { SupabaseClient } from "@supabase/supabase-js";
import { loadPricingContext } from "../../pricing/index.ts";
import {
  resolverPreciosMayorista,
  type ItemPedido,
} from "../../utils/precioMayorista.ts";
import { resolverPromociones } from "../../utils/promociones.ts";

export interface PrevisualizarPedidoParams {
  cliente_id: number;
  items: Array<{ producto_id: number; cantidad: number }>;
}

export interface ResumenItem {
  producto_id: number;
  codigo: string | null;
  nombre: string;
  cantidad: number;
  precio_unitario: number;
  subtotal: number;
  regla_precio: "base" | "mayorista" | "promo_regalo";
  es_bonificacion: boolean;
  promo_nombre?: string | null;
  stock_disponible: number;
}

export interface AlertaStock {
  producto_id: number;
  nombre: string;
  pedido: number;
  disponible: number;
}

export interface AlertaCredito {
  limite: number;
  saldo_actual: number;
  pedido_total: number;
  excedente: number;
}

export interface PrevisualizarPedidoResult {
  confirmacion_id: string;
  cliente: {
    id: number;
    codigo: number | null;
    nombre: string;
    saldo_actual: number;
    limite_credito: number;
  };
  items: ResumenItem[];
  total: number;
  total_items: number;
  forma_pago_default: "efectivo";
  alertas: {
    stock: AlertaStock[];
    credito: AlertaCredito | null;
  };
}

interface ProductoRow {
  id: number;
  codigo: string | null;
  nombre: string;
  precio: number | string;
  stock: number;
  porcentaje_iva: number | null;
  impuestos_internos: number | null;
  activo: boolean;
  sucursal_id: number;
}

interface ClienteRow {
  id: number;
  codigo: number | null;
  nombre_fantasia: string | null;
  razon_social: string | null;
  saldo_cuenta: number | string;
  limite_credito: number | string;
  activo: boolean;
  sucursal_id: number;
}

export const previsualizarPedidoTool: Tool<
  PrevisualizarPedidoParams,
  PrevisualizarPedidoResult
> = {
  name: "previsualizar_pedido",
  description:
    "Calcula el resumen de un pedido (cliente + items) aplicando precios " +
    "mayoristas y promos automáticas, igual que la app web. Devuelve un " +
    "confirmacion_id con TTL 10 min que el botón 'Confirmar' usa para " +
    "crear el pedido real. NO crea el pedido — solo previsualiza. " +
    "Incluye alertas de stock por item y de crédito si el cliente excede el " +
    "límite. Después del resumen, mostrá al usuario un keyboard inline con " +
    "los items + total + alertas. Forma de pago siempre 'efectivo' por default — " +
    "se ajusta en la app web si hace falta. Para preventistas: el cliente " +
    "debe estar asignado a ellos o ser huérfano (sin preventista asignado). " +
    "Para tomar el pedido el usuario debe haber confirmado explícitamente " +
    "con el callback de Telegram — vos NO crees el pedido.",
  parameters: {
    type: "object",
    properties: {
      cliente_id: {
        type: "integer",
        minimum: 1,
        description: "ID interno del cliente (sacalo antes con buscar_cliente).",
      },
      items: {
        type: "array",
        minItems: 1,
        maxItems: 50,
        items: {
          type: "object",
          properties: {
            producto_id: { type: "integer", minimum: 1 },
            cantidad: { type: "integer", minimum: 1, maximum: 1000 },
          },
          required: ["producto_id", "cantidad"],
        },
        description: "Items del pedido. Cada uno con producto_id (sacalo con buscar_producto) y cantidad (1-1000).",
      },
    },
    required: ["cliente_id", "items"],
  },
  allowedRoles: ["admin", "encargado", "preventista"],
  handler: async ({ cliente_id, items }, ctx) => {
    // ---- Validación de inputs ----
    if (!Number.isInteger(cliente_id) || cliente_id < 1) {
      throw new Error("cliente_id inválido");
    }
    if (!Array.isArray(items) || items.length === 0) {
      throw new Error("items vacío — pasame al menos 1 producto");
    }
    if (items.length > 50) {
      throw new Error("items: máximo 50 por pedido");
    }
    for (const it of items) {
      if (!Number.isInteger(it.producto_id) || it.producto_id < 1) {
        throw new Error(`Item con producto_id inválido: ${it.producto_id}`);
      }
      if (!Number.isInteger(it.cantidad) || it.cantidad < 1 || it.cantidad > 1000) {
        throw new Error(`Cantidad inválida (1-1000): ${it.cantidad}`);
      }
    }
    if (ctx.sucursal_id == null) {
      throw new Error("Sucursal no asignada — contactá al administrador");
    }

    const sb = ctx.supabase;
    const sucursalId = ctx.sucursal_id;

    // ---- Cargar cliente ----
    const cliente = await loadCliente(sb, cliente_id, sucursalId);
    if (!cliente) {
      throw new Error("Cliente no encontrado o sin permiso");
    }
    // Scoping preventista: el cliente debe estar asignado a él O ser huérfano
    if (ctx.rol === "preventista") {
      const allowed = await isClienteAccesibleParaPreventista(sb, cliente_id, ctx.perfil_id);
      if (!allowed) {
        throw new Error("Cliente asignado a otro preventista");
      }
    }

    // ---- Cargar productos referenciados ----
    const productoIds = items.map((it) => it.producto_id);
    const productosById = await loadProductos(sb, productoIds, sucursalId);
    for (const it of items) {
      if (!productosById.has(it.producto_id)) {
        throw new Error(`Producto ${it.producto_id} no encontrado o no activo`);
      }
    }

    // ---- Cargar pricing context ----
    const { pricingMap, promoMap } = await loadPricingContext(sb, sucursalId);

    // ---- Resolver promos primero (las bonificaciones se agregan como items) ----
    const itemsParaUtils: ItemPedido[] = items.map((it) => {
      const p = productosById.get(it.producto_id)!;
      return {
        productoId: String(it.producto_id),
        cantidad: it.cantidad,
        precioUnitario: Number(p.precio),
      };
    });
    const promoRes = resolverPromociones(itemsParaUtils, promoMap);

    // ---- Resolver precios mayoristas ----
    const precios = resolverPreciosMayorista(itemsParaUtils, pricingMap);

    // ---- Construir items finales (los del usuario + las bonificaciones) ----
    const resumen: ResumenItem[] = [];
    let total = 0;

    for (const it of items) {
      const p = productosById.get(it.producto_id)!;
      const precioRes = precios.get(String(it.producto_id));
      const precioUnitario = precioRes ? precioRes.precioResuelto : Number(p.precio);
      const subtotal = precioUnitario * it.cantidad;
      total += subtotal;

      resumen.push({
        producto_id: it.producto_id,
        codigo: p.codigo,
        nombre: p.nombre,
        cantidad: it.cantidad,
        precio_unitario: precioUnitario,
        subtotal,
        regla_precio: precioRes?.esMayorista ? "mayorista" : "base",
        es_bonificacion: false,
        stock_disponible: p.stock,
      });
    }

    // Bonificaciones (regalos, no suman al total)
    for (const bonif of promoRes.bonificaciones) {
      const productoId = Number(bonif.productoId);
      // El producto regalo puede no estar entre los productos que pidió el user
      // — si no está, lo cargamos puntualmente.
      let p = productosById.get(productoId);
      if (!p) {
        p = await loadProducto(sb, productoId, sucursalId) ?? undefined;
        if (p) productosById.set(productoId, p);
      }
      if (!p) continue; // producto regalo no encontrado — skip silently

      resumen.push({
        producto_id: productoId,
        codigo: p.codigo,
        nombre: p.nombre,
        cantidad: bonif.cantidadBonificacion,
        precio_unitario: 0,
        subtotal: 0,
        regla_precio: "promo_regalo",
        es_bonificacion: true,
        promo_nombre: bonif.promoNombre,
        stock_disponible: p.stock,
      });
    }

    // ---- Alertas de stock ----
    // Acumulamos cantidad total por producto (incluyendo bonificaciones que mueven stock).
    const cantidadTotalPorProducto = new Map<number, number>();
    for (const r of resumen) {
      const cur = cantidadTotalPorProducto.get(r.producto_id) ?? 0;
      cantidadTotalPorProducto.set(r.producto_id, cur + r.cantidad);
    }
    const alertasStock: AlertaStock[] = [];
    for (const [pid, cantidad] of cantidadTotalPorProducto) {
      const p = productosById.get(pid)!;
      if (p.stock < cantidad) {
        alertasStock.push({
          producto_id: pid,
          nombre: p.nombre,
          pedido: cantidad,
          disponible: p.stock,
        });
      }
    }

    // ---- Alerta de crédito ----
    const limiteCredito = Number(cliente.limite_credito ?? 0);
    const saldoActual = Number(cliente.saldo_cuenta ?? 0);
    let alertaCredito: AlertaCredito | null = null;
    if (limiteCredito > 0 && (saldoActual + total) > limiteCredito) {
      alertaCredito = {
        limite: limiteCredito,
        saldo_actual: saldoActual,
        pedido_total: total,
        excedente: (saldoActual + total) - limiteCredito,
      };
    }

    // ---- Persistir en bot_pedidos_pendientes ----
    // El items shape coincide con el que crear_pedido_completo_bot lee.
    const itemsParaPersistir = resumen.map((r) => {
      const p = productosById.get(r.producto_id)!;
      const porcentajeIva = Number(p.porcentaje_iva ?? 0);
      const impInternos = Number(p.impuestos_internos ?? 0);
      // ZZ (consumidor final) usa el precio como total con IVA incluido.
      const netoUnitario = porcentajeIva > 0
        ? Number((r.precio_unitario / (1 + porcentajeIva / 100)).toFixed(4))
        : r.precio_unitario;
      const ivaUnitario = porcentajeIva > 0
        ? Number((r.precio_unitario - netoUnitario).toFixed(4))
        : 0;

      const promoId = r.es_bonificacion ? findPromoIdByName(promoRes.bonificaciones, r.promo_nombre ?? "") : null;

      return {
        producto_id: r.producto_id,
        cantidad: r.cantidad,
        precio_unitario: r.precio_unitario,
        neto_unitario: netoUnitario,
        iva_unitario: ivaUnitario,
        impuestos_internos_unitario: impInternos,
        porcentaje_iva: porcentajeIva,
        es_bonificacion: r.es_bonificacion,
        promocion_id: promoId,
      };
    });

    const totalNeto = itemsParaPersistir.reduce(
      (acc, it) => acc + (it.neto_unitario * it.cantidad),
      0,
    );
    const totalIva = itemsParaPersistir.reduce(
      (acc, it) => acc + (it.iva_unitario * it.cantidad),
      0,
    );

    const { data: insertData, error: insertErr } = await sb
      .from("bot_pedidos_pendientes")
      .insert({
        perfil_id: ctx.perfil_id,
        sucursal_id: sucursalId,
        cliente_id,
        items: itemsParaPersistir,
        total,
        total_neto: Number(totalNeto.toFixed(2)),
        total_iva: Number(totalIva.toFixed(2)),
        forma_pago: "efectivo",
      })
      .select("id")
      .single();
    if (insertErr) {
      throw new Error(`previsualizar_pedido: insert pendiente: ${insertErr.message}`);
    }
    const confirmacionId = (insertData as { id: string }).id;

    return {
      confirmacion_id: confirmacionId,
      cliente: {
        id: cliente.id,
        codigo: cliente.codigo,
        nombre: cliente.nombre_fantasia?.trim() || cliente.razon_social?.trim() || "(sin nombre)",
        saldo_actual: saldoActual,
        limite_credito: limiteCredito,
      },
      items: resumen,
      total,
      total_items: items.length,
      forma_pago_default: "efectivo",
      alertas: {
        stock: alertasStock,
        credito: alertaCredito,
      },
    };
  },
};

// ----------------------------------------------------------------------------
// Helpers internos
// ----------------------------------------------------------------------------

async function loadCliente(
  sb: SupabaseClient,
  clienteId: number,
  sucursalId: number,
): Promise<ClienteRow | null> {
  const { data, error } = await sb
    .from("clientes")
    .select("id, codigo, nombre_fantasia, razon_social, saldo_cuenta, limite_credito, activo, sucursal_id")
    .eq("id", clienteId)
    .eq("sucursal_id", sucursalId)
    .eq("activo", true)
    .maybeSingle();
  if (error) {
    throw new Error(`previsualizar_pedido: cliente lookup: ${error.message}`);
  }
  return (data as ClienteRow | null);
}

async function isClienteAccesibleParaPreventista(
  sb: SupabaseClient,
  clienteId: number,
  perfilId: string,
): Promise<boolean> {
  const { data, error } = await sb
    .from("cliente_preventistas")
    .select("preventista_id")
    .eq("cliente_id", clienteId);
  if (error) {
    throw new Error(`previsualizar_pedido: scoping check: ${error.message}`);
  }
  const rows = (data ?? []) as Array<{ preventista_id: string }>;
  if (rows.length === 0) return true; // huérfano
  return rows.some((r) => r.preventista_id === perfilId);
}

async function loadProductos(
  sb: SupabaseClient,
  ids: number[],
  sucursalId: number,
): Promise<Map<number, ProductoRow>> {
  const uniqIds = [...new Set(ids)];
  const { data, error } = await sb
    .from("productos")
    .select("id, codigo, nombre, precio, stock, porcentaje_iva, impuestos_internos, activo, sucursal_id")
    .in("id", uniqIds)
    .eq("sucursal_id", sucursalId)
    .eq("activo", true);
  if (error) {
    throw new Error(`previsualizar_pedido: productos lookup: ${error.message}`);
  }
  const out = new Map<number, ProductoRow>();
  for (const row of ((data ?? []) as ProductoRow[])) {
    out.set(row.id, row);
  }
  return out;
}

async function loadProducto(
  sb: SupabaseClient,
  id: number,
  sucursalId: number,
): Promise<ProductoRow | null> {
  const { data, error } = await sb
    .from("productos")
    .select("id, codigo, nombre, precio, stock, porcentaje_iva, impuestos_internos, activo, sucursal_id")
    .eq("id", id)
    .eq("sucursal_id", sucursalId)
    .eq("activo", true)
    .maybeSingle();
  if (error) {
    throw new Error(`previsualizar_pedido: producto regalo lookup: ${error.message}`);
  }
  return (data as ProductoRow | null);
}

function findPromoIdByName(
  bonifs: Array<{ promoId: string; promoNombre: string }>,
  nombre: string,
): number | null {
  if (!nombre) return null;
  const match = bonifs.find((b) => b.promoNombre === nombre);
  return match ? Number(match.promoId) : null;
}
