// CORS de las edge functions que llama el front (escanear-factura, optimizar-ruta).
//
// `APP_ORIGIN` acepta uno o varios orígenes separados por coma (prod + staging). Si el origen
// del request está en la lista se le devuelve ese, con `Vary: Origin`; si no, el primero (el
// navegador lo bloquea). Sin `APP_ORIGIN`, "*": así lo usa escanear-factura. optimizar-ruta
// no llega a llamarla sin la lista: falla cerrada antes (optimizar-ruta/cors.ts, Rut-B14).
// Se mudó acá desde escanear-factura/handler.ts (Rut-B14, ola 3) para que la usen las dos.

/** Los orígenes de `APP_ORIGIN`, sin espacios ni vacíos. */
export function origenesPermitidos(appOrigin: string | undefined | null): string[] {
  return (appOrigin ?? "").split(",").map((s) => s.trim()).filter(Boolean);
}

export function crearCors(appOrigin: string | undefined): (req: Request) => Record<string, string> {
  const origenes = origenesPermitidos(appOrigin);
  return (req) => {
    const origen = req.headers.get("Origin") ?? "";
    const permitido = origenes.length === 0 ? "*" : origenes.includes(origen) ? origen : origenes[0];
    return {
      "Access-Control-Allow-Origin": permitido,
      "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-sucursal-id",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Vary": "Origin",
    };
  };
}
