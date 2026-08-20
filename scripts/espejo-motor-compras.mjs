#!/usr/bin/env node
/**
 * EL ESPEJO ENTRE LAS DOS IMPLEMENTACIONES DEL MOTOR DE COSTOS DE COMPRA.
 *
 * El motor está escrito dos veces y las dos tienen que dar el mismo número:
 *
 *   · TypeScript — `src/utils/prorrateoCompra.ts`, la vista previa del modal.
 *   · SQL — `prorratear_cargo` / `calcular_costos_compra` (mig 193), la
 *     canónica: lo que se PERSISTE sale de ahí.
 *
 * Este script corre LAS DOS sobre los mismos casos y sale con 1 ante cualquier
 * divergencia. Es la única de las dos capas que ve los dos lados: el test de
 * vitest (`src/utils/prorrateoCompra.espejo.test.ts`) compara el TS contra un
 * fixture congelado y por eso NO puede detectar que se movió el SQL. Este sí, y
 * además es el que regenera ese fixture.
 *
 * CÓMO COMPARA. Las entradas se serializan a JSON —lo que viajaría por la red— y
 * el MISMO texto va a los dos motores. El de TypeScript se importa de verdad
 * (vía Vite, para que el `.ts` se resuelva igual que en la app): nada de copiar
 * la aritmética acá, que sería un tercer motor para mantener. La comparación la
 * hace Postgres, en `espejo_motor_compras` (mig 196), con `IS DISTINCT FROM`
 * sobre `numeric`: así `500` contra `500.00` no cuenta y un centavo sí.
 *
 * Requiere env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (service_role, NO anon:
 * la RPC del espejo no está expuesta a anon ni a authenticated).
 *
 *   node scripts/espejo-motor-compras.mjs             # compara y falla si difiere
 *   node scripts/espejo-motor-compras.mjs --fijar     # además regenera el fixture
 *   node scripts/espejo-motor-compras.mjs --payload p.json   # sólo escribe el payload
 *   node scripts/espejo-motor-compras.mjs --respuesta r.json # lee la respuesta de un archivo
 *
 * Los dos últimos existen para poder correr el espejo sin credenciales de
 * servicio a mano —se manda el payload a la base por otro camino y se le da la
 * respuesta al script—, que es como se verifica desde una máquina de desarrollo.
 * No los usa el gate.
 */
import { writeFileSync, readFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FIXTURE = path.join(RAIZ, 'src', 'utils', 'prorrateoCompra.espejo.fixture.json');

const args = process.argv.slice(2);
const flag = (nombre) => args.includes(nombre);
const valor = (nombre) => {
  const i = args.indexOf(nombre);
  return i >= 0 ? args[i + 1] : undefined;
};

const fijar = flag('--fijar');
const salidaPayload = valor('--payload');
const desdeArchivo = valor('--respuesta');

// --- 1. El motor de TypeScript, importado de verdad ---------------------------
// `ssrLoadModule` de Vite en vez de un import de Node: `prorrateoCompra.ts`
// importa `./calculations` sin extensión y el resolver de Node no la completa.
// Usar Vite además garantiza que se está cargando EL MISMO módulo que la app,
// que es la única forma de que este script signifique algo.
const { createServer } = await import('vite');
const vite = await createServer({
  configFile: false,          // sin el config de la app: el motor es TS puro
  root: RAIZ,
  logLevel: 'error',
  appType: 'custom',
  server: { middlewareMode: true, hmr: false, watch: null },
  optimizeDeps: { noDiscovery: true, include: [] },
});

let espejo;
try {
  espejo = await vite.ssrLoadModule('/src/utils/prorrateoCompra.espejo.ts');
} finally {
  // Se cierra apenas se cargó el módulo: el resto del script no necesita Vite y
  // un servidor abierto deja el proceso colgado en CI.
  await vite.close();
}

const { CASOS_ESPEJO, DECIMALES_ESPEJO, correrMotorTS, redondearSalida, NO_CUBIERTO } = espejo;

// --- 2. El payload: la misma entrada para los dos motores ---------------------
const casos = CASOS_ESPEJO.map((c) => {
  const { ts, ts_error } = correrMotorTS(c);
  return { caso: c.caso, motor: c.motor, origen: c.origen, entrada: c.entrada, ts, ts_error };
});
const payload = { p_casos: casos, p_decimales: DECIMALES_ESPEJO };

if (salidaPayload) {
  writeFileSync(salidaPayload, JSON.stringify(payload), 'utf8');
  console.log(`Payload de ${casos.length} caso(s) escrito en ${salidaPayload}.`);
  console.log('Pasalo por public.espejo_motor_compras(p_casos, p_decimales) y volvé con --respuesta.');
  process.exit(0);
}

// --- 3. El motor de SQL y la comparación, adentro de Postgres -----------------
let r;
if (desdeArchivo) {
  r = JSON.parse(readFileSync(desdeArchivo, 'utf8'));
  console.log(`Respuesta leída de ${desdeArchivo} (sin ir a la red).`);
} else {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) {
    console.error('Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en el entorno.');
    process.exit(2);
  }
  const res = await fetch(`${url.replace(/\/$/, '')}/rest/v1/rpc/espejo_motor_compras`, {
    method: 'POST',
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    console.error(`El RPC espejo_motor_compras() falló: HTTP ${res.status}\n${await res.text()}`);
    console.error('¿Aplicaste migrations/196_espejo_del_motor_de_compras.sql?');
    process.exit(2);
  }
  r = await res.json();
}

// --- 4. Reporte ---------------------------------------------------------------
const detalle = Array.isArray(r.detalle) ? r.detalle : [];
const rojos = detalle.filter((c) => (c.divergencias ?? []).length > 0);

console.log(`Espejo TS ↔ SQL del motor de compras @ ${r.generado_at ?? '(sin fecha)'}`);
console.log(
  `Casos: ${r.casos} | celdas comparadas: ${r.celdas} | ` +
  `divergencias: ${r.divergencias} en ${r.casos_rojos} caso(s) | ` +
  `comparado a ${r.decimales} decimales`,
);

// Un caso que no compara ninguna celda y tampoco es de contrato pasa por no
// mirar nada. Se nombra: es la forma más silenciosa de que este gate se vacíe.
const mudos = detalle.filter((c) => c.celdas === 0 && !c.sql_error && !c.ts_error);
if (mudos.length) {
  console.log('\n⚠ Casos que no compararon ninguna celda (las dos salidas vacías):');
  for (const c of mudos) console.log(`   ${c.caso}`);
}

const contrato = detalle.filter((c) => c.sql_error || c.ts_error);
console.log(
  `\nContrato: ${contrato.length} caso(s) donde alguna implementación rechaza la entrada; ` +
  `${contrato.filter((c) => c.sql_error && c.ts_error).length} donde la rechazan las dos.`,
);

if (rojos.length) {
  console.log('\n❌ Divergencias:');
  for (const c of rojos) {
    console.log(`\n  ${c.caso}  [${c.motor}, de ${c.origen ?? '?'}]`);
    for (const d of c.divergencias.slice(0, 12)) {
      console.log(`    ${d.campo}  ${d.motivo}`);
      console.log(`      TS  = ${JSON.stringify(d.ts)}`);
      console.log(`      SQL = ${JSON.stringify(d.sql)}`);
    }
    if (c.divergencias.length > 12) {
      console.log(`    … y ${c.divergencias.length - 12} más.`);
    }
  }
}

// --- 5. El fixture de la capa 1 ----------------------------------------------
// Se escribe SIEMPRE que se pida, aun con divergencias, pero después del reporte
// y sólo si el espejo está en verde: congelar una salida de SQL que no coincide
// con el TS convertiría el test rápido en un test que exige la divergencia.
if (fijar) {
  if (rojos.length) {
    console.error('\n❌ No se regenera el fixture con divergencias abiertas: congelaría el desacuerdo.');
    process.exit(1);
  }
  const fixture = {
    _: [
      'GENERADO por scripts/espejo-motor-compras.mjs --fijar. No editar a mano.',
      'Es la salida del motor de SQL (mig 193) para cada caso, redondeada a los',
      'mismos decimales a los que el espejo compara: la referencia contra la que',
      'prorrateoCompra.espejo.test.ts corre el motor de TypeScript sin base.',
      'Sin fecha a proposito: regenerarlo sin cambios tiene que dar un archivo',
      'identico, para que un diff vacio signifique "el SQL no se movio".',
    ].join(' '),
    decimales: r.decimales,
    casos: detalle.map((c) => ({
      caso: c.caso,
      motor: c.motor,
      origen: c.origen,
      entrada: casos.find((x) => x.caso === c.caso)?.entrada,
      celdas: c.celdas,
      sql: c.sql == null ? null : redondearSalida(c.sql, r.decimales),
      sql_error: c.sql_error ?? null,
    })),
  };
  writeFileSync(FIXTURE, `${JSON.stringify(fixture, null, 2)}\n`, 'utf8');
  console.log(`\nFixture regenerado: ${path.relative(RAIZ, FIXTURE)}`);
}

if (rojos.length) {
  console.error(
    `\n❌ ${r.divergencias} divergencia(s) entre el motor de TypeScript y el de SQL. ` +
    'Una de las dos implementaciones se movió sin la otra.',
  );
  process.exit(1);
}

console.log('\n✅ Las dos implementaciones dan lo mismo en todos los casos.');
console.log('   Lo que este espejo NO cubre:');
for (const l of NO_CUBIERTO) console.log(`   · ${l}`);
