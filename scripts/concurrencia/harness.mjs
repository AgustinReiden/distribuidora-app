// =========================================================================
// Arnés de concurrencia (plan #1378, tarjeta 1; issue #1288)
//
// QUÉ ES
// ------
// El código de UNA edge function de prueba que se despliega A MANO, SÓLO EN UNA
// RAMA DE SUPABASE (nunca en prod), con el nombre `harness`. Recibe
// `SUPABASE_DB_URL` y abre las conexiones que haga falta: es la única forma de
// tener dos (o treinta) transacciones a la vez contra la misma base, porque no
// hay `psql` en la máquina de trabajo y el MCP da una conexión por llamada.
//
// NO está en `supabase/functions/` A PROPÓSITO: `deploy-functions.yml` despliega
// esa carpeta a prod al mergear. Esto vive en `scripts/concurrencia/` y se sube
// con `deploy_edge_function` apuntando al project_id de la rama (ver README.md).
//
// Es JS plano (no TS) para que ni `tsc` ni ESLint del front lo tomen por código
// de la app. Se despliega con el nombre de archivo `index.ts`: JS es TS válido.
//
// ES GENÉRICO: no sabe nada del negocio. Recibe un guion (JSON) con SQL por
// trabajador y lo ejecuta; los guiones de cada escenario están en
// `scripts/concurrencia/escenarios.mjs` y los manda `run.mjs`.
//
// SEGURIDAD
// ---------
//  · Se niega a correr si la URL del proyecto o de la base nombra el ref de prod.
//  · Pide el header `x-harness-token` (el valor se pone en el deploy).
//  · Es de una rama sin datos reales, que se borra al terminar la corrida.
// =========================================================================
import postgres from "npm:postgres@3.4.4";

const PROD_REF = "hmuchlzmuqqxcldbzkgc";
const TOKEN = Deno.env.get("HARNESS_TOKEN") ?? "__HARNESS_TOKEN__";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const rand = (n) => (n > 0 ? Math.floor(Math.random() * (n + 1)) : 0);

function pct(sorted, p) {
  if (!sorted.length) return null;
  return sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))];
}
function stats(ms) {
  const s = [...ms].sort((a, b) => a - b);
  const sum = s.reduce((a, b) => a + b, 0);
  return {
    n: s.length,
    p50: pct(s, 50),
    p95: pct(s, 95),
    p99: pct(s, 99),
    max: s.length ? s[s.length - 1] : null,
    media: s.length ? +(sum / s.length).toFixed(1) : null,
  };
}

// {{a.b}} -> valor de ctx.a.b. Los strings se escapan para ir dentro de '...'.
function sub(sql, ctx) {
  return sql.replace(/\{\{([\w.]+)\}\}/g, (_, path) => {
    let v = ctx;
    for (const k of path.split(".")) v = v == null ? undefined : v[k];
    if (v === undefined || v === null) throw new Error(`falta {{${path}}} en el contexto`);
    return typeof v === "object" ? JSON.stringify(v).replace(/'/g, "''") : String(v).replace(/'/g, "''");
  });
}

function impersonar(uid, suc) {
  // auth.uid() lee request.jwt.claims; se setea también la forma vieja. La
  // sucursal activa la manda el front en el header x-sucursal-id.
  return `SET LOCAL ROLE authenticated; ` +
    `SELECT set_config('request.jwt.claims', json_build_object('sub','${uid}','role','authenticated')::text, true), ` +
    `set_config('request.jwt.claim.sub', '${uid}', true), set_config('request.jwt.claim.role', 'authenticated', true)` +
    (suc ? `, set_config('request.headers', json_build_object('x-sucursal-id','${suc}')::text, true)` : "");
}

const errInfo = (e) => ({
  code: e?.code ?? null,
  message: String(e?.message ?? e).slice(0, 400),
  detail: e?.detail ? String(e.detail).slice(0, 600) : null,
  where: e?.where ? String(e.where).slice(0, 600) : null,
});

function abrir(url) {
  return postgres(url, {
    max: 1,
    prepare: false,
    idle_timeout: 0,
    connect_timeout: 30,
    onnotice: () => {},
  });
}

// Una transacción de un trabajador. Los pasos comparten `vars`: la primera fila
// de cada paso se mezcla en ellas (columna `r` jsonb -> {{r.campo}}).
async function transaccion(c, w, base, opts) {
  const t0 = performance.now();
  const rec = { ok: true, err: null, ms: 0, ini: t0, fin: 0, pasos: [] };
  const vars = { ...base };
  let paso = -1;
  try {
    await c.unsafe("BEGIN");
    await c.unsafe(`SET LOCAL statement_timeout = ${opts.statement_timeout_ms}`);
    if (w.as) await c.unsafe(impersonar(sub(w.as, vars), w.suc ? sub(String(w.suc), vars) : null));
    for (let i = 0; i < w.steps.length; i++) {
      paso = i;
      const rows = await c.unsafe(sub(w.steps[i], vars));
      const fila = rows[0] ?? null;
      if (fila) Object.assign(vars, fila);
      if (opts.guardar_pasos) rec.pasos.push(fila);
    }
    await c.unsafe("COMMIT");
  } catch (e) {
    rec.ok = false;
    rec.err = { ...errInfo(e), paso };
    try {
      await c.unsafe("ROLLBACK");
    } catch (_) { /* la conexión puede estar cerrada */ }
  }
  rec.fin = performance.now();
  rec.ms = +(rec.fin - t0).toFixed(1);
  rec.vars = vars;
  return rec;
}

// Muestrea quién espera un lock, por qué relación y detrás de quién.
const SQL_MUESTRA = `
SELECT a.pid,
       a.wait_event,
       substring(a.query from 'public\\.(\\w+)\\(') AS fn,
       (SELECT string_agg(DISTINCT coalesce(substring(b.query from 'public\\.(\\w+)\\('), left(b.query, 40)), ',')
          FROM pg_stat_activity b WHERE b.pid = ANY (pg_blocking_pids(a.pid))) AS bloquea,
       (SELECT string_agg(DISTINCT coalesce(l.relation::regclass::text, l.locktype), ',')
          FROM pg_locks l
         WHERE l.pid = a.pid
           AND ((l.locktype IN ('relation','extend','advisory','page') AND NOT l.granted)
                OR l.locktype = 'tuple')) AS sobre
  FROM pg_stat_activity a
 WHERE a.datname = current_database() AND a.pid <> pg_backend_pid()
   AND a.wait_event_type = 'Lock'`;

function muestreador(url, ms) {
  const estado = { activo: true, ronda: -1, muestras: 0, con_espera: 0, claves: {}, rondas_con_espera: new Set(), max_esperando: 0 };
  const c = abrir(url);
  const tarea = (async () => {
    while (estado.activo) {
      try {
        const rows = await c.unsafe(SQL_MUESTRA);
        estado.muestras++;
        if (rows.length) {
          estado.con_espera++;
          estado.max_esperando = Math.max(estado.max_esperando, rows.length);
          if (estado.ronda >= 0) estado.rondas_con_espera.add(estado.ronda);
          for (const r of rows) {
            const k = `${r.fn ?? "?"} espera ${r.sobre ?? "?"} [${r.wait_event}] detrás de ${r.bloquea ?? "?"}`;
            estado.claves[k] = (estado.claves[k] ?? 0) + 1;
          }
        }
      } catch (_) { /* ignorar: sólo es observación */ }
      await sleep(ms);
    }
    await c.end({ timeout: 2 }).catch(() => {});
  })();
  return { estado, parar: async () => { estado.activo = false; await tarea; } };
}

function resumenLocks(m) {
  const top = Object.entries(m.estado.claves).sort((a, b) => b[1] - a[1]).slice(0, 25);
  return {
    muestras: m.estado.muestras,
    muestras_con_espera: m.estado.con_espera,
    max_esperando_a_la_vez: m.estado.max_esperando,
    rondas_con_espera: m.estado.rondas_con_espera.size,
    esperas: Object.fromEntries(top),
  };
}

async function snapshots(admin, defs) {
  const out = {};
  for (const [k, sql] of Object.entries(defs ?? {})) {
    try {
      out[k] = await admin.unsafe(sql);
    } catch (e) {
      out[k] = { error: errInfo(e) };
    }
  }
  return out;
}

const SQL_DBSTAT = "SELECT deadlocks, xact_commit, xact_rollback, blks_hit, blks_read FROM pg_stat_database WHERE datname = current_database()";
const dbstat = async (admin) => (await admin.unsafe(SQL_DBSTAT))[0];

// Cada caja/trabajador usa su propio usuario si el setup devolvió `users`.
const conUsuario = (ctx, i) => (Array.isArray(ctx.users) && ctx.users.length ? { ...ctx, uid: ctx.users[i % ctx.users.length] } : ctx);

async function modoRondas(url, spec, opts) {
  const admin = abrir(url);
  const sampler = spec.sample_ms ? muestreador(url, spec.sample_ms) : null;
  const conns = spec.workers.map(() => abrir(url));
  const rondas = [];
  const dbAntes = await dbstat(admin);
  try {
    await Promise.all(conns.map((c) => c.unsafe("SELECT 1")));
    for (let r = 0; r < spec.rounds; r++) {
      if (sampler) sampler.estado.ronda = r;
      const ctx = { ...(spec.ctx ?? {}), round: r };
      const reg = { r, verify: [], workers: [], setup_error: null };
      try {
        for (const s of spec.setup ?? []) {
          const rows = await admin.unsafe(sub(s, ctx));
          if (rows[0]) Object.assign(ctx, rows[0]);
        }
      } catch (e) {
        reg.setup_error = errInfo(e);
        rondas.push(reg);
        continue;
      }
      let soltar;
      const puerta = new Promise((res) => { soltar = res; });
      const trabajos = spec.workers.map((w, i) => (async () => {
        await puerta;
        const espera = (w.delay_ms ?? 0) + rand(w.jitter_ms ?? 0);
        if (espera > 0) await sleep(espera);
        return await transaccion(conns[i], w, conUsuario({ ...ctx, worker: i }, i), opts);
      })());
      soltar();
      const res = await Promise.all(trabajos);
      reg.workers = res.map((x, i) => ({
        w: spec.workers[i].label ?? `w${i}`,
        ok: x.ok,
        ms: x.ms,
        ini: +(x.ini - res[0].ini).toFixed(1),
        err: x.err,
        pasos: x.pasos,
      }));
      // ¿las transacciones se pisaron en el tiempo?
      let solape = false;
      for (let i = 0; i < res.length; i++) {
        for (let j = i + 1; j < res.length; j++) {
          if (res[i].ini < res[j].fin && res[j].ini < res[i].fin) solape = true;
        }
      }
      reg.solape = solape;
      try {
        for (const s of spec.verify ?? []) {
          const rows = await admin.unsafe(sub(s, ctx));
          for (const row of rows) reg.verify.push({ ok: !!row.ok, msg: String(row.msg ?? "") });
        }
      } catch (e) {
        reg.verify.push({ ok: false, msg: `verify falló: ${errInfo(e).message}` });
      }
      for (const s of spec.teardown ?? []) {
        try { await admin.unsafe(sub(s, ctx)); } catch (_) { /* limpieza best-effort */ }
      }
      rondas.push(reg);
    }
  } finally {
    if (sampler) await sampler.parar();
    await Promise.all(conns.map((c) => c.end({ timeout: 2 }).catch(() => {})));
  }
  const final = await snapshots(admin, spec.final);
  const dbDespues = await dbstat(admin);
  await admin.end({ timeout: 2 }).catch(() => {});

  // Agregados.
  const porEtiqueta = {};
  const codigos = {};
  for (const g of rondas) {
    for (const w of g.workers) {
      (porEtiqueta[w.w] ??= []).push(w.ms);
      if (!w.ok) {
        const k = `${w.w}: ${w.err.code ?? "?"} ${w.err.message.slice(0, 90)}`;
        codigos[k] = (codigos[k] ?? 0) + 1;
      }
    }
  }
  return {
    modo: "rondas",
    rondas: rondas.length,
    rondas_con_solape: rondas.filter((g) => g.solape).length,
    rondas_con_verify_fallido: rondas.filter((g) => g.verify.some((v) => !v.ok)).length,
    errores: codigos,
    latencia_ms: Object.fromEntries(Object.entries(porEtiqueta).map(([k, v]) => [k, stats(v)])),
    locks: sampler ? resumenLocks(sampler) : null,
    deadlocks_de_la_base: Number(dbDespues.deadlocks) - Number(dbAntes.deadlocks),
    final,
    detalle: rondas,
  };
}

async function modoCarga(url, spec, opts) {
  const admin = abrir(url);
  const antes = await snapshots(admin, spec.snapshots);
  const sampler = spec.sample_ms ? muestreador(url, spec.sample_ms) : null;
  const copias = spec.copies ?? 1;
  const conns = Array.from({ length: copias }, () => abrir(url));
  const ctx = { ...(spec.ctx ?? {}) };
  for (const s of spec.setup ?? []) {
    const rows = await admin.unsafe(sub(s, ctx));
    if (rows[0]) Object.assign(ctx, rows[0]);
  }
  await Promise.all(conns.map((c) => c.unsafe("SELECT 1")));
  const dbAntes = await dbstat(admin);
  const fin = performance.now() + spec.duration_s * 1000;
  const t0 = performance.now();
  const ops = []; // { w, ok, ms, code }
  const mensajes = {};
  // Una caja repite su `seq` (una o más transacciones seguidas, como las llamadas
  // de la app: vender y después cobrar) hasta que se acaba el tiempo. Si una
  // transacción de la secuencia falla, la secuencia se corta.
  const caja = async (i) => {
    let iter = 0;
    while (performance.now() < fin) {
      const w = spec.workers[i % spec.workers.length];
      let vars = conUsuario({ ...ctx, worker: i, iter: iter++ }, i);
      for (const tx of w.seq ?? [w]) {
        const r = await transaccion(conns[i], tx, vars, opts);
        vars = r.vars;
        ops.push({ w: tx.label ?? w.label ?? "op", ok: r.ok, ms: r.ms, code: r.err?.code ?? null });
        if (!r.ok) {
          const k = `${r.err.code ?? "?"} ${r.err.message.slice(0, 110)}`;
          if (!mensajes[k]) mensajes[k] = { n: 0, where: r.err.where, detail: r.err.detail };
          mensajes[k].n++;
          break;
        }
      }
      if (spec.think_ms) await sleep(spec.think_ms + rand(spec.think_jitter_ms ?? 0));
    }
  };
  await Promise.all(conns.map((_, i) => caja(i)));
  const seg = (performance.now() - t0) / 1000;
  if (sampler) await sampler.parar();
  await Promise.all(conns.map((c) => c.end({ timeout: 2 }).catch(() => {})));
  const despues = await snapshots(admin, spec.snapshots);
  const final = await snapshots(admin, spec.final);
  const dbDespues = await dbstat(admin);
  await admin.end({ timeout: 2 }).catch(() => {});

  const porOp = {};
  for (const o of ops) (porOp[o.w] ??= []).push(o);
  const resumen = {};
  for (const [k, v] of Object.entries(porOp)) {
    const buenas = v.filter((o) => o.ok);
    resumen[k] = {
      intentos: v.length,
      ok: buenas.length,
      por_segundo: +(buenas.length / seg).toFixed(2),
      latencia_ok_ms: stats(buenas.map((o) => o.ms)),
      error_codes: v.filter((o) => !o.ok).reduce((a, o) => ((a[o.code ?? "?"] = (a[o.code ?? "?"] ?? 0) + 1), a), {}),
    };
  }
  return {
    modo: "carga",
    cajas: copias,
    segundos: +seg.toFixed(1),
    por_operacion: resumen,
    mensajes_de_error: mensajes,
    locks: sampler ? resumenLocks(sampler) : null,
    deadlocks_de_la_base: Number(dbDespues.deadlocks) - Number(dbAntes.deadlocks),
    transacciones_confirmadas: Number(dbDespues.xact_commit) - Number(dbAntes.xact_commit),
    transacciones_revertidas: Number(dbDespues.xact_rollback) - Number(dbAntes.xact_rollback),
    snapshots_antes: antes,
    snapshots_despues: despues,
    final,
  };
}

Deno.serve(async (req) => {
  const url = Deno.env.get("SUPABASE_DB_URL") ?? "";
  const api = Deno.env.get("SUPABASE_URL") ?? "";
  if (url.includes(PROD_REF) || api.includes(PROD_REF)) {
    return new Response("prohibido: este arnés no corre contra prod", { status: 403 });
  }
  if (req.headers.get("x-harness-token") !== TOKEN || TOKEN.startsWith("__")) {
    return new Response("token inválido", { status: 401 });
  }
  let spec;
  try {
    spec = await req.json();
  } catch (_) {
    return new Response("json inválido", { status: 400 });
  }
  const opts = { statement_timeout_ms: spec.statement_timeout_ms ?? 30000, guardar_pasos: spec.guardar_pasos ?? true };
  try {
    if (spec.modo === "info") {
      const u = new URL(url.replace(/^postgres(ql)?:/, "http:"));
      const admin = abrir(url);
      const v = await admin.unsafe("select version() as v, current_user as u, current_setting('max_connections') as maxc, current_setting('deadlock_timeout') as dt");
      await admin.end({ timeout: 2 });
      return Response.json({ host: u.hostname, port: u.port, user: u.username.replace(/\..*/, ".<ref>"), db: v[0] });
    }
    if (spec.modo === "sql") {
      const admin = abrir(url);
      const out = [];
      for (const s of spec.sql) {
        try { out.push(await admin.unsafe(s)); } catch (e) { out.push({ error: errInfo(e) }); }
      }
      await admin.end({ timeout: 2 });
      return Response.json(out);
    }
    const res = spec.modo === "carga" ? await modoCarga(url, spec, opts) : await modoRondas(url, spec, opts);
    return Response.json(res);
  } catch (e) {
    return Response.json({ error: errInfo(e) }, { status: 500 });
  }
});
