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

// ---------------------------------------------------------------------------
// mig 307: /sugerencias con clientes_atrasados
// ---------------------------------------------------------------------------
import { formatSugerenciasResult } from "../telegram-webhook/formatters/sugerencias.ts";
import type { ClientesAtrasadosResult } from "../_shared/tools/common/clientes_atrasados.ts";

function atrasados(cartera: "sucursal" | "preventista"): ClientesAtrasadosResult {
  const fila = {
    cliente_id: 1, codigo: 10, nombre: "Kiosco (Centro) - 2", zona: "ZONA 1", es_comodin: false,
    saldo: 1500.5, ultima_compra: "2026-09-14", dias_sin_comprar: 23, frecuencia_dias: 5,
    ratio: 4.6, estado: "atrasado", monto_mensual: 395583.33,
  };
  return {
    cartera, preventista: null, montos: cartera === "sucursal" ? "todos" : "propios",
    clientes_en_cartera: 614, por_estado: {}, atrasados: 2, monto_mensual_en_riesgo: 3331340.97,
    criterio: null, alerta_app_clientes_inactivos: null,
    clientes: [fila, { ...fila, cliente_id: 2, nombre: "Otro.kiosco" }],
  };
}

Deno.test("/sugerencias: todo carácter reservado de MarkdownV2 va escapado", () => {
  const out = formatSugerenciasResult(atrasados("preventista"));
  // Reservados que el formatter no usa a propósito como marcado (* sí se usa para negrita).
  for (const ch of ["~", "(", ")", ".", "-", "|", "#", "!", "_", "[", "]", "{", "}", "+", "=", ">"]) {
    for (let i = out.indexOf(ch); i !== -1; i = out.indexOf(ch, i + 1)) {
      assert(out[i - 1] === "\\", `"${ch}" sin escapar en: ...${out.slice(Math.max(0, i - 20), i + 5)}...`);
    }
  }
  assertStringIncludes(out, "\~5");
});

Deno.test("/sugerencias: dice 'en la sucursal' al admin y 'en tu cartera' al preventista", () => {
  assertStringIncludes(formatSugerenciasResult(atrasados("sucursal")), "en la sucursal");
  assertStringIncludes(formatSugerenciasResult(atrasados("preventista")), "en tu cartera");
});
