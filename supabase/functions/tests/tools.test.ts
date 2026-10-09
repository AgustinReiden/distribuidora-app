// Tests Deno para el tool registry framework + 3 common tools.
// Correr con: deno task test (desde supabase/functions/).
//
// Cubrimos:
//   1. registerTool throws on duplicate
//   2. canInvoke / permissions filter por rol
//   3. buscar_cliente happy path (preventista) + verifica filter cliente_preventistas
//   4. buscar_cliente input "x" (1 char) lanza "Búsqueda muy corta"
//   5. ficha_cliente cliente no encontrado lanza "Cliente no encontrado o sin permiso"
//   6. ficha_cliente happy path con RPC mockeada
//   7. invokeTool tool inexistente → ok:false con audit log
//   8. invokeTool permission denied → ok:false con audit log
//   9. buscar_cliente escapa metacaracteres PostgREST ('.', ':', '(', ')')
//  10. tools rechazan ctx.sucursal_id == null para roles no-admin
//  11. ficha_cliente: preventista no puede leer cliente NO asignado a él

import { assert, assertEquals, assertStringIncludes } from "std/assert/mod.ts";
import type { SupabaseClient } from "@supabase/supabase-js";

import {
  _clearToolsForTests,
  _resetRegisterFlagForTests,
  canInvoke,
  getTool,
  invokeTool,
  registerAllTools,
  registerTool,
} from "../_shared/tools/index.ts";
import { buscarClienteTool } from "../_shared/tools/common/buscar_cliente.ts";
import { buscarProductoTool } from "../_shared/tools/common/buscar_producto.ts";
import { fichaClienteTool } from "../_shared/tools/common/ficha_cliente.ts";
import { fichaProductoTool } from "../_shared/tools/common/ficha_producto.ts";
import { listarCategoriasTool } from "../_shared/tools/common/listar_categorias.ts";
import {
  esProductoMostrable,
  fetchMostrarSinStock,
} from "../_shared/utils/catalogoVisible.ts";
import { productosPorCategoriaTool } from "../_shared/tools/common/productos_por_categoria.ts";
import { ventasPeriodoTool } from "../_shared/tools/admin/ventas_periodo.ts";
import { ventasPorPreventistaTool } from "../_shared/tools/admin/ventas_por_preventista.ts";
import { rankingPreventistasPorProductoTool } from "../_shared/tools/admin/ranking_preventistas_por_producto.ts";
import { misVentasTool } from "../_shared/tools/preventista/mis_ventas.ts";
import { pendientesPagoTool } from "../_shared/tools/admin/pendientes_pago.ts";
import { historicoPagosClienteTool } from "../_shared/tools/admin/historico_pagos_cliente.ts";
import { comprasPeriodoTool } from "../_shared/tools/admin/compras_periodo.ts";
import { historicoClienteTool } from "../_shared/tools/preventista/historico_cliente.ts";
import { productosRecurrentesTool } from "../_shared/tools/preventista/productos_recurrentes.ts";
import { recorridoResumenTool } from "../_shared/tools/transportista/recorrido_resumen.ts";
import { misClientesTool } from "../_shared/tools/preventista/mis_clientes.ts";
import { clientesAtrasadosTool } from "../_shared/tools/common/clientes_atrasados.ts";
import { rankingClientesTool } from "../_shared/tools/common/ranking_clientes.ts";
import { productosSinVentaConStockTool, stockYVentasTool } from "../_shared/tools/common/productos_stock.ts";
import { resumenClienteVisitaTool } from "../_shared/tools/preventista/resumen_cliente_visita.ts";
import { miRecorridoHoyTool } from "../_shared/tools/transportista/mi_recorrido_hoy.ts";
import type { Tool, ToolContext } from "../_shared/tools/base.ts";
import { rolEfectivo } from "../_shared/tools/permissions.ts";
import { _setServiceRoleClientForTests } from "../_shared/supabase.ts";

// ============================================================================
// Mock helpers
// ============================================================================

interface QueryFilter {
  type: "eq" | "neq" | "in" | "gt" | "gte" | "not" | "or" | "ilike";
  args: unknown[];
}

interface QueryRecord {
  table: string;
  selectCols?: string;
  selectOpts?: Record<string, unknown>;
  filters: QueryFilter[];
  orderArgs?: unknown[];
  limitArg?: number;
  terminator: "maybeSingle" | "await";
}

interface MockSupabaseOpts {
  /** Respuesta para queries `.from(...).select(...)...await` */
  selectResponse?: {
    data: unknown[] | null;
    error: { message: string } | null;
    count?: number | null;
  };
  /** Respuesta para queries `.from(...).select(...)...maybeSingle()` */
  maybeSingleResponse?: {
    data: Record<string, unknown> | null;
    error: { message: string } | null;
  };
  /** Respuesta para `.rpc(...)` */
  rpcResponse?: { data: unknown; error: { message: string } | null };
  /** Si distintas tablas necesitan distintas respuestas, override por tabla. */
  perTable?: Record<string, MockSupabaseOpts>;
}

interface MockSupabaseSpy {
  queries: QueryRecord[];
  rpcCalls: Array<{ fn: string; params: Record<string, unknown> }>;
  inserts: Array<{ table: string; row: Record<string, unknown> }>;
}

function createMockSupabase(opts: MockSupabaseOpts = {}): {
  client: SupabaseClient;
  spy: MockSupabaseSpy;
} {
  const spy: MockSupabaseSpy = { queries: [], rpcCalls: [], inserts: [] };

  function buildQuery(table: string): QueryRecord {
    return { table, filters: [], terminator: "await" };
  }

  function makeBuilder(record: QueryRecord, tableOpts: MockSupabaseOpts) {
    // deno-lint-ignore no-explicit-any
    const builder: any = {
      select(cols: string, selectOpts?: Record<string, unknown>) {
        record.selectCols = cols;
        record.selectOpts = selectOpts;
        return builder;
      },
      eq(col: string, val: unknown) {
        record.filters.push({ type: "eq", args: [col, val] });
        return builder;
      },
      neq(col: string, val: unknown) {
        record.filters.push({ type: "neq", args: [col, val] });
        return builder;
      },
      in(col: string, vals: unknown[]) {
        record.filters.push({ type: "in", args: [col, vals] });
        return builder;
      },
      gte(col: string, val: unknown) {
        record.filters.push({ type: "gte", args: [col, val] });
        return builder;
      },
      not(col: string, op: string, val: unknown) {
        record.filters.push({ type: "not", args: [col, op, val] });
        return builder;
      },
      gt(col: string, val: unknown) {
        record.filters.push({ type: "gt", args: [col, val] });
        return builder;
      },
      or(expr: string) {
        record.filters.push({ type: "or", args: [expr] });
        return builder;
      },
      ilike(col: string, pattern: string) {
        record.filters.push({ type: "ilike", args: [col, pattern] });
        return builder;
      },
      order(col: string, orderOpts?: Record<string, unknown>) {
        record.orderArgs = [col, orderOpts];
        return builder;
      },
      limit(n: number) {
        record.limitArg = n;
        return builder;
      },
      maybeSingle() {
        record.terminator = "maybeSingle";
        const r = tableOpts.maybeSingleResponse ?? { data: null, error: null };
        return Promise.resolve(r);
      },
      // Thenable: cuando alguien hace `await query` sin un terminator explícito,
      // resolvemos con selectResponse.
      then(
        // deno-lint-ignore no-explicit-any
        onFulfilled?: (value: any) => any,
        // deno-lint-ignore no-explicit-any
        onRejected?: (reason: any) => any,
      ) {
        const r = tableOpts.selectResponse ?? { data: [], error: null, count: 0 };
        return Promise.resolve(r).then(onFulfilled, onRejected);
      },
    };
    return builder;
  }

  // deno-lint-ignore no-explicit-any
  const client: any = {
    from(table: string) {
      const tableOpts = opts.perTable?.[table] ?? opts;
      const record = buildQuery(table);
      spy.queries.push(record);
      return makeBuilder(record, tableOpts);
    },
    rpc(fn: string, params: Record<string, unknown>) {
      spy.rpcCalls.push({ fn, params });
      return Promise.resolve(opts.rpcResponse ?? { data: null, error: null });
    },
    // Para que logEvent (audit) funcione: getServiceRoleClient va a retornar
    // el mock que setea cada test, y este mock tiene from().insert().
  };

  // Wrap from() para que también soporte insert (audit log usa from().insert()).
  const origFrom = client.from.bind(client);
  client.from = (table: string) => {
    const builder = origFrom(table);
    // deno-lint-ignore no-explicit-any
    (builder as any).insert = (row: Record<string, unknown>) => {
      spy.inserts.push({ table, row });
      return Promise.resolve({ error: null });
    };
    return builder;
  };

  return { client: client as SupabaseClient, spy };
}

function makeCtx(
  client: SupabaseClient,
  override: Partial<ToolContext> = {},
): ToolContext {
  return {
    perfil_id: "11111111-1111-1111-1111-111111111111",
    rol: "admin",
    sucursal_id: 1,
    supabase: client,
    ...override,
  };
}

// ============================================================================
// 1. registerTool throws on duplicate
// ============================================================================

Deno.test("registerTool lanza si la tool ya está registrada", () => {
  _clearToolsForTests();
  _resetRegisterFlagForTests();

  registerTool(buscarClienteTool);
  let threw = false;
  try {
    registerTool(buscarClienteTool);
  } catch (err) {
    threw = true;
    assertStringIncludes(
      err instanceof Error ? err.message : String(err),
      "ya registrada",
    );
  }
  assert(threw, "registerTool debió lanzar al duplicar");
  _clearToolsForTests();
  _resetRegisterFlagForTests();
});

// ============================================================================
// 2. permissions filtra por rol
// ============================================================================

Deno.test("canInvoke deniega rol no autorizado", () => {
  const adminOnly: Tool = {
    name: "admin_only_tool",
    description: "test",
    parameters: { type: "object", properties: {} },
    allowedRoles: ["admin"],
    handler: () => Promise.resolve({}),
  };
  assertEquals(canInvoke("admin", adminOnly), true);
  assertEquals(canInvoke("preventista", adminOnly), false);
  assertEquals(canInvoke("transportista", adminOnly), false);
});

// Las tools de reporte agregado son admin-only desde migracion 039:
// encargado pierde acceso a ventas_periodo, ventas_por_preventista,
// ranking_preventistas_por_producto y compras_periodo (defensa en profundidad
// para el filtrado de tools que ve Gemini).
Deno.test("canInvoke bloquea reportes agregados al encargado", () => {
  const adminOnlyReports = [
    ventasPeriodoTool,
    ventasPorPreventistaTool,
    rankingPreventistasPorProductoTool,
    comprasPeriodoTool,
  ] as unknown as Tool[];
  for (const t of adminOnlyReports) {
    assertEquals(canInvoke("encargado", t), false);
    assertEquals(canInvoke("admin", t), true);
  }
});

// ============================================================================
// 3. buscar_cliente: invoca el RPC bot_buscar_cliente con los params correctos
// ============================================================================
// La tool delega al RPC (migration 020). El test verifica que se invoca con
// los argumentos correctos y el shape de salida se mapea bien — la lógica de
// scoping y accent-fold vive en el SQL y se valida con tests de integración
// directos a la BD (no acá).

Deno.test("buscar_cliente invoca el RPC bot_buscar_cliente con params correctos (preventista)", async () => {
  const { client, spy } = createMockSupabase({
    rpcResponse: {
      data: [
        {
          id: 1,
          codigo: 100,
          nombre_fantasia: "Pedro SRL",
          razon_social: "Pedro Sociedad",
          saldo_cuenta: "1500.50",
          direccion: "Calle 1",
          zona: "Centro",
          sucursal_id: 1,
        },
        {
          id: 2,
          codigo: 101,
          nombre_fantasia: "Pepito",
          razon_social: "Pepito SA",
          saldo_cuenta: 0,
          direccion: null,
          zona: null,
          sucursal_id: 1,
        },
      ],
      error: null,
    },
  });

  const ctx = makeCtx(client, {
    rol: "preventista",
    perfil_id: "22222222-2222-2222-2222-222222222222",
    sucursal_id: 1,
  });

  const result = await buscarClienteTool.handler({ q: "Pe", limit: 25 }, ctx);

  assertEquals(result.total, 2);
  assertEquals(result.clientes.length, 2);
  assertEquals(result.clientes[0].nombre, "Pedro SRL");
  assertEquals(result.clientes[0].saldo_cuenta, 1500.5);

  // Se invocó al RPC bot_buscar_cliente con los params esperados.
  assertEquals(spy.rpcCalls.length, 1);
  const call = spy.rpcCalls[0];
  assertEquals(call.fn, "bot_buscar_cliente");
  assertEquals(call.params.p_q, "Pe");
  assertEquals(call.params.p_perfil_id, "22222222-2222-2222-2222-222222222222");
  assertEquals(call.params.p_rol, "preventista");
  assertEquals(call.params.p_sucursal_id, 1);
  assertEquals(call.params.p_limit, 25);
});

// ============================================================================
// 4. buscar_cliente input muy corto lanza "Búsqueda muy corta"
// ============================================================================

Deno.test("buscar_cliente con q de 1 char (post-trim) lanza Búsqueda muy corta", async () => {
  const { client } = createMockSupabase({});
  const ctx = makeCtx(client);

  let threw = false;
  try {
    await buscarClienteTool.handler({ q: " x " }, ctx);
  } catch (err) {
    threw = true;
    assertStringIncludes(
      err instanceof Error ? err.message : String(err),
      "Búsqueda muy corta",
    );
  }
  assert(threw, "debió lanzar Búsqueda muy corta");
});

// ============================================================================
// 5. ficha_cliente: cliente no encontrado
// ============================================================================

Deno.test("ficha_cliente lanza 'Cliente no encontrado o sin permiso' si maybeSingle retorna null", async () => {
  const { client } = createMockSupabase({
    maybeSingleResponse: { data: null, error: null },
  });
  const ctx = makeCtx(client, { rol: "preventista" });

  let threw = false;
  try {
    await fichaClienteTool.handler({ cliente_id: 999 }, ctx);
  } catch (err) {
    threw = true;
    assertStringIncludes(
      err instanceof Error ? err.message : String(err),
      "Cliente no encontrado o sin permiso",
    );
  }
  assert(threw, "debió lanzar 'Cliente no encontrado o sin permiso'");
});

// ============================================================================
// 6. ficha_cliente happy path con RPC mockeada
// ============================================================================

Deno.test("ficha_cliente happy path retorna saldo + último pedido", async () => {
  const { client, spy } = createMockSupabase({
    perTable: {
      clientes: {
        maybeSingleResponse: {
          data: {
            id: 42,
            codigo: 555,
            nombre_fantasia: "Almacén Don Tito",
            razon_social: "Tito SRL",
            direccion: "Mitre 100",
            telefono: "1100000000",
            zona: "Norte",
            sucursal_id: 1,
          },
          error: null,
        },
      },
    },
    rpcResponse: {
      data: {
        saldo_actual: 25000.75,
        limite_credito: 50000,
        credito_disponible: 24999.25,
        total_pedidos: 12,
        total_compras: 350000,
        total_pagos: 325000,
        pedidos_pendientes_pago: 2,
        // RPC actual retorna timestamp string (no objeto). La tool debe
        // tolerar ambos shapes.
        ultimo_pedido: "2026-04-20T10:30:00Z",
        ultimo_pago: "2026-04-15T11:00:00Z",
      },
      error: null,
    },
  });

  const ctx = makeCtx(client, { rol: "admin" });
  const result = await fichaClienteTool.handler({ cliente_id: 42 }, ctx);

  assertEquals(result.cliente.id, 42);
  assertEquals(result.cliente.nombre, "Almacén Don Tito");
  assertEquals(result.saldo_actual, 25000.75);
  assertEquals(result.limite_credito, 50000);
  assertEquals(result.total_pedidos, 12);
  assertEquals(result.pedidos_pendientes_pago, 2);
  assert(result.ultimo_pedido, "ultimo_pedido debió no ser null");
  assertEquals(result.ultimo_pedido!.fecha, "2026-04-20T10:30:00Z");
  assertEquals(result.ultimo_pedido!.monto, 0); // string-shape: monto=0 default

  // Se llamó a la RPC `_bot` con cliente_id correcto. La variante `_bot`
  // existe porque la edge function usa service_role y la RPC original
  // (`obtener_resumen_cuenta_cliente`) chequea auth.uid() — que es null
  // bajo service_role y haría fallar la tool.
  const rpcCall = spy.rpcCalls.find((c) =>
    c.fn === "obtener_resumen_cuenta_cliente_bot"
  );
  assert(rpcCall, "no se llamó al RPC obtener_resumen_cuenta_cliente_bot");
  assertEquals(rpcCall!.params.p_cliente_id, 42);
});

Deno.test("ficha_cliente acepta ultimo_pedido como objeto {fecha, monto}", async () => {
  const { client } = createMockSupabase({
    perTable: {
      clientes: {
        maybeSingleResponse: {
          data: {
            id: 1,
            codigo: 1,
            nombre_fantasia: "X",
            razon_social: "X",
            direccion: null,
            telefono: null,
            zona: null,
            sucursal_id: 1,
          },
          error: null,
        },
      },
    },
    rpcResponse: {
      data: {
        saldo_actual: 0,
        limite_credito: 0,
        credito_disponible: 0,
        total_pedidos: 1,
        total_compras: 0,
        total_pagos: 0,
        pedidos_pendientes_pago: 0,
        ultimo_pedido: { fecha: "2026-04-01T00:00:00Z", monto: 9999 },
        ultimo_pago: null,
      },
      error: null,
    },
  });

  const ctx = makeCtx(client, { rol: "admin" });
  const result = await fichaClienteTool.handler({ cliente_id: 1 }, ctx);
  assertEquals(result.ultimo_pedido!.monto, 9999);
  assertEquals(result.ultimo_pago, null);
});

// ============================================================================
// 7. invokeTool: tool inexistente
// ============================================================================

Deno.test("invokeTool retorna ok:false 'tool_no_existe' si el nombre no existe", async () => {
  _clearToolsForTests();
  _resetRegisterFlagForTests();

  const { client, spy } = createMockSupabase({});
  // logEvent usa getServiceRoleClient — apuntemos al mock.
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  try {
    const ctx = makeCtx(client);
    const r = await invokeTool("inexistente_xyz", { foo: 1 }, ctx);

    assertEquals(r.ok, false);
    if (!r.ok) {
      assertEquals(r.error, "tool_no_existe");
    }

    // Audit log: tipo=error con error=tool_not_found.
    const auditErr = spy.inserts.find((i) =>
      i.table === "bot_audit_log" && i.row.tool_name === "inexistente_xyz" &&
      i.row.tipo === "error"
    );
    assert(auditErr, "no se logueó audit error de tool_no_existe");
    const meta = auditErr!.row.resultado_meta as Record<string, unknown>;
    assertEquals(meta.error, "tool_not_found");
  } finally {
    _setServiceRoleClientForTests(null);
    _clearToolsForTests();
    _resetRegisterFlagForTests();
  }
});

// ============================================================================
// 8. invokeTool: permission denied
// ============================================================================

Deno.test("invokeTool retorna ok:false 'permiso_denegado' cuando rol no autorizado", async () => {
  _clearToolsForTests();
  _resetRegisterFlagForTests();

  const { client, spy } = createMockSupabase({});
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  // Tool restringida a admin.
  const adminOnly: Tool<{ x: number }, { y: number }> = {
    name: "admin_only_tool",
    description: "solo admin",
    parameters: {
      type: "object",
      properties: { x: { type: "integer" } },
      required: ["x"],
    },
    allowedRoles: ["admin"],
    handler: ({ x }) => Promise.resolve({ y: x * 2 }),
  };
  registerTool(adminOnly as Tool);

  try {
    const ctx = makeCtx(client, { rol: "preventista" });
    const r = await invokeTool("admin_only_tool", { x: 5 }, ctx);

    assertEquals(r.ok, false);
    if (!r.ok) {
      assertEquals(r.error, "permiso_denegado");
    }

    const auditErr = spy.inserts.find((i) =>
      i.table === "bot_audit_log" && i.row.tool_name === "admin_only_tool" &&
      i.row.tipo === "error"
    );
    assert(auditErr, "no se logueó audit del permission denied");
    const meta = auditErr!.row.resultado_meta as Record<string, unknown>;
    assertEquals(meta.error, "permission_denied");
    assertEquals(meta.rol, "preventista");
  } finally {
    _setServiceRoleClientForTests(null);
    _clearToolsForTests();
    _resetRegisterFlagForTests();
  }
});

// ============================================================================
// Bonus sanity: registerAllTools registra las 3 esperadas
// ============================================================================

Deno.test("registerAllTools registra todas las tools esperadas", () => {
  _clearToolsForTests();
  _resetRegisterFlagForTests();

  registerAllTools();
  assert(getTool("buscar_cliente"), "buscar_cliente no registrada");
  assert(getTool("buscar_producto"), "buscar_producto no registrada");
  assert(getTool("ficha_cliente"), "ficha_cliente no registrada");
  assert(getTool("ficha_producto"), "ficha_producto no registrada");
  assert(getTool("listar_categorias"), "listar_categorias no registrada");
  assert(getTool("productos_por_categoria"), "productos_por_categoria no registrada");
  assert(getTool("ventas_periodo"), "ventas_periodo no registrada");
  assert(getTool("ventas_por_preventista"), "ventas_por_preventista no registrada");
  assert(getTool("ranking_preventistas_por_producto"), "ranking_preventistas_por_producto no registrada");
  assert(getTool("pendientes_pago"), "pendientes_pago no registrada");
  assert(getTool("historico_pagos_cliente"), "historico_pagos_cliente no registrada");
  assert(getTool("compras_periodo"), "compras_periodo no registrada");
  assert(getTool("mis_ventas"), "mis_ventas no registrada");
  assert(getTool("historico_pedidos_cliente"), "historico_pedidos_cliente no registrada");
  assert(getTool("productos_recurrentes_cliente"), "productos_recurrentes_cliente no registrada");
  assert(getTool("recorrido_resumen"), "recorrido_resumen no registrada");
  assert(getTool("mis_clientes"), "mis_clientes no registrada");
  assert(getTool("clientes_atrasados"), "clientes_atrasados no registrada");
  assert(!getTool("sugerir_visitas_rfm"), "la RFM se reemplazó por clientes_atrasados (mig 308)");
  assert(getTool("mi_recorrido_hoy"), "mi_recorrido_hoy no registrada");

  // Sanity: las refs son las correctas.
  assertEquals(getTool("buscar_cliente"), buscarClienteTool);
  assertEquals(getTool("buscar_producto"), buscarProductoTool);
  assertEquals(getTool("ficha_cliente"), fichaClienteTool);
  assertEquals(getTool("ficha_producto"), fichaProductoTool);
  assertEquals(getTool("listar_categorias"), listarCategoriasTool);
  assertEquals(getTool("productos_por_categoria"), productosPorCategoriaTool);
  assertEquals(getTool("ventas_periodo"), ventasPeriodoTool);
  assertEquals(getTool("ventas_por_preventista"), ventasPorPreventistaTool);
  assertEquals(
    getTool("ranking_preventistas_por_producto"),
    rankingPreventistasPorProductoTool,
  );
  assertEquals(getTool("pendientes_pago"), pendientesPagoTool);
  assertEquals(getTool("historico_pagos_cliente"), historicoPagosClienteTool);
  assertEquals(getTool("compras_periodo"), comprasPeriodoTool);
  assertEquals(getTool("mis_ventas"), misVentasTool);
  assertEquals(getTool("historico_pedidos_cliente"), historicoClienteTool);
  assertEquals(getTool("productos_recurrentes_cliente"), productosRecurrentesTool);
  assertEquals(getTool("recorrido_resumen"), recorridoResumenTool);
  assertEquals(getTool("mis_clientes"), misClientesTool);
  assertEquals(getTool("clientes_atrasados"), clientesAtrasadosTool);
  assertEquals(getTool("ranking_clientes"), rankingClientesTool);
  assertEquals(getTool("stock_y_ventas"), stockYVentasTool);
  assertEquals(getTool("productos_sin_venta_con_stock"), productosSinVentaConStockTool);
  assertEquals(getTool("resumen_cliente_visita"), resumenClienteVisitaTool);
  assertEquals(getTool("mi_recorrido_hoy"), miRecorridoHoyTool);

  _clearToolsForTests();
  _resetRegisterFlagForTests();
});

// ============================================================================
// 9. buscar_cliente: pasa el q multi-word + acentuado tal cual al RPC
// ============================================================================
// La normalización (lowercase + unaccent + split) la hace el SQL — la tool TS
// debe pasar el q sin tocar para que el RPC tenga el dato original. Test
// dual: confirma que multi-word ('almacen gabriel') y trim() funcionan, y que
// el output trimmea trailing whitespace de los nombres (caso real id=565).

Deno.test("buscar_cliente con q multi-word + accent-fold pasa el q tal cual al RPC y trimmea output", async () => {
  const { client, spy } = createMockSupabase({
    rpcResponse: {
      data: [
        {
          id: 565,
          codigo: 549,
          nombre_fantasia: "Almacén Gabriel ", // trailing space del dato real
          razon_social: "Briondi Gabriel ",
          saldo_cuenta: 0,
          direccion: null,
          zona: null,
          sucursal_id: 1,
        },
      ],
      error: null,
    },
  });

  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 1 });

  // q con espacio (multi-word) + sin acentos en el input (el SQL hace el fold).
  // Trim() en el handler convierte "  almacen gabriel  " → "almacen gabriel".
  const result = await buscarClienteTool.handler(
    { q: "  almacen gabriel  " },
    ctx,
  );

  assertEquals(result.clientes.length, 1);
  // El handler devuelve el nombre trimmed (limpia trailing space del dato).
  assertEquals(result.clientes[0].nombre, "Almacén Gabriel");

  assertEquals(spy.rpcCalls.length, 1);
  const call = spy.rpcCalls[0];
  assertEquals(call.fn, "bot_buscar_cliente");
  // El q se pasa tal cual (post-trim). El SQL lo lowerea + unaccent + splitea.
  assertEquals(call.params.p_q, "almacen gabriel");
});

// ============================================================================
// 10. sucursal_id null guard: rol no-admin debe ser rechazado
// ============================================================================

Deno.test("buscar_cliente rechaza preventista sin sucursal asignada", async () => {
  const { client } = createMockSupabase({});
  const ctx = makeCtx(client, {
    rol: "preventista",
    sucursal_id: null,
    perfil_id: "33333333-3333-3333-3333-333333333333",
  });

  let threw = false;
  try {
    await buscarClienteTool.handler({ q: "Pedro" }, ctx);
  } catch (err) {
    threw = true;
    assertStringIncludes(
      err instanceof Error ? err.message : String(err),
      "Sucursal no asignada",
    );
  }
  assert(threw, "debió lanzar 'Sucursal no asignada'");
});

Deno.test("buscar_producto rechaza transportista sin sucursal asignada", async () => {
  const { client } = createMockSupabase({});
  const ctx = makeCtx(client, {
    rol: "transportista",
    sucursal_id: null,
    perfil_id: "44444444-4444-4444-4444-444444444444",
  });

  let threw = false;
  try {
    await buscarProductoTool.handler({ q: "agua" }, ctx);
  } catch (err) {
    threw = true;
    assertStringIncludes(
      err instanceof Error ? err.message : String(err),
      "Sucursal no asignada",
    );
  }
  assert(threw, "debió lanzar 'Sucursal no asignada'");
});

Deno.test("ficha_cliente rechaza encargado sin sucursal asignada", async () => {
  const { client } = createMockSupabase({});
  const ctx = makeCtx(client, {
    rol: "encargado",
    sucursal_id: null,
    perfil_id: "55555555-5555-5555-5555-555555555555",
  });

  let threw = false;
  try {
    await fichaClienteTool.handler({ cliente_id: 1 }, ctx);
  } catch (err) {
    threw = true;
    assertStringIncludes(
      err instanceof Error ? err.message : String(err),
      "Sucursal no asignada",
    );
  }
  assert(threw, "debió lanzar 'Sucursal no asignada'");
});

// ============================================================================
// 11. Preventista bypass via cliente_id NO asignado
// ============================================================================

// La regla nueva (migration 028): preventista ve sus asignados + huérfanos,
// NO ve los asignados a OTRO preventista. La verificación va en 2 queries:
// (1) clientes, (2) cliente_preventistas. Estos 3 tests cubren los 3 paths.

Deno.test("ficha_cliente preventista — cliente asignado a OTRO preventista → denegado", async () => {
  const callerPerfilId = "66666666-6666-6666-6666-666666666666";
  const otroPerfilId = "99999999-9999-9999-9999-999999999999";
  const { client, spy } = createMockSupabase({
    perTable: {
      clientes: {
        maybeSingleResponse: {
          data: {
            id: 999,
            codigo: 1,
            nombre_fantasia: "Cliente Robado",
            razon_social: "Cliente Robado SA",
            direccion: null,
            telefono: null,
            zona: null,
            sucursal_id: 1,
          },
          error: null,
        },
      },
      cliente_preventistas: {
        // El cliente está asignado SOLO a otro preventista — sin caller.
        selectResponse: {
          data: [{ preventista_id: otroPerfilId }],
          error: null,
          count: 1,
        },
      },
    },
  });

  const ctx = makeCtx(client, {
    rol: "preventista",
    sucursal_id: 1,
    perfil_id: callerPerfilId,
  });

  let threw = false;
  try {
    await fichaClienteTool.handler({ cliente_id: 999 }, ctx);
  } catch (err) {
    threw = true;
    assertStringIncludes(
      err instanceof Error ? err.message : String(err),
      "asignado a otro preventista",
    );
  }
  assert(threw, "debió bloquear porque está asignado a otro");

  // Step 1: clientes query SIN inner join.
  const clienteQuery = spy.queries.find((q) => q.table === "clientes");
  assert(clienteQuery, "no se hizo query a clientes");
  assert(
    !(clienteQuery!.selectCols ?? "").includes("cliente_preventistas"),
    "el select a clientes ya NO debe incluir el inner join",
  );

  // Step 2: cliente_preventistas query con eq cliente_id=999 (NO con perfil_id
  // del caller — leemos todas las filas y decidimos en TS).
  const cpQuery = spy.queries.find((q) => q.table === "cliente_preventistas");
  assert(cpQuery, "debió consultar cliente_preventistas para verificar asignación");
  assert(
    cpQuery!.filters.some((f) =>
      f.type === "eq" && f.args[0] === "cliente_id" && f.args[1] === 999
    ),
    "cliente_preventistas debe filtrar por cliente_id",
  );

  // No invocó RPC.
  assertEquals(spy.rpcCalls.length, 0);
});

Deno.test("ficha_cliente preventista — cliente HUÉRFANO (sin asignación) → permitido", async () => {
  const callerPerfilId = "66666666-6666-6666-6666-666666666666";
  const { client, spy } = createMockSupabase({
    perTable: {
      clientes: {
        maybeSingleResponse: {
          data: {
            id: 500,
            codigo: 12,
            nombre_fantasia: "Almacén Huérfano",
            razon_social: "Huérfano SA",
            direccion: "Calle 1",
            telefono: null,
            zona: "Centro",
            sucursal_id: 1,
          },
          error: null,
        },
      },
      cliente_preventistas: {
        // Cero asignaciones: huérfano.
        selectResponse: { data: [], error: null, count: 0 },
      },
    },
    rpcResponse: {
      data: {
        saldo_actual: 5000,
        limite_credito: 10000,
        credito_disponible: 5000,
        total_pedidos: 3,
        total_compras: 12000,
        total_pagos: 7000,
        pedidos_pendientes_pago: 1,
        ultimo_pedido: null,
        ultimo_pago: null,
      },
      error: null,
    },
  });

  const ctx = makeCtx(client, {
    rol: "preventista",
    sucursal_id: 1,
    perfil_id: callerPerfilId,
  });

  const result = await fichaClienteTool.handler({ cliente_id: 500 }, ctx);
  assertEquals(result.cliente.nombre, "Almacén Huérfano");
  assertEquals(result.saldo_actual, 5000);
  // Confirmamos que TUVO que ir a cliente_preventistas para chequear
  // (defensa-en-profundidad: aunque sea huérfano, la query corre).
  assert(spy.queries.find((q) => q.table === "cliente_preventistas"));
  // RPC sí se invocó porque el cliente es accesible.
  assertEquals(spy.rpcCalls.length, 1);
});

Deno.test("ficha_cliente preventista — cliente asignado a MÍ → permitido", async () => {
  const callerPerfilId = "66666666-6666-6666-6666-666666666666";
  const { client, spy } = createMockSupabase({
    perTable: {
      clientes: {
        maybeSingleResponse: {
          data: {
            id: 100,
            codigo: 5,
            nombre_fantasia: "Mi Cliente",
            razon_social: "Mi Cliente SA",
            direccion: null,
            telefono: null,
            zona: null,
            sucursal_id: 1,
          },
          error: null,
        },
      },
      cliente_preventistas: {
        // El caller está entre los asignados (incluso si hay otros).
        selectResponse: {
          data: [
            { preventista_id: callerPerfilId },
            { preventista_id: "otro-id-cualquiera" },
          ],
          error: null,
          count: 2,
        },
      },
    },
    rpcResponse: {
      data: {
        saldo_actual: 0,
        limite_credito: 5000,
        credito_disponible: 5000,
        total_pedidos: 10,
        total_compras: 50000,
        total_pagos: 50000,
        pedidos_pendientes_pago: 0,
        ultimo_pedido: null,
        ultimo_pago: null,
      },
      error: null,
    },
  });

  const ctx = makeCtx(client, {
    rol: "preventista",
    sucursal_id: 1,
    perfil_id: callerPerfilId,
  });

  const result = await fichaClienteTool.handler({ cliente_id: 100 }, ctx);
  assertEquals(result.cliente.nombre, "Mi Cliente");
  assertEquals(spy.rpcCalls.length, 1);
});

// ============================================================================
// 12. mis_clientes: rol incorrecto (admin) → permission denied via invokeTool
// ============================================================================

Deno.test("mis_clientes rechaza rol admin via invokeTool con permiso_denegado", async () => {
  _clearToolsForTests();
  _resetRegisterFlagForTests();

  const { client, spy } = createMockSupabase({});
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  registerTool(misClientesTool);

  try {
    const ctx = makeCtx(client, { rol: "admin", sucursal_id: 1 });
    const r = await invokeTool("mis_clientes", {}, ctx);

    assertEquals(r.ok, false);
    if (!r.ok) {
      assertEquals(r.error, "permiso_denegado");
    }

    const auditErr = spy.inserts.find((i) =>
      i.table === "bot_audit_log" && i.row.tool_name === "mis_clientes" &&
      i.row.tipo === "error"
    );
    assert(auditErr, "no se logueó audit del permission denied");
    const meta = auditErr!.row.resultado_meta as Record<string, unknown>;
    assertEquals(meta.error, "permission_denied");
    assertEquals(meta.rol, "admin");

    // No debió haber llamado al RPC: el gate de permisos se hizo antes.
    assertEquals(spy.rpcCalls.length, 0, "no debió invocarse el RPC con permiso denegado");
  } finally {
    _setServiceRoleClientForTests(null);
    _clearToolsForTests();
    _resetRegisterFlagForTests();
  }
});

// ============================================================================
// 13. mis_clientes: happy path con RPC mockeada
// ============================================================================

Deno.test("mis_clientes happy path retorna shape esperado y mapea nombres", async () => {
  const { client, spy } = createMockSupabase({
    rpcResponse: {
      data: {
        total: 2,
        clientes: [
          {
            id: 10,
            codigo: 100,
            nombre_fantasia: "Almacén Norte",
            razon_social: "Norte SRL",
            saldo_cuenta: "12500.50",
            zona: "Norte",
            ultima_compra: "2026-04-20",
            dias_desde_ultima: 6,
          },
          {
            id: 11,
            codigo: null,
            nombre_fantasia: null,
            razon_social: "Sur SA",
            saldo_cuenta: 0,
            zona: null,
            ultima_compra: null,
            dias_desde_ultima: null,
          },
        ],
      },
      error: null,
    },
  });

  const ctx = makeCtx(client, {
    rol: "preventista",
    perfil_id: "77777777-7777-7777-7777-777777777777",
    sucursal_id: 1,
  });

  const result = await misClientesTool.handler(
    { con_deuda: true, sin_pedidos_dias: 30, limit: 25 },
    ctx,
  );

  assertEquals(result.total, 2);
  assertEquals(result.clientes.length, 2);

  // Mapeo nombre: nombre_fantasia tiene precedencia.
  assertEquals(result.clientes[0].nombre, "Almacén Norte");
  assertEquals(result.clientes[0].saldo_cuenta, 12500.5);
  assertEquals(result.clientes[0].dias_desde_ultima, 6);
  assertEquals(result.clientes[0].ultima_compra, "2026-04-20");

  // Fallback razón social cuando nombre_fantasia es null.
  assertEquals(result.clientes[1].nombre, "Sur SA");
  assertEquals(result.clientes[1].codigo, null);
  assertEquals(result.clientes[1].dias_desde_ultima, null);
  assertEquals(result.clientes[1].ultima_compra, null);

  // RPC: nombre y params correctos.
  assertEquals(spy.rpcCalls.length, 1);
  const call = spy.rpcCalls[0];
  assertEquals(call.fn, "bot_mis_clientes");
  assertEquals(call.params.p_preventista_id, "77777777-7777-7777-7777-777777777777");
  assertEquals(call.params.p_sucursal_id, 1);
  assertEquals(call.params.p_con_deuda, true);
  assertEquals(call.params.p_sin_pedidos_dias, 30);
  assertEquals(call.params.p_limit, 25);
});

// ============================================================================
// 14. mi_recorrido_hoy: sin recorrido → recorrido null + pedidos vacíos
// ============================================================================

Deno.test("mi_recorrido_hoy sin recorrido del día retorna recorrido:null y pedidos:[]", async () => {
  const { client, spy } = createMockSupabase({
    rpcResponse: {
      data: { recorrido: null, pedidos: [] },
      error: null,
    },
  });

  const ctx = makeCtx(client, {
    rol: "transportista",
    perfil_id: "88888888-8888-8888-8888-888888888888",
    sucursal_id: 2,
  });

  const result = await miRecorridoHoyTool.handler({}, ctx);

  assertEquals(result.recorrido, null);
  assertEquals(result.pedidos.length, 0);

  // El RPC se llamó con fecha resuelta en TS (TZ ART) — string YYYY-MM-DD,
  // NUNCA null. PostgREST pasaría un null verbatim al RPC y el DEFAULT
  // CURRENT_DATE no triggearía → retornaría 0 rows.
  assertEquals(spy.rpcCalls.length, 1);
  const call = spy.rpcCalls[0];
  assertEquals(call.fn, "bot_mi_recorrido");
  assertEquals(call.params.p_transportista_id, "88888888-8888-8888-8888-888888888888");
  assertEquals(call.params.p_sucursal_id, 2);
  assert(
    typeof call.params.p_fecha === "string" &&
      /^\d{4}-\d{2}-\d{2}$/.test(call.params.p_fecha),
    `p_fecha debió ser un string YYYY-MM-DD, fue: ${JSON.stringify(call.params.p_fecha)}`,
  );
});

// ============================================================================
// 15. mi_recorrido_hoy: con recorrido y 3 pedidos → ordenados por orden_entrega
// ============================================================================

Deno.test("mi_recorrido_hoy con recorrido + 3 pedidos retorna estructura completa", async () => {
  // Nota: el ORDER BY orden_entrega lo hace el RPC SQL. Acá la mock devuelve
  // los pedidos ya ordenados (como lo haría el RPC) — la tool solo mapea.
  const { client, spy } = createMockSupabase({
    rpcResponse: {
      data: {
        recorrido: {
          id: 555,
          fecha: "2026-04-26",
          estado: "en_curso",
          total_pedidos: 3,
          pedidos_entregados: 1,
          total_facturado: "150000.00",
          total_cobrado: "50000.00",
        },
        pedidos: [
          {
            pedido_id: 1001,
            orden_entrega: 1,
            estado_entrega: "entregado",
            cliente_id: 10,
            cliente_nombre: "Almacén Uno",
            direccion: "Calle 1 100",
            total: "50000.00",
            estado_pago: "pagado",
          },
          {
            pedido_id: 1002,
            orden_entrega: 2,
            estado_entrega: "pendiente",
            cliente_id: 20,
            cliente_nombre: "Almacén Dos",
            direccion: null,
            total: 60000,
            estado_pago: "pendiente",
          },
          {
            pedido_id: 1003,
            orden_entrega: 3,
            estado_entrega: "pendiente",
            cliente_id: 30,
            cliente_nombre: "Almacén Tres",
            direccion: "Av. Siempre Viva 742",
            total: 40000,
            estado_pago: "parcial",
          },
        ],
      },
      error: null,
    },
  });

  const ctx = makeCtx(client, {
    rol: "transportista",
    perfil_id: "99999999-9999-9999-9999-999999999999",
    sucursal_id: 3,
  });

  const result = await miRecorridoHoyTool.handler({ fecha: "2026-04-26" }, ctx);

  // Recorrido: shape correcto y números casteados.
  assert(result.recorrido, "recorrido debió no ser null");
  assertEquals(result.recorrido!.id, 555);
  assertEquals(result.recorrido!.fecha, "2026-04-26");
  assertEquals(result.recorrido!.estado, "en_curso");
  assertEquals(result.recorrido!.total_pedidos, 3);
  assertEquals(result.recorrido!.pedidos_entregados, 1);
  assertEquals(result.recorrido!.total_facturado, 150000);
  assertEquals(result.recorrido!.total_cobrado, 50000);

  // Pedidos: 3, en orden de orden_entrega (1, 2, 3).
  assertEquals(result.pedidos.length, 3);
  assertEquals(result.pedidos[0].orden_entrega, 1);
  assertEquals(result.pedidos[0].pedido_id, 1001);
  assertEquals(result.pedidos[0].cliente_nombre, "Almacén Uno");
  assertEquals(result.pedidos[0].total, 50000);

  assertEquals(result.pedidos[1].orden_entrega, 2);
  assertEquals(result.pedidos[1].direccion, null);

  assertEquals(result.pedidos[2].orden_entrega, 3);
  assertEquals(result.pedidos[2].estado_pago, "parcial");

  // RPC: fecha pasada como string YYYY-MM-DD.
  assertEquals(spy.rpcCalls.length, 1);
  assertEquals(spy.rpcCalls[0].fn, "bot_mi_recorrido");
  assertEquals(spy.rpcCalls[0].params.p_fecha, "2026-04-26");
});

// ============================================================================
// 16. mi_recorrido_hoy: fecha inválida lanza error claro
// ============================================================================

Deno.test("mi_recorrido_hoy rechaza fecha con formato inválido", async () => {
  const { client } = createMockSupabase({});
  const ctx = makeCtx(client, {
    rol: "transportista",
    sucursal_id: 1,
    perfil_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  });

  let threw = false;
  try {
    await miRecorridoHoyTool.handler({ fecha: "26/04/2026" }, ctx);
  } catch (err) {
    threw = true;
    assertStringIncludes(
      err instanceof Error ? err.message : String(err),
      "fecha inválida",
    );
  }
  assert(threw, "debió lanzar 'fecha inválida'");
});

// ============================================================================
// 17. Defense-in-depth: handlers rechazan rol incorrecto cuando se llaman
// directo (bypass del registry). En producción `invokeTool` ya gatea por
// `allowedRoles` (cubierto por el test 12), pero si alguien llama el handler
// desde tests/scripts/sin pasar por el registry, el guard interno debe disparar.
// ============================================================================

Deno.test("mis_clientes handler rechaza rol distinto a preventista", async () => {
  const { client } = createMockSupabase({});
  const ctx = makeCtx(client, {
    rol: "admin",
    perfil_id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
    sucursal_id: 1,
  });

  let threw = false;
  try {
    await misClientesTool.handler({}, ctx);
  } catch (err) {
    threw = true;
    assertStringIncludes(
      err instanceof Error ? err.message : String(err),
      "preventista",
    );
  }
  assert(threw, "mis_clientes debió rechazar rol admin");
});

Deno.test("mi_recorrido_hoy handler rechaza rol distinto a transportista", async () => {
  const { client } = createMockSupabase({});
  const ctx = makeCtx(client, {
    rol: "preventista",
    perfil_id: "cccccccc-cccc-cccc-cccc-cccccccccccc",
    sucursal_id: 1,
  });

  let threw = false;
  try {
    await miRecorridoHoyTool.handler({}, ctx);
  } catch (err) {
    threw = true;
    assertStringIncludes(
      err instanceof Error ? err.message : String(err),
      "transportista",
    );
  }
  assert(threw, "mi_recorrido_hoy debió rechazar rol preventista");
});

// ============================================================================
// 21. listar_categorias: happy path con dedupe + filtro de null/empty
// ============================================================================

Deno.test("listar_categorias dedupe y filtra null/'' del resultado", async () => {
  // Mock devuelve filas con categorías repetidas, una null, una "". El handler
  // debe dedupear preservando orden de aparición y descartar null/"".
  const { client, spy } = createMockSupabase({
    selectResponse: {
      data: [
        { categoria: "AGUAS" },
        { categoria: "FIDEOS" },
        { categoria: "GASEOSAS" },
        { categoria: "GASEOSAS" }, // duplicado
        { categoria: null },
        { categoria: "" },
        { categoria: "FIDEOS" }, // duplicado
      ],
      error: null,
      count: 7,
    },
  });

  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 1 });
  const result = await listarCategoriasTool.handler({} as never, ctx);

  assertEquals(result.total, 3);
  assertEquals(result.categorias, ["AGUAS", "FIDEOS", "GASEOSAS"]);

  // Sanity: scoping por sucursal aplicado.
  const q = spy.queries.find((qq) => qq.table === "productos");
  assert(q, "no se hizo query a productos");
  const eqFilters = q!.filters.filter((f) => f.type === "eq");
  assert(
    eqFilters.some((f) => f.args[0] === "sucursal_id" && f.args[1] === 1),
    "no se aplicó filter sucursal_id",
  );
});

// ============================================================================
// 22. listar_categorias: catalogo vacío → total 0, categorias []
// ============================================================================

Deno.test("listar_categorias retorna shape vacío cuando no hay productos", async () => {
  const { client } = createMockSupabase({
    selectResponse: { data: [], error: null, count: 0 },
  });
  const ctx = makeCtx(client, { rol: "encargado", sucursal_id: 7 });
  const result = await listarCategoriasTool.handler({} as never, ctx);
  assertEquals(result.total, 0);
  assertEquals(result.categorias, []);
});

// ============================================================================
// 23. listar_categorias: rechaza preventista sin sucursal asignada
// ============================================================================

Deno.test("listar_categorias rechaza preventista sin sucursal asignada", async () => {
  const { client } = createMockSupabase({});
  const ctx = makeCtx(client, {
    rol: "preventista",
    sucursal_id: null,
    perfil_id: "11111111-2222-3333-4444-555555555555",
  });

  let threw = false;
  try {
    await listarCategoriasTool.handler({} as never, ctx);
  } catch (err) {
    threw = true;
    assertStringIncludes(
      err instanceof Error ? err.message : String(err),
      "Sucursal no asignada",
    );
  }
  assert(threw, "debió lanzar 'Sucursal no asignada'");
});

// ============================================================================
// 24. productos_por_categoria: happy path con categoria + q
// ============================================================================

Deno.test("productos_por_categoria filtra por categoria y refina con q", async () => {
  const { client, spy } = createMockSupabase({
    selectResponse: {
      data: [
        {
          id: 10,
          codigo: "G001",
          nombre: "Coca Naranja 2.25L",
          precio: "850.50",
          stock: 12,
          stock_minimo: 4,
          categoria: "GASEOSAS",
          sucursal_id: 1,
        },
      ],
      error: null,
      count: 1,
    },
  });

  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 1 });
  const result = await productosPorCategoriaTool.handler(
    { categoria: "GASEOSAS", q: "naranja" },
    ctx,
  );

  assertEquals(result.total, 1);
  assertEquals(result.categoria, "GASEOSAS");
  assertEquals(result.productos.length, 1);
  assertEquals(result.productos[0].id, 10);
  assertEquals(result.productos[0].nombre, "Coca Naranja 2.25L");
  assertEquals(result.productos[0].precio, 850.5);
  assertEquals(result.productos[0].bajo_stock, false); // 12 > 4

  // Verifico shape de la query: ilike sobre categoria + or sobre nombre/codigo.
  const q = spy.queries.find((qq) => qq.table === "productos");
  assert(q, "no se hizo query a productos");

  const ilikeFilters = q!.filters.filter((f) => f.type === "ilike");
  assert(
    ilikeFilters.some((f) =>
      f.args[0] === "categoria" && f.args[1] === "GASEOSAS"
    ),
    "no se aplicó ilike(categoria)",
  );

  const orFilter = q!.filters.find((f) => f.type === "or");
  assert(orFilter, "no se aplicó .or() para refinar con q");
  assertStringIncludes(orFilter!.args[0] as string, "nombre.ilike.%naranja%");
  assertStringIncludes(orFilter!.args[0] as string, "codigo.ilike.%naranja%");

  // Sucursal scoping.
  const eqFilters = q!.filters.filter((f) => f.type === "eq");
  assert(
    eqFilters.some((f) => f.args[0] === "sucursal_id" && f.args[1] === 1),
    "no se aplicó filter sucursal_id",
  );
});

// ============================================================================
// 25. productos_por_categoria: sin q solo filtra por categoria
// ============================================================================

Deno.test("productos_por_categoria sin q omite el .or() de refinamiento", async () => {
  const { client, spy } = createMockSupabase({
    selectResponse: {
      data: [
        {
          id: 1,
          codigo: "F001",
          nombre: "Fideo Spaghetti 500g",
          precio: 350,
          stock: 20,
          stock_minimo: 5,
          categoria: "FIDEOS",
          sucursal_id: 2,
        },
      ],
      error: null,
      count: 1,
    },
  });

  const ctx = makeCtx(client, { rol: "preventista", sucursal_id: 2, perfil_id: "preventista-uuid" });
  const result = await productosPorCategoriaTool.handler(
    { categoria: "FIDEOS" },
    ctx,
  );

  assertEquals(result.total, 1);
  const q = spy.queries.find((qq) => qq.table === "productos");
  assert(q, "no se hizo query a productos");
  // No debió haber .or() porque no se pasó q.
  const orFilter = q!.filters.find((f) => f.type === "or");
  assertEquals(
    orFilter,
    undefined,
    "no debió aplicarse .or() cuando no se pasa q",
  );
});

// ============================================================================
// 26. productos_por_categoria: rechaza sucursal_id null para no-admin
// ============================================================================

Deno.test("productos_por_categoria rechaza transportista sin sucursal asignada", async () => {
  const { client } = createMockSupabase({});
  const ctx = makeCtx(client, {
    rol: "transportista",
    sucursal_id: null,
    perfil_id: "trans-no-suc",
  });

  let threw = false;
  try {
    await productosPorCategoriaTool.handler({ categoria: "AGUAS" }, ctx);
  } catch (err) {
    threw = true;
    assertStringIncludes(
      err instanceof Error ? err.message : String(err),
      "Sucursal no asignada",
    );
  }
  assert(threw, "debió lanzar 'Sucursal no asignada'");
});

// ============================================================================
// 27. productos_por_categoria: escapa metacaracteres PostgREST en q
// ============================================================================

Deno.test("productos_por_categoria escapa metacaracteres PostgREST en q", async () => {
  const { client, spy } = createMockSupabase({
    selectResponse: { data: [], error: null, count: 0 },
  });
  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 1 });

  await productosPorCategoriaTool.handler(
    { categoria: "GASEOSAS", q: "foo.bar:baz(x)" },
    ctx,
  );

  const q = spy.queries.find((qq) => qq.table === "productos");
  assert(q, "no se hizo query a productos");
  const orFilter = q!.filters.find((f) => f.type === "or");
  assert(orFilter, "no se aplicó .or()");
  const expr = orFilter!.args[0] as string;
  assertStringIncludes(expr, "nombre.ilike.%foo\\.bar\\:baz\\(x\\)%");
});

// ============================================================================
// 28. productos_por_categoria: limit fuera de rango lanza error
// ============================================================================

Deno.test("productos_por_categoria rechaza limit fuera de rango", async () => {
  const { client } = createMockSupabase({});
  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 1 });

  let threw = false;
  try {
    await productosPorCategoriaTool.handler(
      { categoria: "GASEOSAS", limit: 100 },
      ctx,
    );
  } catch (err) {
    threw = true;
    assertStringIncludes(
      err instanceof Error ? err.message : String(err),
      "Límite fuera de rango",
    );
  }
  assert(threw, "debió lanzar 'Límite fuera de rango'");
});

// ============================================================================
// 29. ficha_producto: invoca el RPC bot_ficha_producto y mapea bajo_stock
// ============================================================================

Deno.test("ficha_producto invoca el RPC y derivado bajo_stock cuando stock <= minimo", async () => {
  const { client, spy } = createMockSupabase({
    rpcResponse: {
      data: {
        producto: {
          id: 215,
          codigo: "M00025",
          nombre: "MANAOS CITRUS 2250CC X 6",
          precio: "9100",
          precio_sin_iva: 9100,
          stock: 5,
          stock_minimo: 10,
          categoria: "GASEOSAS",
          proveedor_id: null,
        },
        ventas_30d_cantidad: 3,
        ultima_venta: "2026-04-21T15:53:48.330307+00:00",
      },
      error: null,
    },
  });

  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 2 });
  const result = await fichaProductoTool.handler({ producto_id: 215 }, ctx);

  assertEquals(result.producto.id, 215);
  assertEquals(result.producto.nombre, "MANAOS CITRUS 2250CC X 6");
  assertEquals(result.producto.precio, 9100);
  assertEquals(result.producto.bajo_stock, true); // 5 <= 10
  assertEquals(result.ventas_30d_cantidad, 3);
  assert(result.ultima_venta?.startsWith("2026-04-21"));

  // RPC se llamó con los params correctos.
  assertEquals(spy.rpcCalls.length, 1);
  const call = spy.rpcCalls[0];
  assertEquals(call.fn, "bot_ficha_producto");
  assertEquals(call.params.p_producto_id, 215);
  assertEquals(call.params.p_sucursal_id, 2);
});

// ============================================================================
// 30. ficha_producto: producto no encontrado lanza error claro
// ============================================================================

Deno.test("ficha_producto lanza si el RPC retorna null (producto no existe)", async () => {
  const { client } = createMockSupabase({
    rpcResponse: { data: null, error: null },
  });
  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 1 });

  let threw = false;
  try {
    await fichaProductoTool.handler({ producto_id: 99999 }, ctx);
  } catch (err) {
    threw = true;
    assertStringIncludes(
      err instanceof Error ? err.message : String(err),
      "Producto no encontrado",
    );
  }
  assert(threw, "debió lanzar 'Producto no encontrado'");
});

// ============================================================================
// 31. ficha_producto: rechaza preventista sin sucursal asignada
// ============================================================================

Deno.test("ficha_producto rechaza preventista sin sucursal asignada", async () => {
  const { client } = createMockSupabase({});
  const ctx = makeCtx(client, {
    rol: "preventista",
    sucursal_id: null,
    perfil_id: "no-sucursal",
  });

  let threw = false;
  try {
    await fichaProductoTool.handler({ producto_id: 1 }, ctx);
  } catch (err) {
    threw = true;
    assertStringIncludes(
      err instanceof Error ? err.message : String(err),
      "Sucursal no asignada",
    );
  }
  assert(threw, "debió lanzar 'Sucursal no asignada'");
});

// ============================================================================
// 32. ficha_producto: producto_id inválido lanza error
// ============================================================================

Deno.test("ficha_producto rechaza producto_id no entero", async () => {
  const { client } = createMockSupabase({});
  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 1 });

  let threw = false;
  try {
    // deno-lint-ignore no-explicit-any
    await fichaProductoTool.handler({ producto_id: "abc" as any }, ctx);
  } catch (err) {
    threw = true;
    assertStringIncludes(
      err instanceof Error ? err.message : String(err),
      "entero positivo",
    );
  }
  assert(threw, "debió lanzar error de producto_id inválido");
});

// ============================================================================
// 33. ventas_periodo: invoca el RPC y mapea top_clientes con nombre derivado
// ============================================================================

Deno.test("ventas_periodo invoca el RPC y deriva nombre de cliente", async () => {
  const { client, spy } = createMockSupabase({
    rpcResponse: {
      data: {
        desde: "2026-04-01",
        hasta: "2026-04-28",
        total_ventas: "8125460",
        pedidos_count: 173,
        ticket_promedio: "46967.98",
        top_clientes: [
          {
            id: 440, codigo: 424,
            nombre_fantasia: "Taco Pozo", razon_social: "Comercial",
            total_comprado: "994200", pedidos: 13,
          },
          {
            id: 999, codigo: null,
            nombre_fantasia: null, razon_social: "Solo Razón",
            total_comprado: 100, pedidos: 1,
          },
        ],
        top_productos: [
          { id: 178, codigo: "M00002", nombre: "MANAOS COLA 3000CC X 6", unidades: 82, facturado: "910200" },
        ],
      },
      error: null,
    },
  });
  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 2 });
  const result = await ventasPeriodoTool.handler(
    { desde: "2026-04-01", hasta: "2026-04-28", limit: 5 },
    ctx,
  );

  assertEquals(result.total_ventas, 8125460);
  assertEquals(result.pedidos_count, 173);
  assertEquals(result.ticket_promedio, 46967.98);
  // Timestamp ART para que el LLM lo muestre y el usuario vea el corte exacto.
  assert(
    /\d{2}\/\d{2}\/\d{4}.*\d{2}:\d{2}.*\(ART\)/.test(result.consulta_realizada_at),
    `consulta_realizada_at con formato inesperado: ${result.consulta_realizada_at}`,
  );
  // Primer cliente: nombre_fantasia.
  assertEquals(result.top_clientes[0].nombre, "Taco Pozo");
  assertEquals(result.top_clientes[0].total_comprado, 994200);
  // Segundo cliente: fallback a razon_social cuando nombre_fantasia es null.
  assertEquals(result.top_clientes[1].nombre, "Solo Razón");

  // RPC params correctos.
  assertEquals(spy.rpcCalls.length, 1);
  const call = spy.rpcCalls[0];
  assertEquals(call.fn, "bot_ventas_periodo");
  assertEquals(call.params.p_desde, "2026-04-01");
  assertEquals(call.params.p_hasta, "2026-04-28");
  assertEquals(call.params.p_sucursal_id, 2);
  assertEquals(call.params.p_limit, 5);
});

Deno.test("ventas_periodo rechaza fechas inválidas y rangos invertidos", async () => {
  const { client } = createMockSupabase({});
  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 1 });

  let threw = 0;
  try {
    await ventasPeriodoTool.handler(
      { desde: "01/04/2026", hasta: "2026-04-28" },
      ctx,
    );
  } catch (err) {
    threw++;
    assertStringIncludes(err instanceof Error ? err.message : "", "Fechas inválidas");
  }
  try {
    await ventasPeriodoTool.handler(
      { desde: "2026-04-30", hasta: "2026-04-01" },
      ctx,
    );
  } catch (err) {
    threw++;
    assertStringIncludes(err instanceof Error ? err.message : "", "desde");
  }
  assertEquals(threw, 2, "debió lanzar 2 veces (fechas + rango)");
});

// ============================================================================
// 34. pendientes_pago: invoca RPC y mapea
// ============================================================================

Deno.test("pendientes_pago invoca RPC con dias_atraso default 0", async () => {
  const { client, spy } = createMockSupabase({
    rpcResponse: {
      data: {
        sucursal_id: 2,
        dias_atraso_min: 0,
        // Forma de la mig 300: consume reporte_cuentas_por_cobrar.
        total_global: "9604385",
        vencido_global: "50000",
        total_sucursal: "9700000",
        criterio: "Pedidos no cancelados con saldo (total - monto_pagado > 0).",
        clientes_count: 81,
        clientes: [
          {
            cliente_id: 415, cliente_codigo: 399,
            nombre_fantasia: "RAMON ABREGU", razon_social: "RAMON ABREGU",
            es_comodin: false, activo: true,
            pedidos_pendientes: 3, total_adeudado: "87800", vencido: "50000",
            corriente: "37800", vencido_1_30: "50000", vencido_31_60: "0", vencido_mas_60: "0",
          },
        ],
      },
      error: null,
    },
  });
  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 2 });
  const result = await pendientesPagoTool.handler({}, ctx);

  assertEquals(result.total_global, 9604385);
  assertEquals(result.clientes_count, 81);
  assertEquals(result.clientes[0].nombre, "RAMON ABREGU");
  assertEquals(result.clientes[0].total_adeudado, 87800);
  assertEquals(result.clientes[0].vencido, 50000);
  assertEquals(result.clientes[0].aging.vencido_1_30, 50000);
  assertEquals(result.total_sucursal, 9700000);
  assertEquals(result.vencido_global, 50000);
  assert(result.criterio?.includes("monto_pagado"));

  assertEquals(spy.rpcCalls.length, 1);
  assertEquals(spy.rpcCalls[0].fn, "bot_pendientes_pago");
  assertEquals(spy.rpcCalls[0].params.p_dias_atraso, 0);
  assertEquals(spy.rpcCalls[0].params.p_limit, 50);
});

// ============================================================================
// 35. historico_pagos_cliente
// ============================================================================

Deno.test("historico_pagos_cliente invoca RPC con cliente_id correcto", async () => {
  const { client, spy } = createMockSupabase({
    rpcResponse: {
      data: {
        cliente_id: 42,
        pagos_count: 2,
        total_ultimos: "5000",
        pagos: [
          { id: 1, monto: "3000", forma_pago: "efectivo", fecha: "2026-04-20", referencia: null, notas: null, pedido_id: 100 },
          { id: 2, monto: 2000, forma_pago: "transferencia", fecha: "2026-04-15", referencia: "ABC", notas: null, pedido_id: null },
        ],
      },
      error: null,
    },
  });
  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 2 });
  const result = await historicoPagosClienteTool.handler(
    { cliente_id: 42, limit: 10 },
    ctx,
  );

  assertEquals(result.pagos_count, 2);
  assertEquals(result.total_ultimos, 5000);
  assertEquals(result.pagos[0].monto, 3000);
  assertEquals(result.pagos[0].forma_pago, "efectivo");
  assertEquals(result.pagos[1].referencia, "ABC");

  assertEquals(spy.rpcCalls[0].fn, "bot_historico_pagos_cliente");
  assertEquals(spy.rpcCalls[0].params.p_cliente_id, 42);
  assertEquals(spy.rpcCalls[0].params.p_sucursal_id, 2);
});

// ============================================================================
// 36. compras_periodo: top_proveedores con nombre y cuit
// ============================================================================

Deno.test("compras_periodo invoca RPC y mapea top_proveedores", async () => {
  const { client, spy } = createMockSupabase({
    rpcResponse: {
      data: {
        desde: "2026-01-01",
        hasta: "2026-04-28",
        total_compras: "7864107.9",
        compras_count: 11,
        top_proveedores: [
          {
            proveedor_id: 12,
            nombre: "MANAOS//REFRES NOW S.A.",
            cuit: "30708668733",
            total_comprado: "1805295.6",
            compras_count: 3,
          },
          {
            proveedor_id: null, nombre: "Sin nombre",
            cuit: null, total_comprado: 1557178, compras_count: 1,
          },
        ],
      },
      error: null,
    },
  });
  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 2 });
  const result = await comprasPeriodoTool.handler(
    { desde: "2026-01-01", hasta: "2026-04-28" },
    ctx,
  );

  assertEquals(result.total_compras, 7864107.9);
  assertEquals(result.compras_count, 11);
  assertEquals(result.top_proveedores[0].nombre, "MANAOS//REFRES NOW S.A.");
  assertEquals(result.top_proveedores[0].cuit, "30708668733");
  assertEquals(result.top_proveedores[1].proveedor_id, null);
  assertEquals(spy.rpcCalls[0].fn, "bot_compras_periodo");
  assertEquals(spy.rpcCalls[0].params.p_desde, "2026-01-01");
  // RPC sin desglose (anterior a las transferencias): todo es factura.
  assertEquals(result.compras_facturas, 7864107.9);
  assertEquals(result.compras_transferencias, 0);
});

Deno.test("compras_periodo pasa el desglose facturas / transferencias netas", async () => {
  const { client } = createMockSupabase({
    rpcResponse: {
      data: {
        desde: "2026-10-01",
        hasta: "2026-10-31",
        total_compras: "8790",
        compras_facturas: "10000",
        compras_transferencias: "-1210",
        compras_count: 2,
        top_proveedores: [],
      },
      error: null,
    },
  });
  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 1 });
  const result = await comprasPeriodoTool.handler(
    { desde: "2026-10-01", hasta: "2026-10-31" },
    ctx,
  );

  assertEquals(result.total_compras, 8790);
  assertEquals(result.compras_facturas, 10000);
  assertEquals(result.compras_transferencias, -1210);
});

// ============================================================================
// 37. historico_pedidos_cliente: pasa scope params al RPC
// ============================================================================

Deno.test("historico_pedidos_cliente pasa perfil_id+rol al RPC", async () => {
  const { client, spy } = createMockSupabase({
    rpcResponse: {
      data: {
        cliente_id: 565,
        pedidos_count: 1,
        rango_dias: 90,
        total_periodo: 8600,
        pedidos: [{
          id: 1280, fecha: "2026-04-27", total: 8600,
          estado: "entregado", estado_pago: "pagado",
          created_at: "2026-04-27T13:01:07Z",
          items: [
            { producto_id: 138, codigo: "1000", nombre: "AZUCAR X 1KG X 10",
              cantidad: 1, subtotal: 8600 },
          ],
        }],
      },
      error: null,
    },
  });
  const ctx = makeCtx(client, {
    rol: "preventista", sucursal_id: 1, perfil_id: "prev-uuid",
  });
  const result = await historicoClienteTool.handler(
    { cliente_id: 565, dias: 90, limit: 5 },
    ctx,
  );

  assertEquals(result.pedidos_count, 1);
  assertEquals(result.total_periodo, 8600);
  assertEquals(result.pedidos[0].items[0].nombre, "AZUCAR X 1KG X 10");

  const call = spy.rpcCalls[0];
  assertEquals(call.fn, "bot_historico_pedidos_cliente");
  assertEquals(call.params.p_perfil_id, "prev-uuid");
  assertEquals(call.params.p_rol, "preventista");
});

Deno.test("historico_pedidos_cliente: error de scope se propaga al output", async () => {
  const { client } = createMockSupabase({
    rpcResponse: {
      data: {
        cliente_id: 999,
        pedidos_count: 0,
        rango_dias: 90,
        pedidos: [],
        error: "Cliente no asignado a este preventista",
      },
      error: null,
    },
  });
  const ctx = makeCtx(client, {
    rol: "preventista", sucursal_id: 1, perfil_id: "otro-prev",
  });
  const result = await historicoClienteTool.handler({ cliente_id: 999 }, ctx);
  assertEquals(result.pedidos.length, 0);
  assertEquals(result.error, "Cliente no asignado a este preventista");
});

// ============================================================================
// 38. productos_recurrentes_cliente
// ============================================================================

Deno.test("productos_recurrentes_cliente ordena por pedidos_con_producto", async () => {
  const { client, spy } = createMockSupabase({
    rpcResponse: {
      data: {
        cliente_id: 440,
        rango_dias: 90,
        productos: [
          { id: 206, codigo: "F000006", nombre: "PAPAS FRITAS",
            precio: 300, pedidos_con_producto: 3,
            unidades_totales: 54, facturado_total: "16200" },
        ],
      },
      error: null,
    },
  });
  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 2 });
  const result = await productosRecurrentesTool.handler({ cliente_id: 440 }, ctx);

  assertEquals(result.productos[0].pedidos_con_producto, 3);
  assertEquals(result.productos[0].facturado_total, 16200);

  const call = spy.rpcCalls[0];
  assertEquals(call.fn, "bot_productos_recurrentes_cliente");
  assertEquals(call.params.p_dias, 90);
});

// ============================================================================
// 39. recorrido_resumen
// ============================================================================

Deno.test("recorrido_resumen invoca RPC con perfil_id como transportista_id", async () => {
  const { client, spy } = createMockSupabase({
    rpcResponse: {
      data: {
        recorrido_id: 555,
        fecha: "2026-04-26",
        estado: "completado",
        total_pedidos: 12,
        pedidos_entregados: 10,
        pedidos_pendientes: 2,
        total_facturado: "150000",
        total_cobrado: "120000",
        porcentaje_cobrado: "80",
        completed_at: null,
      },
      error: null,
    },
  });
  const ctx = makeCtx(client, {
    rol: "transportista", sucursal_id: 1, perfil_id: "trans-uuid",
  });
  const result = await recorridoResumenTool.handler({}, ctx);

  assertEquals(result.recorrido_id, 555);
  assertEquals(result.pedidos_entregados, 10);
  assertEquals(result.pedidos_pendientes, 2);
  assertEquals(result.porcentaje_cobrado, 80);

  const call = spy.rpcCalls[0];
  assertEquals(call.fn, "bot_recorrido_resumen");
  assertEquals(call.params.p_transportista_id, "trans-uuid");
  assertEquals(call.params.p_fecha, null);
});

Deno.test("recorrido_resumen sin recorrido devuelto lanza mensaje claro", async () => {
  const { client } = createMockSupabase({
    rpcResponse: { data: null, error: null },
  });
  const ctx = makeCtx(client, {
    rol: "transportista", sucursal_id: 1, perfil_id: "trans-uuid",
  });
  let threw = false;
  try {
    await recorridoResumenTool.handler({}, ctx);
  } catch (err) {
    threw = true;
    assertStringIncludes(
      err instanceof Error ? err.message : "",
      "No tenés recorrido cargado",
    );
  }
  assert(threw, "debió lanzar 'No tenés recorrido'");
});

// ============================================================================
// 50. ventas_por_preventista: invoca el RPC y mapea el ranking
// ============================================================================

Deno.test("ventas_por_preventista invoca el RPC y mapea preventistas", async () => {
  const { client, spy } = createMockSupabase({
    rpcResponse: {
      data: {
        desde: "2026-04-28",
        hasta: "2026-04-28",
        solo_preventistas: true,
        total_ventas: "1266750",
        pedidos_count: 47,
        preventistas_count: 4,
        preventistas: [
          {
            usuario_id: "aaa", nombre: "Christian", rol: "preventista",
            pedidos: 18, total_vendido: "420020", ticket_promedio: "23334.44",
          },
          {
            usuario_id: "bbb", nombre: "Joaquin", rol: "preventista",
            pedidos: 12, total_vendido: 355870, ticket_promedio: 29655.83,
          },
        ],
      },
      error: null,
    },
  });
  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 1 });
  const result = await ventasPorPreventistaTool.handler(
    { desde: "2026-04-28", hasta: "2026-04-28", limit: 10 },
    ctx,
  );

  assertEquals(result.total_ventas, 1266750);
  assertEquals(result.pedidos_count, 47);
  assertEquals(result.preventistas_count, 4);
  assertEquals(result.preventistas.length, 2);
  assertEquals(result.preventistas[0].nombre, "Christian");
  assertEquals(result.preventistas[0].total_vendido, 420020);
  assertEquals(result.preventistas[1].nombre, "Joaquin");
  assertEquals(result.preventistas[1].ticket_promedio, 29655.83);

  // RPC params correctos.
  assertEquals(spy.rpcCalls.length, 1);
  const call = spy.rpcCalls[0];
  assertEquals(call.fn, "bot_ventas_por_preventista");
  assertEquals(call.params.p_desde, "2026-04-28");
  assertEquals(call.params.p_hasta, "2026-04-28");
  assertEquals(call.params.p_sucursal_id, 1);
  assertEquals(call.params.p_solo_preventistas, true);
  assertEquals(call.params.p_limit, 10);
});

Deno.test("ventas_por_preventista respeta solo_preventistas=false", async () => {
  const { client, spy } = createMockSupabase({
    rpcResponse: {
      data: {
        desde: "2026-04-28", hasta: "2026-04-28", solo_preventistas: false,
        total_ventas: 0, pedidos_count: 0, preventistas_count: 0,
        preventistas: [],
      },
      error: null,
    },
  });
  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 1 });
  await ventasPorPreventistaTool.handler(
    { desde: "2026-04-28", hasta: "2026-04-28", solo_preventistas: false },
    ctx,
  );
  assertEquals(spy.rpcCalls[0].params.p_solo_preventistas, false);
});

Deno.test("ventas_por_preventista valida fechas y rango", async () => {
  const { client } = createMockSupabase({});
  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 1 });
  let threw = 0;
  try {
    await ventasPorPreventistaTool.handler(
      { desde: "ayer", hasta: "2026-04-28" },
      ctx,
    );
  } catch (err) {
    threw++;
    assertStringIncludes(err instanceof Error ? err.message : "", "Fechas inválidas");
  }
  try {
    await ventasPorPreventistaTool.handler(
      { desde: "2026-04-28", hasta: "2026-04-01" },
      ctx,
    );
  } catch (err) {
    threw++;
    assertStringIncludes(err instanceof Error ? err.message : "", "desde");
  }
  assertEquals(threw, 2);
});

// ============================================================================
// 51. mis_ventas: solo preventista, scopea al perfil_id propio
// ============================================================================

Deno.test("mis_ventas invoca el RPC con perfil_id del caller y mapea top_clientes", async () => {
  const { client, spy } = createMockSupabase({
    rpcResponse: {
      data: {
        desde: "2026-04-01",
        hasta: "2026-04-29",
        total_ventas: "1500000",
        pedidos_count: 25,
        ticket_promedio: "60000",
        clientes_distintos: 14,
        top_clientes: [
          {
            cliente_id: 100, cliente_codigo: 12,
            nombre_fantasia: "Almacén Pepe", razon_social: "Pepe SA",
            total_comprado: "350000", pedidos: 5,
          },
          {
            cliente_id: 101, cliente_codigo: null,
            nombre_fantasia: null, razon_social: "María SRL",
            total_comprado: 200000, pedidos: 3,
          },
        ],
      },
      error: null,
    },
  });
  const ctx = makeCtx(client, {
    rol: "preventista",
    sucursal_id: 1,
    perfil_id: "PERFIL-CHRISTIAN",
  });
  const result = await misVentasTool.handler(
    { desde: "2026-04-01", hasta: "2026-04-29" },
    ctx,
  );

  assertEquals(result.total_ventas, 1500000);
  assertEquals(result.pedidos_count, 25);
  assertEquals(result.ticket_promedio, 60000);
  assertEquals(result.clientes_distintos, 14);
  assertEquals(result.top_clientes[0].nombre, "Almacén Pepe");
  assertEquals(result.top_clientes[1].nombre, "María SRL");

  assertEquals(spy.rpcCalls.length, 1);
  const call = spy.rpcCalls[0];
  assertEquals(call.fn, "bot_mis_ventas");
  assertEquals(call.params.p_preventista_id, "PERFIL-CHRISTIAN");
  assertEquals(call.params.p_desde, "2026-04-01");
  assertEquals(call.params.p_hasta, "2026-04-29");
  assertEquals(call.params.p_sucursal_id, 1);
});

Deno.test("mis_ventas rechaza si el rol no es preventista", async () => {
  const { client } = createMockSupabase({});
  const ctxAdmin = makeCtx(client, { rol: "admin", sucursal_id: 1 });
  let threw = false;
  try {
    await misVentasTool.handler(
      { desde: "2026-04-28", hasta: "2026-04-28" },
      ctxAdmin,
    );
  } catch (err) {
    threw = true;
    assertStringIncludes(
      err instanceof Error ? err.message : "",
      "preventista",
    );
  }
  assert(threw, "debió rechazar a admin (defense-in-depth)");
});

Deno.test("mis_ventas valida fechas y rango", async () => {
  const { client } = createMockSupabase({});
  const ctx = makeCtx(client, { rol: "preventista", sucursal_id: 1 });
  let threw = 0;
  try {
    await misVentasTool.handler(
      { desde: "01-01-2026", hasta: "2026-04-28" },
      ctx,
    );
  } catch (err) {
    threw++;
    assertStringIncludes(err instanceof Error ? err.message : "", "Fechas inválidas");
  }
  try {
    await misVentasTool.handler(
      { desde: "2026-05-01", hasta: "2026-04-01" },
      ctx,
    );
  } catch (err) {
    threw++;
    assertStringIncludes(err instanceof Error ? err.message : "", "desde");
  }
  assertEquals(threw, 2);
});

// ============================================================================
// 52. ranking_preventistas_por_producto: invoca RPC con producto_ids array
// ============================================================================

Deno.test("ranking_preventistas_por_producto invoca el RPC con producto_ids array y mapea ranking agregado", async () => {
  const { client, spy } = createMockSupabase({
    rpcResponse: {
      data: {
        producto_ids: [10, 17, 23],
        productos: [
          { id: 10, codigo: "M0010", nombre: "MANAOS COLA 3000CC X 6" },
          { id: 17, codigo: "M0017", nombre: "MANAOS NARANJA 3000CC X 6" },
          { id: 23, codigo: "M0023", nombre: "MANAOS POMELO 3000CC X 6" },
        ],
        desde: "2026-04-01",
        hasta: "2026-04-30",
        unidades_total: 240,
        facturado_total: "1200000",
        preventistas_count: 3,
        preventistas: [
          {
            usuario_id: "aaa",
            nombre: "Christian",
            rol: "preventista",
            unidades: 120,
            facturado: "600000",
            productos_distintos: 3,
            line_items: 18,
          },
          {
            usuario_id: "bbb",
            nombre: "Joaquin",
            rol: "preventista",
            unidades: 80,
            facturado: 400000,
            productos_distintos: 2,
            line_items: 10,
          },
          {
            usuario_id: null,
            nombre: null,
            rol: null,
            unidades: 40,
            facturado: 200000,
            productos_distintos: 1,
            line_items: 5,
          },
        ],
      },
      error: null,
    },
  });
  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 1 });
  const result = await rankingPreventistasPorProductoTool.handler(
    {
      producto_ids: [10, 17, 23],
      desde: "2026-04-01",
      hasta: "2026-04-30",
      limit: 10,
    },
    ctx,
  );

  assertEquals(result.producto_ids, [10, 17, 23]);
  assertEquals(result.productos.length, 3);
  assertEquals(result.productos[0].nombre, "MANAOS COLA 3000CC X 6");
  assertEquals(result.unidades_total, 240);
  assertEquals(result.facturado_total, 1200000);
  assertEquals(result.preventistas_count, 3);
  assertEquals(result.preventistas.length, 3);
  assertEquals(result.preventistas[0].nombre, "Christian");
  assertEquals(result.preventistas[0].unidades, 120);
  assertEquals(result.preventistas[0].productos_distintos, 3);
  assertEquals(result.preventistas[1].line_items, 10);
  assertEquals(result.preventistas[2].nombre, "(sin asignar)");

  assertEquals(spy.rpcCalls.length, 1);
  const call = spy.rpcCalls[0];
  assertEquals(call.fn, "bot_ranking_preventistas_por_producto");
  assertEquals(call.params.p_producto_ids, [10, 17, 23]);
  assertEquals(call.params.p_desde, "2026-04-01");
  assertEquals(call.params.p_hasta, "2026-04-30");
  assertEquals(call.params.p_sucursal_id, 1);
  assertEquals(call.params.p_limit, 10);
});

Deno.test("ranking_preventistas_por_producto acepta un solo producto_id en el array", async () => {
  const { client, spy } = createMockSupabase({
    rpcResponse: {
      data: {
        producto_ids: [166],
        productos: [{ id: 166, codigo: "SAL01", nombre: "SAL FINA X 500 GRS" }],
        desde: "2026-04-01",
        hasta: "2026-04-30",
        unidades_total: 780,
        facturado_total: 160200,
        preventistas_count: 1,
        preventistas: [
          {
            usuario_id: "aaa",
            nombre: "Christian",
            rol: "preventista",
            unidades: 510,
            facturado: 104700,
            productos_distintos: 1,
            line_items: 22,
          },
        ],
      },
      error: null,
    },
  });
  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 1 });
  const result = await rankingPreventistasPorProductoTool.handler(
    { producto_ids: [166], desde: "2026-04-01", hasta: "2026-04-30" },
    ctx,
  );
  assertEquals(result.producto_ids, [166]);
  assertEquals(spy.rpcCalls[0].params.p_producto_ids, [166]);
});

Deno.test("ranking_preventistas_por_producto rechaza array vacío", async () => {
  const { client } = createMockSupabase({});
  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 1 });
  let threw = false;
  try {
    await rankingPreventistasPorProductoTool.handler(
      { producto_ids: [], desde: "2026-04-01", hasta: "2026-04-30" },
      ctx,
    );
  } catch (err) {
    threw = true;
    assertStringIncludes(
      err instanceof Error ? err.message : "",
      "al menos 1",
    );
  }
  assert(threw, "debió rechazar array vacío");
});

Deno.test("ranking_preventistas_por_producto rechaza array con ID inválido", async () => {
  const { client } = createMockSupabase({});
  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 1 });
  let threw = false;
  try {
    await rankingPreventistasPorProductoTool.handler(
      { producto_ids: [10, 0, 23], desde: "2026-04-01", hasta: "2026-04-30" },
      ctx,
    );
  } catch (err) {
    threw = true;
    assertStringIncludes(
      err instanceof Error ? err.message : "",
      "ID inválido",
    );
  }
  assert(threw, "debió rechazar ID 0");
});

Deno.test("ranking_preventistas_por_producto rechaza array de >25 elementos", async () => {
  const { client } = createMockSupabase({});
  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 1 });
  const big = Array.from({ length: 26 }, (_, i) => i + 1);
  let threw = false;
  try {
    await rankingPreventistasPorProductoTool.handler(
      { producto_ids: big, desde: "2026-04-01", hasta: "2026-04-30" },
      ctx,
    );
  } catch (err) {
    threw = true;
    assertStringIncludes(
      err instanceof Error ? err.message : "",
      "más de 25",
    );
  }
  assert(threw, "debió rechazar array > 25");
});

Deno.test("ranking_preventistas_por_producto valida fechas y rango", async () => {
  const { client } = createMockSupabase({});
  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 1 });
  let threw = 0;
  try {
    await rankingPreventistasPorProductoTool.handler(
      { producto_ids: [1], desde: "ayer", hasta: "2026-04-30" },
      ctx,
    );
  } catch (err) {
    threw++;
    assertStringIncludes(
      err instanceof Error ? err.message : "",
      "Fechas inválidas",
    );
  }
  try {
    await rankingPreventistasPorProductoTool.handler(
      { producto_ids: [1], desde: "2026-04-30", hasta: "2026-04-01" },
      ctx,
    );
  } catch (err) {
    threw++;
    assertStringIncludes(err instanceof Error ? err.message : "", "desde");
  }
  assertEquals(threw, 2);
});

// ============================================================================
// Catálogo ofrecible: activo AND (stock > 0 OR mostrar_sin_stock)
// ============================================================================

Deno.test("esProductoMostrable: activo AND (stock > 0 OR mostrar_sin_stock)", () => {
  // Inactivo: nunca, con o sin política.
  assertEquals(esProductoMostrable({ activo: false, stock: 10 }, true), false);
  assertEquals(esProductoMostrable({ activo: false, stock: 10 }, false), false);
  // Activo con stock: siempre.
  assertEquals(esProductoMostrable({ activo: true, stock: 1 }, false), true);
  assertEquals(esProductoMostrable({ activo: true, stock: "5" }, false), true);
  // Activo sin stock: depende de la política.
  assertEquals(esProductoMostrable({ activo: true, stock: 0 }, true), true);
  assertEquals(esProductoMostrable({ activo: true, stock: 0 }, false), false);
  assertEquals(esProductoMostrable({ activo: true, stock: -3 }, false), false);
  assertEquals(esProductoMostrable({ activo: true, stock: null }, false), false);
  // activo desconocido no es activo.
  assertEquals(esProductoMostrable({ activo: null, stock: 5 }, true), false);
});

Deno.test("fetchMostrarSinStock: fila true/false, sin fila y sucursal null", async () => {
  const mk = (row: Record<string, unknown> | null) =>
    createMockSupabase({
      perTable: {
        politicas_comerciales: { maybeSingleResponse: { data: row, error: null } },
      },
    });

  const a = mk({ mostrar_sin_stock: false });
  assertEquals(await fetchMostrarSinStock(a.client, 1), false);
  const pol = a.spy.queries.find((q) => q.table === "politicas_comerciales");
  assert(pol!.filters.some((f) => f.type === "eq" && f.args[0] === "sucursal_id" && f.args[1] === 1));

  assertEquals(await fetchMostrarSinStock(mk({ mostrar_sin_stock: true }).client, 1), true);
  assertEquals(await fetchMostrarSinStock(mk(null).client, 1), true); // sin fila

  const n = mk({ mostrar_sin_stock: false });
  assertEquals(await fetchMostrarSinStock(n.client, null), true); // sin sucursal
  assertEquals(n.spy.queries.length, 0, "sin sucursal no debe consultar");
});

function clientePolitica(mostrar: boolean | null) {
  return createMockSupabase({
    perTable: {
      politicas_comerciales: {
        maybeSingleResponse: {
          data: mostrar === null ? null : { mostrar_sin_stock: mostrar },
          error: null,
        },
      },
      productos: { selectResponse: { data: [], error: null, count: 0 } },
    },
  });
}

for (
  const [nombre, tool, params] of [
    ["buscar_producto", buscarProductoTool, { q: "agua" }],
    ["productos_por_categoria", productosPorCategoriaTool, { categoria: "AGUAS" }],
  ] as const
) {
  Deno.test(`${nombre}: filtra activo = true y, con mostrar_sin_stock=false, stock > 0 en la query`, async () => {
    const { client, spy } = clientePolitica(false);
    // deno-lint-ignore no-explicit-any
    await (tool as any).handler(params, makeCtx(client, { rol: "admin", sucursal_id: 1 }));
    const q = spy.queries.find((qq) => qq.table === "productos")!;
    assert(q.filters.some((f) => f.type === "eq" && f.args[0] === "activo" && f.args[1] === true));
    assert(q.filters.some((f) => f.type === "gt" && f.args[0] === "stock" && f.args[1] === 0));
  });

  Deno.test(`${nombre}: con mostrar_sin_stock=true no filtra stock (sólo activo)`, async () => {
    const { client, spy } = clientePolitica(true);
    // deno-lint-ignore no-explicit-any
    await (tool as any).handler(params, makeCtx(client, { rol: "admin", sucursal_id: 1 }));
    const q = spy.queries.find((qq) => qq.table === "productos")!;
    assert(q.filters.some((f) => f.type === "eq" && f.args[0] === "activo" && f.args[1] === true));
    assertEquals(q.filters.filter((f) => f.type === "gt").length, 0);
  });

  Deno.test(`${nombre}: sin fila de política rige el default (muestra sin stock)`, async () => {
    const { client, spy } = clientePolitica(null);
    // deno-lint-ignore no-explicit-any
    await (tool as any).handler(params, makeCtx(client, { rol: "preventista", sucursal_id: 1 }));
    const q = spy.queries.find((qq) => qq.table === "productos")!;
    assertEquals(q.filters.filter((f) => f.type === "gt").length, 0);
    assert(q.filters.some((f) => f.type === "eq" && f.args[0] === "activo"));
  });

  Deno.test(`${nombre}: admin sin sucursal usa el default y no consulta la política`, async () => {
    const { client, spy } = clientePolitica(false);
    // deno-lint-ignore no-explicit-any
    await (tool as any).handler(params, makeCtx(client, { rol: "admin", sucursal_id: null }));
    assertEquals(spy.queries.some((qq) => qq.table === "politicas_comerciales"), false);
    const q = spy.queries.find((qq) => qq.table === "productos")!;
    assertEquals(q.filters.filter((f) => f.type === "gt").length, 0);
    assert(q.filters.some((f) => f.type === "eq" && f.args[0] === "activo"));
  });
}

Deno.test("listar_categorias sólo mira productos activos (sin política de stock)", async () => {
  const { client, spy } = createMockSupabase({
    selectResponse: { data: [{ categoria: "AGUAS" }], error: null },
  });
  await listarCategoriasTool.handler({} as never, makeCtx(client, { rol: "admin", sucursal_id: 1 }));
  const q = spy.queries.find((qq) => qq.table === "productos")!;
  assert(q.filters.some((f) => f.type === "eq" && f.args[0] === "activo" && f.args[1] === true));
  assertEquals(q.filters.filter((f) => f.type === "gt").length, 0);
  assertEquals(spy.queries.some((qq) => qq.table === "politicas_comerciales"), false);
});

// ============================================================================
// 296. El bot ve lo que ve la app: roles combinados y fichas acotadas
// ============================================================================

Deno.test("rolEfectivo: elige el rol de más alcance que la tool acepta", () => {
  const soloTransportista = { allowedRoles: ["transportista"] } as unknown as Tool;
  const comercial = {
    allowedRoles: ["admin", "encargado", "preventista"],
  } as unknown as Tool;
  const todos = {
    allowedRoles: ["admin", "preventista", "transportista", "encargado", "deposito"],
  } as unknown as Tool;
  const prevYTransp = ["preventista", "transportista"] as const;

  assertEquals(rolEfectivo(prevYTransp, soloTransportista), "transportista");
  assertEquals(rolEfectivo(prevYTransp, comercial), "preventista");
  // Con todos los roles habilitados manda el de más alcance, no el extra.
  assertEquals(rolEfectivo(prevYTransp, todos), "preventista");
  // Un transportista puro sigue sin poder usar las comerciales.
  assertEquals(rolEfectivo(["transportista"], comercial), null);
  assertEquals(canInvoke("transportista", comercial), false);
  assertEquals(canInvoke(prevYTransp, soloTransportista), true);
});

Deno.test("invokeTool: un preventista que además reparte corre cada tool con el rol que corresponde", async () => {
  _clearToolsForTests();
  _resetRegisterFlagForTests();
  const { client } = createMockSupabase({});
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);

  const vistos: Record<string, string> = {};
  const espia = (name: string, allowedRoles: Tool["allowedRoles"]): Tool => ({
    name,
    description: "espía",
    parameters: { type: "object", properties: {} },
    allowedRoles,
    handler: (_p, ctx) => {
      vistos[name] = ctx.rol;
      return Promise.resolve({ ok: true });
    },
  });
  registerTool(espia("de_reparto", ["transportista"]));
  registerTool(espia("de_venta", ["admin", "encargado", "preventista"]));
  registerTool(espia("de_admin", ["admin"]));

  const ctx = makeCtx(client, {
    rol: "preventista",
    roles: ["preventista", "transportista"],
  });

  assertEquals((await invokeTool("de_reparto", {}, ctx)).ok, true);
  assertEquals((await invokeTool("de_venta", {}, ctx)).ok, true);
  const denegada = await invokeTool("de_admin", {}, ctx);
  assertEquals(denegada.ok, false);

  assertEquals(vistos.de_reparto, "transportista");
  assertEquals(vistos.de_venta, "preventista");
  assertEquals(vistos.de_admin, undefined);

  // Sin roles extra (contexto viejo) se comporta como antes.
  const ctxSimple = makeCtx(client, { rol: "preventista" });
  assertEquals((await invokeTool("de_reparto", {}, ctxSimple)).ok, false);
  _clearToolsForTests();
});

function mockFichaCliente(
  pedidosPropios: Array<{ total: number; estado?: string | null; estado_pago?: string; tipo_factura?: string }>,
  clienteExtra: Record<string, unknown> = {},
) {
  return createMockSupabase({
    perTable: {
      clientes: {
        maybeSingleResponse: {
          data: {
            id: 500,
            codigo: 12,
            nombre_fantasia: "Almacén",
            razon_social: null,
            direccion: null,
            telefono: null,
            zona: null,
            sucursal_id: 1,
            reservado_admin: false,
            ...clienteExtra,
          },
          error: null,
        },
      },
      cliente_preventistas: { selectResponse: { data: [], error: null, count: 0 } },
      pedidos: { selectResponse: { data: pedidosPropios, error: null } },
    },
    rpcResponse: {
      data: {
        saldo_actual: 5000,
        limite_credito: 10000,
        credito_disponible: 5000,
        // Totales del cliente con TODOS los vendedores.
        total_pedidos: 30,
        total_compras: 900000,
        total_pagos: 895000,
        pedidos_pendientes_pago: 1,
        ultimo_pedido: "2026-10-01",
        ultimo_pago: "2026-09-30",
      },
      error: null,
    },
  });
}

Deno.test("ficha_cliente preventista: los totales son sólo los suyos", async () => {
  const yo = "66666666-6666-6666-6666-666666666666";
  const { client, spy } = mockFichaCliente([
    { total: 1000, estado: "entregado", estado_pago: "pagado" },
    { total: 2500, estado: null, estado_pago: "pendiente" },
    // Cancelados y anulados no cuentan, igual que en historico y recurrentes.
    { total: 9999, estado: "cancelado", estado_pago: "pendiente" },
    { total: 8888, estado: "anulado", estado_pago: "pendiente" },
  ]);
  const r = await fichaClienteTool.handler(
    { cliente_id: 500 },
    makeCtx(client, { rol: "preventista", perfil_id: yo }),
  );
  assertEquals(r.alcance_totales, "propios");
  assertEquals(r.total_pedidos, 2);
  assertEquals(r.total_compras, 3500);
  // Los pendientes también son los suyos: el cliente tiene 1 en la RPC, él 1.
  assertEquals(r.pedidos_pendientes_pago, 1);
  // El saldo y la fecha del último pedido son del cliente: la app los muestra.
  assertEquals(r.saldo_actual, 5000);
  assertEquals(r.ultimo_pedido?.fecha, "2026-10-01");
  // El preventista ve los pagos de la sucursal en la app (mt_pagos_select).
  assertEquals(r.total_pagos, 895000);

  const q = spy.queries.find((x) => x.table === "pedidos");
  assert(q, "debió consultar los pedidos propios");
  const or = q!.filters.find((f) => f.type === "or");
  assertEquals(or?.args[0], `usuario_id.eq.${yo},transportista_id.eq.${yo}`);
  // Y acotado a su sucursal y al cliente.
  assert(q!.filters.some((f) => f.type === "eq" && f.args[0] === "sucursal_id" && f.args[1] === 1));
  assert(q!.filters.some((f) => f.type === "eq" && f.args[0] === "cliente_id" && f.args[1] === 500));
});

Deno.test("ficha_cliente transportista: sin pagos del cliente", async () => {
  const { client } = mockFichaCliente([{ total: 700 }]);
  const r = await fichaClienteTool.handler(
    { cliente_id: 500 },
    makeCtx(client, { rol: "transportista" }),
  );
  assertEquals(r.alcance_totales, "propios");
  assertEquals(r.total_compras, 700);
  assertEquals(r.total_pagos, null);
  assertEquals(r.ultimo_pago, null);
});

Deno.test("ficha_cliente admin y encargado: totales del cliente completo", async () => {
  for (const rol of ["admin", "encargado"] as const) {
    const { client, spy } = mockFichaCliente([{ total: 1 }]);
    const r = await fichaClienteTool.handler({ cliente_id: 500 }, makeCtx(client, { rol }));
    assertEquals(r.alcance_totales, "todos");
    assertEquals(r.total_compras, 900000);
    assertEquals(r.total_pagos, 895000);
    assertEquals(spy.queries.some((x) => x.table === "pedidos"), false);
  }
});

Deno.test("ficha_cliente preventista: un vale blanco no suma a los totales de venta", async () => {
  const { client } = mockFichaCliente([
    { total: 1000, estado: "entregado", estado_pago: "pagado" },
    { total: 5000, estado: "entregado", estado_pago: "pagado", tipo_factura: "VB" },
  ]);
  const r = await fichaClienteTool.handler(
    { cliente_id: 500 },
    makeCtx(client, { rol: "preventista" }),
  );
  assertEquals(r.total_pedidos, 1);
  assertEquals(r.total_compras, 1000);
  assertEquals(r.consumo_interno, null);
});

Deno.test("ficha_cliente cliente VB: consumo interno aparte, sin cancelados", async () => {
  const { client, spy } = mockFichaCliente(
    [
      { total: 300, estado: "entregado" },
      { total: 200, estado: "entregado" },
      { total: 999, estado: "cancelado" },
    ],
    { tipo_factura_default: "VB" },
  );
  const r = await fichaClienteTool.handler({ cliente_id: 500 }, makeCtx(client, { rol: "admin" }));
  // Los totales de venta vienen de la RPC (que excluye VB), no de esta query.
  assertEquals(r.total_compras, 900000);
  assertEquals(r.consumo_interno, { monto: 500, pedidos: 2 });
  const q = spy.queries.find((x) => x.table === "pedidos");
  assert(q, "debió consultar los vales del cliente");
  assert(q!.filters.some((f) => f.type === "eq" && f.args[0] === "tipo_factura" && f.args[1] === "VB"));
});

// #1034: el total de un vale blanco es su costo. Fuera de admin y encargado,
// el consumo interno es sólo lo que cargó el que pregunta: el que lo repartió
// no lo ve (mig 332, mismo alcance que mt_pedidos_select para un VB).
Deno.test("ficha_cliente cliente VB: el consumo interno no incluye lo que el usuario sólo repartió", async () => {
  const yo = "77777777-7777-7777-7777-777777777777";
  for (const rol of ["preventista", "transportista"] as const) {
    const { client, spy } = mockFichaCliente(
      [{ total: 300, estado: "entregado" }],
      { tipo_factura_default: "VB" },
    );
    await fichaClienteTool.handler({ cliente_id: 500 }, makeCtx(client, { rol, perfil_id: yo }));
    const q = spy.queries.find((x) =>
      x.table === "pedidos" &&
      x.filters.some((f) => f.type === "eq" && f.args[0] === "tipo_factura" && f.args[1] === "VB")
    );
    assert(q, `debió consultar los vales del cliente (${rol})`);
    assert(
      q!.filters.some((f) => f.type === "eq" && f.args[0] === "usuario_id" && f.args[1] === yo),
      `${rol}: el consumo interno se acota a lo que cargó`,
    );
    assertEquals(
      q!.filters.some((f) => f.type === "or" && String(f.args[0]).includes("transportista_id")),
      false,
      `${rol}: el consumo interno no se abre por transportista_id`,
    );
  }
});

Deno.test("ficha_producto: el volumen de ventas de la sucursal sólo para admin y encargado", async () => {
  const respuesta = {
    data: {
      producto: {
        id: 215,
        codigo: "M00025",
        nombre: "MANAOS CITRUS 2250CC X 6",
        precio: 9100,
        precio_sin_iva: 9100,
        stock: 50,
        stock_minimo: 10,
        categoria: "GASEOSAS",
        proveedor_id: null,
      },
      ventas_30d_cantidad: 752,
      ultima_venta: "2026-10-06T15:00:00+00:00",
    },
    error: null,
  };
  for (const rol of ["preventista", "transportista", "deposito"] as const) {
    const { client } = createMockSupabase({ rpcResponse: respuesta });
    const r = await fichaProductoTool.handler({ producto_id: 215 }, makeCtx(client, { rol }));
    assertEquals(r.ventas_30d_cantidad, null, `${rol} no debe ver el volumen`);
    assertEquals(r.ultima_venta, null);
    assertEquals(r.producto.stock, 50);
  }
  for (const rol of ["admin", "encargado"] as const) {
    const { client } = createMockSupabase({ rpcResponse: respuesta });
    const r = await fichaProductoTool.handler({ producto_id: 215 }, makeCtx(client, { rol }));
    assertEquals(r.ventas_30d_cantidad, 752);
  }
});

// ============================================================================
// 300. El bot cuenta como la app
// ============================================================================

Deno.test("ventas_por_preventista: trae la sucursal, el total de todos los roles y los excluidos", async () => {
  const { client } = createMockSupabase({
    rpcResponse: {
      data: {
        desde: "2026-09-01", hasta: "2026-09-30", sucursal: "Tucumán",
        solo_preventistas: true,
        total_ventas: "31953780", pedidos_count: 834,
        total_todos_los_roles: "33544660", pedidos_todos_los_roles: 862,
        excluidos: [{ nombre: "Nacho R", rol: "admin", total_vendido: "1590880" }],
        preventistas_count: 1,
        preventistas: [{ usuario_id: "u1", nombre: "Marcelo", rol: "preventista", pedidos: 405, total_vendido: "14529870", ticket_promedio: "35876.22" }],
      },
      error: null,
    },
  });
  const r = await ventasPorPreventistaTool.handler(
    { desde: "2026-09-01", hasta: "2026-09-30" },
    makeCtx(client, { rol: "admin", sucursal_id: 1 }),
  );
  assertEquals(r.sucursal, "Tucumán");
  assertEquals(r.total_todos_los_roles, 33544660);
  assertEquals(r.excluidos, [{ nombre: "Nacho R", rol: "admin", total_vendido: 1590880 }]);
  // Preventistas + excluidos = todos: el bot puede decir cuánto dejó afuera.
  assertEquals(r.total_ventas + r.excluidos[0].total_vendido, r.total_todos_los_roles);
});

Deno.test("ficha_producto: vendidas y regaladas por separado", async () => {
  const { client } = createMockSupabase({
    rpcResponse: {
      data: {
        producto: { id: 126, codigo: "1", nombre: "AGUA 600", precio: 1, precio_sin_iva: 1, stock: 918, stock_minimo: 10, categoria: null, proveedor_id: null },
        ventas_30d_cantidad: 699,
        regaladas_30d_cantidad: 31,
        ultima_venta: "2026-10-05",
      },
      error: null,
    },
  });
  const r = await fichaProductoTool.handler({ producto_id: 126 }, makeCtx(client, { rol: "admin" }));
  assertEquals(r.ventas_30d_cantidad, 699);
  assertEquals(r.regaladas_30d_cantidad, 31);
  const { client: c2 } = createMockSupabase({
    rpcResponse: {
      data: {
        producto: { id: 126, codigo: "1", nombre: "AGUA 600", precio: 1, precio_sin_iva: 1, stock: 918, stock_minimo: 10, categoria: null, proveedor_id: null },
        ventas_30d_cantidad: 699, regaladas_30d_cantidad: 31, ultima_venta: "2026-10-05",
      },
      error: null,
    },
  });
  const p = await fichaProductoTool.handler({ producto_id: 126 }, makeCtx(c2, { rol: "preventista" }));
  assertEquals(p.regaladas_30d_cantidad, null, "el preventista tampoco ve las regaladas de la sucursal");
});

Deno.test("historico_pedidos_cliente: el total es de la ventana aunque se muestre un pedido", async () => {
  const { client } = createMockSupabase({
    rpcResponse: {
      data: {
        cliente_id: 756, pedidos_count: 6, pedidos_mostrados: 1, rango_dias: 365,
        total_periodo: "416350", alcance: "todos",
        pedidos: [{ id: 1, fecha: "2026-10-01", total: "110400", estado: "entregado", estado_pago: "pagado", created_at: "2026-10-01T12:00:00Z", items: [] }],
      },
      error: null,
    },
  });
  const r = await historicoClienteTool.handler(
    { cliente_id: 756, dias: 365, limit: 1 },
    makeCtx(client, { rol: "admin", sucursal_id: 1 }),
  );
  assertEquals(r.total_periodo, 416350);
  assertEquals(r.pedidos_count, 6);
  assertEquals(r.pedidos_mostrados, 1);
  assertEquals(r.pedidos.length, 1);
});

Deno.test("invokeTool: las filas tool_call del registro llevan el chat de Telegram", async () => {
  _clearToolsForTests();
  _resetRegisterFlagForTests();
  const { client, spy } = createMockSupabase({});
  // deno-lint-ignore no-explicit-any
  _setServiceRoleClientForTests(client as any);
  registerTool({
    name: "eco",
    description: "eco",
    parameters: { type: "object", properties: {} },
    allowedRoles: ["admin"],
    handler: () => Promise.resolve({ ok: true }),
  });
  await invokeTool("eco", {}, makeCtx(client, { rol: "admin", telegram_user_id: 777 }));
  const filas = spy.inserts.filter((i) => i.table === "bot_audit_log" && i.row.tipo === "tool_call");
  assert(filas.length > 0, "debió auditar la llamada");
  for (const f of filas) assertEquals(f.row.telegram_user_id, 777);
  _clearToolsForTests();
});

// ============================================================================
// 308. Herramientas comerciales
// ============================================================================

Deno.test("clientes_atrasados preventista: ignora 'preventista' y no consulta perfiles", async () => {
  const yo = "66666666-6666-6666-6666-666666666666";
  const { client, spy } = createMockSupabase({
    rpcResponse: {
      data: { cartera: "preventista", montos: "propios", clientes_en_cartera: 3, atrasados: 1, monto_mensual_en_riesgo: 1000, clientes: [] },
      error: null,
    },
  });
  const r = await clientesAtrasadosTool.handler(
    { preventista: "Osvaldo" },
    makeCtx(client, { rol: "preventista", perfil_id: yo }),
  );
  // Un preventista no puede pedir la cartera de otro.
  assertEquals(spy.rpcCalls[0].params.p_preventista_id, null);
  assertEquals(spy.rpcCalls[0].params.p_perfil_id, yo);
  assertEquals(spy.rpcCalls[0].params.p_rol, "preventista");
  assertEquals(spy.queries.some((q) => q.table === "perfiles"), false);
  assertEquals(r.montos, "propios");
});

Deno.test("clientes_atrasados admin: resuelve el preventista por nombre en la sucursal", async () => {
  const marcelo = "77777777-7777-7777-7777-777777777777";
  const { client, spy } = createMockSupabase({
    perTable: {
      usuario_sucursales: { selectResponse: { data: [{ usuario_id: marcelo }], error: null } },
      perfiles: { selectResponse: { data: [{ id: marcelo, nombre: "Marcelo" }], error: null } },
    },
    rpcResponse: {
      data: { cartera: "preventista", montos: "todos", clientes_en_cartera: 187, atrasados: 2, monto_mensual_en_riesgo: 5000, clientes: [] },
      error: null,
    },
  });
  const r = await clientesAtrasadosTool.handler(
    { preventista: "marcelo" },
    makeCtx(client, { rol: "admin", sucursal_id: 1 }),
  );
  assertEquals(spy.rpcCalls[0].params.p_preventista_id, marcelo);
  assertEquals(r.preventista, "Marcelo");
  // Sólo busca entre los asignados a la sucursal activa.
  const qSuc = spy.queries.find((q) => q.table === "usuario_sucursales");
  assert(qSuc?.filters.some((f) => f.type === "eq" && f.args[0] === "sucursal_id" && f.args[1] === 1));
});

Deno.test("clientes_atrasados admin: dos preventistas con el mismo nombre → pregunta cuál", async () => {
  const { client } = createMockSupabase({
    perTable: {
      usuario_sucursales: { selectResponse: { data: [{ usuario_id: "a" }, { usuario_id: "b" }], error: null } },
      perfiles: { selectResponse: { data: [{ id: "a", nombre: "Juan Pérez" }, { id: "b", nombre: "Juan Gómez" }], error: null } },
    },
  });
  let mensaje = "";
  try {
    await clientesAtrasadosTool.handler({ preventista: "Juan" }, makeCtx(client, { rol: "admin" }));
  } catch (e) {
    mensaje = e instanceof Error ? e.message : "";
  }
  assertStringIncludes(mensaje, "más de uno que coincide");
});

Deno.test("ranking_clientes: valida orden y fechas, y pasa el preventista propio", async () => {
  const yo = "66666666-6666-6666-6666-666666666666";
  const { client, spy } = createMockSupabase({
    rpcResponse: { data: { orden: "caidas", total_periodo: 10, total_anterior: 20, clientes: [] }, error: null },
  });
  await rankingClientesTool.handler(
    { desde: "2026-09-08", hasta: "2026-10-07", orden: "caidas" },
    makeCtx(client, { rol: "preventista", perfil_id: yo }),
  );
  assertEquals(spy.rpcCalls[0].params.p_orden, "caidas");
  assertEquals(spy.rpcCalls[0].params.p_preventista_id, null);
  let threw = 0;
  for (const p of [
    { desde: "08/09/2026", hasta: "2026-10-07" },
    { desde: "2026-10-07", hasta: "2026-09-08" },
    { desde: "2026-09-08", hasta: "2026-10-07", orden: "peores" as never },
  ]) {
    try {
      await rankingClientesTool.handler(p, makeCtx(client, { rol: "admin" }));
    } catch {
      threw++;
    }
  }
  assertEquals(threw, 3);
});

Deno.test("stock_y_ventas: sin filtro rechaza; preventista no recibe ventas aunque la RPC las mande", async () => {
  const { client } = createMockSupabase({
    rpcResponse: {
      data: {
        ventas_visibles: false,
        productos_count: 1,
        productos: [{ id: 1, codigo: "1", nombre: "MANAOS", stock: 10, precio: 100, vendidas_30d: 999, regaladas_30d: 9, cobertura_dias: 3 }],
      },
      error: null,
    },
  });
  let threw = false;
  try {
    await stockYVentasTool.handler({}, makeCtx(client, { rol: "admin" }));
  } catch {
    threw = true;
  }
  assert(threw, "sin filtro debió rechazar");
  const r = await stockYVentasTool.handler({ proveedor: "Zingaras" }, makeCtx(client, { rol: "preventista" }));
  assertEquals(r.productos[0].vendidas_30d, null);
  assertEquals(r.productos[0].cobertura_dias, null);
  assertEquals(r.productos[0].stock, 10);
});

Deno.test("productos_sin_venta_con_stock: sólo admin y encargado", () => {
  assertEquals(canInvoke("preventista", productosSinVentaConStockTool), false);
  assertEquals(canInvoke("encargado", productosSinVentaConStockTool), true);
});

Deno.test("productos_recurrentes_cliente trae los dejados del cliente", async () => {
  const { client, spy } = createMockSupabase({
    rpcResponse: {
      data: {
        cliente_id: 5, rango_dias: 90, montos: "todos", productos: [],
        // La misma respuesta sirve para la segunda RPC (dejados).
        entregas: 12,
      },
      error: null,
    },
  });
  // deno-lint-ignore no-explicit-any
  (client as any).rpc = (fn: string, params: Record<string, unknown>) => {
    spy.rpcCalls.push({ fn, params });
    if (fn === "bot_productos_dejados_cliente") {
      return Promise.resolve({
        data: { productos: [{ producto_id: 9, nombre: "MANAOS LIMA 2.25", ultima_vez: "2026-08-01" }] },
        error: null,
      });
    }
    return Promise.resolve({ data: { cliente_id: 5, rango_dias: 90, montos: "todos", productos: [] }, error: null });
  };
  const r = await productosRecurrentesTool.handler({ cliente_id: 5 }, makeCtx(client, { rol: "admin" }));
  assertEquals(r.dejados, [{ producto_id: 9, nombre: "MANAOS LIMA 2.25", ultima_vez: "2026-08-01" }]);
  assert(spy.rpcCalls.some((c) => c.fn === "bot_productos_dejados_cliente"));
});

Deno.test("resumen_cliente_visita: el rebote del gate llega como error, sin datos", async () => {
  const { client } = createMockSupabase({
    rpcResponse: { data: { cliente_id: 5, error: "Cliente asignado a otro preventista" }, error: null },
  });
  const r = await resumenClienteVisitaTool.handler({ cliente_id: 5 }, makeCtx(client, { rol: "preventista" }));
  assertEquals(r.error, "Cliente asignado a otro preventista");
  assertEquals(r.cliente, null);
  assertEquals(r.top_productos, []);
});

Deno.test("stock_y_ventas: la guarda es por rol, aunque la RPC diga que las ventas son visibles", async () => {
  const { client } = createMockSupabase({
    rpcResponse: {
      data: {
        ventas_visibles: true, // como si el SQL se hubiera roto
        productos_count: 1,
        productos: [{ id: 1, codigo: "1", nombre: "MANAOS", stock: 10, precio: 100, vendidas_30d: 999, regaladas_30d: 9, cobertura_dias: 3 }],
      },
      error: null,
    },
  });
  for (const rol of ["preventista", "transportista", "deposito"] as const) {
    const r = await stockYVentasTool.handler({ texto: "manaos" }, makeCtx(client, { rol }));
    assertEquals(r.productos[0].vendidas_30d, null, `${rol} no debe ver ventas`);
    assertEquals(r.ventas_visibles, false);
  }
  const admin = await stockYVentasTool.handler({ texto: "manaos" }, makeCtx(client, { rol: "admin" }));
  assertEquals(admin.productos[0].vendidas_30d, 999);
});

Deno.test("ranking_clientes admin: busca entre quienes vendieron (cualquier rol) y prefiere el nombre exacto", async () => {
  const juan = "88888888-8888-8888-8888-888888888888";
  const { client, spy } = createMockSupabase({
    perTable: {
      pedidos: { selectResponse: { data: [{ usuario_id: juan }, { usuario_id: "x" }, { usuario_id: juan }], error: null } },
      perfiles: { selectResponse: { data: [{ id: juan, nombre: "Juan" }, { id: "x", nombre: "Juan Carlos" }], error: null } },
    },
    rpcResponse: { data: { orden: "mayores", clientes: [] }, error: null },
  });
  await rankingClientesTool.handler(
    { desde: "2026-09-08", hasta: "2026-10-07", preventista: "juan" },
    makeCtx(client, { rol: "admin", sucursal_id: 2 }),
  );
  assertEquals(spy.rpcCalls[0].params.p_preventista_id, juan);
  // Universo "vendedor": no filtra por rol ni por activo.
  const qPerf = spy.queries.find((q) => q.table === "perfiles");
  assert(!qPerf?.filters.some((f) => f.type === "eq" && f.args[0] === "rol"));
  assert(spy.queries.some((q) => q.table === "pedidos"));
});
