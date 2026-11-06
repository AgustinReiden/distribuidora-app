// Escenarios C1 a C12 del plan #1378 (tarjeta 1, issue #1288). El C9 es de #1342 (#1412) y el C12 de #1398.
//
// Cada escenario es una lista de VARIANTES. Una variante es un guion para
// `harness.mjs`: un `setup` por ronda (crea el caso en `conc.*`), los
// `workers` (cada uno una transacción, en su propia conexión, que arranca a la
// vez que los demás), y un `verify` por ronda que mira la base: el veredicto sale
// de invariantes medidos ahí, no de "no tiró error".
//
// Los SQL llevan {{ruta}} que el arnés reemplaza con lo que devolvió el setup
// (`{{c.pedido}}`), el usuario de la caja (`{{uid}}`) o la ronda (`{{round}}`).
//
// Un resultado "serial" (referencias): para lo que no tiene un número único, la
// variante corre antes los mismos trabajadores UNO DESPUÉS DEL OTRO, en cada orden
// posible, y guarda el estado final normalizado (`ESTADO=...`). La ronda
// concurrente pasa si su estado final es el de alguno de esos órdenes seriales
// (o el de uno solo de los dos, si el otro fue la víctima de un 40P01).
const HOY = "(now() at time zone 'America/Argentina/Buenos_Aires')::date";

// ----- piezas ------------------------------------------------------------
const w = (label, as, suc, steps, extra = {}) => ({ label, as, suc, steps, ...extra });
const ADMIN = "{{c.admin}}";
const SUC = "{{c.suc}}";

const cobroSql = (monto, ped = "{{c.pedido}}") =>
  `select public.registrar_pagos_pedido(${ped}::bigint, '[{"monto":${monto},"forma_pago":"efectivo"}]'::jsonb, ${HOY}, 'conc', null, null) as r`;
const fifoSql = (monto) =>
  `select public.registrar_pago_cliente_fifo({{c.cli}}::bigint, ${monto}, 'efectivo', ${HOY}, null, 'conc', null) as r`;
const dormir = (s) => `select pg_sleep(${s}) as dormido`;

// Una venta de `cant` unidades de cada producto de `prods` (claves del setup), al cliente `cli`.
const ventaSql = (cli, uid, prods, cant) => {
  const items = prods.map((p) => `jsonb_build_object('producto_id', {{c.${p}}}, 'cantidad', ${cant}, 'precio_unitario', 100)`).join(", ");
  return `select public.crear_pedido_completo({{c.${cli}}}::bigint, ${cant * 100 * prods.length}, '${uid}'::uuid, jsonb_build_array(${items}), 'conc') as r`;
};
const editarSql = (ped, prods, cant, uid = "{{c.admin}}") => {
  const items = prods.map((p) => `jsonb_build_object('producto_id', {{c.${p}}}, 'cantidad', ${cant}, 'precio_unitario', 100)`).join(", ");
  return `select public.actualizar_pedido_items(${ped}::bigint, jsonb_build_array(${items}), '${uid}'::uuid, null, null) as r`;
};
const cancelarSql = (ped) => `select public.cancelar_pedido_con_stock(${ped}::bigint, 'conc', '{{c.admin}}'::uuid, null) as r`;

// verify de un cobro: monto_pagado = suma de los pagos = lo esperado.
const verifyCobro = (esperado, ped = "{{c.pedido}}") =>
  `select (pd.monto_pagado = s.suma and s.suma = ${esperado}) as ok,
          format('monto_pagado=%s suma_pagos=%s estado_pago=%s esperado=%s', pd.monto_pagado, s.suma, pd.estado_pago, ${esperado}) as msg
     from public.pedidos pd, lateral (select coalesce(sum(monto), 0) as suma from public.pagos where pedido_id = pd.id) s
    where pd.id = ${ped}::bigint`;

// verify de varias boletas: ninguna pagada de más, monto_pagado = sus pagos, y el total cobrado.
const verifyBoletas = (totales) =>
  `select (b.malas = 0 and b.cobrado in (${totales.join(",")})) as ok,
          format('boletas mal=%s cobrado=%s (esperado uno de ${totales.join("/")}) a_favor=%s', b.malas, b.cobrado, f.favor) as msg
     from (select count(*) filter (where p.monto_pagado > p.total
                                     or p.monto_pagado <> coalesce((select sum(monto) from public.pagos where pedido_id = p.id), 0)) as malas,
                  sum(p.monto_pagado) as cobrado
             from public.pedidos p where p.id in ({{c.p1}}, {{c.p2}}, {{c.p3}})) b(malas, cobrado),
          (select coalesce(sum(monto), 0) as favor from public.pagos where cliente_id = {{c.cli}} and pedido_id is null) f`;

// verify de ventas: el stock cierra contra lo vendido vivo, y cuántas ventas entraron.
const verifyStock = (prods, stock0, ventasEsperadas) =>
  prods.map((p) =>
    `select (conc.stock_cierra({{c.${p}}}, ${stock0}) is null) as ok,
            coalesce(conc.stock_cierra({{c.${p}}}, ${stock0}), 'stock ok') || ' [' || conc.estado_prod({{c.${p}}}) || ']' as msg`
  ).concat(ventasEsperadas == null ? [] : [
    `select (count(*) = ${ventasEsperadas}) as ok, 'ventas vivas del producto A=' || count(*) || ' esperadas=${ventasEsperadas}' as msg
       from public.pedido_items pi join public.pedidos pe on pe.id = pi.pedido_id
      where pi.producto_id = {{c.pa}} and coalesce(pe.estado, '') not in ('cancelado', 'anulado')`,
  ]);

// Estado normalizado de los productos de un caso y del pedido X (para comparar contra los seriales).
const estadoSql = (prods, conPedido) =>
  `select ${prods.map((p) => `conc.estado_prod({{c.${p}}})`).join(" || ';' || ")}` +
  (conPedido ? ` || ';X=' || (select coalesce(estado, '?') || '/' || total from public.pedidos where id = {{c.x}}::bigint)` : "") +
  ` as s`;
const verifyRefs = (prods, conPedido) =>
  `select position('|ESTADO=' || q.s || '|' in '|{{refs}}|') > 0 as ok, 'estado=' || q.s as msg from (${estadoSql(prods, conPedido)}) q`;
const verifyRef = (prods, conPedido) =>
  `select true as ok, 'ESTADO=' || q.s as msg from (${estadoSql(prods, conPedido)}) q`;

// Referencias seriales de una variante: cada trabajador solo, y todos los órdenes de a dos.
// `baseRef` (opcional) fija el tramo de días de las referencias de C6: cada una usa baseRef + 10·k.
function referencias(base, workers, verifyFn, baseRef = null) {
  const sep = 900;
  const spec = (ws) => ({ ...base, workers: ws, verify: [verifyFn], sample_ms: 0, jitter: 0, ...(baseRef == null ? {} : { ctx: { base: baseRef + 10 * refs.length } }) });
  const refs = [];
  const orden = (idx) => idx.map((i, k) => ({ ...workers[i], delay_ms: k * sep, jitter_ms: 0 }));
  for (let i = 0; i < workers.length; i++) refs.push(spec(orden([i])));
  if (workers.length === 2) {
    refs.push(spec(orden([0, 1])));
    refs.push(spec(orden([1, 0])));
  }
  return refs;
}

const esDeNegocio = (...codigos) => (err) => codigos.includes(err.code);

// ----- C1 ----------------------------------------------------------------
function c1() {
  const base = { modo: "rondas", setup: ["select conc.c1_setup(80) as c"], sample_ms: 4 };
  const c = (nombre, rondas, spec, extra = {}) => ({ nombre, rondas, spec: { ...base, ...spec }, ...extra });
  const a = w("cobro50", ADMIN, SUC, [cobroSql(50)], { jitter_ms: 3 });
  const b = w("cobro30", ADMIN, SUC, [cobroSql(30)], { jitter_ms: 3 });
  const insDirecto = (m) =>
    `insert into public.pagos (cliente_id, pedido_id, monto, forma_pago, sucursal_id, notas, fecha) values ({{c.cli}}, {{c.pedido}}, ${m}, 'efectivo', {{c.suc}}, 'conc', ${HOY}) returning id as pid`;
  return [
    c("C1a · 50 + 30 por RPC, a la vez (arranque simultáneo, jitter 0–3 ms)", 200, { workers: [a, b], verify: [verifyCobro(80)] }),
    c("C1b · 50 + 30 por RPC; A retiene 300 ms con el lock y B entra a los 60 ms", 40, {
      workers: [w("cobro50", ADMIN, SUC, [cobroSql(50), dormir(0.3)]), w("cobro30", ADMIN, SUC, [cobroSql(30)], { delay_ms: 60 })],
      verify: [verifyCobro(80)],
    }),
    c("C1c · 50 + 30 con INSERT directo en pagos (sólo el trigger); A retiene 300 ms", 40, {
      workers: [w("ins50", null, null, [insDirecto(50), dormir(0.3)]), w("ins30", null, null, [insDirecto(30)], { delay_ms: 60 })],
      verify: [verifyCobro(80)],
    }),
    c("C1d · dos cobros de 80 a una boleta de 80 (sobrepago): entra uno solo", 200, {
      workers: [w("cobro80a", ADMIN, SUC, [cobroSql(80)], { jitter_ms: 3 }), w("cobro80b", ADMIN, SUC, [cobroSql(80)], { jitter_ms: 3 })],
      verify: [verifyCobro(80)],
    }, { esperado: esDeNegocio("22023") }),
  ];
}

// ----- C2 ----------------------------------------------------------------
function c2() {
  const base = { modo: "rondas", setup: ["select conc.c2_setup() as c"], sample_ms: 4 };
  const c = (nombre, rondas, spec, extra = {}) => ({ nombre, rondas, spec: { ...base, ...spec }, ...extra });
  const f = (l, extra) => w(l, ADMIN, SUC, [fifoSql(250)], extra);
  return [
    c("C2a · FIFO 250 contra FIFO 250 del mismo cliente (boletas 100/200/300), a la vez", 200, {
      workers: [f("fifoA", { jitter_ms: 3 }), f("fifoB", { jitter_ms: 3 })], verify: [verifyBoletas([500])],
    }),
    c("C2b · FIFO contra FIFO; A retiene 300 ms y B entra a los 60 ms", 40, {
      workers: [w("fifoA", ADMIN, SUC, [fifoSql(250), dormir(0.3)]), w("fifoB", ADMIN, SUC, [fifoSql(250)], { delay_ms: 60 })],
      verify: [verifyBoletas([500])],
    }),
    c("C2c · FIFO 250 contra el cobro de 100 de la boleta más vieja (registrar_pagos_pedido)", 200, {
      workers: [f("fifo", { jitter_ms: 3 }), w("cobroP1", ADMIN, SUC, [cobroSql(100, "{{c.p1}}")], { jitter_ms: 3 })],
      verify: [verifyBoletas([250, 350])],
    }, { esperado: esDeNegocio("22023") }),
  ];
}

// ----- C3 ----------------------------------------------------------------
function c3() {
  const dos = (extra = {}) => ({ modo: "rondas", sample_ms: 4, ...extra });
  const lotes = JSON.stringify([{ dias: 10, cantidad: 2 }, { dias: 20, cantidad: 2 }]);
  const c = (nombre, rondas, spec, extra = {}) => ({ nombre, rondas, spec, ...extra });
  const v = (l, cli, uid, prods, cant, extra) => w(l, uid, SUC, [ventaSql(cli, uid, prods, cant)], extra);
  return [
    c("C3a · dos ventas de 3 sobre un producto con stock 5 (entra una sola)", 300, dos({
      setup: ["select conc.c3_setup(1, 5) as c"],
      workers: [v("venta1", "cli1", "{{c.p1}}", ["pa"], 3, { jitter_ms: 3 }), v("venta2", "cli2", "{{c.p2}}", ["pa"], 3, { jitter_ms: 3 })],
      verify: verifyStock(["pa"], 5, 1),
    })),
    c("C3b · [A,B] contra [B,A], 3 de cada con stock 5 de cada uno, mismo cliente (orden inverso)", 300, dos({
      setup: ["select conc.c3_setup(2, 5, '[]', true) as c"],
      workers: [v("venta[A,B]", "cli1", "{{c.p1}}", ["pa", "pb"], 3, { jitter_ms: 3 }), v("venta[B,A]", "cli2", "{{c.p2}}", ["pb", "pa"], 3, { jitter_ms: 3 })],
      verify: verifyStock(["pa", "pb"], 5, 1),
    })),
    c("C3c · el producto con lotes (bolsa 1 + lotes 2 y 2): dos ventas de 3", 200, dos({
      setup: [`select conc.c3_setup(1, 1, '${lotes}'::jsonb) as c`],
      workers: [v("venta1", "cli1", "{{c.p1}}", ["pa"], 3, { jitter_ms: 3 }), v("venta2", "cli2", "{{c.p2}}", ["pa"], 3, { jitter_ms: 3 })],
      verify: verifyStock(["pa"], 5, 1),
    })),
    c("C3d · 8 cajas venden 1 unidad del mismo producto con stock 4 (entran cuatro)", 100, dos({
      setup: ["select conc.c3_setup(1, 4) as c, (select jsonb_agg(conc.f('prev_a' || g)) from generate_series(1, 8) g) as users"],
      workers: Array.from({ length: 8 }, (_, i) =>
        w(`caja${i + 1}`, "{{uid}}", SUC, [`select public.crear_pedido_completo({{c.cli1}}::bigint, 100, '{{uid}}'::uuid, jsonb_build_array(jsonb_build_object('producto_id', {{c.pa}}, 'cantidad', 1, 'precio_unitario', 100)), 'conc') as r`], { jitter_ms: 3 })),
      verify: verifyStock(["pa"], 4, 4),
    })),
  ];
}

// ----- C4 ----------------------------------------------------------------
function c4() {
  const lotes = JSON.stringify([{ dias: 10, cantidad: 4 }, { dias: 20, cantidad: 4 }]);
  const mk = (nombre, rondas, setup, workers, prods, conPedido = true) => {
    const base = { modo: "rondas", setup: [setup], sample_ms: 4 };
    return {
      nombre, rondas,
      spec: { ...base, workers },
      referencias: referencias(base, workers, verifyRef(prods, conPedido)),
      verify: [verifyRefs(prods, conPedido)],
      esperado: esDeNegocio(),
    };
  };
  // bolsa 2 + lotes 4 y 4 = stock 10; X toma 4 (queda 6).
  const set1 = `select conc.c4_setup(2, '${lotes}'::jsonb, 4) as c`;
  const set2 = `select conc.c4_setup(2, '${lotes}'::jsonb, 4, true) as c`;
  const venta3 = (l = "venta") => w(l, "{{c.p2}}", SUC, [ventaSql("cli1", "{{c.p2}}", ["pa"], 3)], { jitter_ms: 3 });
  const ventaAB = w("venta[B,A]", "{{c.p2}}", SUC, [ventaSql("cli1", "{{c.p2}}", ["pb", "pa"], 3)], { jitter_ms: 3 });
  const cancelar = w("cancelar", ADMIN, SUC, [cancelarSql("{{c.x}}")], { jitter_ms: 3 });
  const editar2 = w("editar4→2", ADMIN, SUC, [editarSql("{{c.x}}", ["pa"], 2)], { jitter_ms: 3 });
  const editarMas = w("editar4→6", ADMIN, SUC, [editarSql("{{c.x}}", ["pa"], 6)], { jitter_ms: 3 });
  const v = mk("C4a · cancelar el pedido X (4 u.) contra una venta de 3 del mismo producto y cliente", 200, set1, [cancelar, venta3()], ["pa"]);
  const b = mk("C4b · editar X a la baja (4→2) contra una venta de 3", 200, set1, [editar2, venta3()], ["pa"]);
  const b2 = mk("C4b' · editar X al alza (4→6) contra una venta de 3 (stock 10: alcanza para las dos)", 200, set1, [editarMas, venta3()], ["pa"]);
  const c = mk("C4c · cancelar X contra editar X (el mismo pedido)", 200, set1, [cancelar, editar2], ["pa"]);
  const d = mk("C4d · cancelar X=[A,B] contra una venta [B,A] al mismo cliente (orden inverso)", 200, set2, [cancelar, ventaAB], ["pa", "pb"]);
  return [v, b, b2, c, d];
}

// ----- C5 ----------------------------------------------------------------
function c5() {
  const lotes = JSON.stringify([{ dias: 10, cantidad: 4 }, { dias: 20, cantidad: 4 }]);
  const control = (l = "control") =>
    w(l, ADMIN, SUC, [`select public.aplicar_control_stock('{{c.ajustes}}'::jsonb, 'conc', '{{c.planilla}}'::uuid) as r`], { jitter_ms: 3 });
  const venta = (prods, cant, l = "venta") => w(l, "{{c.p1}}", SUC, [ventaSql("cli1", "{{c.p1}}", prods, cant)], { jitter_ms: 3 });
  // La diferencia (real - planilla) se suma al stock de ESE momento: stock final = stock0 + dif - vendido.
  const verifySuma = (prods, stock0) =>
    prods.map((p) =>
      `select (conc.stock_cierra({{c.${p}}}, ${stock0}, {{c.diferencia}}::int) is null) as ok,
              coalesce(conc.stock_cierra({{c.${p}}}, ${stock0}, {{c.diferencia}}::int), 'stock ok') || ' [' || conc.estado_prod({{c.${p}}}) || ']' as msg`);
  const sumaC = (nombre, rondas, setup, workers, prods, stock0) => ({
    nombre, rondas,
    spec: { modo: "rondas", setup: [setup], workers, verify: verifySuma(prods, stock0), sample_ms: 4 },
  });
  const refC = (nombre, rondas, setup, workers, prods) => {
    const base = { modo: "rondas", setup: [setup], sample_ms: 4 };
    return { nombre, rondas, spec: { ...base, workers }, referencias: referencias(base, workers, verifyRef(prods, false)), verify: [verifyRefs(prods, false)] };
  };
  return [
    sumaC("C5a · control (stock 20, contó 15: −5) contra una venta de 4: stock final = 20 − 5 − 4", 300,
      "select conc.c5_setup(1, 20, 15) as c", [control(), venta(["pa"], 4)], ["pa"], 20),
    sumaC("C5b · control de [A,B] contra una venta [B,A], con lotes (bolsa 2 + 4 + 4; contó 6: −4)", 300,
      `select conc.c5_setup(2, 2, 6, '${lotes}'::jsonb) as c`, [control(), venta(["pb", "pa"], 3)], ["pa", "pb"], 10),
    refC("C5c · borde: control que dejaría negativo (stock 5, contó 0) contra una venta de 3", 200,
      "select conc.c5_setup(1, 5, 0) as c", [control(), venta(["pa"], 3)], ["pa"]),
  ];
}

// ----- C6 ----------------------------------------------------------------
function c6() {
  const SB = "{{c.suc}}";
  const cortar = w("recortar boleta 100→70", "{{c.admin}}", SB,
    [`select public.actualizar_pedido_items({{c.pedido}}::bigint, jsonb_build_array(jsonb_build_object('producto_id', {{c.relleno}}, 'cantidad', 70, 'precio_unitario', 1)), '{{c.admin}}'::uuid, null, null) as r`],
    { jitter_ms: 6 });
  const confirmar = w("confirmar rendición", "{{c.admin}}", SB,
    [`select public.confirmar_rendicion('{{c.fecha}}'::date,'{{c.tr}}'::uuid, 'confirmada', '{}'::jsonb, 'conc') as r`], { jitter_ms: 6 });
  const verFn = `select true as ok, 'ESTADO=' || conc.estado_pagos({{c.cli}}::bigint) || ';' || (select monto_pagado || '/' || total from public.pedidos where id = {{c.pedido}}::bigint) as msg`;
  const verMain = `select position('|ESTADO=' || q.s || '|' in '|{{refs}}|') > 0 as ok, 'estado=' || q.s as msg
                     from (select conc.estado_pagos({{c.cli}}::bigint) || ';' || (select monto_pagado || '/' || total from public.pedidos where id = {{c.pedido}}::bigint) as s) q`;
  const verFoto = `select (count(*) = count(distinct pago_id)) as ok, 'pagos en la foto=' || count(*) as msg
                     from public.rendicion_pagos_confirmados r join public.pagos pg on pg.id = r.pago_id where pg.cliente_id = {{c.cli}}::bigint`;
  // Cada ronda usa un día propio (creciente): una rendición confirmada bloquea los cobros de su
  // sucursal con fecha <= la suya. {{off}} es el inicio de la tanda y {{base}} separa las
  // referencias seriales (0, 10, 20, 30) de la corrida concurrente (60).
  const base = { modo: "rondas", setup: ["select conc.c6_setup({{round}} + {{off}} + {{base}}) as c"], sample_ms: 3 };
  const workers = [cortar, confirmar];
  // Confirmar primero y recortar después es un orden serial legítimo: el recorte lo frena `guard_pago_fecha_cerrada`
  // (42501, "la caja de la sucursal está cerrada hasta el …"), igual que con una rendición confirmada de antes.
  const esperado = (err) => err.code === "42501" && /caja de la sucursal esta cerrada/.test(err.message);

  // C6b: forzar el cruce que C6 casi no puede alcanzar. `_rendicion_tomar_foto` toma los pagos del día FOR SHARE
  // en orden de id (P1, P2); el recorte (`desafectar_sobrepago_pedido`) los toma FOR UPDATE de fecha DESC, id DESC
  // (P2, P1). Cada uno los toma dentro de un solo statement, así que sin ayuda la ventana es de microsegundos. Un
  // tercer trabajador retiene P1 250 ms: primero entra la confirmación y queda en cola por P1; después entra el
  // recorte, toma P2 y queda detrás de ella; al soltar P1 la foto pide P2 y los dos se esperan.
  const retieneP1 = w("retiene P1", null, null,
    ["select id as retenido from public.pagos where id = {{c.p1}}::bigint for update", dormir(0.25)]);
  const verBoletas = (clis) =>
    `select (count(*) filter (where pe.monto_pagado > pe.total
                               or pe.monto_pagado <> coalesce((select sum(monto) from public.pagos where pedido_id = pe.id), 0)) = 0) as ok,
            'boletas con monto_pagado mal=' || count(*) filter (where pe.monto_pagado > pe.total
                               or pe.monto_pagado <> coalesce((select sum(monto) from public.pagos where pedido_id = pe.id), 0)) as msg
       from public.pedidos pe where pe.cliente_id in (${clis}) and coalesce(pe.estado, '') not in ('cancelado', 'anulado')`;
  const cortarB = { ...cortar, delay_ms: 90, jitter_ms: 4 };
  const confirmarB = { ...confirmar, delay_ms: 30, jitter_ms: 4 };

  // C6c: lo mismo con `_pagos_excedente_a_favor` (FOR UPDATE de fecha DESC, id DESC), que sólo corre desde
  // `cambiar_cliente_pedido` (admin) cuando el pedido nuevo vale menos que lo cobrado: 100 → 70 pasa 30 a saldo a favor.
  const cambiar = w("cambiar cliente 100→70", "{{c.admin}}", SB,
    [`select public.cambiar_cliente_pedido({{c.pedido}}::bigint, {{c.cli2}}::bigint, '{{c.admin}}'::uuid, jsonb_build_array(jsonb_build_object('producto_id', {{c.relleno}}, 'cantidad', 70, 'precio_unitario', 1)), 70) as r`],
    { delay_ms: 90, jitter_ms: 4 });
  const estadoC = `conc.estado_pagos({{c.cli}}::bigint) || ' # ' || conc.estado_pagos({{c.cli2}}::bigint) || ' # ' ||
                   (select coalesce(string_agg(pe.estado || '/' || pe.monto_pagado || '/' || pe.total, ',' order by pe.estado, pe.total), '')
                      from public.pedidos pe where pe.cliente_id in ({{c.cli}}, {{c.cli2}}))`;
  const verFnC = `select true as ok, 'ESTADO=' || ${estadoC} as msg`;
  const verMainC = `select position('|ESTADO=' || q.s || '|' in '|{{refs}}|') > 0 as ok, 'estado=' || q.s as msg from (select ${estadoC} as s) q`;
  const verFotoC = `select (count(*) = count(distinct pago_id)) as ok, 'pagos en la foto=' || count(*) as msg
                      from public.rendicion_pagos_confirmados r join public.pagos pg on pg.id = r.pago_id where pg.cliente_id in ({{c.cli}}, {{c.cli2}})`;
  const workersC = [cambiar, confirmar];
  const baseTocado = { ...base, setup: ["select conc.c6_setup({{round}} + {{off}} + {{base}}, true) as c"] };

  // C6e (#1359/#1369): el recorte parte un pedazo (Y, de un crédito R) contra la confirmación. En los dos órdenes
  // seriales el cliente rinde 140: R 40 del admin, Y en la foto del chofer, y Z (30, hijo de Y) vivo del admin si el
  // recorte fue antes o adentro de la foto de Y si fue después. Medido contra la raíz R, que no está en ninguna foto,
  // Z se contaba dos veces (170). Los días los elige conc.c6e_setup, así que el ctx no lleva base.
  const baseE = { modo: "rondas", setup: ["select conc.c6e_setup({{round}}) as c"], sample_ms: 3 };
  const rendido = `select coalesce(sum(v.monto), 0) as s from public._rendicion_pagos({{c.suc}}::bigint, '{{c.fecha}}'::date, '{{c.fecha}}'::date + 30, null) v
                    where v.cliente_id = {{c.cli}}::bigint`;
  const verSumaE = `select (q.s = 140) as ok, 'rendido=' || q.s as msg from (${rendido}) q`;
  const verFnE = `select true as ok, 'ESTADO=' || conc.estado_pagos({{c.cli}}::bigint) || ';rendido=' || (${rendido}) as msg`;
  const verMainE = `select position('|ESTADO=' || q.s || '|' in '|{{refs}}|') > 0 as ok, 'estado=' || q.s as msg
                      from (select conc.estado_pagos({{c.cli}}::bigint) || ';rendido=' || (${rendido}) as s) q`;
  const workersE = [cortar, confirmar];

  // Tramos de días (de 900 hacia atrás de hoy): cada variante y sus referencias van en un tramo propio.
  return [
    {
      nombre: "C6 · recortar una boleta cobrada en dos pagos del mismo día contra confirmar la rendición de ese día",
      rondas: 200,
      spec: { ...base, workers, ctx: { base: 60 } },
      referencias: referencias(base, workers, verFn),
      verify: [verMain, verFoto],
      esperado,
    },
    {
      nombre: "C6b · lo mismo con P1 retenido 250 ms para forzar el cruce (foto: id ASC FOR SHARE; recorte: fecha/id DESC FOR UPDATE)",
      rondas: 100,
      spec: { ...base, workers: [retieneP1, confirmarB, cortarB], ctx: { base: 360 } },
      referencias: referencias(base, workers, verFn, 300),
      verify: [verMain, verFoto, verBoletas("{{c.cli}}")],
      esperado,
    },
    {
      nombre: "C6c · cambiar el cliente de la boleta (100→70, `_pagos_excedente_a_favor`) contra confirmar la rendición, con P1 retenido 250 ms",
      rondas: 100,
      spec: { ...base, workers: [retieneP1, confirmarB, cambiar], ctx: { base: 560 } },
      referencias: referencias(base, workersC, verFnC, 500),
      verify: [verMainC, verFotoC, verBoletas("{{c.cli}}, {{c.cli2}}")],
      esperado,
    },
    {
      // Igual que C6c, pero P1 se actualizó antes: su versión vigente queda físicamente después de P2 y el
      // `UPDATE pagos ... WHERE pedido_id` de cambiar_cliente_pedido (que recorre en orden físico) toma P2 y después P1.
      nombre: "C6d · igual que C6c, con P1 ya editado (su versión vigente queda físicamente después de P2)",
      rondas: 100,
      spec: { ...baseTocado, workers: [retieneP1, confirmarB, cambiar], ctx: { base: 760 } },
      referencias: referencias(baseTocado, workersC, verFnC, 700),
      verify: [verMainC, verFotoC, verBoletas("{{c.cli}}, {{c.cli2}}")],
      esperado,
    },
    {
      nombre: "C6e · recortar una boleta pagada con un pedazo de crédito (el pedazo se parte otra vez) contra confirmar la rendición",
      rondas: 100,
      spec: { ...baseE, workers: workersE },
      referencias: referencias(baseE, workersE, verFnE),
      verify: [verMainE, verSumaE, verBoletas("{{c.cli}}")],
      esperado,
    },
    // ---- Repetición final (#1378, paso 3): `cancelar_pedido_con_stock` contra la foto (C6g y C6h) ----
    // (Se llamaron C6e y C6f en la primera corrida; #1418 ya usa C6e para otra variante.)
    // Su `UPDATE pagos SET pedido_id = NULL WHERE pedido_id = …` (la 439 no lo ordena) recorre `idx_pagos_pedido_id`, y para
    // la misma clave el índice sigue la posición física de cada entrada. La foto toma los pagos del día por id ASC (FOR
    // SHARE). Con P1 ya editado: si la versión nueva entra en la misma página (HOT), la entrada del índice sigue en el
    // TID raíz de P1, menor que el de P2, y el orden coincide con el de la foto; si cae en otra página, la entrada nueva
    // queda detrás de la de P2 y los dos órdenes se cruzan (3 de cada 60 preparaciones). Va en CONC-C ('c'): la ventana de
    // días de CONC-B ya la gastaron C6 a C6d (una rendición confirmada no se reabre).
    ...(() => {
      const cancelar = w("cancelar la boleta cobrada", "{{c.admin}}", SB,
        [`select public.cancelar_pedido_con_stock({{c.pedido}}::bigint, 'conc', '{{c.admin}}'::uuid, null) as r`],
        { delay_ms: 90, jitter_ms: 4 });
      const setupC = (tocar) => ({ ...base, setup: [`select conc.c6_setup({{round}} + {{off}} + {{base}}, ${tocar}, 'c') as c`] });
      const workersX = [cancelar, confirmar];
      return [
        {
          nombre: "C6g · cancelar la boleta cobrada (cancelar_pedido_con_stock) contra confirmar la rendición, con P1 retenido 250 ms",
          rondas: 100,
          spec: { ...setupC(false), workers: [retieneP1, confirmarB, cancelar], ctx: { base: 60 } },
          referencias: referencias(setupC(false), workersX, verFn, 0),
          verify: [verMain, verFoto, verBoletas("{{c.cli}}")],
          esperado,
        },
        {
          nombre: "C6h · igual que C6g, con P1 ya editado (si su versión nueva cae en otra página, el UPDATE de pagos de la cancelación lo recorre después de P2)",
          rondas: 100,
          spec: { ...setupC(true), workers: [retieneP1, confirmarB, cancelar], ctx: { base: 360 } },
          referencias: referencias(setupC(true), workersX, verFn, 300),
          verify: [verMain, verFoto, verBoletas("{{c.cli}}")],
          esperado,
        },
      ];
    })(),
  ];
}

// ----- C7 ----------------------------------------------------------------
function c7() {
  const reordenar = (uid) => w("reordenar [Y,X]", uid, "{{c.suc}}",
    [`select public.aplicar_orden_ruta('{{c.tr}}'::uuid, jsonb_build_array(jsonb_build_object('pedido_id', {{c.y}}, 'orden_entrega', 1), jsonb_build_object('pedido_id', {{c.x}}, 'orden_entrega', 2)), null, null, null, '{{c.fecha}}'::date) as r`],
    { jitter_ms: 12 });
  const reordenarXY = w("reordenar [X,Y]", "{{c.enc2}}", "{{c.suc}}",
    [`select public.aplicar_orden_ruta('{{c.tr}}'::uuid, jsonb_build_array(jsonb_build_object('pedido_id', {{c.x}}, 'orden_entrega', 1), jsonb_build_object('pedido_id', {{c.y}}, 'orden_entrega', 2)), null, null, null, '{{c.fecha}}'::date) as r`],
    { jitter_ms: 12 });
  const entregar = (ped, l) => w(l, "{{c.tr}}", "{{c.suc}}",
    [`update public.pedidos set estado = 'entregado', fecha_entrega = ('{{c.fecha}}' || 'T12:00:00-03:00')::timestamptz, transportista_id = '{{c.tr}}'::uuid, updated_at = now() where id = {{c.${ped}}}::bigint returning id as entregado`],
    { jitter_ms: 12 });
  const ver = `select (select count(*) from public.pedidos where id in ({{c.x}}, {{c.y}}) and estado = 'entregado') >= 0 as ok,
                      'entregados=' || (select count(*) from public.pedidos where id in ({{c.x}}, {{c.y}}) and estado = 'entregado') as msg`;
  // Invariante propio: ningún pedido entregado queda fuera del recorrido, y el recorrido cuenta bien.
  const ver2 = `select (r.total_pedidos = (select count(*) from public.recorrido_pedidos where recorrido_id = r.id)
                         and r.pedidos_entregados = (select count(*) from public.recorrido_pedidos where recorrido_id = r.id and estado_entrega = 'entregado')) as ok,
                       'recorrido total=' || r.total_pedidos || ' entregados=' || r.pedidos_entregados as msg
                  from public.recorridos r where r.id = {{c.recorrido}}::bigint`;
  // Las masivas y el cobro tocan `pedidos` por el mismo trigger (`trigger_actualizar_recorrido_entrega`, que
  // dispara también por `monto_pagado`). Además del recorrido, se pide que cada boleta cierre contra sus pagos.
  const ver3 = `select (count(*) filter (where p.monto_pagado > p.total
                                       or p.monto_pagado <> coalesce((select sum(monto) from public.pagos where pedido_id = p.id), 0)) = 0) as ok,
                       'monto_pagado de X/Y = suma de sus pagos' as msg
                  from public.pedidos p where p.id in ({{c.x}}, {{c.y}})`;
  const masivo = (label, uid, ids) => w(label, uid, "{{c.suc}}",
    [`select public.marcar_entregas_masivo(array[${ids}]::bigint[], '{{c.tr}}'::uuid, ${HOY}) as r`], { jitter_ms: 12 });
  const masivoPago = (uid) => w("entrega y pago masivo [X,Y]", uid, "{{c.suc}}",
    [`select public.marcar_entrega_y_pago_masivo(array[{{c.x}}, {{c.y}}]::bigint[], '{{c.tr}}'::uuid, 'efectivo', ${HOY}, null) as r`], { jitter_ms: 12 });
  const cobroX = w("cobro de X", "{{c.enc2}}", "{{c.suc}}", [cobroSql(50, "{{c.x}}")], { jitter_ms: 12 });
  // #1406 (C7j2, C7j3, C7l, C7l2)
  const setupC7 = "select conc.c7_setup({{round}} + {{off}}, {{base}}) as c";
  const desfasarAlReves = "update public.recorrido_pedidos set estado_entrega = 'entregado', hora_entrega = now() where recorrido_id = {{c.recorrido}}::bigint and pedido_id = {{c.x}}::bigint returning id as desfasada";
  const recalcular = w("recalcular la ruta", "{{c.enc2}}", "{{c.suc}}", ["select public.recalcular_recorrido({{c.recorrido}}::bigint) as r"]);
  const quitarX = (extra) => w("quitar X de la ruta", "{{c.enc2}}", "{{c.suc}}", ["select public.quitar_pedido_de_recorridos_activos({{c.x}}::bigint) as r"], extra);
  const retieneRuta = w("retiene la ruta", null, null,
    ["select id as retenido from public.recorridos where id = {{c.recorrido}}::bigint for no key update", dormir(0.25)]);
  // Tramos de días de la sucursal A (hacia atrás de hoy; `base` + 1 … `base` + rondas), que comparten C7, el C6e de #1418 y la C9
  // de #1412. Cada uno confirma rendiciones de un chofer (una confirmada no se reabre y cierra la caja de A hasta su día):
  // C6e 1500–2000 (tr_a1), C9a 2851–3000, C9b 2601–2700, C9c 2251–2400 y C9d 251–400 (tr_a2). Los de C7 quedan fuera de todos:
  // C7a–c 1–250, C7d2 421–570, C7e 581–730, C7f 741–890, C7g 1001–1300, C7j 2001–2200, C7k 2401–2600, C7d 2701–2850,
  // C7h 3101–3300, C7i 3401–3600, C7k2 3701–3900, C7j2 4001–4200, C7l 4201–4400, C7j3 4401–4500 y C7l2 4501–4600. Si se suma
  // uno, se elige un hueco: no se solapa con ninguno de esos.
  const c = (nombre, rondas, workers, extra = {}, base = 0, verifies = [ver, ver2]) => ({
    nombre, rondas, spec: { modo: "rondas", setup: ["select conc.c7_setup({{round}} + {{off}}, {{base}}) as c"], workers, verify: verifies, sample_ms: 3, ctx: { base } }, ...extra,
  });
  return [
    c("C7a · reordenar la ruta a [Y,X] contra la entrega de X (el 2.º del nuevo orden)", 250, [reordenar("{{c.enc}}"), entregar("x", "entrega X")]),
    c("C7b · reordenar la ruta a [Y,X] contra la entrega de Y (el 1.º del nuevo orden)", 250, [reordenar("{{c.enc}}"), entregar("y", "entrega Y")]),
    c("C7c · dos encargados reordenan la misma ruta a la vez, en orden inverso", 250, [reordenar("{{c.enc}}"), reordenarXY]),
    c("C7d · marcar_entregas_masivo([X,Y]) contra el reordenamiento a [Y,X]", 150,
      [reordenar("{{c.enc}}"), masivo("masivo [X,Y]", "{{c.enc2}}", "{{c.x}}, {{c.y}}")], {}, 2700, [ver, ver2, ver3]),
    c("C7d2 · dos marcar_entregas_masivo con los ids en orden inverso ([X,Y] y [Y,X])", 150,
      [masivo("masivo [X,Y]", "{{c.enc}}", "{{c.x}}, {{c.y}}"), masivo("masivo [Y,X]", "{{c.enc2}}", "{{c.y}}, {{c.x}}")], {}, 420, [ver, ver2, ver3]),
    c("C7e · marcar_entrega_y_pago_masivo([X,Y]) contra el reordenamiento a [Y,X]", 150,
      [reordenar("{{c.enc}}"), masivoPago("{{c.enc2}}")], {}, 580, [ver, ver2, ver3]),
    c("C7f · un cobro suelto de X (registrar_pagos_pedido) contra el reordenamiento a [Y,X]", 150,
      [reordenar("{{c.enc}}"), cobroX], {}, 740, [ver, ver2, ver3]),
    // ---- C7g a C7k2: las variantes de la tarjeta 2 (#1375, #1397), traídas de su scratchpad. ----
    c("C7h · dos entregas sueltas de la misma ruta, X e Y, a la vez", 200, [entregar("x", "entrega X"), entregar("y", "entrega Y")], {}, 3100, [ver, ver2]),
    c("C7i · entregar X contra volver Y a pendiente, en la misma ruta", 200,
      [entregar("x", "entrega X"), w("volver Y a pendiente", "{{c.enc2}}", "{{c.suc}}", ["select public.volver_pedido_a_pendiente({{c.y}}::bigint) as r"], { jitter_ms: 12 })], {}, 3400, [ver, ver2]),
    c("C7k · reordenar la ruta a [Y,X] contra recalcular_recorrido de la ruta", 200,
      [reordenar("{{c.enc}}"), w("recalcular la ruta", "{{c.enc2}}", "{{c.suc}}", ["select public.recalcular_recorrido({{c.recorrido}}::bigint) as r"], { jitter_ms: 12 })], {}, 2400, [ver, ver2]),
    {
      nombre: "C7k2 · reordenar contra recalcular_recorrido, con X entregado y su parada desfasada (recalcular toma la parada y después la ruta)",
      rondas: 200,
      spec: {
        modo: "rondas", sample_ms: 3, ctx: { base: 3700 },
        setup: ["select conc.c7_setup({{round}} + {{off}}, {{base}}) as c",
                "update public.pedidos set estado = 'entregado', fecha_entrega = ('{{c.fecha}}' || 'T12:00:00-03:00')::timestamptz, transportista_id = '{{c.tr}}'::uuid where id = {{c.x}}::bigint returning id as entregado",
                "update public.recorrido_pedidos set estado_entrega = 'pendiente', hora_entrega = null where recorrido_id = {{c.recorrido}}::bigint and pedido_id = {{c.x}}::bigint returning id as desfasada"],
        workers: [reordenar("{{c.enc}}"), w("recalcular la ruta", "{{c.enc2}}", "{{c.suc}}", ["select public.recalcular_recorrido({{c.recorrido}}::bigint) as r"], { jitter_ms: 12 })],
        verify: [ver, ver2],
      },
    },
    c("C7j · entregar X contra recalcular_recorrido de la ruta", 200,
      [entregar("x", "entrega X"), w("recalcular la ruta", "{{c.enc2}}", "{{c.suc}}", ["select public.recalcular_recorrido({{c.recorrido}}::bigint) as r"], { jitter_ms: 12 })], {}, 2000, [ver, ver2]),
    // ---- #1406: el orden pedidos → recorridos → paradas. ----
    // C7j2 es el cruce por el que la 441 dejó la ruta de recalcular_recorrido después de las paradas: la parada de X dice
    // 'entregado' y X no (el paso b la vuelve a pendiente), y la entrega de X reescribe esa parada. Si recalcular tomara la
    // ruta primero y la entrega siguiera tomando la parada antes que la ruta, cada una tendría lo que la otra pide.
    {
      nombre: "C7j2 · entregar X contra recalcular_recorrido, con la parada de X en 'entregado' y X sin entregar (desfasada al revés)",
      rondas: 200,
      spec: {
        modo: "rondas", sample_ms: 3, ctx: { base: 4000 },
        setup: [setupC7, desfasarAlReves],
        workers: [entregar("x", "entrega X"), { ...recalcular, jitter_ms: 12 }],
        verify: [ver, ver2],
      },
    },
    // C7l: quitar_pedido_de_recorridos_activos llamada sola (el front la tiene para "Volver a pendiente"), contra la entrega
    // de ese mismo pedido. Borra la parada y recalcula la ruta: si borrara antes de tomar la ruta, se cruzaría con una entrega
    // que toma la ruta y después la parada.
    c("C7l · quitar X de la ruta (quitar_pedido_de_recorridos_activos) contra la entrega de X", 200,
      [entregar("x", "entrega X"), quitarX({ jitter_ms: 12 })], {}, 4200, [ver, ver2]),
    // C7j3 y C7l2 fuerzan esos dos cruces, que sin forzar caen en una ventana de microsegundos (la entrega escribe la parada
    // y pide la ruta en la misma sentencia): un tercer trabajador retiene la ruta 250 ms, el primero se pone en cola por ella
    // y el segundo entra después. Si el primero tomara la ruta antes que la parada y el segundo la parada antes que la ruta,
    // al soltarla se esperarían.
    {
      nombre: "C7j3 · igual que C7j2, con la ruta retenida 250 ms: recalcular entra primero y la entrega después",
      rondas: 100,
      spec: {
        modo: "rondas", sample_ms: 3, ctx: { base: 4400 },
        setup: [setupC7, desfasarAlReves],
        workers: [retieneRuta, { ...recalcular, delay_ms: 30, jitter_ms: 4 }, { ...entregar("x", "entrega X"), delay_ms: 60, jitter_ms: 4 }],
        verify: [ver, ver2],
      },
    },
    c("C7l2 · igual que C7l, con la ruta retenida 250 ms: la entrega entra primero y quitar después", 100,
      [retieneRuta, { ...entregar("x", "entrega X"), delay_ms: 30, jitter_ms: 4 }, quitarX({ delay_ms: 60, jitter_ms: 4 })], {}, 4500, [ver, ver2]),
    {
      nombre: "C7g · dos marcar_entregas_masivo SIN pedidos en común, cruzados sobre dos recorridos",
      rondas: 300,
      spec: {
        modo: "rondas", setup: ["select conc.c7g_setup({{round}}, 1000) as c"], sample_ms: 3,
        workers: [
          w("masivo [A,B]", "{{c.enc}}", "{{c.suc}}", [`select public.marcar_entregas_masivo(array[{{c.a}}, {{c.b}}]::bigint[], '{{c.tr1}}'::uuid, ${HOY}) as r`], { jitter_ms: 2 }),
          w("masivo [C,D]", "{{c.enc2}}", "{{c.suc}}", [`select public.marcar_entregas_masivo(array[{{c.c}}, {{c.d}}]::bigint[], '{{c.tr2}}'::uuid, ${HOY}) as r`], { jitter_ms: 2 }),
        ],
        verify: [`select bool_and(r.pedidos_entregados = (select count(*) from public.recorrido_pedidos rp join public.pedidos p on p.id = rp.pedido_id where rp.recorrido_id = r.id and p.estado = 'entregado')) as ok, 'contadores' as msg from public.recorridos r where r.id in ({{c.r1}}, {{c.r2}})`],
      },
    },
  ];
}

// ----- C11 ----------------------------------------------------------------
// Repetición final (#1388, ítem de locks de #1296): editar un pedido pasando los productos en ORDEN INVERSO contra una
// venta. `actualizar_pedido_items` bloquea los productos juntos y por id (ORDER BY id); `crear_pedido_completo` los toma en
// el orden interno del jsonb (largo de la clave y después bytes: para ids positivos, el numérico). Los dos suben por id, así que
// el orden en que llegan en el JSON no importa. La ventana de un cruce es de microsegundos: las variantes "forzadas" retienen
// el producto de MENOR id 250 ms, de modo que la venta espera en él sin nada y la edición, si lockeara de mayor a menor, tomaría
// el otro y esperaría. Con el `ORDER BY id DESC` del control negativo (controles-negativos-orden.sql, M3) esa variante da 40P01 en las 100 rondas.
function c11() {
  const lotes = JSON.stringify([{ dias: 10, cantidad: 4 }, { dias: 20, cantidad: 4 }]);
  // bolsa 2 + lotes 4 y 4 = stock 10 de cada uno (A < B); X toma 4 de cada uno.
  const base = { modo: "rondas", setup: [`select conc.c4_setup(2, '${lotes}'::jsonb, 4, true) as c`], sample_ms: 4 };
  const editarInv = w("editar X a [B,A] de 2", ADMIN, SUC, [editarSql("{{c.x}}", ["pb", "pa"], 2)], { jitter_ms: 3 });
  const ventaAB = w("venta [A,B]", "{{c.p2}}", SUC, [ventaSql("cli1", "{{c.p2}}", ["pa", "pb"], 3)], { jitter_ms: 3 });
  const ventaBA = w("venta [B,A]", "{{c.p2}}", SUC, [ventaSql("cli1", "{{c.p2}}", ["pb", "pa"], 3)], { jitter_ms: 3 });
  const retieneA = w("retiene A", null, null, ["select id as retenido from public.productos where id = {{c.pa}}::bigint for update", dormir(0.25)]);
  const prods = ["pa", "pb"];
  const mk = (nombre, rondas, workers, venta) => ({
    nombre, rondas,
    spec: { ...base, workers },
    referencias: referencias(base, [editarInv, venta], verifyRef(prods, true)),
    verify: [verifyRefs(prods, true), ...verifyStock(prods, 10, null)],
    esperado: esDeNegocio(),
  });
  const forzar = (venta) => [retieneA, { ...venta, delay_ms: 30, jitter_ms: 4 }, { ...editarInv, delay_ms: 90, jitter_ms: 4 }];
  return [
    mk("C11a · editar X a [B,A] (orden inverso) contra una venta [A,B], arranque simultáneo", 300, [editarInv, ventaAB], ventaAB),
    mk("C11b · lo mismo con A retenido 250 ms: la venta espera en A, la edición entra después", 100, forzar(ventaAB), ventaAB),
    mk("C11c · editar X a [B,A] contra una venta [B,A], con A retenido 250 ms", 100, forzar(ventaBA), ventaBA),
  ];
}

// ----- C10 ---------------------------------------------------------------
// Repetición final (#1326, REG-4): sustituir o dividir un regalo contra una venta. Los ids quedan A < C < D < B: el original
// (B) es MAYOR que los sustitutos, el caso que antes se bloqueaba al revés y contra una venta daba 40P01. Ahora los productos
// del regalo se bloquean juntos y por id. Las "forzadas" retienen C (el menor de los que cruzan con la venta [C,B]).
function c10() {
  const base = { modo: "rondas", setup: ["select conc.c10_setup() as c"], sample_ms: 4 };
  const sustituir = w("sustituir el regalo B por C", ADMIN, SUC,
    [`select public.sustituir_regalo_pedido({{c.item}}::bigint, {{c.pc}}::bigint, 2, 'conc') as r`], { jitter_ms: 3 });
  const dividir = w("dividir el regalo B en C y D", ADMIN, SUC,
    [`select public.dividir_regalo_pedido({{c.item}}::bigint, jsonb_build_array(jsonb_build_object('producto_id', {{c.pc}}, 'cantidad', 1), jsonb_build_object('producto_id', {{c.pd}}, 'cantidad', 1)), 'conc') as r`],
    { jitter_ms: 3 });
  const venta = w("venta [C,B]", "{{c.p2}}", SUC, [ventaSql("cli1", "{{c.p2}}", ["pc", "pb"], 1)], { jitter_ms: 3 });
  const retieneC = w("retiene C", null, null, ["select id as retenido from public.productos where id = {{c.pc}}::bigint for update", dormir(0.25)]);
  // Estado: stock y lotes de A, B, C y D; las líneas de X por etiqueta (el id cambia en cada ronda) y cuántas sustituciones tiene.
  const estadoR = `conc.estado_prod({{c.pa}}) || ';' || conc.estado_prod({{c.pb}}) || ';' || conc.estado_prod({{c.pc}}) || ';' || conc.estado_prod({{c.pd}})
      || ';X=' || (select coalesce(string_agg(l.t, ',' order by l.t), '')
                     from (select (case producto_id when {{c.pa}} then 'A' when {{c.pb}} then 'B' when {{c.pc}} then 'C' when {{c.pd}} then 'D' else '?' end)
                                  || ':' || cantidad || ':' || coalesce(es_bonificacion, false)::text as t
                             from public.pedido_items where pedido_id = {{c.x}}::bigint) l)
      || ';sust=' || (select count(*) from public.pedido_item_sustituciones where pedido_id = {{c.x}}::bigint)`;
  const verFnR = `select true as ok, 'ESTADO=' || ${estadoR} as msg`;
  const verMainR = `select position('|ESTADO=' || q.s || '|' in '|{{refs}}|') > 0 as ok, 'estado=' || q.s as msg from (select ${estadoR} as s) q`;
  const verStock = `select (min(stock) >= 0 and bool_and(stock >= coalesce((select sum(cantidad_restante) from public.producto_lotes where producto_id = productos.id), 0))) as ok,
                           'stock mínimo=' || min(stock) as msg
                      from public.productos where id in ({{c.pa}}, {{c.pb}}, {{c.pc}}, {{c.pd}})`;
  const mk = (nombre, rondas, workers, op) => ({
    nombre, rondas,
    spec: { ...base, workers },
    referencias: referencias(base, [op, venta], verFnR),
    verify: [verMainR, verStock],
    esperado: esDeNegocio(),
  });
  const forzar = (op) => [retieneC, { ...venta, delay_ms: 30, jitter_ms: 4 }, { ...op, delay_ms: 90, jitter_ms: 4 }];
  return [
    mk("C10a · sustituir el regalo B por C contra una venta [C,B], arranque simultáneo", 300, [sustituir, venta], sustituir),
    mk("C10b · lo mismo con C retenido 250 ms (fuerza el cruce)", 100, forzar(sustituir), sustituir),
    mk("C10c · dividir el regalo B en C y D contra una venta [C,B], arranque simultáneo", 300, [dividir, venta], dividir),
    mk("C10d · lo mismo con C retenido 250 ms (fuerza el cruce)", 100, forzar(dividir), dividir),
  ];
}

// ----- C8 ----------------------------------------------------------------
function c8() {
  const venta = (zona) => `
    with it as (select id, precio, 1 + floor(random() * 3)::int as q
                  from public.productos
                 where sucursal_id = {{c.suc}} and nombre like 'CONC-P%' ${zona}
                 order by random() limit (select 1 + floor(random() * 4)::int)),
         t as (select jsonb_agg(jsonb_build_object('producto_id', id, 'cantidad', q, 'precio_unitario', precio)) as items, sum(q * precio) as total from it)
    select public.crear_pedido_completo(
             (select id from public.clientes where sucursal_id = {{c.suc}} and razon_social like 'CONC-C%' order by random() limit 1),
             t.total, '{{uid}}'::uuid, t.items, 'conc') as r
      from t`;
  const cobro = `select public.registrar_pagos_pedido(({{r.pedido_id}})::bigint,
                   jsonb_build_array(jsonb_build_object('monto', {{r.total}}, 'forma_pago', 'efectivo')), ${HOY}, 'conc', null, gen_random_uuid()) as p`;
  const tablas = `select relname, n_tup_ins, n_tup_upd, n_tup_del from pg_stat_user_tables where schemaname = 'public'
                    and relname in ('pedidos','pedido_items','productos','producto_lotes','stock_historico','clientes','pagos','pedido_historial','pedido_item_lotes','recorridos') order by relname`;
  const stmts = `select calls, round(total_exec_time::numeric, 0) as total_ms, round(mean_exec_time::numeric, 2) as medio_ms, left(regexp_replace(query, '\\s+', ' ', 'g'), 90) as q
                   from pg_stat_statements order by total_exec_time desc limit 12`;
  const out = [];
  for (const [zona, etiqueta] of [["", "uniforme (200 productos)"], ["and nombre <= 'CONC-P0008'", "caliente (8 productos)"]]) {
    for (const cajas of [1, 2, 4, 8, 16]) {
      out.push({
        nombre: `C8 · ${cajas} caja${cajas > 1 ? "s" : ""}, ${etiqueta}`,
        spec: {
          modo: "carga", copies: cajas, duration_s: 20, sample_ms: 10,
          setup: ["select jsonb_build_object('suc', conc.f('suc_a')::bigint) as c, (select jsonb_agg(conc.f('prev_a' || g)) from generate_series(1, 16) g) as users"],
          workers: [{ label: "caja", seq: [w("venta", "{{uid}}", "{{c.suc}}", [venta(zona)], {}), w("cobro", "{{uid}}", "{{c.suc}}", [cobro], {})] }],
          snapshots: { tablas },
          final: { stmts },
          guardar_pasos: false,
        },
      });
    }
  }
  return out;
}

// ----- C9 ----------------------------------------------------------------
// #1342: una entrega contra la confirmación de la rendición de ese día y chofer. Los dos órdenes
// seriales son legítimos: entregar y después confirmar (la foto cuenta las entregas), o confirmar
// y después entregar (la entrega se rechaza: reabriría el día). Lo que no vale es que la
// confirmación termine bien y el control desaparezca, que es lo que hacía el trigger cuando la
// entrega miraba el control antes de que se confirmara y escribía después.
function c9() {
  const SA = "{{c.suc}}";
  const confirmar = w("confirmar rendición", "{{c.adm}}", SA,
    [`select public.confirmar_rendicion('{{c.fecha}}'::date, '{{c.tr}}'::uuid, 'confirmada', '{}'::jsonb, 'conc') as r`], { jitter_ms: 12 });
  const masivo = w("masivo [X,Y]", "{{c.adm2}}", SA,
    [`select public.marcar_entregas_masivo(array[{{c.x}}, {{c.y}}]::bigint[], '{{c.tr}}'::uuid, '{{c.fecha}}'::date) as r`], { jitter_ms: 12 });
  const masivoPago = w("entrega y pago masivo [X,Y]", "{{c.adm2}}", SA,
    [`select public.marcar_entrega_y_pago_masivo(array[{{c.x}}, {{c.y}}]::bigint[], '{{c.tr}}'::uuid, 'efectivo', '{{c.fecha}}'::date, null) as r`], { jitter_ms: 12 });
  const suelta = w("entrega suelta de X por REST (encargado)", "{{c.enc}}", SA,
    [`update public.pedidos set estado = 'entregado', fecha_entrega = ('{{c.fecha}}' || 'T12:00:00-03:00')::timestamptz, transportista_id = '{{c.tr}}'::uuid, updated_at = now() where id = {{c.x}}::bigint returning id as entregado`],
    { jitter_ms: 12 });
  // Retiene X entre el chequeo de la masiva y su UPDATE: la masiva lo pide después de mirar el
  // control (antes de la migración) y la confirmación no lo necesita.
  const retieneX = w("retiene X", null, null,
    ["select id as retenido from public.pedidos where id = {{c.x}}::bigint for update", dormir(0.25)]);

  const ver = `select (rc.estado = 'confirmada' and rc.cantidad_pedidos_confirmada = e.n) as ok,
                      format('control=%s foto=%s entregados=%s', coalesce(rc.estado, 'BORRADO'), rc.cantidad_pedidos_confirmada, e.n) as msg
                 from (select count(*) as n from public.pedidos where id in ({{c.x}}, {{c.y}}) and estado = 'entregado') e
                 left join public.rendiciones_control rc
                   on rc.fecha = '{{c.fecha}}'::date and rc.transportista_id = '{{c.tr}}'::uuid and rc.sucursal_id = {{c.suc}}::bigint`;
  const verBoletas = `select (count(*) filter (where p.monto_pagado > p.total
                                             or p.monto_pagado <> coalesce((select sum(monto) from public.pagos where pedido_id = p.id), 0)) = 0) as ok,
                             'monto_pagado de X/Y = suma de sus pagos' as msg
                        from public.pedidos p where p.id in ({{c.x}}, {{c.y}})`;
  // Confirmar primero y entregar después: la entrega se rechaza (42501, "ya fue controlada"). Un
  // verify en rojo con "control=BORRADO" es el control que se borró; con "foto=0 entregados=2", la
  // confirmación que se cerró sin ver las entregas que se hicieron en el medio.
  const esperado = (err) => err.code === "42501" && /ya fue controlada/.test(err.message);
  // Con cobro, confirmar primero también cierra la caja de ese día: el pago se rechaza antes.
  const esperadoCobro = (err) => esperado(err) || (err.code === "42501" && /caja de la sucursal esta cerrada/.test(err.message));
  // La entrega suelta por REST (C9c) puede recibir 40001 en vez de 42501, y es el diseño de la 443: `anular_control_por_cambio_fecha_entrega`
  // (líneas 53-55) hace pg_try_advisory_xact_lock_shared de la rendición del chofer y del día y, si confirmar tiene la clave tomada, corta en
  // el acto con 40001 "volvé a intentar"; si esperara, igual terminaría rechazada con el 42501. El front ya lo trata como transitorio
  // (src/utils/errorDeSupabase.ts). Sólo C9c lo admite, y sólo con este mensaje: en las demás variantes el 40001 sigue siendo un error inesperado.
  const esperadoSuelta = (err) => esperado(err) || (err.code === "40001" && /se está controlando o editando/.test(err.message));
  const c = (nombre, rondas, workers, base, verifies = [ver], esp = esperado) => ({
    nombre, rondas, esperado: esp,
    spec: { modo: "rondas", setup: ["select conc.c9_setup({{round}} + {{off}}, {{base}}) as c"], workers, verify: verifies, sample_ms: 3, ctx: { base } },
  });
  // Tramos de días (hoy - base, crecientes): cada variante en el suyo, y la del cobro la última y la
  // más cercana a hoy, para que la caja cerrada por las otras no le frene los pagos.
  return [
    c("C9a · marcar_entregas_masivo([X,Y]) contra confirmar la rendición de ese día y chofer", 150, [masivo, confirmar], 3000),
    c("C9b · lo mismo con X retenido 250 ms entre el chequeo de la masiva y su UPDATE", 100,
      [retieneX, { ...masivo, delay_ms: 20, jitter_ms: 4 }, { ...confirmar, delay_ms: 80, jitter_ms: 4 }], 2700),
    c("C9c · la entrega suelta de X por REST (encargado) contra confirmar la rendición", 150, [suelta, confirmar], 2400, [ver], esperadoSuelta),
    c("C9d · marcar_entrega_y_pago_masivo([X,Y]) contra confirmar la rendición", 150, [masivoPago, confirmar], 400, [ver, verBoletas], esperadoCobro),
  ];
}

// ----- C12 ---------------------------------------------------------------
// #1398 (tarjeta 12 de #1378): la venta contra el contenedor de una promo. crear_pedido_completo y el alta del bot bloquean
// los productos de sus líneas por id, y recién después, en aplicar_uso_promo_acumulador, la fila de la promo y el
// contenedor del bloque que se cierra. Cancelar y editar (431b-c, 447) bloquean productos y contenedores juntos, por id, y la
// promo después. Con un contenedor distinto del sabor y menor que lo que bloquea la venta (C < A < S), la venta tiene A y
// pide C, y la otra tiene C y pide A. Las forzadas retienen A 250 ms: la venta espera en A sin nada, y la otra entra después,
// toma C y espera A. C12i (el contenedor es el sabor, lo único que hay hoy en prod) y C12j (el contenedor es el mayor) son
// los controles con ids que no cruzan: dan 0 con y sin arreglo. C12k mide aparte las filas de promociones, que el motor
// bloquea en el orden de las líneas del JSON. Ninguna variante confirma rendiciones ni usa días: los pedidos son de hoy.
function c12() {
  const regalo = (cant = 2) =>
    `jsonb_build_object('producto_id', {{c.ps}}, 'cantidad', ${cant}, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', {{c.promo}})`;
  const lineaA = (cant = 10) => `jsonb_build_object('producto_id', {{c.pa}}, 'cantidad', ${cant}, 'precio_unitario', 100)`;
  // La RPC devuelve success:false en vez de tirar: sin esto, una venta rechazada pasaría por "no cambió nada".
  const exigeOk = "select case when '{{r.success}}' = 'true' then true else (1 / 0)::boolean end as rpc_ok";
  const venta = (l, uid, cli, extra = [], chequear = true) =>
    w(l, uid, SUC, [
      `select public.crear_pedido_completo({{c.${cli}}}::bigint, ${1000 + 100 * extra.length}, '${uid}'::uuid, jsonb_build_array(${[...extra, lineaA(), regalo()].join(", ")}), 'conc') as r`,
      ...(chequear ? [exigeOk] : []),
    ], { jitter_ms: 3 });
  const ventaP2 = venta("venta", "{{c.p2}}", "cli2");
  const ventaP1 = venta("venta 2", "{{c.p1}}", "cli1");
  const ventaConC = venta("venta con el contenedor suelto", "{{c.p1}}", "cli1",
    ["jsonb_build_object('producto_id', {{c.pc}}, 'cantidad', 1, 'precio_unitario', 100)"]);
  const bot = w("venta del bot", null, null,
    ["select public.crear_pedido_completo_bot('{{c.p2}}'::uuid, '{{c.conf}}'::uuid) as r", exigeOk], { jitter_ms: 3 });
  const cancelar = w("cancelar X", ADMIN, SUC, [cancelarSql("{{c.x}}"), exigeOk], { jitter_ms: 3 });
  const editar = w("editar X (A 10→20, regalo 2→4)", ADMIN, SUC,
    [`select public.actualizar_pedido_items({{c.x}}::bigint, jsonb_build_array(${lineaA(20)}, ${regalo(4)}), '{{c.admin}}'::uuid, null, null) as r`, exigeOk],
    { jitter_ms: 3 });
  const retieneA = w("retiene A", null, null, ["select id as retenido from public.productos where id = {{c.pa}}::bigint for update", dormir(0.25)]);

  const vivas = `from public.pedido_items pi join public.pedidos pe on pe.id = pi.pedido_id where pe.estado <> 'cancelado'`;
  const estado = (conX) => `conc.estado_prod({{c.pa}}) || ';' || conc.estado_prod({{c.ps}}) || ';' || conc.estado_prod({{c.pc}})
      || ';barra=' || (select coalesce(usos_pendientes, 0) || '/' || coalesce(activo, true) from public.promociones where id = {{c.promo}})
      || ';ventas=' || (select count(distinct pi.pedido_id) ${vivas} and pi.promocion_id = {{c.promo}})` +
    (conX ? ` || ';X=' || (select estado || '/' || total from public.pedidos where id = {{c.x}}::bigint)` : "");
  const verFn = (conX) => `select true as ok, 'ESTADO=' || ${estado(conX)} as msg`;
  const verMain = (conX) =>
    `select position('|ESTADO=' || q.s || '|' in '|{{refs}}|') > 0 as ok, 'estado=' || q.s as msg from (select ${estado(conX)} as s) q`;
  // La barra y el contenedor cierran: cada 2 de regalo vivo es 1 bloque que salió del contenedor, más lo que quedó en la barra.
  const verBarra = `select (2 * ({{c.c0}} - c.stock - c.suelto) + b.resto = b.regalado) as ok,
                           format('contenedor %s (vendido suelto %s, inicial {{c.c0}}), barra %s, regalo vivo %s', c.stock, c.suelto, b.resto, b.regalado) as msg
                      from (select (select stock from public.productos where id = {{c.pc}}) as stock,
                                   (select coalesce(sum(pi.cantidad), 0) ${vivas} and pi.producto_id = {{c.pc}} and not coalesce(pi.es_bonificacion, false)) as suelto) c,
                           (select coalesce((select usos_pendientes from public.promociones where id = {{c.promo}}), 0) as resto,
                                   (select coalesce(sum(pi.cantidad), 0) ${vivas} and pi.promocion_id = {{c.promo}} and pi.es_bonificacion) as regalado) b`;
  const verStockA = `select (conc.stock_cierra({{c.pa}}, 100) is null) as ok, coalesce(conc.stock_cierra({{c.pa}}, 100), 'stock de A ok') as msg`;
  const verLimite = `select (sum(pi.cantidad) <= {{c.limite}}) as ok, 'regalo vivo ' || sum(pi.cantidad) || ' de un límite de {{c.limite}}' as msg
                       ${vivas} and pi.promocion_id = {{c.promo}} and pi.es_bonificacion`;

  const mk = (nombre, rondas, setup, workers, refWorkers, { conX = true, extra = [], esperado = esDeNegocio() } = {}) => {
    const base = { modo: "rondas", setup: [setup], sample_ms: 4 };
    return {
      nombre, rondas, esperado,
      spec: { ...base, workers },
      referencias: referencias(base, refWorkers, verFn(conX)),
      verify: [verMain(conX), verBarra, verStockA, ...extra],
    };
  };
  const forzar = (primero, segundo) => [retieneA, { ...primero, delay_ms: 30, jitter_ms: 4 }, { ...segundo, delay_ms: 90, jitter_ms: 4 }];
  const MENOR = "select conc.c12_setup('menor') as c";
  // El límite (4) deja lugar para X (2) y una sola de las dos ventas: la otra se rechaza al confirmar
  // (trg_limite_usos_promo) o, si llega después de que la primera apagó la promo, por la validación del regalo.
  const limiteVentas = [venta("venta", "{{c.p2}}", "cli2", [], false), venta("venta 2", "{{c.p1}}", "cli1", [], false)];
  const esLimite = (err) => err.code === "P0001" && /límite/.test(err.message);

  // C12k: dos promos y dos ventas de admin sin productos en común, con los regalos en orden inverso. Van a clientes
  // distintos: dos ventas al mismo cliente se serializan en su saldo antes de llegar a las promos.
  const linea = (p, cant, promo) =>
    `jsonb_build_object('producto_id', {{c.${p}}}, 'cantidad', ${cant}, 'precio_unitario', ${promo ? 0 : 100}${promo ? `, 'es_bonificacion', true, 'promocion_id', {{c.${promo}}}` : ""})`;
  const ventaK = (l, uid, cli, lineas) =>
    w(l, uid, SUC, [`select public.crear_pedido_completo({{c.${cli}}}::bigint, 2000, '${uid}'::uuid, jsonb_build_array(${lineas.join(", ")}), 'conc') as r`, exigeOk]);
  const k1 = ventaK("venta [P1, P2]", "{{c.admin}}", "cli1", [linea("a1", 10), linea("r1a", 2, "promo1"), linea("a2", 10), linea("r2a", 2, "promo2")]);
  const k2 = ventaK("venta [P2, P1]", "{{c.admin2}}", "cli2", [linea("b2", 10), linea("r2b", 2, "promo2"), linea("b1", 10), linea("r1b", 2, "promo1")]);
  const retieneP1 = w("retiene P1", null, null, ["select id as retenido from public.promociones where id = {{c.promo1}}::bigint for update", dormir(0.25)]);
  // Las dos ventas, o una sola si la otra fue la víctima de un 40P01: cada venta viva suma 2 en cada barra.
  const verK = `select (v.n between 1 and 2 and p1.usos = 2 * v.n and p2.usos = 2 * v.n) as ok, format('usos P1=%s P2=%s, ventas=%s', p1.usos, p2.usos, v.n) as msg
                  from (select coalesce(usos_pendientes, 0) as usos from public.promociones where id = {{c.promo1}}) p1,
                       (select coalesce(usos_pendientes, 0) as usos from public.promociones where id = {{c.promo2}}) p2,
                       (select count(distinct pi.pedido_id) as n ${vivas} and pi.promocion_id in ({{c.promo1}}, {{c.promo2}})) v`;
  const c12k = (nombre, rondas, workers) => ({
    nombre, rondas, esperado: esDeNegocio(),
    spec: { modo: "rondas", setup: ["select conc.c12k_setup() as c"], workers, verify: [verK], sample_ms: 4 },
  });

  // C12m a C12o (#1442): cambiarle el tipo a la promo mientras una venta carga su regalo. La línea se sella en el INSERT
  // (451), la foto se toma en ese INSERT y la bajada de stock se decidía en una sentencia posterior, leyendo la promo de
  // nuevo. Lo que tiene que dar siempre: el sello, la foto y lo que bajó el stock del regalo dicen el mismo modo. C12m
  // retiene la promo 250 ms y le cambia el tipo antes de soltarla, con la venta ya esperando; C12n es al revés: la venta
  // retiene sus locks 250 ms y el cambio llega en el medio.
  const cambiaTipo = w("cambiar el tipo de la promo por REST", ADMIN, SUC,
    ["update public.promociones set regalo_mueve_stock = false where id = {{c.promo}}::bigint returning id as cambiado"], { jitter_ms: 3 });
  const retieneYCambia = w("retiene la promo y le cambia el tipo", ADMIN, SUC, [
    "select id as retenido from public.promociones where id = {{c.promo}}::bigint for update",
    dormir(0.25),
    "update public.promociones set regalo_mueve_stock = false where id = {{c.promo}}::bigint returning id as cambiado",
  ]);
  const ventaQueRetiene = { ...ventaP2, label: "venta (retiene 250 ms)", steps: [...ventaP2.steps, dormir(0.25)] };
  const verModo = `select (m.lineas = 0 or (m.sello = m.foto and m.stock_s = 20 - case when m.foto then 2 else 0 end)) as ok,
                          format('lineas=%s sello=%s foto=%s stock del regalo=%s', m.lineas, m.sello, m.foto, m.stock_s) as msg
                     from (select (select count(*) from public.pedido_items where promocion_id = {{c.promo}} and es_bonificacion) as lineas,
                                  (select bool_and(regalo_mueve_stock_foto) from public.pedido_items where promocion_id = {{c.promo}} and es_bonificacion) as sello,
                                  (select bool_and(regalo_mueve_stock) from public.pedido_promo_reglas where promocion_id = {{c.promo}}) as foto,
                                  (select stock from public.productos where id = {{c.ps}}) as stock_s) m`;
  const c12m = (nombre, rondas, workers) => ({
    nombre, rondas, esperado: esDeNegocio(),
    spec: { modo: "rondas", setup: ["select conc.c12m_setup() as c"], workers, verify: [verModo], sample_ms: 4 },
  });

  return [
    mk("C12a · venta con regalo contra cancelar X, contenedor menor (C < A < S), arranque simultáneo", 200, MENOR, [ventaP2, cancelar], [cancelar, ventaP2]),
    mk("C12b · lo mismo con A retenido 250 ms: la venta espera en A, la cancelación entra después", 100, MENOR, forzar(ventaP2, cancelar), [cancelar, ventaP2]),
    mk("C12c · venta con regalo contra editar X, contenedor menor, arranque simultáneo", 200, MENOR, [ventaP2, editar], [editar, ventaP2]),
    mk("C12d · lo mismo con A retenido 250 ms", 100, MENOR, forzar(ventaP2, editar), [editar, ventaP2]),
    mk("C12e · la venta del bot contra cancelar X, contenedor menor, con A retenido 250 ms", 100,
      "select conc.c12_setup('menor', null, true, true) as c", forzar(bot, cancelar), [cancelar, bot]),
    mk("C12f · dos ventas de la promo, una vende además el contenedor suelto, con A retenido 250 ms", 100, MENOR,
      forzar(ventaP2, ventaConC), [ventaConC, ventaP2]),
    mk("C12g · dos ventas con la misma promo a la vez", 200, MENOR, [ventaP1, ventaP2], [ventaP1, ventaP2]),
    mk("C12h · dos ventas con la misma promo y límite de usos 4 (X ya usa 2): entra una sola", 200,
      "select conc.c12_setup('menor', 4) as c", limiteVentas, limiteVentas, { extra: [verLimite], esperado: esLimite }),
    mk("C12i · control: el contenedor es el sabor (como hoy en prod), venta contra cancelar X con A retenido", 100,
      "select conc.c12_setup('sabor') as c", forzar(ventaP2, cancelar), [cancelar, ventaP2]),
    mk("C12j · control: el contenedor es el mayor (A < S < C), venta contra cancelar X con A retenido", 100,
      "select conc.c12_setup('mayor') as c", forzar(ventaP2, cancelar), [cancelar, ventaP2]),
    c12k("C12k · dos ventas con dos promos en orden inverso y sin productos en común, arranque simultáneo", 200,
      [{ ...k1, jitter_ms: 3 }, { ...k2, jitter_ms: 3 }]),
    c12k("C12k2 · lo mismo con la promo 1 retenida 250 ms", 100,
      [retieneP1, { ...k1, delay_ms: 30, jitter_ms: 4 }, { ...k2, delay_ms: 90, jitter_ms: 4 }]),
    c12m("C12m · cambiarle el tipo a la promo (retenida 250 ms) mientras entra una venta con su regalo", 100,
      [retieneYCambia, { ...ventaP2, delay_ms: 30, jitter_ms: 4 }]),
    c12m("C12n · una venta con el regalo retiene sus locks 250 ms y el cambio de tipo llega en el medio", 100,
      [ventaQueRetiene, { ...cambiaTipo, delay_ms: 60, jitter_ms: 4 }]),
    c12m("C12o · venta con el regalo contra el cambio de tipo, arranque simultáneo", 300, [ventaP2, cambiaTipo]),
  ];
}

// ----- T10 ---------------------------------------------------------------
// Tarjeta 10 de #1378 (#1439, #1424): cobros, créditos y stock contra el orden global de locks, pedidos por id →
// recorridos por id → paradas → pagos por id, y productos por id. Todas están forzadas: un trabajador retiene 250 ms la
// fila que las dos operaciones piden primero en el orden global; la que lo respeta entra a los 30 ms y queda en cola
// ahí, y la otra a los 90 ms. Si la segunda tomara algo antes de esa fila, al soltarla se esperarían. Los casos están
// en conc.t10_* (fixtures.sql). Corre antes que C6e y C9, o sobre una base nueva (ver el comentario de los fixtures).
function t10() {
  const SA = "{{c.suc}}";
  const retiene = (tabla, clave, modo = "update") => w(`retiene ${clave}`, null, null,
    [`select id as retenido from public.${tabla} where id = {{c.${clave}}}::bigint for ${modo}`, dormir(0.25)]);
  const primero = (x) => ({ ...x, delay_ms: 30, jitter_ms: 4 });
  const segundo = (x) => ({ ...x, delay_ms: x.delay_ms ?? 90, jitter_ms: 4 });
  // Las RPCs sólo de server (EXECUTE para postgres y service_role): como postgres, con el usuario y la sucursal en los GUC.
  const comoServer = (uid) =>
    `select set_config('request.jwt.claims', json_build_object('sub','${uid}','role','authenticated')::text, true) as cl,
            set_config('request.headers', json_build_object('x-sucursal-id','{{c.suc}}')::text, true) as hd`;
  const pedidoEstado = (k) => `(select coalesce(estado, '?') || '/' || monto_pagado || '/' || total || '/' || coalesce(forma_pago, '-') from public.pedidos where id = {{c.${k}}}::bigint)`;
  const formas = `(select coalesce(string_agg(round(monto, 2) || ':' || forma_pago, ',' order by monto, forma_pago), '') from public.pagos where cliente_id = {{c.cli}}::bigint)`;
  // Estado normalizado (para las referencias seriales): los pagos del cliente y las boletas que se nombran.
  const estado = (...peds) => `conc.estado_pagos({{c.cli}}::bigint) || ';' || ${formas}` +
    peds.map((k) => ` || ';${k}=' || coalesce(${pedidoEstado(k)}, 'BORRADO')`).join("");
  const verFn = (s) => `select true as ok, 'ESTADO=' || ${s} as msg`;
  const verMain = (s) => `select position('|ESTADO=' || q.s || '|' in '|{{refs}}|') > 0 as ok, 'estado=' || q.s as msg from (select ${s} as s) q`;
  const verBoletas = `select (count(*) filter (where pe.monto_pagado > pe.total
                                            or pe.monto_pagado <> coalesce((select sum(monto) from public.pagos where pedido_id = pe.id), 0)) = 0) as ok,
                             'boletas del cliente con monto_pagado mal=' || count(*) filter (where pe.monto_pagado > pe.total
                                            or pe.monto_pagado <> coalesce((select sum(monto) from public.pagos where pedido_id = pe.id), 0)) as msg
                        from public.pedidos pe where pe.cliente_id = {{c.cli}}::bigint`;
  const verFoto = `select (count(*) = count(distinct pago_id)) as ok, 'pagos en la foto=' || count(*) as msg
                     from public.rendicion_pagos_confirmados r join public.pagos pg on pg.id = r.pago_id where pg.cliente_id = {{c.cli}}::bigint`;
  const deNegocio = (err) => err.code === "22023" || (err.code === "42501" && /caja de la sucursal esta cerrada/.test(err.message));
  // Una variante con referencias: `workers` son los dos que cruzan (sin el que retiene), en el orden en que entran.
  const conRefs = (nombre, rondas, setup, retenedor, workers, s, extra = [], esp = deNegocio) => {
    const base = { modo: "rondas", setup: [setup], sample_ms: 3 };
    return {
      nombre, rondas, esperado: esp,
      spec: { ...base, workers: [retenedor, primero(workers[0]), segundo(workers[1])] },
      referencias: referencias(base, workers, verFn(s)),
      verify: [verMain(s), verBoletas, ...extra],
    };
  };
  const conVerify = (nombre, rondas, setup, retenedor, workers, verify) => ({
    nombre, rondas,
    spec: { modo: "rondas", setup: [setup], sample_ms: 3, workers: [retenedor, primero(workers[0]), segundo(workers[1])], verify },
  });

  // --- créditos (#1439, #1424) ---
  const editarX = w("editar X 100→120", ADMIN, SA,
    [`select public.actualizar_pedido_items({{c.x}}::bigint, jsonb_build_array(jsonb_build_object('producto_id', {{c.relleno}}, 'cantidad', 120, 'precio_unitario', 1)), '{{c.admin}}'::uuid, null, null) as r`]);
  const imputar = (ped, extra = {}) => w(`imputar C→${ped.toUpperCase()}`, ADMIN, SA,
    [`select public.imputar_credito_a_pedido({{c.c}}::bigint, {{c.${ped}}}::bigint, null, null) as r`], extra);
  // --- un pago de una boleta cobrada (#1439) ---
  const cancelar = w("cancelar X", ADMIN, SA, [cancelarSql("{{c.pedido}}")]);
  const forma = w("forma de P1 → cheque", ADMIN, SA, ["select public.actualizar_forma_pago_pago({{c.p1}}::bigint, 'cheque') as r"]);
  const borrar = w("DELETE REST de P1", ADMIN, SA, ["delete from public.pagos where id = {{c.p1}}::bigint returning id as borrado"]);
  // --- cobros de varias boletas (#1439) ---
  const fifo = (monto) => w(`FIFO ${monto}`, ADMIN, SA, [fifoSql(monto)]);
  const combinado = (monto) => w(`FIFO combinado ${monto}`, ADMIN, SA,
    [`select public.registrar_pago_combinado_cliente_fifo({{c.cli}}::bigint, '[{"monto":${monto},"forma_pago":"efectivo"}]'::jsonb, ${HOY}, null, 'conc', null) as r`]);
  const masivoPagos = (ids, uid) => w(`marcar_pagos_masivo [${ids}]`, uid, SA,
    [`select public.marcar_pagos_masivo(array[${ids.split(",").map((k) => `{{c.${k}}}`).join(", ")}]::bigint[], 'efectivo', ${HOY}, null) as r`]);
  const entregarAC = w("marcar_entregas_masivo [a,c]", "{{c.enc}}", SA,
    [`select public.marcar_entregas_masivo(array[{{c.a}}, {{c.c}}]::bigint[], '{{c.tr1}}'::uuid, ${HOY}) as r`]);
  const verRutas = [
    `select bool_and(r.total_pedidos = (select count(*) from public.recorrido_pedidos rp where rp.recorrido_id = r.id)
                     and r.pedidos_entregados = (select count(*) from public.recorrido_pedidos rp join public.pedidos p on p.id = rp.pedido_id
                                                  where rp.recorrido_id = r.id and p.estado = 'entregado')) as ok,
            'contadores de r1 y r2' as msg
       from public.recorridos r where r.id in ({{c.r1}}, {{c.r2}})`,
    `select (count(*) filter (where estado = 'entregado' and id in ({{c.a}}, {{c.c}})) = 2
             and count(*) filter (where id in ({{c.b}}, {{c.d}}) and monto_pagado = total
                                    and monto_pagado = coalesce((select sum(monto) from public.pagos where pedido_id = pedidos.id), 0)) = 2) as ok,
            'a y c entregados, b y d cobrados' as msg
       from public.pedidos where id in ({{c.a}}, {{c.b}}, {{c.c}}, {{c.d}})`,
  ];
  // --- contra la foto de la rendición (#1424) ---
  const confirmar = w("confirmar la rendición de D", ADMIN, SA,
    [`select public.confirmar_rendicion('{{c.fecha}}'::date, '{{c.tr}}'::uuid, 'confirmada', '{}'::jsonb, 'conc') as r`]);
  const eliminar = w("eliminar X (server)", null, null,
    [comoServer("{{c.admin}}"), "select public.eliminar_pedido_completo({{c.pedido}}::bigint, '{{c.admin}}'::uuid, 'conc', true) as r"]);
  const anular = w("anular la NC", ADMIN, SA, ["select public.anular_nota_credito_venta({{c.nc}}::bigint, 'conc') as r"]);
  const ncEstado = `${estado()} || ';NC=' || (select anulada::text from public.notas_credito_venta where id = {{c.nc}}::bigint)`;
  // --- stock (#1255) ---
  const verStock = (prods, inicial, ajuste) => prods.map((p) =>
    `select (conc.stock_cierra({{c.${p}}}, ${inicial}, (${ajuste(p)})::int) is null) as ok,
            coalesce(conc.stock_cierra({{c.${p}}}, ${inicial}, (${ajuste(p)})::int), 'stock ok') || ' [${p} ' || conc.estado_prod({{c.${p}}}) || ']' as msg`);
  const ingresado = (p) => `coalesce((select sum(cantidad) from public.transferencia_items where producto_id = {{c.${p}}}), 0)`;
  const ingreso = w("ingreso [B,A] (server)", null, null, [comoServer("{{c.admin}}"),
    `select conc.t10_exigir(public.registrar_ingreso_sucursal({{c.suc}}::bigint, ${HOY}, 'conc', 0, '{{c.admin}}'::uuid,
       jsonb_build_array(jsonb_build_object('producto_id', {{c.pb}}, 'cantidad', 5, 'costo_unitario', 60),
                         jsonb_build_object('producto_id', {{c.pa}}, 'cantidad', 5, 'costo_unitario', 60)))) as r`]);
  const aceptado = `(select case when estado = 'aceptada' then 2 else 0 end from public.movimientos_sucursal where id = {{c.mov}}::bigint)`;
  const aceptar = w("aceptar el envío (oA→dY, oB→dX)", ADMIN, SA,
    ["select conc.t10_exigir(public.aceptar_movimiento_sucursal({{c.mov}}::bigint, '{{c.res}}'::jsonb)) as r"]);

  return [
    conRefs("T10a · imputar el crédito C a X contra editar X al alza (la edición llega a C por pedidos_reconciliar_pagos), X retenida",
      100, "select conc.t10_credito_setup(false) as c", retiene("pedidos", "x"), [editarX, imputar("x")], estado("x")),
    // La imputación entra a los 220 ms (C se suelta a los 250), con la edición ya en cola por C: si aplicar_credito_cliente
    // tomara C antes que Y (la boleta que C paga), la imputación tomaría Y y pediría C. Con 180 ms, en la primera ronda de
    // cada tanda (conexión en frío) la edición todavía no había llegado a C y el cruce era el de T10b2 (t10r).
    conRefs("T10b · imputar C a Y (la boleta más vieja) contra editar X del mismo cliente, C retenido y la edición ya esperándolo",
      100, "select conc.t10_credito_setup(true) as c", retiene("pagos", "c"), [editarX, imputar("y", { delay_ms: 220 })], estado("x", "y")),
    conRefs("T10c · cambiar la forma de pago de P1 contra cancelar su boleta, la boleta retenida",
      100, "select conc.t10_cobrado_setup() as c", retiene("pedidos", "pedido"), [cancelar, forma], estado("pedido")),
    conRefs("T10d · el DELETE REST de P1 (admin) contra cancelar su boleta, la boleta retenida",
      100, "select conc.t10_cobrado_setup() as c", retiene("pedidos", "pedido"), [cancelar, borrar], estado("pedido")),
    conVerify("T10e · marcar_pagos_masivo([b,d]) contra marcar_entregas_masivo([a,c]), cruzados sobre dos rutas, r1 retenida",
      100, "select conc.t10_rutas_setup() as c", retiene("recorridos", "r1", "no key update"), [entregarAC, masivoPagos("b,d", "{{c.enc2}}")], verRutas),
    conRefs("T10f · FIFO de 100 (Y, X por fecha) contra marcar_pagos_masivo([X,Y]) del mismo cliente, X retenida",
      100, "select conc.t10_fifo_setup() as c", retiene("pedidos", "x"), [masivoPagos("x,y", "{{c.enc}}"), fifo(100)], estado("x", "y")),
    conRefs("T10f2 · lo mismo con el FIFO combinado",
      100, "select conc.t10_fifo_setup() as c", retiene("pedidos", "x"), [masivoPagos("x,y", "{{c.enc}}"), combinado(100)], estado("x", "y")),
    conVerify("T10g · FIFO de 100 sobre [b,d] contra marcar_entregas_masivo([a,c]), cruzados sobre dos rutas, r1 retenida",
      100, "select conc.t10_rutas_setup() as c", retiene("recorridos", "r1", "no key update"), [entregarAC, fifo(100)], verRutas),
    conRefs("T10h · eliminar_pedido_completo de X (dos pagos del día, P1 editado) contra confirmar la rendición de ese día, P1 retenido",
      20, "select conc.t10_foto_setup('eliminar') as c", retiene("pagos", "p1"), [confirmar, eliminar], estado("pedido"), [verFoto]),
    conRefs("T10i · anular una NC con dos créditos del día (P1 editado) contra confirmar la rendición, P1 retenido",
      20, "select conc.t10_foto_setup('anular') as c", retiene("pagos", "p1"), [confirmar, anular], ncEstado, [verFoto]),
    conRefs("T10j · un FIFO que aplica dos créditos (uno de D - 1 que cae en D, #1328) contra confirmar la rendición de D, P1 retenido",
      20, "select conc.t10_foto_setup('aplicar') as c", retiene("pagos", "p1"), [confirmar, fifo(10)], estado("pedido"), [verFoto]),
    conVerify("T10k · registrar_ingreso_sucursal([B,A]) contra una venta [A,B], A retenido",
      100, "select conc.c3_setup(2, 10) as c", retiene("productos", "pa"),
      [w("venta [A,B]", "{{c.p1}}", SA, [ventaSql("cli1", "{{c.p1}}", ["pa", "pb"], 1)]), ingreso], verStock(["pa", "pb"], 10, ingresado)),
    conVerify("T10l · aceptar un envío de B emparejado al revés (dY antes que dX) contra una venta [dX,dY] en A, dX retenido",
      100, "select conc.t10_mov_setup() as c", retiene("productos", "dx"),
      [w("venta [dX,dY]", "{{c.p1}}", SA, [ventaSql("cli1", "{{c.p1}}", ["dx", "dy"], 1)]), aceptar],
      [...verStock(["dx", "dy"], 10, () => aceptado), ...verStock(["oa", "ob"], 10, () => `-${aceptado}`)]),
  ];
}

// ----- T10r --------------------------------------------------------------
// Lo que la tarjeta 10 midió y no es suyo (#1446). Editar una boleta que cambia el total toma la boleta, su ruta y
// el cliente (trigger_actualizar_saldo_pedido) y recién después, por zzz_pedidos_reconciliar_pagos, los créditos y las
// otras boletas que pagan. Un camino que toma otra boleta del cliente y después el cliente (imputar un crédito, un cobro)
// se cruza con ella en cualquier orden de sus locks. Acá se retiene el cliente: la edición queda en cola con X tomada y
// la imputación toma Y y C antes de pedirlo. Da 40P01 antes y después de la migración de la tarjeta 10.
function t10r() {
  const SA = "{{c.suc}}";
  const verX = `select true as ok, conc.estado_pagos({{c.cli}}::bigint) as msg`;
  return [{
    nombre: "T10b2 · imputar C a Y contra editar X del mismo cliente, con el cliente retenido (la edición lo tiene antes que Y y C)",
    rondas: 50,
    spec: {
      modo: "rondas", setup: ["select conc.t10_credito_setup(true) as c"], sample_ms: 3, verify: [verX],
      workers: [
        w("retiene el cliente", null, null, ["select id as retenido from public.clientes where id = {{c.cli}}::bigint for no key update", dormir(0.25)]),
        w("editar X 100→120", ADMIN, SA,
          [`select public.actualizar_pedido_items({{c.x}}::bigint, jsonb_build_array(jsonb_build_object('producto_id', {{c.relleno}}, 'cantidad', 120, 'precio_unitario', 1)), '{{c.admin}}'::uuid, null, null) as r`],
          { delay_ms: 30, jitter_ms: 4 }),
        w("imputar C→Y", ADMIN, SA, ["select public.imputar_credito_a_pedido({{c.c}}::bigint, {{c.y}}::bigint, null, null) as r"], { delay_ms: 90, jitter_ms: 4 }),
      ],
    },
    esperado: (err) => err.code === "22023",
  }];
}

// ----- T13 ---------------------------------------------------------------
// #1446 (plan #1378 tarjeta 13). Un UPDATE OF total de una boleta X corría sus triggers AFTER en orden de nombre: las
// rutas de X, el cliente (trigger_actualizar_saldo_pedido) y recién al final, por zzz_pedidos_reconciliar_pagos, los
// pagos de X, las otras boletas que los créditos pagan y los créditos. Un camino que toma otra boleta Y del cliente y
// después el cliente se cruzaba con ella. Y la edición tomaba X al entrar y llegaba a Y recién en el trigger: con Y de
// id menor, un FIFO (Y, X por id desde la 454) también se cruzaba. T10b2 (t10r) es la misma medición con la
// imputación; acá se suman el cobro suelto, la baja de una boleta cobrada (el cliente lo toma
// desafectar_sobrepago_pedido, antes que aplicar), la salvedad, la corrida sin forzar, Y < X contra el FIFO y contra
// imputar, el vale blanco (un camino que cambia el total por otro lado) y dos ediciones del mismo cliente. Las
// forzadas retienen el cliente (o el producto) 250 ms: la edición entra a los 30 ms y el otro camino a los 90.
function t13() {
  const SA = "{{c.suc}}";
  const retiene = w("retiene el cliente", null, null,
    ["select id as retenido from public.clientes where id = {{c.cli}}::bigint for no key update", dormir(0.25)]);
  const primero = (x) => ({ ...x, delay_ms: 30, jitter_ms: 4 });
  const segundo = (x) => ({ ...x, delay_ms: 90, jitter_ms: 4 });
  const editar = (ped, n) => w(`editar ${ped.toUpperCase()} 100→${n}`, ADMIN, SA,
    [`select public.actualizar_pedido_items({{c.${ped}}}::bigint, jsonb_build_array(jsonb_build_object('producto_id', {{c.relleno}}, 'cantidad', ${n}, 'precio_unitario', 1)), '{{c.admin}}'::uuid, null, null) as r`]);
  const salvedad = w("salvedad de 20 en X (cliente_rechaza)", ADMIN, SA,
    ["select conc.t10_exigir(public.registrar_salvedad({{c.x}}::bigint, {{c.xi}}::bigint, 20, 'cliente_rechaza', 'conc', null, true, null)) as r"]);
  const imputar = w("imputar C→Y", ADMIN, SA, ["select public.imputar_credito_a_pedido({{c.c}}::bigint, {{c.y}}::bigint, null, null) as r"]);
  const cobrar = w("cobrar 50 de Y", ADMIN, SA, [cobroSql(50, "{{c.y}}")]);
  const cobrarW = w("cobrar 50 de W", ADMIN, SA, [cobroSql(50, "{{c.w}}")]);
  const fifo = w("FIFO 150", ADMIN, SA, [fifoSql(150)]);
  const aVB = w("pasar X a vale blanco", ADMIN, SA,
    ["select conc.t10_exigir(public.cambiar_tipo_factura_pedido({{c.x}}::bigint, 'VB', '{{c.admin}}'::uuid)) as r"]);
  // cambiar_tipo_factura_pedido reescribe las líneas de X antes de cambiarle el total: retener una fuerza la ventana.
  const retieneLinea = w("retiene la línea de X", null, null,
    ["select id as retenido from public.pedido_items where id = {{c.xi}}::bigint for update", dormir(0.25)]);
  const retieneProducto = w("retiene el producto", null, null,
    ["select id as retenido from public.productos where id = {{c.relleno}}::bigint for update", dormir(0.25)]);
  // El cliente cierra (boletas y saldo), y X quedó con el total que pidió la edición.
  const cierra = (totalX) => [
    `select (conc.t13_cierra({{c.cli}}::bigint) = '') as ok,
            coalesce(nullif(conc.t13_cierra({{c.cli}}::bigint), ''), 'cierra') || ' [' || conc.estado_pagos({{c.cli}}::bigint) || ']' as msg`,
    `select (total = ${totalX}) as ok, 'total de X=' || total as msg from public.pedidos where id = {{c.x}}::bigint`,
  ];
  // La imputación que llega tarde encuentra el crédito ya aplicado por la edición: 22023.
  const deNegocio = (err) => err.code === "22023";
  const forzada = (nombre, setup, otro, verify, rondas = 100) => ({
    nombre, rondas, esperado: deNegocio,
    spec: { modo: "rondas", setup: [setup], sample_ms: 3, verify, workers: [retiene, primero(otro[0]), segundo(otro[1])] },
  });
  const porProducto = (nombre, setup, otro, verify, rondas = 100, ret = retieneProducto) => ({
    nombre, rondas, esperado: deNegocio,
    spec: { modo: "rondas", setup: [setup], sample_ms: 3, verify, workers: [ret, primero(otro[0]), segundo(otro[1])] },
  });
  const verVB = "select (tipo_factura = 'VB') as ok, 'X=' || tipo_factura || '/' || total || '/' || monto_pagado as msg from public.pedidos where id = {{c.x}}::bigint";
  return [
    forzada("T13a · imputar C a Y contra subir X, el cliente retenido (T10b2)",
      "select conc.t13_setup(false) as c", [editar("x", 120), imputar], cierra(120)),
    forzada("T13b · el cobro suelto de Y contra subir X, el cliente retenido",
      "select conc.t13_setup(false) as c", [editar("x", 120), cobrar], cierra(120)),
    forzada("T13c · imputar C a Y contra bajar X cobrada (desafectar recorta antes de aplicar), el cliente retenido",
      "select conc.t13_setup(true) as c", [editar("x", 80), imputar], cierra(80)),
    forzada("T13d · el cobro suelto de Y contra una salvedad de X cobrada, el cliente retenido",
      "select conc.t13_setup(true) as c", [salvedad, cobrar], cierra(80)),
    {
      nombre: "T13e · imputar C a Y contra subir X, sin forzar (arrancan juntas)", rondas: 100, esperado: deNegocio,
      spec: { modo: "rondas", setup: ["select conc.t13_setup(false) as c"], sample_ms: 3, verify: cierra(120),
              workers: [{ ...editar("x", 120), jitter_ms: 4 }, { ...imputar, jitter_ms: 4 }] },
    },
    // X antes que las demás boletas. La edición toma X al entrar y llega a Y recién en el trigger; desde la 454 el FIFO
    // toma las boletas del cliente por id. Con Y < X, FIFO (Y, X) contra la edición (X, Y). Se fuerza reteniendo el
    // producto, que la edición pide después de X (el pre-bloqueo de productos de actualizar_pedido_items y de
    // registrar_salvedad): la edición queda en cola con X tomada y el FIFO toma Y antes de pedir X. Un FIFO de 150 y el
    // crédito de 30 alcanzan a las dos boletas. Con Y > X, el FIFO pide X primero y espera.
    porProducto("T13g · el FIFO de 150 contra subir X, con Y < X, el producto retenido",
      "select conc.t13_setup(false, 30, true) as c", [editar("x", 120), fifo], cierra(120)),
    porProducto("T13h · el FIFO de 150 contra subir X, con Y > X, el producto retenido",
      "select conc.t13_setup(false, 30, false) as c", [editar("x", 120), fifo], cierra(120)),
    porProducto("T13i · imputar C a Y contra subir X, con Y < X, el producto retenido",
      "select conc.t13_setup(false, 30, true) as c", [editar("x", 120), imputar], cierra(120)),
    porProducto("T13j · el FIFO de 150 contra una salvedad de X, con Y < X, el producto retenido",
      "select conc.t13_setup(false, 30, true) as c", [salvedad, fifo], cierra(80)),
    // Pasar a vale blanco (cambiar_tipo_factura_pedido) también cambia el total: lo lleva a costo. T13k, contra el
    // cliente; T13l, Y < X contra el FIFO, con la línea de X retenida.
    forzada("T13k · imputar C a Y contra pasar X a vale blanco, el cliente retenido",
      "select conc.t13_vb_setup() as c", [aVB, imputar], [cierra(0)[0], verVB]),
    porProducto("T13l · el FIFO de 150 contra pasar X a vale blanco, con Y < X, la línea de X retenida",
      "select conc.t13_vb_setup(true) as c", [aVB, fifo], [cierra(0)[0], verVB], 100, retieneLinea),
    // La ruta: W es del cliente y comparte la ruta R con Y, pero el crédito no la alcanza (los pre-bloqueos no la toman).
    // Cobrar W toma W, R y el cliente; la edición llega a R por los recorridos de Y. Si la reconciliación corre después
    // del saldo, la edición tiene el cliente cuando pide R: es lo que cubre el orden del trigger.
    forzada("T13m · cobrar W (en la ruta de Y, fuera del alcance del crédito) contra subir X, el cliente retenido",
      "select conc.t13_ruta_setup() as c", [editar("x", 120), cobrarW], cierra(120)),
    // Dos ediciones del mismo cliente con un crédito de 150 que alcanza a las dos: cada una tomaba su boleta al entrar
    // y pedía la otra en el trigger. Arrancan juntas: el cruce no necesita forzarse.
    {
      nombre: "T13f · editar X y editar Y del mismo cliente a la vez, con un crédito que alcanza a las dos", rondas: 100,
      spec: { modo: "rondas", setup: ["select conc.t13_setup(false, 150) as c"], sample_ms: 3,
              verify: [cierra(120)[0]],
              workers: [{ ...editar("x", 120), jitter_ms: 4 }, { ...editar("y", 110), jitter_ms: 4 }] },
    },
  ];
}

// ----- T14 ---------------------------------------------------------------
// Tarjeta 14 de #1378 (#1460): los caminos de stock y promos que no seguían el orden global, productos (con sus
// contenedores) por id → promos por id. La venta (455) lo sigue: bloquea productos y contenedores, y después sus promos.
// Las forzadas retienen 250 ms la fila que la venta pide primero (el contenedor C, el producto A o la promo P1): la
// venta entra a los 30 ms y queda en cola ahí, y la otra a los 90 ms. Si la otra tomara algo que la venta pide después,
// al soltarla se esperan. En C4 la que retiene es la propia operación, al final: el trigger diferido del límite de usos
// toma la promo recién al confirmar. Los casos están en conc.t14_* (fixtures.sql). Ninguna gasta días.
function t14() {
  const SA = "{{c.suc}}";
  const exigeOk = "select case when '{{r.success}}' = 'true' then true else (1 / 0)::boolean end as rpc_ok";
  const primero = (x) => ({ ...x, delay_ms: 30, jitter_ms: 4 });
  const segundo = (x) => ({ ...x, delay_ms: 90, jitter_ms: 4 });
  const retiene = (tabla, clave) =>
    w(`retiene ${clave}`, null, null, [`select id as retenido from public.${tabla} where id = {{c.${clave}}}::bigint for update`, dormir(0.25)]);
  const linea = (p, cant, promo) =>
    `jsonb_build_object('producto_id', {{c.${p}}}, 'cantidad', ${cant}, 'precio_unitario', ${promo ? 0 : 100}${promo ? `, 'es_bonificacion', true, 'promocion_id', {{c.${promo}}}` : ""})`;
  const lineas = (ls) => `jsonb_build_array(${ls.map((l) => linea(...l)).join(", ")})`;
  const venta = (label, uid, cli, ls) => {
    const total = ls.filter((l) => !l[2]).reduce((s, l) => s + 100 * l[1], 0);
    return w(label, uid, SA, [`select public.crear_pedido_completo({{c.${cli}}}::bigint, ${total}, '${uid}'::uuid, ${lineas(ls)}, 'conc') as r`, exigeOk]);
  };
  const editar = (label, ls) =>
    w(label, ADMIN, SA, [`select public.actualizar_pedido_items({{c.x}}::bigint, ${lineas(ls)}, '{{c.admin}}'::uuid, null, null) as r`, exigeOk]);

  // Estado normalizado (para comparar contra los órdenes seriales) y la variante con sus referencias.
  const prods = (ps) => ps.map((p) => `conc.estado_prod({{c.${p}}})`).join(" || ';' || ");
  const vivas = `from public.pedido_items pi join public.pedidos pe on pe.id = pi.pedido_id where pe.estado <> 'cancelado'`;
  const verFn = (estado) => `select true as ok, 'ESTADO=' || ${estado} as msg`;
  const verMain = (estado) =>
    `select position('|ESTADO=' || q.s || '|' in '|{{refs}}|') > 0 as ok, 'estado=' || q.s as msg from (select ${estado} as s) q`;
  const mk = (nombre, rondas, setup, workers, refWorkers, estado, { extra = [], esperado = esDeNegocio() } = {}) => {
    const base = { modo: "rondas", setup: [setup], sample_ms: 4 };
    return {
      nombre, rondas, esperado,
      spec: { ...base, workers },
      referencias: referencias(base, refWorkers, verFn(estado)),
      verify: [verMain(estado), ...extra],
    };
  };
  const forzar = (ret, a, b) => [ret, primero(a), segundo(b)];
  const juntas = (a, b) => [{ ...a, jitter_ms: 3 }, { ...b, jitter_ms: 3 }];

  // C2 y C5 (conc.t14_setup): la promo P con su contenedor C (C < A < B < S) y X, una venta de A con su regalo.
  const barra = "(select coalesce(usos_pendientes, 0) || '/' || coalesce(unidades_por_bloque, 0) from public.promociones where id = {{c.promo}})";
  const estadoP = `${prods(["pc", "pa", "pb", "ps"])} || ';barra=' || ${barra}
      || ';ventas=' || (select count(distinct pi.pedido_id) ${vivas} and pi.promocion_id = {{c.promo}})
      || ';X=' || coalesce((select estado || '/' || total from public.pedidos where id = {{c.x}}::bigint), 'borrado')`;
  // La barra y el contenedor cierran: lo que salió de C es lo que cerró la barra (bloques de stock_por_bloque) más lo
  // que se ajustó a mano, según promo_ajustes.
  const verContenedor = `select (20 - c.stock = a.unidades) as ok, format('contenedor %s, ajustado %s (inicial 20)', c.stock, a.unidades) as msg
                           from (select stock from public.productos where id = {{c.pc}}) c,
                                (select coalesce(sum(unidades_ajustadas), 0) as unidades from public.promo_ajustes
                                  where promocion_id = {{c.promo}} and producto_id = {{c.pc}}) a`;
  const ventaB = venta("venta de B con su regalo", "{{c.admin2}}", "cli2", [["pb", 10], ["ps", 2, "promo"]]);
  const ventaA = venta("venta de A con su regalo", "{{c.admin2}}", "cli2", [["pa", 10], ["ps", 2, "promo"]]);
  const ajustar = w("ajustar 1 de C por la promo (1 uso)", ADMIN, SA,
    ["select conc.t10_exigir(public.ajustar_stock_promocion_completo({{c.promo}}::bigint, {{c.pc}}::bigint, 1, 1, '{{c.admin}}'::uuid, 'conc')) as r"]);
  const factor = w("cambiar el factor de la promo por REST (2 → 1)", ADMIN, SA,
    ["update public.promociones set unidades_por_bloque = 1 where id = {{c.promo}}::bigint returning id as cambiado"]);
  // eliminar_pedido_completo no tiene EXECUTE para authenticated (ningún camino de la app borra un pedido): corre como el
  // server, con el admin en los claims, como en T10.
  const eliminar = w("eliminar X restaurando el stock (server)", null, null, [
    `select set_config('request.jwt.claims', json_build_object('sub','{{c.admin}}','role','authenticated')::text, true) as cl,
            set_config('request.headers', json_build_object('x-sucursal-id','{{c.suc}}')::text, true) as hd`,
    "select conc.t10_exigir(public.eliminar_pedido_completo({{c.x}}::bigint, '{{c.admin}}'::uuid, 'conc', true)) as r"]);
  const retC = retiene("productos", "pc");

  // C3 (conc.t14k_setup): P1 < P2. La venta lleva los regalos de las dos y bloquea P1 y P2 por id. La edición de X no
  // comparte productos con ella: con X ya en P2, toma P2 al devolver la barra vieja y P1 recién en el bucle de las líneas
  // nuevas; sin regalos en X, las toma en el orden del JSON (P2 antes).
  const estadoK = `${prods(["a1", "b1", "a2", "b2", "r1a", "r1b", "r2a", "r2b"])}
      || ';P1=' || (select coalesce(usos_pendientes, 0) from public.promociones where id = {{c.promo1}})
      || ';P2=' || (select coalesce(usos_pendientes, 0) from public.promociones where id = {{c.promo2}})
      || ';X=' || (select estado || '/' || total from public.pedidos where id = {{c.x}}::bigint)`;
  const ventaK = venta("venta [b1, P1, b2, P2]", "{{c.admin2}}", "cli2", [["b1", 10], ["r1b", 2, "promo1"], ["b2", 10], ["r2b", 2, "promo2"]]);
  const editarK = editar("editar X: [a1, P1, a2, P2]", [["a1", 10], ["r1a", 2, "promo1"], ["a2", 10], ["r2a", 2, "promo2"]]);
  const editarKInv = editar("editar X: [a2, P2, a1, P1]", [["a2", 10], ["r2a", 2, "promo2"], ["a1", 10], ["r1a", 2, "promo1"]]);
  const retP1 = retiene("promociones", "promo1");

  // C4 (conc.t14m_setup): P cambió de tipo con X abierta. La salvedad y la edición de X bajan el total (el saldo toma el
  // cliente) y tocan el regalo, y al confirmar trg_limite_usos_promo pide P. La venta al mismo cliente toma P y después el
  // cliente. La operación retiene sus locks 250 ms al final, antes de confirmar.
  const estadoM = `${prods(["pa", "pb", "s1", "s2"])}
      || ';X=' || (select estado || '/' || total from public.pedidos where id = {{c.x}}::bigint)
      || ';regalo X=' || (select coalesce(sum(cantidad), 0) from public.pedido_items where pedido_id = {{c.x}}::bigint and es_bonificacion)
      || ';saldo=' || (select saldo_cuenta from public.clientes where id = {{c.cli}}::bigint)
      || ';pedidos=' || (select count(*) from public.pedidos where cliente_id = {{c.cli}}::bigint)`;
  const ventaM = venta("venta de B con 1 de regalo s2 al mismo cliente", "{{c.admin2}}", "cli", [["pb", 5], ["s2", 1, "promo"]]);
  const salvedadM = w("salvedad de 5 de A en X (cliente_rechaza): el regalo baja a 1", ADMIN, SA,
    ["select conc.t10_exigir(public.registrar_salvedad({{c.x}}::bigint, {{c.xi}}::bigint, 5, 'cliente_rechaza', 'conc', null, true, null)) as r"]);
  const editarM = editar("editar X: A 10 → 5 y el regalo 2 → 1", [["pa", 5], ["s1", 1, "promo"]]);
  const reteniendo = (x) => ({ ...x, label: `${x.label} (retiene 250 ms)`, steps: [...x.steps, dormir(0.25)] });
  const despues = (x) => ({ ...x, delay_ms: 60, jitter_ms: 4 });
  // Los otros caminos que hacen UPDATE de la cantidad de una línea (conc.t14n_setup: X de 12 de A con una salvedad de 2
  // ya registrada, y la promo cambió de tipo después). anular_salvedad rechaza todo lo que toque un regalo de promo
  // (anulacion_toca_promociones), así que nunca dispara el trigger; sustituir y dividir no cambian el total ni toman el
  // cliente. Se miden igual, con la misma forma que T14j.
  const estadoN = `${estadoM} || ';' || conc.estado_prod({{c.s3}})`;
  const anularN = w("anular la salvedad de 2 de A", ADMIN, SA, ["select conc.t10_exigir(public.anular_salvedad({{c.sv}}::bigint, 'conc')) as r"]);
  const sustituirN = w("sustituir el regalo de X por 2 de s3", ADMIN, SA,
    ["select conc.t10_exigir(public.sustituir_regalo_pedido({{c.xr}}::bigint, {{c.s3}}::bigint, 2, 'conc')) as r"]);
  const dividirN = w("repartir el regalo de X en s1 y s3", ADMIN, SA,
    [`select conc.t10_exigir(public.dividir_regalo_pedido({{c.xr}}::bigint, jsonb_build_array(
        jsonb_build_object('producto_id', {{c.s1}}, 'cantidad', 1), jsonb_build_object('producto_id', {{c.s3}}, 'cantidad', 1)), 'conc')) as r`]);

  // C8 (conc.t14p_setup): actualizar_precios_masivo con [B, A] contra una venta de A y B.
  const estadoPr = `${prods(["pa", "pb"])} || ';precios=' || (select string_agg(precio::text, ',' order by id) from public.productos where id in ({{c.pa}}, {{c.pb}}))`;
  const masivo = w("precios masivos [B, A]", ADMIN, SA,
    [`select conc.t14_exigir_masivo(public.actualizar_precios_masivo(jsonb_build_array(
        jsonb_build_object('producto_id', {{c.pb}}, 'precio_final', 120), jsonb_build_object('producto_id', {{c.pa}}, 'precio_final', 110)))) as r`]);
  const ventaPr = venta("venta [A, B]", "{{c.admin2}}", "cli", [["pa", 1], ["pb", 1]]);
  const verPrecios = `select (string_agg(precio::text, ',' order by id) = '110.00,120.00') as ok, 'precios=' || string_agg(precio::text, ',' order by id) as msg
                        from public.productos where id in ({{c.pa}}, {{c.pb}})`;
  const retA = retiene("productos", "pa");

  const S0 = "select conc.t14_setup() as c";
  const S1 = "select conc.t14_setup(1) as c";
  return [
    mk("T14a · C2: ajustar el stock de la promo (P → C) contra una venta (C → P), con C retenido", 100, S1,
      forzar(retC, ventaB, ajustar), [ventaB, ajustar], estadoP, { extra: [verContenedor] }),
    mk("T14b · C2: lo mismo, arranque simultáneo", 200, S1, juntas(ventaB, ajustar), [ventaB, ajustar], estadoP, { extra: [verContenedor] }),
    mk("T14c · C2: cambiar el factor por REST (P, y C en el trigger) contra una venta, con C retenido", 100, S1,
      forzar(retC, ventaB, factor), [ventaB, factor], estadoP, { extra: [verContenedor] }),
    mk("T14d · C2: lo mismo, arranque simultáneo", 200, S1, juntas(ventaB, factor), [ventaB, factor], estadoP, { extra: [verContenedor] }),
    mk("T14e · C5: eliminar X (A, P, C) contra una venta de B (C, B, S, P), con C retenido", 100, S0,
      forzar(retC, ventaB, eliminar), [ventaB, eliminar], estadoP, { extra: [verContenedor] }),
    mk("T14f · C5: eliminar X contra una venta de A (C, A, S, P), con C retenido", 100, S0,
      forzar(retC, ventaA, eliminar), [ventaA, eliminar], estadoP, { extra: [verContenedor] }),
    mk("T14g · C3: editar X (ya en P2) agregando P1, contra una venta de P1 y P2, con P1 retenida", 100,
      "select conc.t14k_setup(true) as c", forzar(retP1, ventaK, editarK), [ventaK, editarK], estadoK),
    mk("T14h · C3: editar X (sin regalos) con [P2, P1] en el JSON, contra una venta de P1 y P2, con P1 retenida", 100,
      "select conc.t14k_setup(false) as c", forzar(retP1, ventaK, editarKInv), [ventaK, editarKInv], estadoK),
    mk("T14i · C3: editar X (ya en P2) agregando P1 contra la venta, arranque simultáneo", 200,
      "select conc.t14k_setup(true) as c", juntas(ventaK, editarK), [ventaK, editarK], estadoK),
    mk("T14j · C4: una salvedad en X (la promo cambió de tipo) retiene 250 ms y llega la venta al mismo cliente", 100,
      "select conc.t14m_setup() as c", [reteniendo(salvedadM), despues(ventaM)], [salvedadM, ventaM], estadoM),
    mk("T14k · C4: lo mismo con la edición de X", 100,
      "select conc.t14m_setup() as c", [reteniendo(editarM), despues(ventaM)], [editarM, ventaM], estadoM),
    mk("T14n · C4: anular una salvedad de X retiene 250 ms y llega la venta al mismo cliente", 100,
      "select conc.t14n_setup() as c", [reteniendo(anularN), despues(ventaM)], [anularN, ventaM], estadoN),
    mk("T14o · C4: sustituir el regalo de X retiene 250 ms y llega la venta al mismo cliente", 100,
      "select conc.t14n_setup() as c", [reteniendo(sustituirN), despues(ventaM)], [sustituirN, ventaM], estadoN),
    mk("T14p · C4: repartir el regalo de X retiene 250 ms y llega la venta al mismo cliente", 100,
      "select conc.t14n_setup() as c", [reteniendo(dividirN), despues(ventaM)], [dividirN, ventaM], estadoN),
    mk("T14l · C8: precios masivos [B, A] contra una venta [A, B], con A retenido", 100,
      "select conc.t14p_setup() as c", forzar(retA, ventaPr, masivo), [ventaPr, masivo], estadoPr, { extra: [verPrecios] }),
    mk("T14m · C8: lo mismo, arranque simultáneo", 200,
      "select conc.t14p_setup() as c", juntas(ventaPr, masivo), [ventaPr, masivo], estadoPr, { extra: [verPrecios] }),
  ];
}

// ----- T6 ----------------------------------------------------------------
// #1473 (plan #1477 tarjeta 6). Salen de leer los cuerpos vivos del 06/11.
//   ADV-1 · editar Y (de C2, cobrada) toma Y, P y después la ruta de Y y los créditos de C2; pasar X (de C1, cobrada) a
//           C2 con 'pedido_nuevo' tomaba en la 459 X, su ruta y los pagos (los de X y los créditos de C2) antes que P.
//           Se fuerza reteniendo P: la edición queda en cola en P y el cambio llega a los pagos y a la ruta antes de
//           pedirlo.
//   ADV-5 · pasar X (A con el regalo S) a C2 con B y el regalo: la cancelación toma A y S, y el pedido nuevo B recién
//           después. Una venta de B y S toma B y después S. Se fuerza reteniendo B.
//   ADV-2 · cambiar el regalo de una promo a Q: por REST, el UPDATE tiene la promo cuando la FK pide Q; una venta que
//           lleva Q toma Q y después la promo. Se fuerza reteniendo Q. Después de la tarjeta 6 esas columnas no se
//           escriben por REST (42501) y el cambio va por cambiar_regalo_promocion.
//   ADV-3 · precios masivos [B, A] con A trabado 9 s (en dos sueños de 4,5 s, cada uno debajo del statement_timeout) y los
//           timeouts de PostgREST (8 s): la 460 esperaba el lock del lote entero y caía; ahora A se saltea y B cambia.
// Las forzadas retienen la fila 250 ms; el primero entra a los 30 ms y el segundo a los 90.
function t6() {
  const SA = "{{c.suc}}";
  const retiene = (clave, seg = 0.25) => w(`retiene ${clave}`, null, null,
    [`select id as retenido from public.productos where id = {{c.${clave}}}::bigint for update`, dormir(seg)]);
  const primero = (x) => ({ ...x, delay_ms: 30, jitter_ms: 4 });
  const segundo = (x) => ({ ...x, delay_ms: 90, jitter_ms: 4 });
  const juntos = (x) => ({ ...x, jitter_ms: 4 });
  const exige = (sql) => `select conc.t10_exigir(${sql}) as r`;
  const linea = (p, cant, precio, promo) =>
    `jsonb_build_object('producto_id', {{c.${p}}}, 'cantidad', ${cant}, 'precio_unitario', ${precio}${promo ? `, 'es_bonificacion', true, 'promocion_id', {{c.${promo}}}` : ""})`;
  const lineas = (ls) => `jsonb_build_array(${ls.map((l) => linea(...l)).join(", ")})`;
  const total = (ls) => ls.filter((l) => !l[3]).reduce((s, l) => s + l[1] * l[2], 0);
  const cambiar = (ls, label) => w(label, ADMIN, SA,
    [exige(`public.cambiar_cliente_pedido({{c.x}}::bigint, {{c.c2}}::bigint, '{{c.admin}}'::uuid, ${lineas(ls)}, ${total(ls)}, null, 0, 'conc', 'pedido_nuevo')`)]);
  const venta = (label, cli, ls) => w(label, "{{c.admin2}}", SA,
    [exige(`public.crear_pedido_completo({{c.${cli}}}::bigint, ${total(ls)}, '{{c.admin2}}'::uuid, ${lineas(ls)}, 'conc')`)]);
  const cierra = (cli) =>
    `select (conc.t13_cierra({{c.${cli}}}::bigint) = '') as ok,
            coalesce(nullif(conc.t13_cierra({{c.${cli}}}::bigint), ''), '${cli} cierra') || ' [' || conc.estado_pagos({{c.${cli}}}::bigint) || ']' as msg`;
  const stock = (p) =>
    `select (conc.stock_cierra({{c.${p}}}, 100) is null) as ok,
            coalesce(conc.stock_cierra({{c.${p}}}, 100), '${p} cierra') || ' [' || conc.estado_prod({{c.${p}}}) || ']' as msg`;
  const cancelado = `select (estado = 'cancelado') as ok, 'X=' || estado || ' ' || coalesce(motivo_cancelacion, '') as msg from public.pedidos where id = {{c.x}}::bigint`;
  const totalY = `select (total = 80) as ok, 'total de Y=' || total as msg from public.pedidos where id = {{c.y}}::bigint`;
  const ventas = (cli, n) =>
    `select (count(*) = ${n}) as ok, 'pedidos vivos de ${cli}=' || count(*) as msg from public.pedidos where cliente_id = {{c.${cli}}}::bigint and estado <> 'cancelado'`;
  const regalo = (col, p) =>
    `select (${col} = {{c.${p}}}) as ok, '${col}=' || coalesce(${col}::text, 'null') as msg from public.promociones where id = {{c.promo}}::bigint`;
  const variante = (nombre, setup, workers, verify, { rondas = 100, esperado = esDeNegocio(), extra = {} } = {}) => ({
    nombre, rondas, esperado, spec: { modo: "rondas", setup: [setup], sample_ms: 3, verify, workers, ...extra },
  });

  // ADV-1
  const editarY = w("editar Y: P 10 → 8", ADMIN, SA,
    [`select public.actualizar_pedido_items({{c.y}}::bigint, jsonb_build_array(jsonb_build_object('producto_id', {{c.p}}, 'cantidad', 8, 'precio_unitario', 10)), '{{c.admin}}'::uuid, null, null) as r`]);
  const cambiarP = cambiar([["p", 10, 10]], "pasar X a C2 con 10 de P ('pedido_nuevo')");
  const ver1 = [cierra("c1"), cierra("c2"), totalY, cancelado, stock("p")];

  // ADV-5
  const cambiarB = cambiar([["pb", 10, 100], ["ps", 2, 0, "promo"]], "pasar X a C2 con 10 de B y el regalo");
  const ventaB = venta("venta de 10 de B con el regalo a otro cliente", "cli3", [["pb", 10, 100], ["ps", 2, 0, "promo"]]);
  const ver5 = [cancelado, ventas("c2", 1), ventas("cli3", 1), stock("pa"), stock("pb"), stock("ps")];

  // ADV-2
  const ventaQ = venta("venta de A con el regalo y 1 de Q", "cli", [["pa", 10, 100], ["ps", 2, 0, "promo"], ["pq", 1, 100]]);
  const restRegalo = w("cambiar el regalo a Q por REST", ADMIN, SA,
    ["update public.promociones set producto_regalo_id = {{c.pq}} where id = {{c.promo}}::bigint returning id as cambiado"]);
  const rpcRegalo = w("cambiar el regalo a Q por cambiar_regalo_promocion", ADMIN, SA,
    [exige("public.cambiar_regalo_promocion({{c.promo}}::bigint, {{c.pq}}::bigint, null, false)")]);
  const rpcContenedor = w("cambiar el contenedor a Q por cambiar_regalo_promocion", ADMIN, SA,
    [exige("public.cambiar_regalo_promocion({{c.promo}}::bigint, {{c.ps}}::bigint, {{c.pq}}::bigint, false)")]);
  const ver2 = [ventas("cli", 1), stock("pa"), stock("ps"), stock("pq")];
  // Después de la tarjeta 6 el UPDATE REST de esas columnas da 42501 en todas las rondas, y es lo esperado.
  const sinGrant = (err) => err.code === "42501";

  // ADV-3
  const reteniendoA = w("retiene A 9 s", null, null,
    ["select id as retenido from public.productos where id = {{c.pa}}::bigint for update", dormir(4.5), dormir(4.5)]);
  const masivo = w("precios masivos [B, A] con los timeouts de PostgREST", ADMIN, SA, [
    "select set_config('lock_timeout', '8s', true) as lt",
    `select conc.t6_exigir_trabado(public.actualizar_precios_masivo(jsonb_build_array(
        jsonb_build_object('producto_id', {{c.pb}}, 'precio_final', 120), jsonb_build_object('producto_id', {{c.pa}}, 'precio_final', 110))), {{c.pa}}::bigint) as r`]);
  const verPrecios = `select (string_agg(precio::text, ',' order by id) = '100.00,120.00') as ok, 'precios=' || string_agg(precio::text, ',' order by id) as msg
                        from public.productos where id in ({{c.pa}}, {{c.pb}})`;

  return [
    variante("T6a · ADV-1: editar Y (de C2, con un crédito K) contra pasar X a C2, P retenido",
      "select conc.t6_cambio_setup(30, false) as c", [retiene("p"), primero(editarY), segundo(cambiarP)], ver1),
    variante("T6b · ADV-1: editar Y (en la ruta de X, sin crédito) contra pasar X a C2, P retenido",
      "select conc.t6_cambio_setup(0, true) as c", [retiene("p"), primero(editarY), segundo(cambiarP)], ver1),
    variante("T6c · ADV-1: editar Y (con crédito y en la ruta de X) contra pasar X a C2, sin forzar (arrancan juntas)",
      "select conc.t6_cambio_setup(30, true) as c", [juntos(editarY), juntos(cambiarP)], ver1, { rondas: 200 }),
    variante("T6d · ADV-5: una venta de B contra pasar X (A) a C2 con B, B retenido",
      "select conc.t6_items_setup() as c", [retiene("pb"), primero(ventaB), segundo(cambiarB)], ver5),
    variante("T6e · ADV-5: lo mismo, sin forzar (arrancan juntas)",
      "select conc.t6_items_setup() as c", [juntos(ventaB), juntos(cambiarB)], ver5, { rondas: 200 }),
    variante("T6f · ADV-2: una venta con Q contra cambiar el regalo a Q por REST, Q retenido (después de la tarjeta 6: 42501)",
      "select conc.t6_promo_setup() as c", [retiene("pq"), primero(ventaQ), segundo(restRegalo)], ver2, { esperado: sinGrant }),
    variante("T6g · ADV-2: una venta con Q contra cambiar el regalo a Q por la RPC, Q retenido",
      "select conc.t6_promo_setup() as c", [retiene("pq"), primero(ventaQ), segundo(rpcRegalo)], [...ver2, regalo("producto_regalo_id", "pq")]),
    variante("T6h · ADV-2: una venta con Q contra cambiar el contenedor a Q por la RPC, Q retenido",
      "select conc.t6_promo_setup() as c", [retiene("pq"), primero(ventaQ), segundo(rpcContenedor)], [...ver2, regalo("ajuste_producto_id", "pq")]),
    variante("T6i · ADV-2: una venta con Q contra cambiar el regalo a Q por la RPC, sin forzar (arrancan juntas)",
      "select conc.t6_promo_setup() as c", [juntos(ventaQ), juntos(rpcRegalo)], [...ver2, regalo("producto_regalo_id", "pq")], { rondas: 200 }),
    variante("T6j · ADV-3: precios masivos [B, A] con A trabado 9 s: B cambia y A se saltea y se nombra",
      "select conc.t14p_setup() as c", [reteniendoA, { ...masivo, delay_ms: 100, jitter_ms: 0 }], [verPrecios],
      { rondas: 5, extra: { statement_timeout_ms: 8000 } }),
  ];
}

// ----- T15 ---------------------------------------------------------------
// #1460 C1, C6 y C7 (plan #1378 tarjeta 15): cobros, cliente y rutas. Salen de leer los cuerpos vivos del 05/11.
//   C1 · editar Y, cobrada, de C2 toma W (otra boleta impaga de C2) por _edicion_bloquea_boletas y después C2 en el
//        saldo; cambiar_cliente_pedido(X → C2, 'pedido_nuevo') con excedente toma C2 en el INSERT del pedido nuevo y
//        después W en aplicar_credito_cliente(C2). Se fuerza reteniendo W: la edición queda en cola en W y el cambio
//        llega a C2 antes de pedirla.
//   C6 · el DELETE REST de un pago de Y contra editar X, del mismo cliente y la misma ruta. Los AFTER de pagos corren
//        por nombre: el del saldo antes que el de monto_pagado. Se fuerza reteniendo la ruta o el cliente.
//   C7 · imputar el crédito C a Y toma Y, C y, por los triggers del UPDATE pagos, el cliente y la ruta de Y. Editar X
//        (misma ruta; el crédito alcanza sólo a Z) toma Z, X, la ruta y después C (pedidos_reconciliar_pagos). Se fuerza
//        reteniendo la ruta: la edición queda en cola en ella y la imputación toma Y y C antes de pedirla.
// Las forzadas retienen la fila 250 ms; el primero entra a los 30 ms y el segundo a los 90.
function t15() {
  const SA = "{{c.suc}}";
  const retiene = (tabla, clave, modo = "update") => w(`retiene ${clave}`, null, null,
    [`select id as retenido from public.${tabla} where id = {{c.${clave}}}::bigint for ${modo}`, dormir(0.25)]);
  const primero = (x) => ({ ...x, delay_ms: 30, jitter_ms: 4 });
  const segundo = (x) => ({ ...x, delay_ms: 90, jitter_ms: 4 });
  const juntos = (x) => ({ ...x, jitter_ms: 4 });
  const editar = (ped, n) => w(`editar ${ped.toUpperCase()} 100→${n}`, ADMIN, SA,
    [`select public.actualizar_pedido_items({{c.${ped}}}::bigint, jsonb_build_array(jsonb_build_object('producto_id', {{c.relleno}}, 'cantidad', ${n}, 'precio_unitario', 1)), '{{c.admin}}'::uuid, null, null) as r`]);
  const salvedadY = w("salvedad de 20 en Y (cliente_rechaza)", ADMIN, SA,
    ["select conc.t10_exigir(public.registrar_salvedad({{c.y}}::bigint, {{c.yi}}::bigint, 20, 'cliente_rechaza', 'conc', null, true, null)) as r"]);
  const cambiar = w("pasar X a C2 con total 80 ('pedido_nuevo')", ADMIN, SA,
    [`select conc.t10_exigir(public.cambiar_cliente_pedido({{c.x}}::bigint, {{c.c2}}::bigint, '{{c.admin}}'::uuid,
       jsonb_build_array(jsonb_build_object('producto_id', {{c.relleno}}, 'cantidad', 80, 'precio_unitario', 1)),
       80, null, 0, 'conc', 'pedido_nuevo')) as r`]);
  const borrar = w("DELETE REST de P1", ADMIN, SA, ["delete from public.pagos where id = {{c.p1}}::bigint returning id as borrado"]);
  const imputar = w("imputar C→Y", ADMIN, SA, ["select public.imputar_credito_a_pedido({{c.c}}::bigint, {{c.y}}::bigint, null, null) as r"]);
  const cierra = (cli) =>
    `select (conc.t13_cierra({{c.${cli}}}::bigint) = '') as ok,
            coalesce(nullif(conc.t13_cierra({{c.${cli}}}::bigint), ''), '${cli} cierra') || ' [' || conc.estado_pagos({{c.${cli}}}::bigint) || ']' as msg`;
  const total = (ped, n) => `select (total = ${n}) as ok, 'total de ${ped.toUpperCase()}=' || total as msg from public.pedidos where id = {{c.${ped}}}::bigint`;
  const cambio = `select (estado = 'cancelado') as ok, 'X=' || estado || ' ' || coalesce(motivo_cancelacion, '') as msg from public.pedidos where id = {{c.x}}::bigint`;
  // La imputación que llega tarde encuentra el crédito ya aplicado por la edición: 22023.
  const deNegocio = (err) => err.code === "22023";
  const variante = (nombre, setup, workers, verify, rondas = 100) => ({
    nombre, rondas, esperado: deNegocio, spec: { modo: "rondas", setup: [setup], sample_ms: 3, verify, workers },
  });
  const verC1 = (totalY) => [cierra("c1"), cierra("c2"), total("y", totalY), cambio];
  const verX = [cierra("cli"), total("x", 120)];
  return [
    variante("T15a · C1: editar Y (cobrada, de C2) contra pasar X a C2 con excedente, W retenida",
      "select conc.t15_cambio_setup() as c", [retiene("pedidos", "w"), primero(editar("y", 120)), segundo(cambiar)], verC1(120)),
    variante("T15b · C1: una salvedad de Y contra pasar X a C2 con excedente, W retenida",
      "select conc.t15_cambio_setup() as c", [retiene("pedidos", "w"), primero(salvedadY), segundo(cambiar)], verC1(80)),
    variante("T15c · C1: editar Y contra pasar X a C2 con excedente, sin forzar (arrancan juntas)",
      "select conc.t15_cambio_setup() as c", [juntos(editar("y", 120)), juntos(cambiar)], verC1(120)),
    variante("T15d · C6: editar X contra el DELETE REST de un pago de Y (misma ruta y cliente), la ruta retenida",
      "select conc.t15_borrar_setup() as c", [retiene("recorridos", "r", "no key update"), primero(editar("x", 120)), segundo(borrar)], verX),
    variante("T15e · C6: el DELETE REST de un pago de Y contra editar X, el cliente retenido",
      "select conc.t15_borrar_setup() as c", [retiene("clientes", "cli", "no key update"), primero(borrar), segundo(editar("x", 120))], verX),
    variante("T15f · C6: el DELETE REST de un pago de Y contra editar X, sin forzar (arrancan juntas)",
      "select conc.t15_borrar_setup() as c", [juntos(borrar), juntos(editar("x", 120))], verX),
    variante("T15g · C7: editar X (el crédito alcanza a Z) contra imputar C a Y, en la misma ruta, la ruta retenida",
      "select conc.t15_imputar_setup() as c", [retiene("recorridos", "r", "no key update"), primero(editar("x", 120)), segundo(imputar)], verX),
    variante("T15h · C7: editar X contra imputar C a Y, sin forzar (arrancan juntas)",
      "select conc.t15_imputar_setup() as c", [juntos(editar("x", 120)), juntos(imputar)], verX),
  ];
}

const T = (titulo, variantes) => ({ titulo, variantes });
export const ESCENARIOS = {
  c1: T("Dos cobros al mismo pedido", c1),
  c2: T("FIFO contra FIFO del mismo cliente", c2),
  c3: T("Dos ventas del mismo producto con stock justo", c3),
  c4: T("Venta contra cancelación y contra edición", c4),
  c5: T("Venta contra control de stock por planilla", c5),
  c6: T("Confirmar una rendición contra partir un pago de ese día", c6),
  c7: T("Reordenar la ruta contra una entrega", c7),
  c8: T("Carga: varias cajas simulando ventas", c8),
  c9: T("Entregar contra confirmar la rendición de ese día y chofer", c9),
  c10: T("Sustituir o dividir un regalo contra una venta", c10),
  c11: T("Editar un pedido en orden inverso contra una venta", c11),
  c12: T("Venta con regalo de una promo con contenedor contra cancelar, editar y otra venta", c12),
  t10: T("Cobros, créditos y stock contra el orden global de locks (tarjeta 10 de #1378)", t10),
  t10r: T("Lo que la tarjeta 10 midió y no es suyo: la edición toma el cliente antes que las otras boletas", t10r),
  t13: T("La edición que cambia el total contra un camino que toma otra boleta del cliente (tarjeta 13 de #1378)", t13),
  t14: T("Stock y promos contra el orden global: productos y contenedores, y las promos después (tarjeta 14 de #1378)", t14),
  t15: T("Cobros, cliente y rutas: cambiar el cliente, borrar un pago e imputar un crédito contra la edición (#1460, tarjeta 15 de #1378)", t15),
  t6: T("El cambio de cliente, los precios en masa y el regalo de una promo en el orden global (#1473, tarjeta 6 de #1477)", t6),
};
