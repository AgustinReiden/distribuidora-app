// Evaluación de modelos del bot (#979): corre las mismas preguntas contra cada
// modelo con el agente de verdad y herramientas reales (sólo lectura), y
// compara elección de herramienta, argumentos, números inventados, costo y
// latencia.
//
//   deno run -A _eval/correr.ts --modelos=gpt-6-luna,gemini-3.5-flash-lite,gemini-2.5-flash \
//     [--casos=a01_catalogo,p08_mis_ventas_mes] [--salida=resultado.json]
//
// Variables: SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY (siempre), GEMINI_API_KEY
// y/o OPENAI_API_KEY según los modelos, y opcionales EVAL_ADMIN_ID,
// EVAL_PREVENTISTA_ID, EVAL_ENCARGADO_ID, EVAL_SUCURSAL_ID (default 1).
//
// No toca el audit log de producción (BOT_AUDIT_DISABLED, ver _shared/audit.ts),
// no guarda conversación (ephemeral) y no suma al techo de gasto (`modelo`).


import type { SupabaseClient } from "@supabase/supabase-js";
import { runAgent } from "../_shared/gemini/agent.ts";
import { getServiceRoleClient } from "../_shared/supabase.ts";
import { registerAllTools } from "../_shared/tools/index.ts";
import type { BotRol, BotUser } from "../_shared/types.ts";
import { type CasoEval, CASOS, type RolEval } from "./casos.ts";
import { type Evaluacion, evaluarCaso, hoyAR, type ToolCallEval } from "./evaluar.ts";

const TELEGRAM_USER_ID_EVAL = -979;

export interface ResultadoCaso {
  caso: string;
  rol: RolEval;
  modelo: string;
  texto: string;
  herramientas: string[];
  toolCalls: ToolCallEval[];
  evaluacion: Evaluacion;
  costoUsd: number;
  ms: number;
  error?: string;
}

function parsearArgs(argv: string[]): Record<string, string> {
  const out: Record<string, string> = {};
  for (const a of argv) {
    const m = a.match(/^--([^=]+)=(.*)$/);
    if (m) out[m[1]] = m[2];
  }
  return out;
}

async function resolverUsuario(
  sb: SupabaseClient,
  rol: RolEval,
  sucursalId: number,
  idForzado: string | undefined,
): Promise<BotUser | null> {
  const armar = (perfilId: string): BotUser => ({
    telegram_user_id: TELEGRAM_USER_ID_EVAL,
    perfil_id: perfilId,
    rol: rol as BotRol,
    roles: [rol as BotRol],
    sucursal_id: sucursalId,
    activo: true,
  });

  if (idForzado) {
    const { data } = await sb.from("perfiles").select("id, activo").eq("id", idForzado)
      .maybeSingle();
    return data && data.activo !== false ? armar(String(data.id)) : null;
  }

  const { data: perfiles, error } = await sb.from("perfiles").select("id").eq("rol", rol)
    .eq("activo", true);
  if (error) throw new Error(`perfiles (${rol}): ${error.message}`);
  const ids = (perfiles ?? []).map((p) => String(p.id));
  if (ids.length === 0) return null;

  const { data: asignadas } = await sb.from("usuario_sucursales").select("usuario_id")
    .eq("sucursal_id", sucursalId).in("usuario_id", ids);
  const enSucursal = (asignadas ?? []).map((a) => String(a.usuario_id));
  // Si ninguno está asignado a la sucursal pedida no hay con quién evaluar ese rol.
  const elegido = ids.find((id) => enSucursal.includes(id));
  return elegido ? armar(elegido) : null;
}

async function correrCaso(
  sb: SupabaseClient,
  user: BotUser,
  caso: CasoEval,
  modelo: string,
  hoy: string,
): Promise<ResultadoCaso> {
  const t0 = performance.now();
  try {
    const r = await runAgent({
      supabase: sb,
      user,
      telegram_user_id: TELEGRAM_USER_ID_EVAL,
      userMessage: caso.pregunta,
      ephemeral: true,
      modelo,
      capturarResultados: true,
    });
    const toolCalls = r.toolCalls as ToolCallEval[];
    return {
      caso: caso.id,
      rol: caso.rol,
      modelo,
      texto: r.text,
      herramientas: toolCalls.map((t) => t.name),
      toolCalls,
      evaluacion: evaluarCaso(caso, r.text, toolCalls, hoy),
      costoUsd: r.costoUsd,
      ms: Math.round(performance.now() - t0),
    };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return {
      caso: caso.id,
      rol: caso.rol,
      modelo,
      texto: "",
      herramientas: [],
      toolCalls: [],
      evaluacion: {
        eleccionOk: false,
        argsOk: false,
        prohibidasOk: true,
        sinPreguntaOk: false,
        inventados: [],
        ok: false,
        motivos: [`error: ${msg}`],
      },
      costoUsd: 0,
      ms: Math.round(performance.now() - t0),
      error: msg,
    };
  }
}

const corto = (s: string, n = 300) => {
  const t = s.replace(/\s+/g, " ").trim();
  return t.length > n ? `${t.slice(0, n)}...` : t;
};
const celda = (s: string) => s.replace(/\|/g, "\\|");
const usd = (n: number) => `US$ ${n.toFixed(4)}`;

/**
 * `publico`: el repo es PÚBLICO, y en GitHub Actions el log y el resumen del
 * run los puede leer cualquiera. Ahí sale sólo lo agregado: aciertos, qué
 * herramientas, CUÁNTOS números sospechosos (no cuáles), costo y el tipo de
 * motivo. Nada de respuestas, nombres ni montos: son datos reales del negocio
 * leídos con la service role. El detalle completo sólo corriéndolo local.
 */
export function armarResumen(
  resultados: ResultadoCaso[],
  modelos: string[],
  hoy: string,
  publico = false,
): string {
  const L: string[] = [];
  L.push(`# Evaluación de modelos del bot (${hoy})`, "");
  L.push("## Totales por modelo", "");
  L.push(
    "| Modelo | Casos ok | % ok | Elección | Args | Inventados (total) | Costo | Latencia prom. | Tool calls prom. | Errores |",
    "|---|---|---|---|---|---|---|---|---|---|",
  );
  for (const m of modelos) {
    const rs = resultados.filter((r) => r.modelo === m);
    const n = rs.length || 1;
    const ok = rs.filter((r) => r.evaluacion.ok).length;
    L.push(
      `| ${m} | ${ok}/${rs.length} | ${Math.round((ok / n) * 100)}% | ` +
        `${rs.filter((r) => r.evaluacion.eleccionOk).length}/${rs.length} | ` +
        `${rs.filter((r) => r.evaluacion.argsOk).length}/${rs.length} | ` +
        `${rs.reduce((s, r) => s + r.evaluacion.inventados.length, 0)} | ` +
        `${usd(rs.reduce((s, r) => s + r.costoUsd, 0))} | ` +
        `${(rs.reduce((s, r) => s + r.ms, 0) / n / 1000).toFixed(1)} s | ` +
        `${(rs.reduce((s, r) => s + r.herramientas.length, 0) / n).toFixed(1)} | ` +
        `${rs.filter((r) => r.error).length} |`,
    );
  }
  L.push("", "Los números inventados son sospechosos para revisar a mano, no una prueba.", "");

  for (const m of modelos) {
    const rs = resultados.filter((r) => r.modelo === m);
    L.push(`## ${m}`, "");
    L.push(
      "| | Caso | Rol | Herramientas | Inventados | Costo | Motivos |",
      "|---|---|---|---|---|---|---|",
    );
    for (const r of rs) {
      L.push(
        `| ${r.evaluacion.ok ? "✓" : "✗"} | ${r.caso} | ${r.rol} | ` +
          `${celda(r.herramientas.join(", ") || "-")} | ` +
          `${
            publico ? String(r.evaluacion.inventados.length) : r.evaluacion.inventados.join(", ") || "-"
          } | ${usd(r.costoUsd)} | ` +
          `${
            celda(
              (publico ? r.evaluacion.motivos.map((m) => m.split(":")[0]) : r.evaluacion.motivos)
                .join("; ") || "-",
            )
          } |`,
      );
    }
    const fallidos = rs.filter((r) => !r.evaluacion.ok);
    if (fallidos.length > 0 && !publico) {
      L.push("", `### Respuestas de los casos que fallaron (${m})`, "");
      for (const r of fallidos) {
        L.push(
          `- **${r.caso}**: ${corto(r.error ? `ERROR ${r.error}` : r.texto) || "(sin texto)"}`,
        );
      }
    }
    L.push("");
  }
  return L.join("\n");
}

async function main() {
  // Adentro de main y no al importar: un test que importa este módulo (por
  // armarResumen) apagaba el audit log de todo el proceso de tests.
  Deno.env.set("BOT_AUDIT_DISABLED", "1");
  const args = parsearArgs(Deno.args);
  const modelos = (args.modelos ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  if (modelos.length === 0) {
    console.error(
      "Uso: deno run -A _eval/correr.ts --modelos=a,b [--casos=id1,id2] [--salida=x.json]",
    );
    Deno.exit(2);
  }
  const ids = args.casos ? new Set(args.casos.split(",").map((s) => s.trim())) : null;
  const casos = CASOS.filter((c) => !ids || ids.has(c.id));
  if (ids) {
    const faltan = [...ids].filter((i) => !CASOS.some((c) => c.id === i));
    if (faltan.length > 0) throw new Error(`Casos que no existen: ${faltan.join(", ")}`);
  }

  // Repo público: en Actions no sale ningún dato del negocio (ver armarResumen).
  const publico = Deno.env.get("GITHUB_ACTIONS") === "true";
  if (publico && args.salida) {
    throw new Error("--salida no se usa en GitHub Actions: el JSON tiene datos reales y el repo es público");
  }
  const sb = getServiceRoleClient();
  registerAllTools();
  const sucursalId = Number(Deno.env.get("EVAL_SUCURSAL_ID") ?? "1");
  const hoy = hoyAR();

  const usuarios = new Map<RolEval, BotUser | null>();
  for (
    const [rol, env] of [
      ["admin", "EVAL_ADMIN_ID"],
      ["preventista", "EVAL_PREVENTISTA_ID"],
      ["encargado", "EVAL_ENCARGADO_ID"],
    ] as const
  ) {
    if (!casos.some((c) => c.rol === rol)) continue;
    const u = await resolverUsuario(sb, rol, sucursalId, Deno.env.get(env));
    usuarios.set(rol, u);
    console.error(
      u
        ? `Usuario ${rol}: ${publico ? "(oculto)" : u.perfil_id} (sucursal ${sucursalId})`
        : `Sin usuario ${rol}: se saltean sus casos`,
    );
  }

  // {cliente} → un cliente de la cartera de cada usuario, el de más entregas
  // en el año (clientes_ritmo_compra, la misma cartera que ve el bot).
  const clientePorRol = new Map<RolEval, string>();
  for (const [rol, u] of usuarios) {
    if (!u || u.sucursal_id == null) continue;
    const { data, error } = await sb.rpc("clientes_ritmo_compra", {
      p_sucursal_id: u.sucursal_id,
      p_rol: rol,
      p_perfil_id: u.perfil_id,
    });
    if (error) throw new Error(`clientes_ritmo_compra: ${error.message}`);
    const filas = ((data ?? []) as Array<{ nombre: string; entregas_365: number; es_comodin: boolean }>)
      .filter((f) => !f.es_comodin)
      .sort((a, b) => b.entregas_365 - a.entregas_365);
    if (filas[0]) {
      clientePorRol.set(rol, filas[0].nombre);
      if (!publico) console.error(`Cliente de prueba de ${rol}: ${filas[0].nombre}`);
    }
  }

  const resultados: ResultadoCaso[] = [];
  for (const modelo of modelos) {
    for (const casoOriginal of casos) {
      const user = usuarios.get(casoOriginal.rol);
      if (!user) continue;
      let caso = casoOriginal;
      if (caso.pregunta.includes("{cliente}")) {
        const nombre = clientePorRol.get(caso.rol);
        if (!nombre) {
          console.error(`  ${caso.id}: sin cliente de prueba para ${caso.rol}, se saltea`);
          continue;
        }
        caso = { ...caso, pregunta: caso.pregunta.replaceAll("{cliente}", nombre) };
      }
      console.error(`[${modelo}] ${caso.id}...`);
      const r = await correrCaso(sb, user, caso, modelo, hoy);
      console.error(`  ${r.evaluacion.ok ? "ok" : "FALLA"} (${r.ms} ms, ${usd(r.costoUsd)})`);
      resultados.push(r);
    }
  }

  const resumen = armarResumen(resultados, modelos, hoy, publico);
  console.log(resumen);

  const summaryFile = Deno.env.get("GITHUB_STEP_SUMMARY");
  if (summaryFile) await Deno.writeTextFile(summaryFile, resumen + "\n", { append: true });
  if (args.salida) {
    await Deno.writeTextFile(
      args.salida,
      JSON.stringify({ fecha: hoy, modelos, resultados }, null, 2),
    );
  }
}

if (import.meta.main) await main();
