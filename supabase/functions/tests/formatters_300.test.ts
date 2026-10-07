// Formatters de las fichas después de las migs 296/300: lo que el usuario lee
// en el chat tiene que decir de quién es cada número.
import { assert, assertStringIncludes } from "std/assert/mod.ts";
import { formatFichaCliente } from "../telegram-webhook/formatters/cliente.ts";
import { formatFichaProducto } from "../telegram-webhook/formatters/ficha-producto.ts";
import type { FichaClienteResult } from "../_shared/tools/common/ficha_cliente.ts";
import type { FichaProductoResult } from "../_shared/tools/common/ficha_producto.ts";

function ficha(over: Partial<FichaClienteResult> = {}): FichaClienteResult {
  return {
    cliente: { id: 454, codigo: 438, nombre: "Cliente extra", direccion: null, telefono: null, zona: null },
    saldo_actual: 0,
    limite_credito: 0,
    credito_disponible: 0,
    total_pedidos: 3,
    total_compras: 1500,
    alcance_totales: "todos",
    total_pagos: 1500,
    pedidos_pendientes_pago: 0,
    ultimo_pedido: null,
    ultimo_pago: null,
    es_comodin: false,
    ...over,
  };
}

Deno.test("ficha de cliente: el comodín se aclara, un comercio no", () => {
  assertStringIncludes(formatFichaCliente(ficha({ es_comodin: true })), "mostrador");
  assert(!formatFichaCliente(ficha()).includes("mostrador"));
});

Deno.test("ficha de cliente: 'Tus pedidos' cuando son sólo los propios, y sin pagos si no los ve", () => {
  const propia = formatFichaCliente(ficha({ alcance_totales: "propios", total_pagos: null }));
  assertStringIncludes(propia, "Tus pedidos");
  assert(!propia.includes("Pagos"), "no debe mostrar pagos que el rol no ve");
  assertStringIncludes(formatFichaCliente(ficha()), "Pedidos:");
});

function producto(over: Partial<FichaProductoResult> = {}): FichaProductoResult {
  return {
    producto: {
      id: 126, codigo: "1", nombre: "AGUA 600", precio: 1000, precio_sin_iva: null,
      stock: 918, stock_minimo: 10, bajo_stock: false, categoria: null, proveedor_id: null,
    },
    ventas_30d_cantidad: 699,
    regaladas_30d_cantidad: 31,
    ultima_venta: "2026-10-05",
    ...over,
  };
}

Deno.test("ficha de producto: regaladas aparte, y nada de ventas para quien no las ve", () => {
  const admin = formatFichaProducto(producto());
  assertStringIncludes(admin, "699");
  assertStringIncludes(admin, "Regaladas");
  assert(!formatFichaProducto(producto({ regaladas_30d_cantidad: 0 })).includes("Regaladas"));
  const preventista = formatFichaProducto(
    producto({ ventas_30d_cantidad: null, regaladas_30d_cantidad: null, ultima_venta: null }),
  );
  assert(!preventista.includes("Ventas"), "el preventista no ve el volumen de la sucursal");
  assert(!preventista.includes("Regaladas"));
});
