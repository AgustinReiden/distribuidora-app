// Base local en Docker para el arnés de concurrencia (#1288, plan #1378 tarjeta 1).
//
// Alternativa a la rama de Supabase: el dueño eligió Docker local (02/11). Levanta la imagen
// oficial de Supabase Postgres (la misma versión que prod), le re-aplica `migrations/` en
// orden y la compara contra prod con la huella de `huella-esquema.sql`.
//
//   node scripts/concurrencia/docker-local.mjs up        # imagen + contenedor `conc-pg` (puerto 54330)
//   node scripts/concurrencia/docker-local.mjs migrar    # aplica migrations/*.sql; frena en la primera que falle
//   node scripts/concurrencia/docker-local.mjs migrar --seguir   # descubrimiento: anota las que fallan y sigue (cada archivo en su transacción)
//   node scripts/concurrencia/docker-local.mjs migrar --tolerante   # sin transacción envolvente, siembra sucursales 1 y 2, anota cada error y sigue
//   node scripts/concurrencia/docker-local.mjs huella    # etapa 1 de la huella (para comparar con prod)
//   node scripts/concurrencia/docker-local.mjs sql "<consulta>"   # una consulta, como postgres
//   node scripts/concurrencia/docker-local.mjs down      # apaga y BORRA el contenedor
//
// Sólo toca el contenedor local. Prod ni se menciona: se lee aparte, por el MCP, con la misma huella.
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const IMAGEN = "supabase/postgres:17.6.1.178"; // prod: Postgres 17.6.1 (README de migrations/)
const NOMBRE = "conc-pg";
const PUERTO = 54330;
const aqui = dirname(fileURLToPath(import.meta.url));
const raiz = join(aqui, "..", "..");
const env = { ...process.env, PATH: `${process.env.PATH}${process.platform === "win32" ? ";C:\\Program Files\\Docker\\Docker\\resources\\bin" : ""}` };

const docker = (...a) => execFileSync("docker", a, { env, encoding: "utf8", maxBuffer: 1 << 28 });
const dockerSpawn = (opts, ...a) => spawnSync("docker", a, { env, encoding: "utf8", maxBuffer: 1 << 28, ...opts });
const psql = (sql) => docker("exec", NOMBRE, "psql", "-U", "postgres", "-h", "localhost", "-At", "-v", "ON_ERROR_STOP=1", "-c", sql);

// Orden de aplicación: el nombre de archivo (000_baseline, 001…, 431d), con las excepciones del
// MANIFEST §A, donde el orden real del ledger no es el alfabético.
const ANTES = [
  ["040_perfiles_rol_check_encargado.sql", "040_pedidos_geolocalizacion.sql"],
  ["081_clientes_horario_entrega.sql", "081_aplicar_orden_ruta.sql"],
  ["091_fix_promo_acumuladores_resto_y_clamp.sql", "091_cambio_motivo_mal_estado.sql"],
  ["139_movimientos_stock_preventivo.sql", "139_guarda_precio_venta.sql"],
  ["167_pagos_idempotencia_client_request_id.sql", "167_baja_de_total_reduce_el_pago.sql"],
];
export function ordenMigraciones() {
  const archivos = readdirSync(join(raiz, "migrations")).filter((f) => f.endsWith(".sql")).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  for (const [primero, segundo] of ANTES) {
    const i = archivos.indexOf(primero), j = archivos.indexOf(segundo);
    if (i < 0 || j < 0) throw new Error(`MANIFEST §A: falta ${i < 0 ? primero : segundo}`);
    if (i > j) { archivos.splice(i, 1); archivos.splice(j, 0, primero); }
  }
  return archivos;
}

function up() {
  docker("pull", IMAGEN);
  try { docker("rm", "-f", NOMBRE); } catch (_) { /* no existía */ }
  const id = docker("run", "-d", "--name", NOMBRE, "-e", "POSTGRES_PASSWORD=pw", "-p", `${PUERTO}:5432`, IMAGEN).trim();
  console.log(`contenedor ${id.slice(0, 12)} en el puerto ${PUERTO}`);
  for (let i = 0; i < 40; i++) {
    if (dockerSpawn({}, "exec", NOMBRE, "pg_isready", "-U", "postgres", "-h", "localhost").status === 0) {
      console.log(psql("select version()").trim());
      return;
    }
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 3000);
  }
  throw new Error("Postgres no levantó en 2 minutos");
}

// Lo que prod trae de sus datos y la cadena de migraciones no siembra: sin las sucursales 1 y 2 fallan
// la 145, la 199, la 302… (las ids y los nombres son los de prod).
const SEMBRAR_SUCURSALES = `INSERT INTO public.sucursales (id, nombre, activa, tipo) VALUES (1, 'Tucuman', true, 'principal'), (2, 'Taco Pozo', true, 'secundaria') ON CONFLICT (id) DO NOTHING; SELECT setval(pg_get_serial_sequence('public.sucursales', 'id'), 4, true)`;

// Modos:
//   (nada)       cada archivo en su transacción (-1), como apply_migration; frena en el primero que falle.
//   --seguir     igual, pero anota los que fallan y sigue (descubrimiento).
//   --tolerante  sin la transacción envolvente: se saca el BEGIN/COMMIT de cada archivo y cada statement va
//                solo, así que uno que falla (un arreglo de datos de prod, una premisa de md5) se saltea y el
//                resto del DDL pasa. Siembra las sucursales 1 y 2 después de la baseline. Anota cada error.
//                Lo que importa es la huella después: dice si el schema quedó como el de prod.
function migrar() {
  const tolerante = process.argv.includes("--tolerante");
  const seguir = tolerante || process.argv.includes("--seguir");
  const archivos = ordenMigraciones();
  const tmp = mkdtempSync(join(tmpdir(), "conc-migs-"));
  // LF siempre: en Windows el working copy puede traer CRLF y las migraciones con premisa (md5 del cuerpo vivo) lo rechazan.
  for (const f of archivos) {
    let sql = readFileSync(join(raiz, "migrations", f), "utf8").replaceAll("\r\n", "\n");
    if (tolerante) sql = sql.replace(/^[ \t]*(BEGIN|COMMIT|START TRANSACTION)( TRANSACTION)?;[ \t]*$/gim, "-- (sin transacción envolvente)");
    writeFileSync(join(tmp, f), sql);
  }
  writeFileSync(join(tmp, "_orden.txt"), archivos.join("\n") + "\n");
  writeFileSync(join(tmp, "_sembrar.sql"), SEMBRAR_SUCURSALES + "\n");
  docker("exec", NOMBRE, "rm", "-rf", "/tmp/migs");
  docker("cp", tmp, `${NOMBRE}:/tmp/migs`);
  const aplicar = tolerante
    ? 'psql -U postgres -h localhost -d postgres -q -f "$f" 2>&1 >/dev/null | grep -E "ERROR|DETAIL" | head -4'
    : 'psql -U postgres -h localhost -d postgres -v ON_ERROR_STOP=1 -q -1 -f "$f" 2>&1 >/dev/null | grep -E "ERROR|DETAIL" | head -3';
  const guion = `SEGUIR=${seguir ? "true" : "false"}; cd /tmp/migs; n=0; malos=0
while read -r f; do
  n=$((n+1))
  out=$(${aplicar}; true)
  if [ -n "$out" ]; then
    malos=$((malos+1)); echo "ERRORES en $f (archivo $n de ${archivos.length})"; echo "$out"
    $SEGUIR || exit 1
  fi
  ${tolerante ? `if [ "$f" = 000_baseline.sql ]; then psql -U postgres -h localhost -d postgres -q -f _sembrar.sql >/dev/null; fi` : ":"}
done < _orden.txt
echo "FIN: $n archivos, $malos con errores"`;
  const t0 = Date.now();
  const r = dockerSpawn({}, "exec", NOMBRE, "bash", "-c", guion);
  console.log(r.stdout + r.stderr);
  console.log(`(${((Date.now() - t0) / 1000).toFixed(0)} s)`);
  process.exit(r.status ?? 1);
}

// Carga el dump de schema de prod (`supabase db dump --linked`: schema `public`, grants, sin datos). La imagen
// ya trae auth, extensions, vault y los roles; el dump referencia auth.uid()/auth.users y pide pg_stat_statements,
// pgcrypto, uuid-ossp, supabase_vault y unaccent (en public). Los privilegios por defecto de la imagen le dan
// rwU/X/arwdDxtm a anon sobre todo lo que se crea en public; el dump sólo REVOKEa PUBLIC y al dueño, así que
// se vacían antes de cargar (el dump deja los suyos al final). Sin ON_ERROR_STOP: se lista todo error.
function dump() {
  const archivo = process.argv[3];
  if (!archivo) throw new Error("Uso: docker-local.mjs dump <ruta-al-schema.sql>  (el archivo vive fuera del repo)");
  docker("cp", archivo, `${NOMBRE}:/tmp/schema-prod.sql`);
  psql(`ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES FROM postgres, anon, authenticated, service_role;
        ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM postgres, anon, authenticated, service_role;
        ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM postgres, anon, authenticated, service_role`);
  const t0 = Date.now();
  const r = dockerSpawn({}, "exec", NOMBRE, "bash", "-c",
    "psql -U postgres -h localhost -d postgres -q -f /tmp/schema-prod.sql >/dev/null 2>/tmp/dump-errores.txt; grep -E 'ERROR|DETAIL|FATAL' /tmp/dump-errores.txt | head -80; echo \"errores: $(grep -c ERROR /tmp/dump-errores.txt)\"");
  console.log(r.stdout + r.stderr);
  ajustarAuth();
  console.log(`(${((Date.now() - t0) / 1000).toFixed(0)} s)`);
}

// Lo que el dump no trae porque es de `auth.*` y la imagen lo trae distinto de Supabase real.
function ajustarAuth() {
  // Falta el trigger del alta de usuarios. Es el de prod, literal (leído con pg_get_triggerdef): sin él las
  // fixtures no arman perfiles ni usuario_sucursales.
  psql(`DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
        CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_user()`);
  // La imagen trae el `auth` viejo: auth.uid()/role()/email() sólo leen los GUC sueltos (`request.jwt.claim.sub`),
  // y PostgREST de hoy sólo setea `request.jwt.claims` (JSON). Se ponen las definiciones de Supabase actual
  // (COALESCE de las dos formas); sin esto auth.uid() da NULL y current_sucursal_id() también. El schema auth
  // es de supabase_auth_admin: se cambia como supabase_admin (superusuario de la imagen).
  docker("exec", NOMBRE, "psql", "-U", "supabase_admin", "-h", "localhost", "-d", "postgres", "-At", "-v", "ON_ERROR_STOP=1", "-c",
    `CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''), (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'))::uuid $$;
     CREATE OR REPLACE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$ select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'))::text $$;
     CREATE OR REPLACE FUNCTION auth.email() RETURNS text LANGUAGE sql STABLE AS $$ select coalesce(nullif(current_setting('request.jwt.claim.email', true), ''), (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email'))::text $$`);
}

function huella() {
  const sql = readFileSync(join(aqui, "huella-esquema.sql"), "utf8");
  console.log(psql(sql.replace(/^--.*$/gm, "")));
}

const cmd = process.argv[2];
if (cmd === "up") up();
else if (cmd === "migrar") migrar();
else if (cmd === "dump") dump();
else if (cmd === "auth") ajustarAuth();
else if (cmd === "huella") huella();
else if (cmd === "sql") console.log(psql(process.argv[3]));
else if (cmd === "down") { docker("rm", "-f", NOMBRE); console.log("contenedor borrado"); }
else { console.error("Uso: docker-local.mjs <up|migrar|huella|sql|down>"); process.exit(2); }
