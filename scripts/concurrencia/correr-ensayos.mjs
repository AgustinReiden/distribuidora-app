// Corre los ensayos `scripts/test-*.sql` contra la base LOCAL del arnés, uno por uno, y arma la tabla (#1539, #1603 B13b).
//
//   CONC_NOMBRE=<contenedor> node scripts/concurrencia/correr-ensayos.mjs [filtro] [--salida tabla.md]
//
// Un ensayo PASA si en su salida aparece `ENSAYO OK` (o «ensayo … OK» en los más viejos): la mayoría termina en un RAISE EXCEPTION que deshace todo, y esa
// línea (`ERROR:  ENSAYO OK …`) es el éxito; los que usan un sub-bloque lo dejan como NOTICE. Todo lo demás es FALLA, con
// la primera línea de error como causa. Cada ensayo corre en UNA transacción (`psql -1`): los que terminan en un NOTICE «ENSAYO OK» y
// un `RAISE ENSAYO_ROLLBACK` aparte (como `test-combo-fecha-1260`) commiteaban su primer `DO` con el autocommit de `-f` y dejaban
// productos, combos y clientes en la base, que se cruzaban con los ensayos siguientes (`clientes_codigo_unique`, checks en rojo). Los dos `test-concurrencia-*` NO CORREN acá: piden dos `psql` a mano y COMMITEAN
// (dejan un cliente y un pedido en la base); se los salta.
//
// Antes de correrlos hace falta la semilla de datos: `docker-local.mjs semilla` y `semilla-ensayos` (ver el README). Corre
// contra la copia local de Docker; nunca contra prod (el contenedor es el único destino).
import { spawnSync } from "node:child_process";
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const aqui = dirname(fileURLToPath(import.meta.url));
const scripts = join(aqui, "..");
const NOMBRE = process.env.CONC_NOMBRE ?? "conc-pg";
const args = process.argv.slice(2);
const iSalida = args.indexOf("--salida");
const salida = iSalida >= 0 ? args.splice(iSalida, 2)[1] : null;
const filtro = args[0] ?? "";

const archivos = readdirSync(scripts).filter((f) => /^test-.*\.sql$/.test(f) && f.includes(filtro)).sort();
const filas = [];
for (const f of archivos) {
  if (f.includes("concurrencia")) {
    filas.push([f, "NO CORRE", "pide dos psql a mano y commitea (ver su encabezado)"]);
    continue;
  }
  const r = spawnSync("docker", ["exec", "-i", NOMBRE, "psql", "-U", "postgres", "-h", "localhost", "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-1", "-f", "-"], {
    input: readFileSync(join(scripts, f)),
    encoding: "utf8",
    maxBuffer: 1 << 28,
    timeout: 5 * 60 * 1000,
  });
  const out = `${r.stdout ?? ""}\n${r.stderr ?? ""}`;
  // `ENSAYO OK …` (casi todos) o, en los más viejos, «ensayo #… OK» (sin la palabra FALLÓ en la misma línea).
  if (out.split("\n").some((l) => /ensayo/i.test(l) && /\bOK\b/.test(l) && !/FALL/i.test(l))) filas.push([f, "PASA", ""]);
  else {
    const linea = out.split("\n").find((l) => /ERROR|FATAL|ENSAYO/.test(l)) ?? (r.error ? String(r.error) : "(sin mensaje)");
    filas.push([f, "FALLA", linea.replace(/^psql:<stdin>:\d+: /, "").slice(0, 240)]);
  }
  console.log(`${filas.at(-1)[1].padEnd(9)} ${f}`);
}
const n = (v) => filas.filter((x) => x[1] === v).length;
const md = [`| Ensayo | Resultado | Causa |`, `|---|---|---|`, ...filas.map(([f, v, c]) => `| ${f} | ${v} | ${c.replace(/\|/g, "\\|")} |`),
  "", `PASA ${n("PASA")} · FALLA ${n("FALLA")} · NO CORRE ${n("NO CORRE")} de ${filas.length}`].join("\n");
if (salida) writeFileSync(salida, md);
console.log(`\nPASA ${n("PASA")} · FALLA ${n("FALLA")} · NO CORRE ${n("NO CORRE")} de ${filas.length}`);
