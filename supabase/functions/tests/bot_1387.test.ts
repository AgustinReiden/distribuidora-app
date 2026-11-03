// #1387 · el resumen perdido se recupera un día atrás (decisión del dueño 02/11)
// y el último pedido de la ficha es el día del pedido.
//   * leerPendientes: cada fila con su fecha; sin fecha (RPC vieja) es la de
//     hoy; "atrasado" sale de la fecha, no de la fila; los atrasados primero.
//   * los mensajes atrasados dicen la fecha que resumen y no hablan de "ayer".
//   * ultimo_pedido como YYYY-MM-DD se muestra con su día, en un runtime UTC.
// La parte SQL (qué devuelve bot_digest_pendientes) es scripts/test-bot-1387-1339.sql.

import { assert, assertEquals, assertStringIncludes } from "std/assert/mod.ts";
import { leerPendientes } from "../telegram-digest/pendientes.ts";
import { AVISO_ATRASADO, encabezadoDigest } from "../telegram-digest/digest.ts";
import { formatMetricasAdmin } from "../telegram-digest/admin.ts";
import {
  type DatosDigestPreventista,
  formatDigestPreventista,
} from "../telegram-digest/preventista.ts";
import { formatFechaCorta } from "../_shared/format.ts";

const FILA = {
  telegram_user_id: 111,
  perfil_id: "p-1",
  rol: "admin",
  sucursal_id: 1,
  sucursal_nombre: "Tucumán",
  secciones: ["ventas"],
};

// ---------------------------------------------------------------------------
// leerPendientes
// ---------------------------------------------------------------------------

Deno.test("leerPendientes: el atrasado sale primero y con su fecha", () => {
  const r = leerPendientes([
    { ...FILA, fecha: "2026-11-02", atrasado: false },
    { ...FILA, telegram_user_id: 222, fecha: "2026-11-02", atrasado: false },
    { ...FILA, fecha: "2026-11-01", atrasado: true },
  ], "2026-11-02");
  assertEquals(r.map((p) => [p.telegram_user_id, p.fecha, p.atrasado]), [
    [111, "2026-11-01", true],
    [111, "2026-11-02", false],
    [222, "2026-11-02", false],
  ]);
});

Deno.test("leerPendientes: una fila sin fecha (RPC anterior a #1387) es la de hoy", () => {
  const [p] = leerPendientes([FILA], "2026-11-02");
  assertEquals(p.fecha, "2026-11-02");
  assertEquals(p.atrasado, false);
});

Deno.test("leerPendientes: 'atrasado' sale de la fecha, no de lo que diga la fila", () => {
  const r = leerPendientes([
    { ...FILA, fecha: "2026-11-02", atrasado: true },
    { ...FILA, fecha: "2026-11-01", atrasado: false },
  ], "2026-11-02");
  assertEquals(r.map((p) => [p.fecha, p.atrasado]), [["2026-11-01", true], ["2026-11-02", false]]);
});

Deno.test("leerPendientes: rol, sucursal y secciones como siempre; basura → []", () => {
  const [p] = leerPendientes([{ ...FILA, rol: null, sucursal_id: "2", secciones: null }], "2026-11-02");
  assertEquals(p.rol, "admin");
  assertEquals(p.sucursal_id, 2);
  assertEquals(p.secciones, []);
  assertEquals(leerPendientes(null, "2026-11-02"), []);
  assertEquals(leerPendientes({ fecha: "x" }, "2026-11-02"), []);
});

// ---------------------------------------------------------------------------
// Los mensajes
// ---------------------------------------------------------------------------

Deno.test("encabezadoDigest atrasado: dice la fecha que resume y por qué llega hoy", () => {
  const h = encabezadoDigest("2026-11-01", "Tucumán", true);
  assertEquals(h, `🌅 Resumen atrasado del dom 01/11/2026 · Tucumán\n${AVISO_ATRASADO}`);
  // El de hoy no cambia.
  assertEquals(encabezadoDigest("2026-11-02", "Tucumán"), "🌅 Resumen lun 02/11/2026 · Tucumán");
  assertEquals(encabezadoDigest("2026-11-02", "Tucumán", false), encabezadoDigest("2026-11-02", "Tucumán"));
});

Deno.test("plantilla admin atrasada: 'ese día' en vez de 'ayer'", () => {
  const metricas = {
    ventas_dia: { pedidos: 2, total: 1000 },
    entregado_dia: { pedidos: 1, total: 500 },
    top_clientes: [{ nombre: "Kiosco", total: 1000, pedidos: 1 }],
    top_productos: [{ nombre: "Agua", cantidad: 3 }],
  };
  const atrasado = formatMetricasAdmin(metricas, { atrasado: true });
  assertStringIncludes(atrasado, "📊 Pedidos de ese día");
  assertStringIncludes(atrasado, "🏪 Mejores clientes de ese día");
  assertStringIncludes(atrasado, "📦 Lo más pedido ese día");
  assert(!/ayer/i.test(atrasado), atrasado);

  const normal = formatMetricasAdmin(metricas);
  assertStringIncludes(normal, "📊 Pedidos de ayer");
  assertStringIncludes(normal, "📦 Lo más pedido ayer");

  const vacio = { ventas_dia: { pedidos: 0 }, entregado_dia: { pedidos: 0 } };
  assertEquals(formatMetricasAdmin(vacio, { atrasado: true }), "📊 Ese día no hubo pedidos.");
  assertEquals(formatMetricasAdmin(vacio), "📊 Ayer no hubo pedidos.");
});

const DATOS: DatosDigestPreventista = {
  mis_ventas: { dia_tomados_pedidos: 2, dia_tomados_total: 1000, mes_total: 5000, mes_pedidos: 4, mes_clientes: 3 },
  mis_atrasados: { clientes_en_cartera: 10, atrasados: 0, monto_mensual_en_riesgo: 0, clientes: [] },
};

Deno.test("resumen del preventista atrasado: la fecha en el título y 'ese día' en el cuerpo", () => {
  const t = formatDigestPreventista("2026-11-01", DATOS, ["mis_ventas"], "Tucumán", true) ?? "";
  assert(t.startsWith(`🌅 Tu resumen atrasado del dom 01/11/2026 · Tucumán\n${AVISO_ATRASADO}\n`), t);
  assertStringIncludes(t, "Ese día tomaste 2 pedidos");
  assert(!/ayer tomaste/i.test(t), t);

  const sinPedidos = formatDigestPreventista(
    "2026-11-01",
    { ...DATOS, mis_ventas: { ...DATOS.mis_ventas, dia_tomados_pedidos: 0 } },
    ["mis_ventas"],
    null,
    true,
  ) ?? "";
  assertStringIncludes(sinPedidos, "Ese día no tomaste pedidos.");

  const normal = formatDigestPreventista("2026-11-02", DATOS, ["mis_ventas"], "Tucumán") ?? "";
  assert(normal.startsWith("🌅 Tu resumen lun 02/11/2026 · Tucumán\n━"), normal);
  assertStringIncludes(normal, "Ayer tomaste 2 pedidos");
});

// ---------------------------------------------------------------------------
// ultimo_pedido = MAX(pedidos.fecha)
// ---------------------------------------------------------------------------

Deno.test("ultimo_pedido como fecha pelada: se muestra su día, no el anterior", () => {
  // La RPC devuelve un `date` (#1387). El formatter corre en la TZ del runtime
  // (UTC en Supabase): un YYYY-MM-DD se lee como medianoche UTC y conserva el día.
  // Con la timestamp de carga, un pedido cargado a las 22 de Argentina del 02/11
  // (01:00 UTC del 03/11) se mostraba como del 03/11.
  if (new Intl.DateTimeFormat().resolvedOptions().timeZone !== "UTC") return;
  assertEquals(formatFechaCorta("2026-11-02"), "02/11/26");
});
