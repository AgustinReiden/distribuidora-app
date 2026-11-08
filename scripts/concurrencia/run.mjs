// Corredor del arnés de concurrencia (#1288, plan #1378 tarjeta 1).
//
//   HARNESS_URL=https://<ref-de-la-rama>.supabase.co/functions/v1/harness \
//   HARNESS_TOKEN=<el del deploy> HARNESS_KEY=<anon key de la rama> \
//   node scripts/concurrencia/run.mjs <comando> [--rondas N] [--out carpeta]
//
// Comandos:
//   info                 qué conexión recibe la función (host, puerto, rol, max_connections)
//   fixtures             carga fixtures.sql en la rama (idempotente)
//   audit                corre auditoria_integridad() y guarda el resultado (la línea base)
//   c1 … c8 | todos      corre los escenarios de escenarios.mjs
//
// Manda a la edge function `harness` (desplegada SÓLO en la rama) el guion de cada
// variante, en tandas chicas para no pasar el límite de tiempo de la función,
// junta los resultados y escribe en <out>/:
//   · <escenario>.json   el crudo, con cada ronda
//   · <escenario>.md     la tabla lista para pegar en #1288
// Después de cada escenario corre auditoria_integridad() y dice qué cambió contra la línea base.
//
// Nunca corre contra prod: se niega si la URL nombra el ref de prod.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// HARNESS_ESCENARIOS cambia el módulo de escenarios (para ensayar el corredor con un caso de juguete).
const { ESCENARIOS } = await import(process.env.HARNESS_ESCENARIOS ?? "./escenarios.mjs");

const PROD_REF = "hmuchlzmuqqxcldbzkgc";
const { HARNESS_URL, HARNESS_TOKEN, HARNESS_KEY } = process.env;
const aqui = dirname(fileURLToPath(import.meta.url));

const args = process.argv.slice(2);
const flag = (n, def) => {
  const i = args.indexOf(`--${n}`);
  return i >= 0 ? args[i + 1] : def;
};
const comando = args.find((a, i) => !a.startsWith("--") && !(args[i - 1] ?? "").startsWith("--"));
const out = flag("out", join(aqui, "resultados"));
const rondasForzadas = flag("rondas", null) ? Number(flag("rondas")) : null;
const solo = flag("variante", null); // prefijo del nombre, p. ej. "C3b"

if (!HARNESS_URL || !HARNESS_TOKEN || !HARNESS_KEY) {
  console.error("Faltan HARNESS_URL, HARNESS_TOKEN y/o HARNESS_KEY (ver README.md).");
  process.exit(2);
}
if (HARNESS_URL.includes(PROD_REF)) {
  console.error(`HARNESS_URL nombra el ref de prod (${PROD_REF}): no corro contra prod.`);
  process.exit(2);
}

async function llamar(spec, reintentos = 1) {
  for (let i = 0; ; i++) {
    const r = await fetch(HARNESS_URL, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${HARNESS_KEY}`,
        apikey: HARNESS_KEY,
        "x-harness-token": HARNESS_TOKEN,
      },
      body: JSON.stringify(spec),
    });
    const txt = await r.text();
    if (r.ok) return JSON.parse(txt);
    if (i >= reintentos || r.status < 500) throw new Error(`HTTP ${r.status}: ${txt.slice(0, 800)}`);
  }
}

const sql = (...s) => llamar({ modo: "sql", sql: s });

// ----- auditoría ---------------------------------------------------------
async function auditar() {
  const r = await sql(
    "select set_config('request.jwt.claims', json_build_object('sub', conc.f('admin_a'), 'role', 'authenticated')::text, false)",
    "select set_config('request.headers', json_build_object('x-sucursal-id', conc.f('suc_a'))::text, false)",
    "select public.auditoria_integridad() as a",
  );
  const fila = r[2];
  if (fila?.error) return { error: fila.error };
  return fila[0].a;
}

// auditoria_integridad() devuelve una lista de checks; se mira cuáles no dan ok.
function fallos(a) {
  const lista = Array.isArray(a) ? a : (a?.checks ?? a?.resultados ?? []);
  const malos = {};
  for (const c of lista) {
    const ok = c.ok ?? c.paso ?? (c.estado ? c.estado === "ok" : undefined) ?? (c.violaciones != null ? Number(c.violaciones) === 0 : undefined) ?? (c.cantidad != null ? Number(c.cantidad) === 0 : undefined);
    if (ok === false) malos[c.id ?? c.check ?? c.nombre ?? JSON.stringify(c).slice(0, 40)] = c.cantidad ?? c.violaciones ?? c.detalle ?? true;
  }
  return malos;
}

// ----- variantes ---------------------------------------------------------
const esperado = (v, err) => (v.esperado ? v.esperado(err) : false);

// De dónde salió un 40P01 (el que Postgres eligió como víctima): el PL/pgSQL más interno ("función línea N") y la
// relación de la fila que esperaba. Con eso se totaliza quién pierde y dónde, no sólo cuántos deadlocks hubo.
const ubicacion = (err) => {
  const donde = err.where ?? "";
  const rel = /in relation "([^"]+)"/.exec(donde)?.[1] ?? "?";
  const fn = /PL\/pgSQL function ([^\n]+?) line (\d+) at ([^\n]+)/.exec(donde);
  return `${fn ? `${fn[1].replace(/\(.*\)/, "")} línea ${fn[2]}` : "SQL directo"} (esperaba una fila de ${rel})`;
};

async function correrVariante(v) {
  const total = rondasForzadas ?? v.rondas ?? 1;
  const lote = v.lote ?? 20;
  const t0 = Date.now();
  if (v.spec.modo === "carga") return { carga: await llamar(v.spec), seg: (Date.now() - t0) / 1000 };

  // Referencias seriales (si la variante las pide): el estado final de cada orden posible.
  let refs = null;
  if (v.referencias) {
    const set = new Set();
    for (const [k, ref] of v.referencias.entries()) {
      const r = await llamar({ ...ref, rounds: 3, ctx: { off: 0, base: 10 * k, ...(ref.ctx ?? {}) } });
      for (const g of r.detalle) {
        for (const x of g.verify) if (x.msg.startsWith("ESTADO=")) set.add(x.msg);
        for (const x of g.workers) if (!x.ok && !esperado(v, x.err)) process.stdout.write(`  (referencia ${k}: ${x.w} dio ${x.err.code} ${x.err.message.slice(0, 80)})\n`);
      }
    }
    refs = [...set];
    console.log(`  referencias seriales: ${refs.length} estados distintos`);
  }

  const agg = {
    rondas: 0, solape: 0, verify_fallidas: 0, locks_obs: 0, deadlocks: 0, deadlocks_base: 0,
    errores: {}, inesperados: {}, lat: {}, detalleFallos: [], locks: {}, muestras: 0, refs, interbloqueos: {},
  };
  for (let hecho = 0; hecho < total; hecho += lote) {
    const spec = {
      ...v.spec,
      rounds: Math.min(lote, total - hecho),
      ctx: { ...(v.spec.ctx ?? {}), off: hecho, ...(refs ? { refs: refs.join("|") } : {}) },
      ...(v.verify ? { verify: v.verify } : {}),
    };
    const r = await llamar(spec);
    agg.rondas += r.rondas;
    agg.solape += r.rondas_con_solape;
    agg.verify_fallidas += r.rondas_con_verify_fallido;
    agg.locks_obs += r.locks?.rondas_con_espera ?? 0;
    agg.muestras += r.locks?.muestras ?? 0;
    agg.deadlocks_base += r.deadlocks_de_la_base ?? 0;
    for (const [k, n] of Object.entries(r.locks?.esperas ?? {})) agg.locks[k] = (agg.locks[k] ?? 0) + n;
    for (const [k, s] of Object.entries(r.latencia_ms)) (agg.lat[k] ??= []).push(s);
    for (const g of r.detalle) {
      // Una ronda cuenta como correcta sólo si pasó el verify, no falló su preparación y ningún trabajador
      // tiró un error inesperado que no sea un deadlock (ése tiene su columna). Sin esto, un guion que
      // nunca corre (p. ej. un error de tipos en el paso 0) dejaría el estado "igual al de antes" y pasaría.
      let mala = !!g.setup_error || g.verify.some((x) => !x.ok);
      for (const w of g.workers) {
        if (w.ok) continue;
        const k = `${w.w}: ${w.err.code ?? "?"} ${w.err.message.replace(/\d{2}\/\d{2}\/\d{4}/g, "<fecha>").slice(0, 100)}`;
        agg.errores[k] = (agg.errores[k] ?? 0) + 1;
        if (w.err.code === "40P01") {
          agg.deadlocks++;
          const u = `${w.w} · ${ubicacion(w.err)}`;
          agg.interbloqueos[u] = (agg.interbloqueos[u] ?? 0) + 1;
        }
        // Un 40001 cuenta como inesperado salvo que la variante lo declare (hoy sólo C9c, con el mensaje de la 443):
        // ningún otro `esperado` lo acepta, así que en el resto sigue cayendo acá por !esperado (#1499).
        if (w.err.code === "40P01" || !esperado(v, w.err)) {
          agg.inesperados[k] = (agg.inesperados[k] ?? 0) + 1;
          if (w.err.code !== "40P01") mala = true;
          if (agg.detalleFallos.length < 6) agg.detalleFallos.push({ ronda: hecho + g.r, w: w.w, err: w.err });
        }
      }
      if (mala) agg.rondas_malas = (agg.rondas_malas ?? 0) + 1;
      for (const x of g.verify) {
        if (!x.ok && agg.detalleFallos.length < 6) agg.detalleFallos.push({ ronda: hecho + g.r, verify: x.msg });
      }
      if (g.setup_error && agg.detalleFallos.length < 6) agg.detalleFallos.push({ ronda: hecho + g.r, setup_error: g.setup_error });
    }
    process.stdout.write(`  ${v.nombre.slice(0, 60)}: ${agg.rondas}/${total}\r`);
  }
  process.stdout.write("\n");
  agg.seg = (Date.now() - t0) / 1000;
  return agg;
}

const maxDe = (arr, k) => (arr?.length ? Math.max(...arr.map((x) => x[k] ?? 0)) : null);

function tablaRondas(res) {
  const L = [
    "| Variante | Rondas | Con solape | Estado final correcto | 40P01 | Rondas con espera de lock vista | Otros errores inesperados | p50 / p95 ms (por trabajador) |",
    "|---|---|---|---|---|---|---|---|",
  ];
  for (const { v, r } of res) {
    const lat = Object.entries(r.lat).map(([k, a]) => `${k}: ${maxDe(a, "p50")} / ${maxDe(a, "p95")}`).join("<br>");
    const otros = Object.entries(r.inesperados).filter(([k]) => !k.includes(": 40P01 ")).map(([k, n]) => `${n}× ${k}`).join("<br>") || "—";
    L.push(`| ${v.nombre} | ${r.rondas} | ${r.solape} | ${r.rondas - (r.rondas_malas ?? 0)}/${r.rondas} | ${r.deadlocks} (base: ${r.deadlocks_base}) | ${r.locks_obs}/${r.rondas} | ${otros} | ${lat} |`);
  }
  return L.join("\n");
}

function mdCarga(v, r) {
  const c = r.carga;
  const L = [`**${v.nombre}** · ${c.cajas} caja(s), ${c.segundos} s · deadlocks de la base: ${c.deadlocks_de_la_base} · tx confirmadas: ${c.transacciones_confirmadas}, revertidas: ${c.transacciones_revertidas}`];
  for (const [k, o] of Object.entries(c.por_operacion)) {
    L.push(`- ${k}: ${o.ok}/${o.intentos} ok → **${o.por_segundo}/s** · p50 ${o.latencia_ok_ms.p50} ms · p95 ${o.latencia_ok_ms.p95} ms · p99 ${o.latencia_ok_ms.p99} ms · errores ${JSON.stringify(o.error_codes)}`);
  }
  const esp = Object.entries(c.locks?.esperas ?? {}).slice(0, 6);
  L.push(`- esperas de lock: ${c.locks?.muestras_con_espera}/${c.locks?.muestras} muestras con alguien esperando (máx. ${c.locks?.max_esperando_a_la_vez} a la vez)` + (esp.length ? "; " + esp.map(([k, n]) => `${k} (${n})`).join("; ") : ""));
  const mm = Object.entries(c.mensajes_de_error ?? {}).slice(0, 4);
  if (mm.length) L.push(`- errores: ${mm.map(([k, o]) => `${o.n}× ${k}`).join("; ")}`);
  return L.join("\n");
}

// ----- comandos ----------------------------------------------------------
async function cmdInfo() {
  console.log(JSON.stringify(await llamar({ modo: "info" }), null, 1));
}

async function cmdFixtures() {
  const bloques = readFileSync(join(aqui, "fixtures.sql"), "utf8").split(/^-- GO\s*$/m).map((b) => b.trim()).filter(Boolean);
  const r = await sql(...bloques);
  const malos = r.map((x, i) => (x?.error ? { bloque: i, sql: bloques[i].slice(0, 80), error: x.error } : null)).filter(Boolean);
  if (malos.length) {
    console.error(JSON.stringify(malos, null, 1));
    process.exit(1);
  }
  const s = await sql("select conc.sembrar(16, 200, 100) as s");
  console.log("fixtures ok:", Object.keys(s[0][0].s).length, "claves");
}

async function cmdAudit() {
  mkdirSync(out, { recursive: true });
  const a = await auditar();
  writeFileSync(join(out, "auditoria-base.json"), JSON.stringify(a, null, 1));
  console.log("auditoría base guardada. Fallos:", JSON.stringify(fallos(a)));
}

async function cmdEscenarios() {
  mkdirSync(out, { recursive: true });
  const ids = comando === "todos" ? Object.keys(ESCENARIOS) : [comando];
  let base = {};
  try {
    base = fallos(JSON.parse(readFileSync(join(out, "auditoria-base.json"), "utf8")));
  } catch (_) { /* sin base: se compara contra vacío */ }
  for (const id of ids) {
    const esc = ESCENARIOS[id];
    console.log(`\n== ${id}: ${esc.titulo}`);
    const res = [];
    for (const v of esc.variantes()) {
      if (solo && !v.nombre.startsWith(solo)) continue;
      console.log(`- ${v.nombre}`);
      res.push({ v, r: await correrVariante(v) });
    }
    const aud = await auditar();
    const nuevos = Object.entries(fallos(aud)).filter(([k]) => !(k in base));
    let md = `### ${id.toUpperCase()} · ${esc.titulo}\n\n`;
    const rondas = res.filter((x) => !x.r.carga);
    if (rondas.length) md += tablaRondas(rondas) + "\n\n";
    for (const { v, r } of rondas) {
      const esperas = Object.entries(r.locks).sort((a, b) => b[1] - a[1]).slice(0, 5);
      if (esperas.length) md += `*${v.nombre.slice(0, 4)}* esperas de lock vistas: ${esperas.map(([k, n]) => `${k} (${n})`).join("; ")}\n\n`;
      const victimas = Object.entries(r.interbloqueos ?? {}).sort((a, b) => b[1] - a[1]);
      if (victimas.length) md += `*${v.nombre.slice(0, 4)}* víctimas de 40P01 (trabajador · dónde): ${victimas.map(([k, n]) => `${k} (${n})`).join("; ")}\n\n`;
      if (r.detalleFallos.length) md += "Primeros fallos de " + v.nombre.slice(0, 4) + ":\n```json\n" + JSON.stringify(r.detalleFallos, null, 1).slice(0, 3500) + "\n```\n\n";
    }
    for (const { v, r } of res.filter((x) => x.r.carga)) md += mdCarga(v, r) + "\n\n";
    md += `**auditoria_integridad() después de ${id.toUpperCase()}:** ` + (nuevos.length ? `checks nuevos en rojo: ${JSON.stringify(Object.fromEntries(nuevos))}` : "sin checks nuevos en rojo respecto de la línea base") + ".\n";
    writeFileSync(join(out, `${id}.json`), JSON.stringify({ variantes: res.map(({ v, r }) => ({ variante: v.nombre, resultado: r })), auditoria: aud }, null, 1));
    writeFileSync(join(out, `${id}.md`), md);
    console.log("\n" + md);
  }
}

const tabla = { info: cmdInfo, fixtures: cmdFixtures, audit: cmdAudit };
(tabla[comando] ?? (ESCENARIOS[comando] || comando === "todos" ? cmdEscenarios : null) ?? (() => {
  console.error(`Uso: run.mjs <info|fixtures|audit|${Object.keys(ESCENARIOS).join("|")}|todos> [--rondas N] [--variante C3b] [--out dir]`);
  process.exit(2);
}))().catch((e) => {
  console.error(e);
  process.exit(1);
});
