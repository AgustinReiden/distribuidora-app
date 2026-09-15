#!/usr/bin/env node
/**
 * Gate de integridad de datos.
 *
 * Dos baterías, las dos contra prod con la service_role key:
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
 *      Hoy se cumple por construcción (las dos consumen `mermas_valorizadas()`),
 *      pero eso es exactamente lo que este gate tiene que seguir verificando: si
 *      alguien vuelve a copiar el criterio adentro de una de las dos, el número se
 *      separa y nadie lo nota hasta que dos pantallas dicen cosas distintas.
 *
 * Las dos corren SIEMPRE, aunque la primera falle: una corrida tiene que decir todo
 * lo que está mal de una vez, no esconder la segunda detrás de la primera.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
 * Uso local:  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/check-integridad.mjs
 */
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

/** `numeric` puede venir como number o como string según el tamaño. */
const num = (v) => (v === null || v === undefined ? null : Number(v));
const igual = (a, b) => num(a) === num(b) || (num(a) === null && num(b) === null);

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

const filas = await rpc('mermas_valorizadas', {
  p_desde: desde,
  p_hasta: hasta,
  p_sucursales: sucursales.map((s) => s.id),
});

for (const f of filas) {
  if (!ORIGENES.has(f.origen_costo)) fallo(`fila ${f.id} · origen_costo`, [...ORIGENES], f.origen_costo);
  if (!CLASIFICACIONES.has(f.clasificacion)) fallo(`fila ${f.id} · clasificacion`, [...CLASIFICACIONES], f.clasificacion);
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
  // Las de promoción no son pérdida: tienen que estar FUERA del total y contadas
  // aparte. Si alguien las mete adentro, el total se infla ~4x. La forma de verlo
  // sin re-sumar las filas es que el total sea EXACTAMENTE la suma de las tres
  // clasificaciones que sí cuentan: si `promocion` se colara, sobraría.
  const porClase =
    num(mer.totales.costo_perdida) + num(mer.totales.costo_ajuste) + num(mer.totales.costo_muestra);
  if (!igual(mer.totales.costo, porClase)) {
    fallo(`partición de mermas · ${a.nombre}`, porClase, mer.totales.costo);
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
  CASOS_CASCADA.length * 3 + CASOS_CLASIFICACION.length + filas.length * 5 + ambitos.length * 3;

console.log(`\nCriterio de merma (mig 238): ${casosCorridos} comprobaciones`);
console.log(
  `  casos fijos de la cascada: ${CASOS_CASCADA.length} | motivos: ${CASOS_CLASIFICACION.length} | ` +
    `filas de ${desde} a ${hasta}: ${filas.length} | ámbitos cruzados: ${ambitos.length}`,
);
if (fallas.length) {
  console.log('\nEn rojo:');
  for (const f of fallas) console.log(`  ${f}`);
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
if (rojoAuditoria || fallas.length) process.exit(1);

console.log('\n✅ Sin checks critical/high en rojo y el criterio de merma cierra en todos los casos.');
