/**
 * Conexión directa a Postgres para los gates que leen el CATÁLOGO (pg_proc, pg_policy,
 * pg_publication…) en vez de llamar a un RPC `auditoria_*`. Sin dependencias: corre
 * `psql`, que está en los runners de GitHub y en el contenedor local.
 *
 * Por qué existe (#1564, #1601): los gates anteriores son un RPC SQL que devuelve un
 * JSON, y endurecerlos o sumar uno nuevo obligaba a una migración. Estos corren su
 * consulta (de sólo lectura) desde el repo, así que un gate nuevo no toca prod.
 *
 * A qué base apuntan (en este orden):
 *   · GATE_DB_CONTENEDOR=<nombre>   `docker exec -i <nombre> psql -U postgres …`
 *     (la base local de Docker: scripts/concurrencia/docker-local.mjs).
 *   · GATE_DB_URL=<url de conexión>    una URL de conexión (psql).
 *   · SUPABASE_DB_URL               la de prod, que ya existe como secret del repo
 *     (backup.yml). Sólo para el cron de integridad.yml.
 *
 * Las consultas son de sólo lectura. Los que escriben (cruce-ids) lo hacen en una
 * transacción que termina en ROLLBACK, y NUNCA contra prod (ver check-cruce-ids.mjs).
 */
import { spawnSync } from 'node:child_process';

/** Cómo llegar a la base, o null si ninguna variable está puesta. */
export function destino(env = process.env) {
  if (env.GATE_DB_CONTENEDOR) {
    return { tipo: 'docker', contenedor: env.GATE_DB_CONTENEDOR, descripcion: `contenedor ${env.GATE_DB_CONTENEDOR}` };
  }
  const url = env.GATE_DB_URL || env.SUPABASE_DB_URL;
  if (url) return { tipo: 'url', url, descripcion: 'la base de GATE_DB_URL / SUPABASE_DB_URL' };
  return null;
}

/** ¿Apunta a prod? Los gates que escriben (aunque sea con ROLLBACK) se niegan. */
export function apuntaAProd(d) {
  const ref = 'hmuchlzmuqqxcldbzkgc';
  return d?.tipo === 'url' && d.url.includes(ref);
}

const ARGS_PSQL = ['-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1'];

/** Corre `sql` (por stdin) y devuelve la salida. Tira un Error con el mensaje de psql si falla. */
export function psql(sql, { env = process.env, destino: d = destino(env) } = {}) {
  if (!d) throw new Error('Falta GATE_DB_CONTENEDOR, GATE_DB_URL o SUPABASE_DB_URL: el gate no puede mirar el catálogo.');
  const [cmd, args] =
    d.tipo === 'docker'
      ? ['docker', ['exec', '-i', d.contenedor, 'psql', '-U', 'postgres', '-h', 'localhost', '-d', 'postgres', ...ARGS_PSQL]]
      : ['psql', [d.url, ...ARGS_PSQL]];
  const r = spawnSync(cmd, args, { input: sql, encoding: 'utf8', maxBuffer: 1 << 28 });
  if (r.error) throw new Error(`No pude ejecutar ${cmd}: ${r.error.message}`);
  if (r.status !== 0) {
    // psql imprime el SQL fallido en el error: sólo se muestra su primera línea.
    const msg = (r.stderr || '').split('\n').find((l) => l.trim()) ?? `código ${r.status}`;
    throw new Error(`psql falló: ${msg}`);
  }
  return r.stdout;
}

/**
 * Corre un guion y devuelve {status, stdout, stderr} sin tirar nada: para los ensayos, que
 * dicen su veredicto en un NOTICE o en el mensaje de su excepción final (los dos van por
 * stderr) y cuyo exit code no es el veredicto. Sin `-At`: el formato no importa.
 */
export function psqlCompleto(sql, { destino: d } = {}) {
  if (!d) throw new Error('Falta la base (destino).');
  const [cmd, args] =
    d.tipo === 'docker'
      ? ['docker', ['exec', '-i', d.contenedor, 'psql', '-U', 'postgres', '-h', 'localhost', '-d', 'postgres', '-X', '-q']]
      : ['psql', [d.url, '-X', '-q']];
  const r = spawnSync(cmd, args, { input: sql, encoding: 'utf8', maxBuffer: 1 << 28 });
  if (r.error) throw new Error(`No pude ejecutar ${cmd}: ${r.error.message}`);
  return { status: r.status, stdout: r.stdout ?? '', stderr: r.stderr ?? '' };
}

/** Corre una consulta que devuelve UN jsonb (una sola fila, una sola columna) y lo parsea. */
export function consultaJson(sql, opciones) {
  const salida = psql(sql, opciones).trim();
  if (!salida) throw new Error('La consulta no devolvió nada.');
  return JSON.parse(salida);
}
