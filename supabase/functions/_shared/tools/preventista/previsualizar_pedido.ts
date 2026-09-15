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
//   5. Resolver precios con `orquestarPrecios` (_shared/utils/, sincronizado
//      byte a byte con la app): promo -> mayorista -> descuento del cliente.
//   6. Construir items finales (incluye items "regalo" como es_bonificacion=true).
//   7. Calcular total, alertas (stock por item, crédito).
//   8. INSERT en bot_pedidos_pendientes con items pre-computados (mismo shape
//      que crear_pedido_completo espera).
//   9. Retornar resumen + confirmacion_id.

import type { Tool } from "../base.ts";
import type { SupabaseClient } from "@supabase/supabase-js";
import { formatCurrency } from "../formatters.ts";
import { loadPricingContext } from "../../pricing/index.ts";
import {
  validarMOQPedido,
  type ItemPedido,
  type MinimosProducto,
  type PrecioResuelto,
} from "../../utils/precioMayorista.ts";
import {
  orquestarPrecios,
  type ItemResuelto,
  type OrquestacionPreciosResult,
} from "../../utils/orquestacionPrecios.ts";
import type {
  ClienteConDescuentos,
  DescuentoCategoriaCliente,
  ProductoConCategoria,
} from "../../utils/descuentoCliente.ts";

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
  regla_precio: "base" | "mayorista" | "desc_cliente" | "desc_categoria" | "promo_regalo";
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
  /**
   * "limite": el cliente tiene `limite_credito` cargado y el pedido lo supera.
   * "deuda": no tiene límite cargado (o no lo supera), pero ya arrastra saldo
   * pendiente — el criterio que usa la app (mismo que `avisoDeudaCliente` en
   * `src/utils/deudaCliente.ts`). En prod, de 718 clientes sólo 1 tiene
   * límite cargado y 121 tienen saldo_cuenta > 0 (#531/#587): sin esta rama
   * el bot no avisaba a casi nadie.
   */
  motivo: "limite" | "deuda";
  limite: number;
  saldo_actual: number;
  pedido_total: number;
  excedente: number;
  /** Texto ya armado para mostrarle al preventista, mismo criterio que la app. */
  mensaje: string;
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
  /** Texto libre. Es la clave del descuento por categoria del cliente (mig 079). */
  categoria: string | null;
  porcentaje_iva: number | null;
  impuestos_internos: number | null;
  /** Mínimo de unidades por pedido (mig 147). null = sin mínimo. */
  cantidad_minima_venta: number | null;
  sucursal_id: number;
}

interface ClienteRow {
  id: number;
  codigo: number | null;
  nombre_fantasia: string | null;
  razon_social: string | null;
  saldo_cuenta: number | string;
  limite_credito: number | string;
  /** Descuento general del cliente (%). Lo pisa el descuento por categoria si hay. */
  descuento_porcentaje: number | string | null;
  activo: boolean;
  sucursal_id: number;
  /** Reservado a administración (mig 214): ningún preventista le carga pedidos. */
  reservado_admin: boolean;
}

export const previsualizarPedidoTool: Tool<
  PrevisualizarPedidoParams,
  PrevisualizarPedidoResult
> = {
  name: "previsualizar_pedido",
  description:
    "Calcula el resumen de un pedido (cliente + items) aplicando promos " +
    "automáticas, precios mayoristas y el descuento del cliente (general o " +
    "por categoría), en ese orden y igual que la app web. Devuelve un " +
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
      const allowed = await isClienteAccesibleParaPreventista(
        sb,
        cliente_id,
        ctx.perfil_id,
        cliente.reservado_admin === true,
      );
      if (!allowed) {
        throw new Error(
          cliente.reservado_admin === true
            ? "Cliente reservado a administración"
            : "Cliente asignado a otro preventista",
        );
      }
    }

    // ---- Cargar productos referenciados ----
    const productoIds = items.map((it) => it.producto_id);
    const productosById = await loadProductos(sb, productoIds, sucursalId);
    for (const it of items) {
      const prod = productosById.get(it.producto_id);
      if (!prod) {
        throw new Error(`Producto ${it.producto_id} no encontrado en esta sucursal`);
      }
      // Sin precio de venta cargado no se puede vender: el backend lo rechaza
      // igual (trigger trg_validar_precio_item_pedido, mig 139), pero acá el
      // preventista recibe el motivo real en vez de un error opaco al confirmar.
      if (!(Number(prod.precio) > 0)) {
        throw new Error(
          `«${prod.nombre}» está pendiente de carga de precio de venta y no se puede vender. Avisá a administración.`,
        );
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
    // ---- Mínimo de venta ----
    // El mínimo es del producto (mig 147/169) y se evalúa con el mismo util
    // que la app web. El trigger de la DB rechaza igual, pero acá el
    // preventista recibe el motivo antes de confirmar, no un error opaco
    // después.
    const minimosProducto: MinimosProducto = new Map();
    for (const prod of productosById.values()) {
      if (prod.cantidad_minima_venta && prod.cantidad_minima_venta > 0) {
        minimosProducto.set(String(prod.id), prod.cantidad_minima_venta);
      }
    }
    const violacionesMOQ = validarMOQPedido(itemsParaUtils, minimosProducto);
    if (violacionesMOQ.length > 0) {
      const detalle = violacionesMOQ
        .map((v) => {
          const nombre = productosById.get(Number(v.productoId))?.nombre ?? v.productoId;
          return `«${nombre}»: mínimo ${v.cantidadMinima} (pediste ${v.cantidadActual})`;
        })
        .join("; ");
      throw new Error(`No se alcanza la compra mínima. ${detalle}`);
    }

    // ---- Resolver precios: promo -> mayorista -> descuento del cliente ----
    // Una sola función, la misma que corre la app web (sincronizada byte a
    // byte). Antes acá se llamaba a los utils sueltos y la SECUENCIA divergía:
    // el mayorista se resolvía también sobre los productos con promo y el
    // descuento del cliente no se aplicaba nunca. El mismo pedido daba un total
    // por Telegram y otro por la app — y crear_pedido_completo_bot copia el
    // total de la previsualización tal cual.
    const productosParaDescuento: ProductoConCategoria[] = [...productosById.values()]
      .map((p) => ({ id: String(p.id), categoria: p.categoria }));
    const clienteConDescuentos: ClienteConDescuentos = {
      descuento_porcentaje: Number(cliente.descuento_porcentaje ?? 0) || 0,
      descuentos_categoria: await loadDescuentosCategoria(sb, cliente_id),
    };

    const orquestacion = orquestarPrecios({
      items: itemsParaUtils,
      promoMap,
      pricingMap,
      productos: productosParaDescuento,
      cliente: clienteConDescuentos,
    });
    const precios = orquestacion.preciosResueltos;
    const total = orquestacion.total;

    // ---- Construir items finales (los del usuario + las bonificaciones) ----
    // orquestacion.items ya viene en orden: primero lo comprado, después los
    // regalos. promoIdPorItem acompaña al resumen índice a índice porque un
    // regalo cuyo producto no existe se saltea y correría la numeración.
    const resumen: ResumenItem[] = [];
    const promoIdPorItem: Array<number | null> = [];

    for (const item of orquestacion.items) {
      const productoId = Number(item.productoId);
      // El producto regalo puede no estar entre los productos que pidió el user
      // — si no está, lo cargamos puntualmente.
      let p = productosById.get(productoId);
      if (!p) {
        p = await loadProducto(sb, productoId, sucursalId) ?? undefined;
        if (p) productosById.set(productoId, p);
      }
      if (!p) continue; // producto regalo no encontrado — skip silently

      const esBonificacion = item.esBonificacion === true;
      const subtotal = esBonificacion ? 0 : item.precioUnitario * item.cantidad;

      resumen.push({
        producto_id: productoId,
        codigo: p.codigo,
        nombre: p.nombre,
        cantidad: item.cantidad,
        precio_unitario: item.precioUnitario,
        subtotal,
        regla_precio: reglaPrecioDeItem(item, orquestacion),
        es_bonificacion: esBonificacion,
        ...(esBonificacion ? { promo_nombre: item.promoNombre ?? null } : {}),
        stock_disponible: p.stock,
      });
      promoIdPorItem.push(
        esBonificacion && item.promoId ? Number(item.promoId) : null,
      );
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

    // ---- Compra mínima del pedido ----
    // El mínimo en $ es de la SUCURSAL (migs 204/205), a diferencia del MOQ de
    // más arriba que es por producto. Se corta acá, antes de persistir la
    // confirmación pendiente: `crear_pedido_completo_bot` lo rechaza igual, pero
    // entonces el preventista ya apretó "confirmar" y recibe un error opaco.
    const { data: politica } = await sb
      .from("politicas_comerciales")
      .select("monto_minimo_pedido")
      .eq("sucursal_id", sucursalId)
      .maybeSingle();
    const montoMinimo = Number(politica?.monto_minimo_pedido ?? 0) || 0;
    if (montoMinimo > 0 && total < montoMinimo) {
      throw new Error(
        `El pedido no alcanza la compra mínima de $${montoMinimo.toLocaleString("es-AR")}. ` +
          `Total del pedido: $${total.toLocaleString("es-AR")}.`,
      );
    }

    // ---- Alerta de crédito ----
    // Dos ramas, mismo criterio que la app (#531/#587): la mayoría de los
    // clientes no tiene límite de crédito cargado, así que basarse sólo en
    // `limite_credito` deja al bot sin avisar de la deuda previa que sí
    // muestra la app (mig 215, `saldo_cuenta`). Rama "límite" primero: si el
    // pedido supera el límite explícito, esa es la alerta que importa.
    const limiteCredito = Number(cliente.limite_credito ?? 0);
    const saldoActual = Number(cliente.saldo_cuenta ?? 0);
    let alertaCredito: AlertaCredito | null = null;
    if (limiteCredito > 0 && (saldoActual + total) > limiteCredito) {
      alertaCredito = {
        motivo: "limite",
        limite: limiteCredito,
        saldo_actual: saldoActual,
        pedido_total: total,
        excedente: (saldoActual + total) - limiteCredito,
        mensaje:
          `Este pedido supera el límite de crédito: ${
            formatCurrency(saldoActual + total)
          } de ${formatCurrency(limiteCredito)} disponibles.`,
      };
    } else if (saldoActual > 0) {
      // Mismo texto que ve el preventista en la app (avisoDeudaCliente,
      // src/utils/deudaCliente.ts).
      alertaCredito = {
        motivo: "deuda",
        limite: limiteCredito,
        saldo_actual: saldoActual,
        pedido_total: total,
        excedente: 0,
        mensaje:
          `Este cliente tiene una deuda previa de ${formatCurrency(saldoActual)}.`,
      };
    }

    // ---- Persistir en bot_pedidos_pendientes ----
    // El items shape coincide con el que crear_pedido_completo_bot lee.
    const itemsParaPersistir = resumen.map((r, idx) => {
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

      return {
        producto_id: r.producto_id,
        cantidad: r.cantidad,
        precio_unitario: r.precio_unitario,
        neto_unitario: netoUnitario,
        iva_unitario: ivaUnitario,
        impuestos_internos_unitario: impInternos,
        porcentaje_iva: porcentajeIva,
        es_bonificacion: r.es_bonificacion,
        promocion_id: promoIdPorItem[idx],
        // Por qué se cobró este precio (mig 148/149). `crear_pedido_completo_bot`
        // ignora las claves que no conoce, así que viaja de arriba: acá todavía
        // se sabe si el precio salió de una escala mayorista, y después de
        // crear el pedido ese contexto ya no existe. Lo lee `crear_pedido`.
        origen_precio: r.es_bonificacion
          ? "bonificacion"
          : (r.regla_precio === "base" ? "lista" : r.regla_precio),
        // Solo cuando el precio lo fijó una escala: una escala que aplicó sin
        // bajar el precio deja escalaId cargado igual, y atribuirle el descuento
        // sería mentir sobre quién decidió el precio (mig 148).
        grupo_precio_escala_id: r.regla_precio === "mayorista"
          ? (precios.get(String(r.producto_id))?.escalaId ?? null)
          : null,
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
    .select("id, codigo, nombre_fantasia, razon_social, saldo_cuenta, limite_credito, descuento_porcentaje, activo, sucursal_id, reservado_admin")
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
  reservadoAdmin: boolean,
): Promise<boolean> {
  // Reservado a administración (mig 214): no hay excepción de historial acá.
  // Ver el pasado es una cosa; cargarle un pedido nuevo es justo lo que la
  // marca cierra. El trigger trg_pedidos_cliente_reservado lo rechaza igual en
  // la base, pero el bot corre con service_role y conviene fallar antes, con un
  // mensaje entendible en vez de un error de Postgres.
  if (reservadoAdmin) return false;

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
  // NOTA: `productos` NO tiene columna `activo` (a diferencia de `clientes` o
  // `promociones`). Pedirla y filtrar por ella hacía fallar la query entera con
  // 42703, así que esta tool nunca pudo tomar un pedido. El equivalente real de
  // "no vendible" es no tener precio de venta, y eso se valida abajo con un
  // mensaje explícito en vez de filtrarlo (si se filtrara, el preventista vería
  // "producto no encontrado" y no entendería por qué).
  const { data, error } = await sb
    .from("productos")
    .select("id, codigo, nombre, precio, stock, categoria, porcentaje_iva, impuestos_internos, cantidad_minima_venta, sucursal_id")
    .in("id", uniqIds)
    .eq("sucursal_id", sucursalId);
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
    .select("id, codigo, nombre, precio, stock, categoria, porcentaje_iva, impuestos_internos, cantidad_minima_venta, sucursal_id")
    .eq("id", id)
    .eq("sucursal_id", sucursalId)
    .maybeSingle();
  if (error) {
    throw new Error(`previsualizar_pedido: producto regalo lookup: ${error.message}`);
  }
  return (data as ProductoRow | null);
}

async function loadDescuentosCategoria(
  sb: SupabaseClient,
  clienteId: number,
): Promise<DescuentoCategoriaCliente[]> {
  const { data, error } = await sb
    .from("cliente_descuentos_categoria")
    .select("categoria, descuento_porcentaje")
    .eq("cliente_id", clienteId);
  if (error) {
    throw new Error(`previsualizar_pedido: descuentos por categoría: ${error.message}`);
  }
  const rows = (data ?? []) as Array<
    { categoria: string; descuento_porcentaje: number | string }
  >;
  return rows.map((d) => ({
    categoria: d.categoria,
    descuento_porcentaje: Number(d.descuento_porcentaje) || 0,
  }));
}

/**
 * Por qué se cobró este precio. Misma precedencia que resolverOrigenPrecio de
 * la app (src/utils/origenPrecio.ts): bonificación -> mayorista -> descuento del
 * cliente -> lista. El bot no toma precios tipeados a mano, así que no hay rama
 * "manual".
 */
function reglaPrecioDeItem(
  item: ItemResuelto,
  orq: Pick<
    OrquestacionPreciosResult,
    "preciosResueltos" | "descuentoClientePct" | "descuentoPorCategoria"
  >,
): ResumenItem["regla_precio"] {
  if (item.esBonificacion) return "promo_regalo";
  const pid = String(item.productoId);
  const mayorista: PrecioResuelto | undefined = orq.preciosResueltos.get(pid);
  if (mayorista?.esMayorista) return "mayorista";
  if ((orq.descuentoClientePct.get(pid) ?? 0) > 0) {
    return orq.descuentoPorCategoria.has(pid) ? "desc_categoria" : "desc_cliente";
  }
  return "base";
}
