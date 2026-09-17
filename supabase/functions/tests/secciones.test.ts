import { assert, assertEquals } from "std/assert/mod.ts";
import {
  filtrarMetricas,
  incluyeVencimientos,
  SECCIONES,
  tieneSeccionesDeMetricas,
} from "../telegram-digest/secciones.ts";

// Muestra recortada de `bot_metricas_admin_dia`, con una clave por sección.
const METRICAS = {
  fecha: "2026-09-15",
  sucursal_id: 1,
  delta_pct: 113.3,
  ventas_dia: { total: 1940920, pedidos: 46 },
  promedio_7d: { total_dia_avg: 910068.57 },
  top_clientes: [{ nombre: "PANIFICACION FLORIDA", total: 136500 }],
  top_productos: [{ nombre: "MANAOS POMELO 3 LT", cantidad: 48 }],
  stock_critico: { top: [{ nombre: "PLACER POMELO 1,5 LT", stock: 0 }] },
  cxc_vencido: { monto_vencido: 2238840, pedidos_vencidos: 16 },
  cuentas_por_cobrar: { deuda_total: 5809200, clientes_con_saldo: 91 },
  pendientes_entrega: { count: 74, monto: 2943920 },
  pendientes_pago: { count: 105, saldo: 5809200 },
  recorridos_hoy: { count: 1, en_curso: 1 },
  rendiciones_pendientes: { count: 1, dias_mas_vieja: 154 },
};

// ============================================================================
// 1. El catálogo contra la lista blanca del CHECK de la base
// ============================================================================

Deno.test("SECCIONES cubre exactamente la lista blanca de bot_digest_config_secciones_ck", () => {
  // Copia literal del CHECK de la migración. Si agregás una sección a la base
  // y no al catálogo, se guarda y no se muestra nunca — este test es el que
  // lo hace visible. Ver el comentario de cabecera de secciones.ts.
  const enLaBase = [
    "ventas",
    "top_clientes",
    "top_productos",
    "stock_critico",
    "deuda",
    "pendientes_entrega",
    "pendientes_pago",
    "recorridos",
    "rendiciones",
    "vencimientos",
  ];
  assertEquals(Object.keys(SECCIONES).sort(), [...enLaBase].sort());
});

Deno.test("SECCIONES: ninguna clave de métricas se reparte entre dos secciones", () => {
  // Si dos secciones habilitaran la misma clave, apagar una no sacaría el dato
  // del mensaje y el panel mentiría.
  const vistas = new Set<string>();
  for (const claves of Object.values(SECCIONES)) {
    for (const c of claves) {
      assert(!vistas.has(c), `la clave ${c} está en dos secciones`);
      vistas.add(c);
    }
  }
});

// ============================================================================
// 2. filtrarMetricas
// ============================================================================

Deno.test("filtrarMetricas: deja sólo las claves de las secciones pedidas", () => {
  const out = filtrarMetricas(METRICAS, ["ventas", "deuda"]) as Record<
    string,
    unknown
  >;

  // Las de ventas y deuda entran…
  assertEquals(out.ventas_dia, METRICAS.ventas_dia);
  assertEquals(out.promedio_7d, METRICAS.promedio_7d);
  assertEquals(out.delta_pct, METRICAS.delta_pct);
  assertEquals(out.cxc_vencido, METRICAS.cxc_vencido);
  assertEquals(out.cuentas_por_cobrar, METRICAS.cuentas_por_cobrar);

  // …y el resto no está. No es que valga 0: la clave no existe, que es lo que
  // hace que el prompt no la nombre.
  assert(!("top_clientes" in out));
  assert(!("stock_critico" in out));
  assert(!("rendiciones_pendientes" in out));
});

Deno.test("filtrarMetricas: fecha y sucursal_id van siempre, aunque no se pida ninguna sección", () => {
  const out = filtrarMetricas(METRICAS, []) as Record<string, unknown>;
  assertEquals(out, { fecha: "2026-09-15", sucursal_id: 1 });
});

Deno.test("filtrarMetricas: una sección desconocida se ignora sin romper", () => {
  // Caso real: una fila vieja con una sección que después se sacó del
  // catálogo. No tiene que voltear el digest de esa persona.
  const out = filtrarMetricas(METRICAS, ["ventas", "seccion_que_ya_no_existe"]) as Record<
    string,
    unknown
  >;
  assertEquals(out.ventas_dia, METRICAS.ventas_dia);
  assert(!("top_clientes" in out));
});

Deno.test("filtrarMetricas: el default reproduce el digest previo a la configuración", () => {
  const out = filtrarMetricas(METRICAS, [
    "ventas",
    "top_clientes",
    "stock_critico",
    "deuda",
    "vencimientos",
  ]) as Record<string, unknown>;

  assertEquals(
    Object.keys(out).sort(),
    [
      "cuentas_por_cobrar",
      "cxc_vencido",
      "delta_pct",
      "fecha",
      "promedio_7d",
      "stock_critico",
      "sucursal_id",
      "top_clientes",
      "ventas_dia",
    ],
  );
});

Deno.test("filtrarMetricas: null o no-objeto pasa tal cual", () => {
  assertEquals(filtrarMetricas(null, ["ventas"]), null);
  assertEquals(filtrarMetricas("no soy un objeto", ["ventas"]), "no soy un objeto");
});

// ============================================================================
// 3. Predicados
// ============================================================================

Deno.test("incluyeVencimientos: sólo cuando la sección está prendida", () => {
  assert(incluyeVencimientos(["ventas", "vencimientos"]));
  assert(!incluyeVencimientos(["ventas", "deuda"]));
  assert(!incluyeVencimientos([]));
});

Deno.test("tieneSeccionesDeMetricas: 'vencimientos' sola no justifica llamar a Gemini", () => {
  // vencimientos no sale de la RPC ni pasa por el modelo: se arma con
  // formatVencimientosTexto. Si es lo único prendido, no hay nada que narrar.
  assert(!tieneSeccionesDeMetricas(["vencimientos"]));
  assert(!tieneSeccionesDeMetricas([]));
  assert(tieneSeccionesDeMetricas(["vencimientos", "ventas"]));
  assert(tieneSeccionesDeMetricas(["rendiciones"]));
});
