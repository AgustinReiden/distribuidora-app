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
import { sugerirVisitasRfmTool } from "../_shared/tools/preventista/sugerir_visitas_rfm.ts";
import { miRecorridoHoyTool } from "../_shared/tools/transportista/mi_recorrido_hoy.ts";
import type { Tool, ToolContext } from "../_shared/tools/base.ts";
import { _setServiceRoleClientForTests } from "../_shared/supabase.ts";

// ============================================================================
// Mock helpers
// ============================================================================

interface QueryFilter {
  type: "eq" | "or" | "ilike";
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
  assert(getTool("sugerir_visitas_rfm"), "sugerir_visitas_rfm no registrada");
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
  assertEquals(getTool("sugerir_visitas_rfm"), sugerirVisitasRfmTool);
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

Deno.test("ficha_cliente rechaza acceso de preventista a cliente no asignado", async () => {
  // Mock supabase: la query a clientes con !inner(cliente_preventistas)
  // devuelve null (porque el join falla — el cliente no tiene match con
  // este preventista_id). El filtro `cliente_preventistas.preventista_id`
  // se aplica con el perfil_id del PREVENTISTA QUE LLAMA, no el del owner real.
  const { client, spy } = createMockSupabase({
    perTable: {
      clientes: {
        maybeSingleResponse: { data: null, error: null },
      },
    },
  });

  const callerPerfilId = "66666666-6666-6666-6666-666666666666";
  const ctx = makeCtx(client, {
    rol: "preventista",
    sucursal_id: 1,
    perfil_id: callerPerfilId,
  });

  let threw = false;
  try {
    // cliente_id existe pero está asignado a OTRO preventista — el join falla.
    await fichaClienteTool.handler({ cliente_id: 999 }, ctx);
  } catch (err) {
    threw = true;
    assertStringIncludes(
      err instanceof Error ? err.message : String(err),
      "Cliente no encontrado o sin permiso",
    );
  }
  assert(threw, "debió lanzar 'Cliente no encontrado o sin permiso'");

  // Verificación crítica: la query construida debe filtrar por el perfil_id
  // del preventista que LLAMA (no es algo que un atacante pueda alterar).
  const clienteQuery = spy.queries.find((q) => q.table === "clientes");
  assert(clienteQuery, "no se hizo query a clientes");
  assertStringIncludes(clienteQuery!.selectCols ?? "", "cliente_preventistas!inner");

  const eqFilters = clienteQuery!.filters.filter((f) => f.type === "eq");
  const hasPreventistaFilter = eqFilters.some((f) =>
    f.args[0] === "cliente_preventistas.preventista_id" &&
    f.args[1] === callerPerfilId
  );
  assert(
    hasPreventistaFilter,
    "no se aplicó filter cliente_preventistas.preventista_id con el perfil_id del caller",
  );

  // Y NO debe haber llamado al RPC — el lookup falló antes.
  assertEquals(spy.rpcCalls.length, 0, "no debió invocarse el RPC tras un null en el lookup");
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
// 18. sugerir_visitas_rfm: defense-in-depth (rol distinto a preventista)
// ============================================================================

Deno.test("sugerir_visitas_rfm handler rechaza rol distinto a preventista", async () => {
  const { client } = createMockSupabase({});
  const ctx = makeCtx(client, {
    rol: "admin",
    perfil_id: "dddddddd-dddd-dddd-dddd-dddddddddddd",
    sucursal_id: 1,
  });

  let threw = false;
  try {
    await sugerirVisitasRfmTool.handler({}, ctx);
  } catch (err) {
    threw = true;
    assertStringIncludes(
      err instanceof Error ? err.message : String(err),
      "preventista",
    );
  }
  assert(threw, "sugerir_visitas_rfm debió rechazar rol admin");
});

// ============================================================================
// 19. sugerir_visitas_rfm: rechaza sucursal_id null
// ============================================================================

Deno.test("sugerir_visitas_rfm rechaza preventista sin sucursal asignada", async () => {
  const { client } = createMockSupabase({});
  const ctx = makeCtx(client, {
    rol: "preventista",
    sucursal_id: null,
    perfil_id: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
  });

  let threw = false;
  try {
    await sugerirVisitasRfmTool.handler({}, ctx);
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
// 20. sugerir_visitas_rfm: happy path con RPC mockeada
// ============================================================================

Deno.test("sugerir_visitas_rfm happy path retorna shape esperado y mapea campos", async () => {
  const { client, spy } = createMockSupabase({
    rpcResponse: {
      data: {
        total: 3,
        sugerencias: [
          {
            cliente_id: 10,
            codigo: 100,
            nombre: "Almacén Norte",
            zona: "Norte",
            saldo_cuenta: "12500.50",
            ultima_compra: "2026-04-01",
            dias_desde_ultima: 25,
            frecuencia_dias: "21.0",
            ticket_promedio: "8500.00",
            n_pedidos: 4,
            score: "0.875",
            vencido: true,
            motivo: "Atrasado: 25 días sin comprar (compra cada ~21)",
          },
          {
            cliente_id: 11,
            codigo: null,
            nombre: "Sur SA",
            zona: null,
            saldo_cuenta: 0,
            ultima_compra: null,
            dias_desde_ultima: 9999,
            frecuencia_dias: 21,
            ticket_promedio: 0,
            n_pedidos: 0,
            score: 0.5,
            vencido: false,
            motivo: "Cliente activo",
          },
          {
            cliente_id: 12,
            codigo: 200,
            nombre: "Boliche Don Tito",
            zona: "Centro",
            saldo_cuenta: 3500,
            ultima_compra: "2026-04-15",
            dias_desde_ultima: 11,
            frecuencia_dias: 7,
            ticket_promedio: 12000,
            n_pedidos: 8,
            score: 0.62,
            vencido: true,
            motivo: "Próximo a re-pedido (cada ~7 días, lleva 11)",
          },
        ],
      },
      error: null,
    },
  });

  const ctx = makeCtx(client, {
    rol: "preventista",
    perfil_id: "ffffffff-ffff-ffff-ffff-ffffffffffff",
    sucursal_id: 2,
  });

  const result = await sugerirVisitasRfmTool.handler({ limit: 10 }, ctx);

  assertEquals(result.total, 3);
  assertEquals(result.sugerencias.length, 3);

  // Primer cliente: campos numéricos casteados desde strings.
  assertEquals(result.sugerencias[0].cliente_id, 10);
  assertEquals(result.sugerencias[0].codigo, 100);
  assertEquals(result.sugerencias[0].nombre, "Almacén Norte");
  assertEquals(result.sugerencias[0].zona, "Norte");
  assertEquals(result.sugerencias[0].saldo_cuenta, 12500.5);
  assertEquals(result.sugerencias[0].ultima_compra, "2026-04-01");
  assertEquals(result.sugerencias[0].dias_desde_ultima, 25);
  assertEquals(result.sugerencias[0].frecuencia_dias, 21);
  assertEquals(result.sugerencias[0].ticket_promedio, 8500);
  assertEquals(result.sugerencias[0].n_pedidos, 4);
  assertEquals(result.sugerencias[0].score, 0.875);
  assertEquals(result.sugerencias[0].vencido, true);
  assertEquals(
    result.sugerencias[0].motivo,
    "Atrasado: 25 días sin comprar (compra cada ~21)",
  );

  // Segundo cliente: campos null, codigo null y dias_desde_ultima sentinel 9999.
  assertEquals(result.sugerencias[1].codigo, null);
  assertEquals(result.sugerencias[1].zona, null);
  assertEquals(result.sugerencias[1].ultima_compra, null);
  assertEquals(result.sugerencias[1].dias_desde_ultima, 9999);
  assertEquals(result.sugerencias[1].n_pedidos, 0);
  assertEquals(result.sugerencias[1].vencido, false);

  // Tercer cliente: vencido true por la regla freq*1.3, sin saldo en motivo.
  assertEquals(result.sugerencias[2].cliente_id, 12);
  assertEquals(result.sugerencias[2].vencido, true);

  // RPC: nombre y params correctos.
  assertEquals(spy.rpcCalls.length, 1);
  const call = spy.rpcCalls[0];
  assertEquals(call.fn, "bot_sugerir_visitas_rfm");
  assertEquals(call.params.p_preventista_id, "ffffffff-ffff-ffff-ffff-ffffffffffff");
  assertEquals(call.params.p_sucursal_id, 2);
  assertEquals(call.params.p_limit, 10);
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
        total_global: "9604385",
        clientes_count: 81,
        clientes: [
          {
            cliente_id: 415, cliente_codigo: 399,
            nombre_fantasia: "RAMON ABREGU", razon_social: "RAMON ABREGU",
            pedidos_pendientes: 3, total_adeudado: "87800",
            pedido_mas_viejo: "2026-03-21", dias_max_atraso: 38,
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
  assertEquals(result.clientes[0].dias_max_atraso, 38);

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
// 52. ranking_preventistas_por_producto: invoca RPC y mapea ranking
// ============================================================================

Deno.test("ranking_preventistas_por_producto invoca el RPC y mapea preventistas", async () => {
  const { client, spy } = createMockSupabase({
    rpcResponse: {
      data: {
        producto_id: 178,
        producto_codigo: "M00002",
        producto_nombre: "MANAOS COLA 3000CC X 6",
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
            pedidos_con_producto: 18,
          },
          {
            usuario_id: "bbb",
            nombre: "Joaquin",
            rol: "preventista",
            unidades: 80,
            facturado: 400000,
            pedidos_con_producto: 10,
          },
          {
            usuario_id: null,
            nombre: null,
            rol: null,
            unidades: 40,
            facturado: 200000,
            pedidos_con_producto: 5,
          },
        ],
      },
      error: null,
    },
  });
  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 1 });
  const result = await rankingPreventistasPorProductoTool.handler(
    {
      producto_id: 178,
      desde: "2026-04-01",
      hasta: "2026-04-30",
      limit: 10,
    },
    ctx,
  );

  assertEquals(result.producto_id, 178);
  assertEquals(result.producto_codigo, "M00002");
  assertEquals(result.producto_nombre, "MANAOS COLA 3000CC X 6");
  assertEquals(result.unidades_total, 240);
  assertEquals(result.facturado_total, 1200000);
  assertEquals(result.preventistas_count, 3);
  assertEquals(result.preventistas.length, 3);
  assertEquals(result.preventistas[0].nombre, "Christian");
  assertEquals(result.preventistas[0].unidades, 120);
  assertEquals(result.preventistas[1].facturado, 400000);
  assertEquals(result.preventistas[2].nombre, "(sin asignar)");

  assertEquals(spy.rpcCalls.length, 1);
  const call = spy.rpcCalls[0];
  assertEquals(call.fn, "bot_ranking_preventistas_por_producto");
  assertEquals(call.params.p_producto_id, 178);
  assertEquals(call.params.p_desde, "2026-04-01");
  assertEquals(call.params.p_hasta, "2026-04-30");
  assertEquals(call.params.p_sucursal_id, 1);
  assertEquals(call.params.p_limit, 10);
});

Deno.test("ranking_preventistas_por_producto rechaza producto_id <= 0", async () => {
  const { client } = createMockSupabase({});
  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 1 });
  let threw = false;
  try {
    await rankingPreventistasPorProductoTool.handler(
      { producto_id: 0, desde: "2026-04-01", hasta: "2026-04-30" },
      ctx,
    );
  } catch (err) {
    threw = true;
    assertStringIncludes(
      err instanceof Error ? err.message : "",
      "producto_id",
    );
  }
  assert(threw, "debió rechazar producto_id=0");
});

Deno.test("ranking_preventistas_por_producto valida fechas y rango", async () => {
  const { client } = createMockSupabase({});
  const ctx = makeCtx(client, { rol: "admin", sucursal_id: 1 });
  let threw = 0;
  try {
    await rankingPreventistasPorProductoTool.handler(
      { producto_id: 1, desde: "ayer", hasta: "2026-04-30" },
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
      { producto_id: 1, desde: "2026-04-30", hasta: "2026-04-01" },
      ctx,
    );
  } catch (err) {
    threw++;
    assertStringIncludes(err instanceof Error ? err.message : "", "desde");
  }
  assertEquals(threw, 2);
});
