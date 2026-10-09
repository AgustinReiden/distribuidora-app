// Tests unitarios de la plantilla del resumen diario del admin (#1041).
// `formatMetricasAdmin` recibe el JSON de `bot_metricas_admin_dia` (ya filtrado
// por las secciones del admin) y devuelve el texto. Sin modelo de por medio.

import { assert, assertEquals, assertStringIncludes } from "std/assert/mod.ts";
import { formatMetricasAdmin } from "../telegram-digest/admin.ts";
import { formatCurrency } from "../_shared/format.ts";

const COMPLETO = {
  fecha: "2026-10-07",
  ventas_dia: { pedidos: 12, total: 125500 },
  entregado_dia: { pedidos: 9, total: 98000 },
  promedio_7d: { pedidos_dia_avg: 10, total_dia_avg: 106000 },
  delta_pct: 18.4,
  top_clientes: [
    { cliente_id: 1, nombre: "Almacén Centro", pedidos: 2, total: 45000 },
    { cliente_id: 2, nombre: "Kiosco Norte", pedidos: 1, total: 30000 },
    { cliente_id: 3, nombre: "Despensa Sur", pedidos: 1, total: 20000 },
    { cliente_id: 4, nombre: "Cuarto Cliente", pedidos: 1, total: 10000 },
  ],
  top_productos: [
    { producto_id: 1, nombre: "Cola 2.25", cantidad: 40 },
    { producto_id: 2, nombre: "Azúcar 1kg", cantidad: 30 },
    { producto_id: 3, nombre: "Yerba 1kg", cantidad: 20 },
    { producto_id: 4, nombre: "Cuarto Producto", cantidad: 10 },
  ],
  stock_critico: {
    count: 3,
    top: [{ nombre: "Harina 000", stock: 2, stock_minimo: 10 }],
  },
  cuentas_por_cobrar: { clientes_con_saldo: 5, deuda_total: 89300 },
  cxc_vencido: { clientes_vencidos: 2, monto_vencido: 40000 },
  pendientes_entrega: { count: 3, monto: 12000 },
  pendientes_pago: { count: 2, saldo: 9500 },
  recorridos_hoy: { count: 1, en_curso: 1, total_paradas: 8 },
  rendiciones_pendientes: { count: 2, dias_mas_vieja: 3 },
};

Deno.test("plantilla admin: cada bloque presente y en el orden documentado", () => {
  const t = formatMetricasAdmin(COMPLETO);
  const marcas = [
    "📊 Pedidos de ayer",
    "🏪 Mejores clientes de ayer",
    "📦 Lo más pedido ayer",
    "⚠️ Stock bajo mínimo",
    "💰 Cuentas por cobrar",
    "🚚 Sin entregar",
    "🧾 Pedidos con saldo sin pagar",
    "🗺️ Recorridos de hoy",
    "📋 Rendiciones sin controlar",
  ];
  let ultimo = -1;
  for (const m of marcas) {
    const i = t.indexOf(m);
    assert(i >= 0, `falta el bloque ${m}`);
    assert(i > ultimo, `el bloque ${m} está fuera de orden`);
    ultimo = i;
  }
  assertStringIncludes(t, `Tomados: ${formatCurrency(125500)} en 12 pedidos`);
  assertStringIncludes(t, `Entregado (venta): ${formatCurrency(98000)} en 9 pedidos`);
  assertStringIncludes(t, `promedio 7 días: ${formatCurrency(106000)}, +18%`);
  assertStringIncludes(t, `Por cobrar: ${formatCurrency(89300)} de 5 clientes`);
  assertStringIncludes(t, `Vencido: ${formatCurrency(40000)} de 2 clientes`);
  assertStringIncludes(t, `3 pedidos por ${formatCurrency(12000)}`);
  assertStringIncludes(t, `2, por ${formatCurrency(9500)}`);
  assertStringIncludes(t, "Recorridos de hoy: 1 (1 en curso), 8 paradas");
  assertStringIncludes(t, "La más vieja es de hace 3 días.");
  // Los bloques van separados por una línea en blanco.
  assertEquals(t.split("\n\n").length, marcas.length);
});

Deno.test("plantilla admin: 0 tomados y 0 entregados → 'Ayer no hubo pedidos.' y nunca '$ 0'", () => {
  const t = formatMetricasAdmin({
    ventas_dia: { pedidos: 0, total: 0 },
    entregado_dia: { pedidos: 0, total: 0 },
    promedio_7d: { total_dia_avg: 100000 },
    delta_pct: -100,
  });
  assertEquals(t, "📊 Ayer no hubo pedidos.");
  assert(!t.includes("$ 0"));
});

Deno.test("plantilla admin: lo tomado no se llama 'ventas'", () => {
  const t = formatMetricasAdmin(COMPLETO);
  assert(!t.includes("Ventas"), "no debe haber un rótulo 'Ventas'");
  assert(!/ventas de ayer/i.test(t));
  // Lo entregado sí es la venta.
  assertStringIncludes(t, "Entregado (venta)");
  assertStringIncludes(t, "Tomados:");
});

Deno.test("plantilla admin: delta negativo con '−' y redondeo; delta null sin porcentaje", () => {
  const base = { ventas_dia: { pedidos: 4, total: 50000 }, promedio_7d: { total_dia_avg: 60000 } };
  const neg = formatMetricasAdmin({ ...base, delta_pct: -12.6 });
  assertStringIncludes(neg, "−13%");
  assert(!neg.includes("-12"), "no debe quedar el guion ni el decimal");

  const sinDelta = formatMetricasAdmin({ ...base, delta_pct: null });
  assertStringIncludes(sinDelta, `promedio 7 días: ${formatCurrency(60000)})`);
  assert(!sinDelta.includes("%"));

  const cero = formatMetricasAdmin({ ...base, delta_pct: 0.2 });
  assertStringIncludes(cero, ", igual");
});

Deno.test("plantilla admin: una sección en cero se omite", () => {
  const t = formatMetricasAdmin({
    ...COMPLETO,
    stock_critico: { count: 0, top: [] },
    pendientes_entrega: { count: 0, monto: 0 },
    pendientes_pago: { count: 0, saldo: 0 },
    rendiciones_pendientes: { count: 0, dias_mas_vieja: 0 },
    cuentas_por_cobrar: { clientes_con_saldo: 0, deuda_total: 0 },
    cxc_vencido: { clientes_vencidos: 0, monto_vencido: 0 },
    recorridos_hoy: { count: 0, en_curso: 0, total_paradas: 0 },
    top_clientes: [],
    top_productos: [],
  });
  assertEquals(t.split("\n\n").length, 1);
  assertStringIncludes(t, "📊 Pedidos de ayer");
  for (
    const nada of [
      "Stock",
      "Sin entregar",
      "saldo sin pagar",
      "Rendiciones",
      "Cuentas por cobrar",
      "Recorridos",
    ]
  ) {
    assert(!t.includes(nada), `no debía aparecer: ${nada}`);
  }
});

Deno.test("plantilla admin: una clave ausente (sección apagada) no se nombra", () => {
  const t = formatMetricasAdmin({ recorridos_hoy: { count: 2, en_curso: 0, total_paradas: 10 } });
  assertEquals(t, "🗺️ Recorridos de hoy: 2, 10 paradas");
  assert(!t.includes("Pedidos"));
  assert(!t.includes("en curso"));
  // Sin ninguna clave conocida no hay mensaje.
  assertEquals(formatMetricasAdmin({ fecha: "2026-10-07" }), "");
});

Deno.test("plantilla admin: los tops se cortan en 3", () => {
  const t = formatMetricasAdmin(COMPLETO);
  assertStringIncludes(t, "Despensa Sur");
  assert(!t.includes("Cuarto Cliente"));
  assertStringIncludes(t, "Yerba 1kg");
  assert(!t.includes("Cuarto Producto"));
});

Deno.test("plantilla admin: el comodín lleva '(mostrador)'", () => {
  const t = formatMetricasAdmin({
    top_clientes: [
      { nombre: "Consumidor Final", es_comodin: true, pedidos: 3, total: 15000 },
      { nombre: "Almacén Centro", es_comodin: false, pedidos: 1, total: 9000 },
    ],
  });
  assertStringIncludes(t, "Consumidor Final (mostrador)");
  assert(!t.includes("Almacén Centro (mostrador)"));
});

Deno.test("plantilla admin: stock muestra '…y N más.' cuando el conteo supera la lista", () => {
  const con = formatMetricasAdmin({
    stock_critico: { count: 5, top: [{ nombre: "Harina", stock: 1, stock_minimo: 10 }] },
  });
  assertStringIncludes(con, "5 productos");
  assertStringIncludes(con, "Harina: quedan 1 (mínimo 10)");
  assertStringIncludes(con, "…y 4 más.");

  const sin = formatMetricasAdmin({
    stock_critico: { count: 1, top: [{ nombre: "Harina", stock: 1, stock_minimo: 10 }] },
  });
  assertStringIncludes(sin, "1 producto\n");
  assert(!sin.includes("más."));
});

Deno.test("plantilla admin: singular y plural", () => {
  const t = formatMetricasAdmin({
    ventas_dia: { pedidos: 1, total: 5000 },
    cuentas_por_cobrar: { clientes_con_saldo: 1, deuda_total: 7000 },
    cxc_vencido: { clientes_vencidos: 1, monto_vencido: 3000 },
    pendientes_entrega: { count: 1, monto: 1000 },
    rendiciones_pendientes: { count: 1, dias_mas_vieja: 1 },
    recorridos_hoy: { count: 1, en_curso: 0, total_paradas: 1 },
  });
  assertStringIncludes(t, "en 1 pedido");
  assert(!t.includes("1 pedidos"));
  assertStringIncludes(t, "de 1 cliente");
  assert(!t.includes("1 clientes"));
  assertStringIncludes(t, "hace 1 día.");
  assert(!t.includes("1 días"));
  assertStringIncludes(t, "1 parada");
  assert(!t.includes("1 paradas"));
});

Deno.test("plantilla admin: los numeric de Postgres que llegan como string se formatean bien", () => {
  const t = formatMetricasAdmin({
    ventas_dia: { pedidos: "12", total: "125500.00" },
    promedio_7d: { total_dia_avg: "106000.50" },
    delta_pct: "18.4",
    cuentas_por_cobrar: { clientes_con_saldo: "5", deuda_total: "89300.00" },
    top_productos: [{ nombre: "Cola", cantidad: "40.00" }],
    stock_critico: { count: "2", top: [{ nombre: "Harina", stock: "1", stock_minimo: "10" }] },
  });
  assertStringIncludes(t, `Tomados: ${formatCurrency(125500)} en 12 pedidos`);
  assertStringIncludes(t, "+18%");
  assertStringIncludes(t, `Por cobrar: ${formatCurrency(89300)} de 5 clientes`);
  assertStringIncludes(t, "Cola — 40 u.");
  assertStringIncludes(t, "…y 1 más.");
  assert(!t.includes("NaN"));
});

Deno.test("plantilla admin: entrada basura → ''", () => {
  assertEquals(formatMetricasAdmin(null), "");
  assertEquals(formatMetricasAdmin(undefined), "");
  assertEquals(formatMetricasAdmin([]), "");
  assertEquals(formatMetricasAdmin([{ ventas_dia: { pedidos: 1 } }]), "");
  assertEquals(formatMetricasAdmin("ventas_dia"), "");
  assertEquals(formatMetricasAdmin(42), "");
});
