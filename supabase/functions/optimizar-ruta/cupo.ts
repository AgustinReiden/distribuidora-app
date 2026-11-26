// Cupo por usuario de optimizar-ruta (Rut-B14, ola 3, T3 de #1677).
//
// Cada llamada a la función es una consulta facturable a Google (optimizar una ruta o
// guiar un tramo). La autorización ya exige rol (auth.ts) y un tope de tamaño (limites.ts),
// pero no había tope de cantidad: un usuario con rol, o un script con su sesión, podía
// llamarla sin límite. Ahora cada llamada consume una unidad de su cupo por minuto y por
// día argentino, con el mismo mecanismo que el bot (_shared/cupo.ts, mig 296): la RPC
// optimizar_ruta_consumir_cupo cuenta en optimizar_ruta_cupo_uso (sólo de server) y la
// edge decide con sus topes. La RPC corre con la sesión del que llama (auth.uid()), como
// las preguntas de rol.
//
// Los topes son constantes técnicas, no política comercial. Alcanzan holgado para el uso
// real: un admin que arma y rearma las rutas del día, y un chofer que pide la guía de cada
// parada (unas 60 por día en una ruta larga, más los recálculos).
//
// Si la RPC falla, deja pasar y lo dice en el log, como el cupo del bot: el cupo protege el
// costo, no la seguridad (el rol ya se verificó), y así un deploy de la función antes que la
// migración no deja a nadie sin rutas.

export const CUPO_RUTA_POR_MINUTO = 20;
export const CUPO_RUTA_POR_DIA = 300;

export type ResultadoCupoRuta =
  | { ok: true }
  | { ok: false; motivo: "por_minuto" | "por_dia" };

/** Lo que contesta la RPC (o su error), con la sesión del que llama. */
export type LlamarCupo = (
  maxPorMinuto: number,
  maxPorDia: number,
) => Promise<{ data: unknown; error: { message: string } | null }>;

/** Consume una unidad del cupo del usuario. Sin respuesta de la base, deja pasar. */
export async function consumirCupoRuta(llamar: LlamarCupo): Promise<ResultadoCupoRuta> {
  let r: { data: unknown; error: { message: string } | null };
  try {
    r = await llamar(CUPO_RUTA_POR_MINUTO, CUPO_RUTA_POR_DIA);
  } catch (e) {
    console.error("[optimizar-ruta] el cupo no respondió, se deja pasar:", (e as Error).message);
    return { ok: true };
  }
  if (r.error) {
    console.error("[optimizar-ruta] optimizar_ruta_consumir_cupo falló, se deja pasar:", r.error.message);
    return { ok: true };
  }
  const d = (r.data ?? {}) as { ok?: unknown; motivo?: unknown };
  if (d.ok === false) {
    return { ok: false, motivo: d.motivo === "por_dia" ? "por_dia" : "por_minuto" };
  }
  return { ok: true };
}

export function mensajeCupoRutaAgotado(motivo: "por_minuto" | "por_dia"): string {
  return motivo === "por_dia"
    ? `Llegaste al máximo de ${CUPO_RUTA_POR_DIA} consultas de rutas por hoy. Mañana se renueva.`
    : "Demasiadas consultas de rutas seguidas: esperá un minuto y volvé a intentar.";
}
