#!/usr/bin/env node
/**
 * Gate de integridad de datos.
 *
 * Cuatro baterías, las cuatro contra prod con la service_role key:
 *
 *   1. El RPC `auditoria_integridad()` (ver migrations/105): los invariantes de
 *      datos. Falla si hay algún check critical/high en rojo.
 *
 *   2. El criterio de merma (mig 238, issues #570 y #572). Acá NO hay datos que
 *      mirar: se le pasan casos FIJOS a las funciones puras y se compara contra el
 *      valor esperado, que es lo que hacían los 25 casos de
 *      `valorizacionMermas.test.ts` antes de que se borraran junto con el módulo
 *      TS. Ahora el criterio vive en SQL, así que el test tiene que correr contra
 *      la base — no hay arnés de SQL en el repo y este script ya es el lugar donde
 *      CI habla con Postgres.
 *
 *      Y encima de los casos fijos, la invariante que justifica todo el diseño de
 *      la 238:
 *
 *          reporte_mermas(d,h,s).totales.costo == reporte_gerencial(s,d,h).kpis.mermas
 *
 *      Rige también con la página y la búsqueda del detalle (#1146): las dos
 *      tocan sólo la lista, y el gate lo comprueba pidiendo una página con una
 *      búsqueda sin coincidencias y recorriendo el detalle de a 50.
 *
 *      Hoy se cumple por construcción (las dos consumen `mermas_valorizadas()`),
 *      pero eso es exactamente lo que este gate tiene que seguir verificando: si
 *      alguien vuelve a copiar el criterio adentro de una de las dos, el número se
 *      separa y nadie lo nota hasta que dos pantallas dicen cosas distintas.
 *
 *   3. Un reporte cierra contra su propio total (#1262, #1315): la venta del
 *      gerencial, de ventas por cliente, por preventista, por categoría y mes a
 *      mes es el mismo número, y cada reporte suma sus filas. Es lo que prueban a
 *      mano test-reportes-y-fechas-1262.sql y test-reportes-cierran-1297.sql,
 *      que no corren en CI. Desde #1518, además: la alerta de cobranza vencida es
 *      lo vencido de Cuentas por cobrar, hay un solo neto (gerencial y
 *      Rentabilidad), el top de clientes por zona cierra contra cobertura y la
 *      venta en curso del bot es la del gerencial con "Todos".
 *
 *   4. Ninguna columna numeric de public tiene NaN ni infinito (#1520, PAT-1):
 *      `auditoria_nan()`. 'NaN'::numeric es mayor que todo número, así que pasa
 *      las guardas `<= 0` y los CHECK de piso; un precio o un cargo en NaN rompe
 *      en silencio todo lo que lo lee.
 *
 * Las cuatro corren SIEMPRE, aunque una falle: una corrida tiene que decir todo lo
 * que está mal de una vez, no esconder una detrás de la otra.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
 * Uso local:  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/check-integridad.mjs
 */
import { igual, num } from './lib/igualMonto.mjs';

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!url || !key) {
  console.error('Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en el entorno.');
  process.exit(2);
}

const base = url.replace(/\/$/, '');
const headers = {
  apikey: key,
  Authorization: `Bearer ${key}`,
  'Content-Type': 'application/json',
};

/** Llama un RPC por PostgREST. Muere con exit 2 si la llamada en sí falla:
 *  un gate que no puede mirar tiene que ser rojo, no verde. */
async function rpc(nombre, body = {}) {
  const res = await fetch(`${base}/rest/v1/rpc/${nombre}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    console.error(`El RPC ${nombre}() falló: HTTP ${res.status}\n${await res.text()}`);
    process.exit(2);
  }
  return res.json();
}

async function tabla(nombre, query) {
  const res = await fetch(`${base}/rest/v1/${nombre}?${query}`, { headers });
  if (!res.ok) {
    console.error(`La lectura de ${nombre} falló: HTTP ${res.status}\n${await res.text()}`);
    process.exit(2);
  }
  return res.json();
}


// ===========================================================================
// 1 · Invariantes de datos
// ===========================================================================
const r = await rpc('auditoria_integridad');
const checks = Array.isArray(r.checks) ? r.checks : [];
const enRojo = checks.filter((c) => !c.ok);

console.log(`Auditoría de integridad @ ${r.generado_at}`);
console.log(
  `Checks: ${r.total_checks} | con violaciones: ${r.con_violaciones} | critical/high en rojo: ${r.critical_high_en_rojo}`,
);
if (enRojo.length) {
  console.log('\nEn rojo:');
  for (const c of enRojo) {
    console.log(`  [${c.severidad}] ${c.id} = ${c.violaciones} — ${c.descripcion}`);
  }
}

// SEG-A (#1009) es estructural: el número solo no dice qué arreglar. Cada
// función que lista necesita un guard de rol, un REVOKE o —si de verdad no
// filtra nada— una entrada justificada en la lista blanca de
// auditoria_definer_sin_rol().
if (enRojo.some((c) => c.id === 'SEG-A')) {
  const sinRol = await rpc('auditoria_definer_sin_rol');
  console.log('\nSEG-A · DEFINER que authenticated ejecuta sin un guard de rol que proteja:');
  // `motivo` (#1048): sin guard, rol leído de un parámetro, o guard muerto.
  for (const f of sinRol) console.log(`  ${f.firma}${f.motivo ? ` — ${f.motivo}` : ''}`);
}

// SEG-B (#1020): la policy mt_pedidos_select y sus copias en funciones DEFINER
// se separaron. Dice cuál: si la policy cambió a propósito, hay que actualizar
// las copias y el texto esperado de auditoria_predicado_pedidos().
if (enRojo.some((c) => c.id === 'SEG-B')) {
  const desfasado = await rpc('auditoria_predicado_pedidos');
  console.log('\nSEG-B · el predicado de pedidos se desfasó:');
  for (const p of desfasado) console.log(`  ${p.problema}`);
}

// ===========================================================================
// 2 · El criterio de merma (mig 238)
// ===========================================================================
const fallas = [];
const fallo = (caso, esperado, obtenido) =>
  fallas.push(`${caso}: esperaba ${JSON.stringify(esperado)}, dio ${JSON.stringify(obtenido)}`);

// --- 2a. La cascada de costo, sobre casos fijos -----------------------------
// snapshot > costo_promedio > costo_real > costo_sin_iva*(1+ii/100), con
// NULLIF(costo_sin_iva, 0) porque un cero no es un costo. `costo_valuacion()`
// devuelve NULL si y sólo si no hay NINGUNA pata cargada: ese "IS NULL" ES el
// predicado sin_costo que la 238 unificó entre las tres funciones (#511).
const CASOS_CASCADA = [
  // caso,                              snapshot, promedio, real, sin_iva, ii,   costo, origen
  ['snapshot gana sobre todo',               200,      120,   90,      50,  10,    200, 'congelado'],
  ['snapshot en cero igual gana',              0,      120,   90,      50,  10,      0, 'congelado'],
  ['promedio gana sobre real',              null,      120,   90,      50,  10,    120, 'estimado'],
  ['real cuando no hay promedio',           null,     null,   90,      50,  10,     90, 'estimado'],
  ['fórmula con impuestos internos',        null,     null, null,      50,  10,     55, 'estimado'],
  ['fórmula sin impuestos internos',        null,     null, null,      50,   0,     50, 'estimado'],
  ['fórmula con ii nulo',                   null,     null, null,      50, null,    50, 'estimado'],
  // El caso de #511: costo_promedio cargado y costo_sin_iva en NULL NO es sin_costo.
  ['sólo promedio (caso #511)',             null,      120, null,    null, null,   120, 'estimado'],
  ['sólo real, con sin_iva en cero',        null,     null,   90,       0,  10,     90, 'estimado'],
  // El NULLIF: costo_sin_iva = 0 sí es sin_costo, que era lo que el predicado
  // viejo de reporte_mermas no capturaba.
  ['sin_iva en cero es sin costo',          null,     null, null,       0,  10,   null, 'sin_costo'],
  ['nada cargado es sin costo',             null,     null, null,    null,  10,   null, 'sin_costo'],
  // Edge documentado a propósito: el NULLIF va SÓLO en costo_sin_iva (decisión
  // del issue). Un cero en costo_promedio SÍ se toma como costo.
  ['promedio en cero se toma',              null,        0,   90,      50,  10,      0, 'estimado'],
];

for (const [caso, snap, prom, real, siva, ii, espCosto, espOrigen] of CASOS_CASCADA) {
  const costo = await rpc('costo_valuacion', {
    p_snapshot: snap,
    p_costo_promedio: prom,
    p_costo_real: real,
    p_costo_sin_iva: siva,
    p_impuestos_internos: ii,
  });
  if (!igual(costo, espCosto)) fallo(`costo_valuacion · ${caso}`, espCosto, costo);

  const origen = await rpc('costo_valuacion_origen', {
    p_snapshot: snap,
    p_costo_promedio: prom,
    p_costo_real: real,
    p_costo_sin_iva: siva,
  });
  if (origen !== espOrigen) fallo(`costo_valuacion_origen · ${caso}`, espOrigen, origen);

  // Los dos tienen que decir lo mismo: si no hay costo, el origen es sin_costo.
  if ((num(costo) === null) !== (origen === 'sin_costo')) {
    fallo(`coherencia costo/origen · ${caso}`, `costo null == sin_costo`, { costo, origen });
  }
}

// --- 2b. La clasificación: los diez motivos del CHECK vivo ------------------
// Son CUATRO valores, no tres. `promocion` es la contrapartida en stock de un
// regalo ya contabilizado como bonificación: no es pérdida y queda fuera del total.
const CASOS_CLASIFICACION = [
  ['vencimiento', 'perdida'], ['rotura', 'perdida'], ['robo', 'perdida'],
  ['decomiso', 'perdida'], ['devolucion', 'perdida'],
  ['muestra', 'muestra'],
  ['error_inventario', 'ajuste'], ['otro', 'ajuste'], ['', 'ajuste'], [null, 'ajuste'],
  ['promociones', 'promocion'], ['promociones_reversion', 'promocion'],
];

for (const [motivo, esperado] of CASOS_CLASIFICACION) {
  const dio = await rpc('merma_clasificacion', { p_motivo: motivo });
  if (dio !== esperado) fallo(`merma_clasificacion(${JSON.stringify(motivo)})`, esperado, dio);
}

// --- 2b'. La procedencia (mig 301, #847): de dónde vino la merma -----------
// Otro eje que el motivo: el mismo 'error_inventario' puede ser el faltante de
// una entrega, una cancelación por falta de stock o un ajuste a mano. La
// promoción gana sobre todo: es la que queda fuera del total.
const CASOS_PROCEDENCIA = [
  [[1, 'error_inventario', 'Salvedad pedido #1: faltante_stock'], 'entrega_salvedad'],
  [[1, 'rotura', null], 'entrega_salvedad'],
  [[null, 'error_inventario', 'Cancelacion por falta de stock, pedido #7'], 'cancelacion_falta_stock'],
  [[null, 'error_inventario', 'conteo de fin de mes'], 'carga_directa'],
  [[null, 'rotura', null], 'carga_directa'],
  [[null, 'promociones', null], 'promocion'],
  [[null, 'promociones_reversion', 'Cancelacion por falta de stock, pedido #7'], 'promocion'],
];

for (const [[salvedad, motivo, obs], esperado] of CASOS_PROCEDENCIA) {
  const dio = await rpc('merma_procedencia', { p_salvedad_id: salvedad, p_motivo: motivo, p_observaciones: obs });
  if (dio !== esperado) fallo(`merma_procedencia(${JSON.stringify([salvedad, motivo, obs])})`, esperado, dio);
}

// --- 2c. Las filas reales que devuelve mermas_valorizadas -------------------
const sucursales = await tabla('sucursales', 'select=id,nombre&activa=eq.true&order=id');
// El día ARGENTINO, que es con el que corta `mermas_valorizadas`. `en-CA` da
// YYYY-MM-DD directo: nada de `toISOString()`, que pasa por UTC y en una máquina
// que no esté en UTC devuelve el día de al lado.
const diaArgentino = new Intl.DateTimeFormat('en-CA', {
  timeZone: 'America/Argentina/Buenos_Aires',
}).format(new Date());
const hasta = diaArgentino;
const desde = `${diaArgentino.slice(0, 7)}-01`;
const ORIGENES = new Set(['congelado', 'estimado', 'sin_costo']);
const CLASIFICACIONES = new Set(['perdida', 'ajuste', 'muestra', 'promocion']);
const PROCEDENCIAS = new Set(['entrega_salvedad', 'cancelacion_falta_stock', 'carga_directa', 'promocion']);

const filas = await rpc('mermas_valorizadas', {
  p_desde: desde,
  p_hasta: hasta,
  p_sucursales: sucursales.map((s) => s.id),
});

for (const f of filas) {
  if (!ORIGENES.has(f.origen_costo)) fallo(`fila ${f.id} · origen_costo`, [...ORIGENES], f.origen_costo);
  if (!CLASIFICACIONES.has(f.clasificacion)) fallo(`fila ${f.id} · clasificacion`, [...CLASIFICACIONES], f.clasificacion);
  if (!PROCEDENCIAS.has(f.procedencia)) fallo(`fila ${f.id} · procedencia`, [...PROCEDENCIAS], f.procedencia);
  // Una cantidad negativa DEVUELVE costo: el producto tiene que seguir el signo.
  const esperado = num(f.costo_unitario) === null ? null : num(f.cantidad) * num(f.costo_unitario);
  if (!igual(f.costo_total, esperado)) fallo(`fila ${f.id} · costo_total`, esperado, f.costo_total);
  // Y el "IS NULL" de la cascada tiene que ser exactamente el sin_costo.
  if ((num(f.costo_unitario) === null) !== (f.origen_costo === 'sin_costo')) {
    fallo(`fila ${f.id} · sin_costo`, 'costo null == origen sin_costo', {
      costo_unitario: f.costo_unitario,
      origen_costo: f.origen_costo,
    });
  }
  if (f.fecha_local < desde || f.fecha_local > hasta) {
    fallo(`fila ${f.id} · fecha_local fuera del rango pedido`, `${desde}..${hasta}`, f.fecha_local);
  }
}

// --- 2d. La invariante: el gerencial y el reporte de mermas dan lo mismo ----
// Mes corriente, cada sucursal y la Red (p_sucursal_id = null).
const ambitos = [...sucursales.map((s) => ({ id: s.id, nombre: s.nombre })), { id: null, nombre: 'Red' }];

for (const a of ambitos) {
  const ger = await rpc('reporte_gerencial', { p_sucursal_id: a.id, p_desde: desde, p_hasta: hasta });
  const mer = await rpc('reporte_mermas', { p_desde: desde, p_hasta: hasta, p_sucursal_id: a.id });

  if (!igual(ger.kpis.mermas, mer.totales.costo)) {
    fallo(`cruce mermas · ${a.nombre}`, ger.kpis.mermas, mer.totales.costo);
  }
  // #1146: el detalle se pagina y se busca en el servidor. Una página o una
  // búsqueda acortan la lista, nunca mueven un total; y recorrer las páginas
  // devuelve cada fila del período una vez.
  const mismo = { p_desde: desde, p_hasta: hasta, p_sucursal_id: a.id };
  const pag = await rpc('reporte_mermas', {
    ...mismo,
    p_limite_detalle: 1,
    p_offset: 1,
    p_busqueda: 'zzzz-sin-match',
  });
  if (JSON.stringify(pag.totales) !== JSON.stringify(mer.totales)) {
    fallo(`paginar mueve los totales · ${a.nombre}`, mer.totales, pag.totales);
  }
  const ids = [];
  for (let off = 0; off < mer.detalle_total; off += 50) {
    const p = await rpc('reporte_mermas', { ...mismo, p_limite_detalle: 50, p_offset: off });
    ids.push(...p.detalle.map((f) => f.id));
  }
  if (ids.length !== mer.detalle_total || new Set(ids).size !== ids.length) {
    fallo(`paginación del detalle · ${a.nombre}`, mer.detalle_total, {
      filas: ids.length,
      unicas: new Set(ids).size,
    });
  }
  // Las de promoción no son pérdida: tienen que estar FUERA del total y contadas
  // aparte. Si alguien las mete adentro, el total se infla ~4x. La forma de verlo
  // sin re-sumar las filas es que el total sea EXACTAMENTE la suma de las tres
  // clasificaciones que sí cuentan: si `promocion` se colara, sobraría.
  const porClase =
    num(mer.totales.costo_perdida) + num(mer.totales.costo_ajuste) + num(mer.totales.costo_muestra);
  if (!igual(mer.totales.costo, porClase)) {
    fallo(`partición de mermas · ${a.nombre}`, porClase, mer.totales.costo);
  }
  // El corte por procedencia (mig 301) parte las MISMAS filas: lo que no es
  // promoción suma el total, y lo que es promoción suma el ajuste aparte.
  const pp = mer.por_procedencia ?? [];
  const ppTotal = pp.filter((x) => x.clasificacion !== 'promocion').reduce((acc, x) => acc + num(x.costo), 0);
  const ppPromo = pp.filter((x) => x.clasificacion === 'promocion').reduce((acc, x) => acc + num(x.costo), 0);
  if (!igual(mer.totales.costo, ppTotal)) fallo(`por_procedencia · ${a.nombre}`, mer.totales.costo, ppTotal);
  if (!igual(mer.totales.costo_ajuste_promocion, ppPromo)) {
    fallo(`por_procedencia promoción · ${a.nombre}`, mer.totales.costo_ajuste_promocion, ppPromo);
  }
  // Y la lista detrás de la alerta tiene que sumar el KPI que la abre (#511).
  const detalle = await rpc('reporte_alerta_detalle', {
    p_sucursal_id: a.id,
    p_codigo: 'productos_sin_costo',
    p_desde: desde,
    p_hasta: hasta,
    p_incluir_no_entregados: false,
  });
  const sumaDetalle = detalle.reduce((acc, it) => acc + num(it.valor), 0);
  if (!igual(sumaDetalle, ger.kpis.ingreso_sin_costo)) {
    fallo(`alerta productos_sin_costo · ${a.nombre}`, ger.kpis.ingreso_sin_costo, sumaDetalle);
  }
}

const casosCorridos =
  CASOS_CASCADA.length * 3 + CASOS_CLASIFICACION.length + CASOS_PROCEDENCIA.length +
  filas.length * 6 + ambitos.length * 7;

console.log(`\nCriterio de merma (mig 238): ${casosCorridos} comprobaciones`);
console.log(
  `  casos fijos de la cascada: ${CASOS_CASCADA.length} | motivos: ${CASOS_CLASIFICACION.length} | ` +
    `procedencias: ${CASOS_PROCEDENCIA.length} | ` +
    `filas de ${desde} a ${hasta}: ${filas.length} | ámbitos cruzados: ${ambitos.length}`,
);
if (fallas.length) {
  console.log('\nEn rojo:');
  for (const f of fallas) console.log(`  ${f}`);
}

// ===========================================================================
// 3 · Un reporte cierra contra su propio total (#1262, #1315)
// ===========================================================================
const cierres = [];
const sumaDe = (filas, campo) => (filas ?? []).reduce((acc, f) => acc + num(f[campo]), 0);

// El mes en curso y el anterior: a principios de mes el primero casi no tiene
// ventas. Los números salen del gerencial, que es el que cierra contra `pedidos`.
const [anio, mes] = diaArgentino.split('-').map(Number);
const finMesAnterior = new Date(Date.UTC(anio, mes - 1, 0)).toISOString().slice(0, 10);
const periodos = [
  { desde, hasta, anio, mes },
  {
    desde: `${finMesAnterior.slice(0, 7)}-01`,
    hasta: finMesAnterior,
    anio: Number(finMesAnterior.slice(0, 4)),
    mes: Number(finMesAnterior.slice(5, 7)),
  },
];

async function cruzarPeriodo(a, p) {
  const fallos = [];
  const noCierra = (caso, esperado, obtenido) =>
    fallos.push(`${caso}: esperaba ${JSON.stringify(esperado)}, dio ${JSON.stringify(obtenido)}`);
  const donde = `${a.nombre} ${p.desde.slice(0, 7)}`;
  const rango = { p_desde: p.desde, p_hasta: p.hasta, p_sucursal_id: a.id };
  const { kpis } = await rpc('reporte_gerencial', rango);

  const porCliente = await rpc('reporte_ventas_por_cliente', { ...rango, p_preventista_id: null });
  if (!igual(porCliente.totales.total, kpis.venta)) {
    noCierra(`ventas por cliente · ${donde}`, kpis.venta, porCliente.totales.total);
  }
  if (num(porCliente.totales.pedidos) !== num(kpis.pedidos)) {
    noCierra(`pedidos por cliente · ${donde}`, kpis.pedidos, porCliente.totales.pedidos);
  }
  for (const lista of ['clientes', 'zonas', 'vendedores']) {
    const suma = sumaDe(porCliente[lista], 'total');
    if (!igual(suma, kpis.venta)) noCierra(`ventas por cliente · Σ ${lista} · ${donde}`, kpis.venta, suma);
  }

  const porPreventista = await rpc('reporte_ventas_por_preventista', rango);
  const sumaPreventistas = sumaDe(porPreventista, 'totalVentas');
  if (!igual(sumaPreventistas, kpis.venta)) {
    noCierra(`ventas por preventista · ${donde}`, kpis.venta, sumaPreventistas);
  }

  const categorias = await rpc('tablero_categorias', {
    p_sucursal_id: a.id,
    p_desde: p.desde,
    p_hasta: p.hasta,
  });
  if (!igual(categorias.total, kpis.venta)) noCierra(`tablero de categorías · ${donde}`, kpis.venta, categorias.total);
  const sumaCategorias = sumaDe(categorias.categorias, 'monto');
  if (!igual(sumaCategorias, kpis.venta)) noCierra(`Σ categorías · ${donde}`, kpis.venta, sumaCategorias);

  const facturacion = await rpc('tablero_facturacion_mensual', { p_sucursal_id: a.id, p_anio: p.anio });
  const delMes = facturacion.meses.find((m) => m.mes === p.mes);
  if (!delMes || !igual(delMes.total, kpis.venta) || num(delMes.pedidos) !== num(kpis.pedidos)) {
    noCierra(`facturación mensual · ${donde}`, { total: kpis.venta, pedidos: kpis.pedidos }, delMes ?? null);
  }

  // #1518 (REP-2): un solo neto. En el gerencial es la venta menos el IVA débito; en
  // Rentabilidad, brutas − IVA − II, y es el ingreso sobre el que se mide el margen.
  if (!igual(kpis.venta_neta, num(kpis.venta) - num(kpis.iva_debito))) {
    noCierra(`venta neta del gerencial · ${donde}`, num(kpis.venta) - num(kpis.iva_debito), kpis.venta_neta);
  }
  const { totales: rent } = await rpc('reporte_rentabilidad', { ...rango, p_combos: 'incluir' });
  const netas = num(rent.ventasBrutas) - num(rent.ivaDiscriminado) - num(rent.impuestosInternos);
  if (!igual(rent.ventasNetas, netas) || Math.abs(num(rent.ventasNetas) - num(rent.ingresosTotales)) > 0.01) {
    noCierra(`rentabilidad · netas = brutas − IVA − II = ingresos · ${donde}`,
      { netas, ingresos: rent.ingresosTotales }, rent.ventasNetas);
  }

  // #1518 (REP-4): el top de clientes por zona cierra contra la facturación de cobertura, que
  // es del mes entero.
  const finMes = new Date(Date.UTC(p.anio, p.mes, 0)).toISOString().slice(0, 10);
  const top = await rpc('tablero_top_clientes_zona', { p_sucursal_id: a.id, p_desde: p.desde, p_hasta: finMes });
  const cobertura = await rpc('tablero_cobertura', { p_sucursal_id: a.id, p_periodo: p.desde });
  const sumaTop = sumaDe(top.zonas, 'total');
  if (!igual(sumaTop, cobertura.totales.facturacion)) {
    noCierra(`top clientes por zona · ${donde}`, cobertura.totales.facturacion, sumaTop);
  }

  // #1518 (REP-8): la venta en curso del bot es el gerencial con "Todos" menos el de entregadas.
  if (a.id !== null) {
    const todos = await rpc('reporte_gerencial', { ...rango, p_incluir_no_entregados: true });
    const bot = await rpc('bot_ventas_periodo', { p_desde: p.desde, p_hasta: p.hasta, p_sucursal_id: a.id });
    const enCurso = num(todos.kpis.venta) - num(kpis.venta);
    if (!igual(bot.en_curso_monto, enCurso)) noCierra(`venta en curso del bot · ${donde}`, enCurso, bot.en_curso_monto);
  }
  return fallos;
}

// #1518 (REP-1, COB-4): la alerta "Cobranza vencida" del gerencial es lo vencido de Cuentas por
// cobrar (la entrega más los días de crédito, descontado el crédito suelto), y su detalle la suma.
// No depende del período: es contra hoy.
async function cruzarVencido(a) {
  const fallos = [];
  const cxc = await rpc('reporte_cuentas_por_cobrar', { p_sucursal_id: a.id });
  const vencido = num(cxc.totales.vencido30) + num(cxc.totales.vencido60) + num(cxc.totales.vencido90);
  const ger = await rpc('reporte_gerencial', { p_sucursal_id: a.id, p_desde: hasta, p_hasta: hasta });
  const alerta = (ger.alertas ?? []).find((x) => x.codigo === 'cobranza_vencida');
  const valor = alerta ? num(alerta.valor) : 0;
  if (!igual(valor, vencido)) {
    fallos.push(`alerta de cobranza vencida · ${a.nombre}: esperaba ${vencido} (Cuentas por cobrar), dio ${valor}`);
  }
  const detalle = await rpc('reporte_alerta_detalle', { p_sucursal_id: a.id, p_codigo: 'cobranza_vencida' });
  if (detalle.length < 100 && !igual(sumaDe(detalle, 'valor'), valor)) {
    fallos.push(`detalle de cobranza vencida · ${a.nombre}: esperaba ${valor}, sumó ${sumaDe(detalle, 'valor')}`);
  }
  return fallos;
}

for (const a of ambitos) {
  for (const p of periodos) {
    // Las RPCs corren una detrás de la otra: una entrega en el medio no es un
    // desvío. Sólo cuenta lo que se repite.
    let fallos = await cruzarPeriodo(a, p);
    if (fallos.length) fallos = await cruzarPeriodo(a, p);
    cierres.push(...fallos);
  }
  let fallos = await cruzarVencido(a);
  if (fallos.length) fallos = await cruzarVencido(a);
  cierres.push(...fallos);
}

console.log(`\nReportes contra su total (#1262, #1315): ${ambitos.length} ámbitos, ${periodos.length} períodos`);
if (cierres.length) {
  console.log('\nEn rojo:');
  for (const c of cierres) console.log(`  ${c}`);
}

// ===========================================================================
// 4 · NaN e infinito en las columnas numeric (#1520, PAT-1)
// ===========================================================================
// 'NaN'::numeric es mayor que todo número: pasa las guardas `<= 0` de las RPCs y los CHECK de piso
// (`>= 0`). auditoria_nan() cuenta, en cada columna numeric de public, las filas en NaN o infinito.
const nan = await rpc('auditoria_nan');
// Cero columnas no es "todo bien": es que el RPC no está mirando nada.
const sinMirarNan = !(nan.columnas > 0) || !Array.isArray(nan.con_nan);
const conNan = sinMirarNan ? [] : nan.con_nan;

console.log(`\nNaN e infinito (#1520): ${nan.columnas ?? 0} columnas numeric`);
if (conNan.length) {
  console.log('\nEn rojo:');
  for (const c of conNan) console.log(`  ${c.tabla}.${c.columna}: ${c.filas} fila(s)`);
}

// ===========================================================================
// Salida
// ===========================================================================
const rojoAuditoria = (r.critical_high_en_rojo ?? 0) > 0;

if (rojoAuditoria) {
  console.error(
    `\n❌ Hay ${r.critical_high_en_rojo} check(s) critical/high en rojo. Revisar antes de presentar números.`,
  );
}
if (fallas.length) {
  console.error(
    `\n❌ ${fallas.length} desvío(s) en el criterio de merma. El criterio vive en ` +
      '`mermas_valorizadas()` (mig 238): si dos funciones dan números distintos, alguna volvió ' +
      'a escribirlo por su cuenta.',
  );
}
if (cierres.length) {
  console.error(
    `\n❌ ${cierres.length} reporte(s) no cierran contra su total. Una fila que se cae suele ser un JOIN ` +
      'interno (el check REPORTE-A) o una definición de venta copiada a mano (CLAUDE.md).',
  );
}
if (sinMirarNan) {
  console.error('\n❌ auditoria_nan() no devolvió columnas: el gate del NaN no puede mirar.');
}
if (conNan.length) {
  console.error(
    `\n❌ ${conNan.length} columna(s) con NaN o infinito. Entró por un camino que no frena el NaN: la regla está ` +
      'en CLAUDE.md (un CHECK de piso no lo frena; `x <> \'NaN\'` o un techo sí).',
  );
}
if (rojoAuditoria || fallas.length || cierres.length || sinMirarNan || conNan.length) process.exit(1);

console.log(
  '\n✅ Sin checks critical/high en rojo, el criterio de merma cierra, los reportes cierran contra su total y no hay NaN.',
);
