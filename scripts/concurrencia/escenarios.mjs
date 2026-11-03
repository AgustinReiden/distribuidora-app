// Escenarios C1 a C8 del plan #1378 (tarjeta 1, issue #1288).
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
  const c = (nombre, rondas, workers, extra = {}, base = 0, verifies = [ver, ver2]) => ({
    nombre, rondas, spec: { modo: "rondas", setup: ["select conc.c7_setup({{round}} + {{off}}, {{base}}) as c"], workers, verify: verifies, sample_ms: 3, ctx: { base } }, ...extra,
  });
  return [
    c("C7a · reordenar la ruta a [Y,X] contra la entrega de X (el 2.º del nuevo orden)", 250, [reordenar("{{c.enc}}"), entregar("x", "entrega X")]),
    c("C7b · reordenar la ruta a [Y,X] contra la entrega de Y (el 1.º del nuevo orden)", 250, [reordenar("{{c.enc}}"), entregar("y", "entrega Y")]),
    c("C7c · dos encargados reordenan la misma ruta a la vez, en orden inverso", 250, [reordenar("{{c.enc}}"), reordenarXY]),
    c("C7d · marcar_entregas_masivo([X,Y]) contra el reordenamiento a [Y,X]", 150,
      [reordenar("{{c.enc}}"), masivo("masivo [X,Y]", "{{c.enc2}}", "{{c.x}}, {{c.y}}")], {}, 260, [ver, ver2, ver3]),
    c("C7d2 · dos marcar_entregas_masivo con los ids en orden inverso ([X,Y] y [Y,X])", 150,
      [masivo("masivo [X,Y]", "{{c.enc}}", "{{c.x}}, {{c.y}}"), masivo("masivo [Y,X]", "{{c.enc2}}", "{{c.y}}, {{c.x}}")], {}, 420, [ver, ver2, ver3]),
    c("C7e · marcar_entrega_y_pago_masivo([X,Y]) contra el reordenamiento a [Y,X]", 150,
      [reordenar("{{c.enc}}"), masivoPago("{{c.enc2}}")], {}, 580, [ver, ver2, ver3]),
    c("C7f · un cobro suelto de X (registrar_pagos_pedido) contra el reordenamiento a [Y,X]", 150,
      [reordenar("{{c.enc}}"), cobroX], {}, 740, [ver, ver2, ver3]),
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
};
