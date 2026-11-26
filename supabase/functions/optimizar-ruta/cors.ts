// CORS de optimizar-ruta (Rut-B14, ola 3, T3 de #1677).
//
// Antes, sin el secret APP_ORIGIN, `Access-Control-Allow-Origin` caía a "*": cualquier
// página podía llamar a la función desde el navegador de un usuario logueado (cada
// llamada es una consulta facturable a Google). Ahora falla cerrada: sin APP_ORIGIN (o con
// "*" en la lista, que es lo mismo) la función no le da permiso de CORS a ningún origen,
// contesta 500 sin tocar Google y lo dice en el log, para que se cargue el secret.
//
// Con APP_ORIGIN, el mismo CORS que escanear-factura (_shared/cors.ts): uno o varios
// orígenes separados por coma; se devuelve el del request si está en la lista, con
// `Vary: Origin`.
//
// Puro y sin Deno.env: el index lo llama con el valor del entorno, y los tests con lo que
// quieran (supabase/functions/tests/optimizar_ruta_cors_cupo.test.ts).

import { crearCors, origenesPermitidos } from "../_shared/cors.ts";

const SIN_ORIGEN = {
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-sucursal-id",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export type ConfigCors =
  | { ok: true; headers: (req: Request) => Record<string, string> }
  | { ok: false; headers: (req: Request) => Record<string, string>; motivo: string };

/**
 * Los headers de CORS para el origen de cada request. Con APP_ORIGIN vacío, ausente o con
 * "*", `ok: false` y headers SIN Access-Control-Allow-Origin: el navegador rechaza la respuesta.
 */
export function configCors(appOrigin: string | undefined | null): ConfigCors {
  const origenes = origenesPermitidos(appOrigin);
  if (origenes.length === 0 || origenes.includes("*")) {
    return {
      ok: false,
      headers: () => ({ ...SIN_ORIGEN }),
      motivo: origenes.includes("*")
        ? 'APP_ORIGIN tiene "*": optimizar-ruta no abre el CORS a cualquier origen. Cargá el origen exacto del front (o la lista separada por comas).'
        : "Falta el secret APP_ORIGIN (el origen exacto del front, o la lista separada por comas): optimizar-ruta no contesta sin él.",
    };
  }
  return { ok: true, headers: crearCors(origenes.join(",")) };
}

/**
 * El handler con los headers de CORS en toda respuesta, según el Origin del request.
 * Si `atender` tira una excepción que no atrapó, contesta un 500 con los mismos headers: sin
 * ellos el navegador muestra un error de CORS en vez del 500 (revisión de Rut-B14).
 */
export function envolverConCors(
  cors: ConfigCors,
  atender: (req: Request) => Promise<Response>,
): (req: Request) => Promise<Response> {
  return async (req) => {
    let res: Response;
    try {
      res = await atender(req);
    } catch (e) {
      console.error("[optimizar-ruta] error sin atrapar:", (e as Error)?.message ?? e);
      res = new Response(
        JSON.stringify({ success: false, error: "Error interno", mensaje: "No se pudo optimizar la ruta. Probá de nuevo en un rato" }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }
    for (const [k, v] of Object.entries(cors.headers(req))) res.headers.set(k, v);
    return res;
  };
}
