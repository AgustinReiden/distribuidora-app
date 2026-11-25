// CORS de optimizar-ruta (Rut-B14, ola 3, T3 de #1677).
//
// Antes, sin el secret APP_ORIGIN, `Access-Control-Allow-Origin` caía a "*": cualquier
// página podía llamar a la función desde el navegador de un usuario logueado (cada
// llamada es una consulta facturable a Google). Ahora falla cerrado: sin APP_ORIGIN (o con
// "*", que es lo mismo) la función no le da permiso de CORS a ningún origen, contesta 500
// sin tocar Google y lo dice en el log, para que se cargue el secret.
//
// Puro y sin Deno.env: el index lo llama con el valor del entorno, y los tests con lo que
// quieran (supabase/functions/tests/optimizar_ruta_cors_cupo.test.ts).

const PERMITIDOS = {
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-sucursal-id",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export type ConfigCors =
  | { ok: true; headers: Record<string, string> }
  | { ok: false; headers: Record<string, string>; motivo: string };

/**
 * Los headers de CORS para el origen del front. Con APP_ORIGIN vacío, ausente o "*",
 * `ok: false` y headers SIN Access-Control-Allow-Origin: el navegador rechaza la respuesta.
 */
export function configCors(appOrigin: string | undefined | null): ConfigCors {
  const origen = (appOrigin ?? "").trim();
  if (!origen || origen === "*") {
    return {
      ok: false,
      headers: { ...PERMITIDOS },
      motivo: origen === "*"
        ? 'APP_ORIGIN es "*": optimizar-ruta no abre el CORS a cualquier origen. Cargá el origen exacto del front.'
        : "Falta el secret APP_ORIGIN (el origen exacto del front): optimizar-ruta no contesta sin él.",
    };
  }
  return { ok: true, headers: { "Access-Control-Allow-Origin": origen, ...PERMITIDOS } };
}
