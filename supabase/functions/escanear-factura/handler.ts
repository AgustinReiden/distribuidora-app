// Handler HTTP de escanear-factura, con todas las dependencias inyectadas
// (auth, storage, Gemini) para testearlo sin red. index.ts arma las de
// producción.

import type {
  GeminiGenerateContentRequest,
  GeminiGenerateContentResponse,
} from "../_shared/gemini/types.ts";
import type { AutorizacionEscaneo } from "./auth.ts";
import { detectarMime, MAX_BYTES_FACTURA, validarRutaFactura } from "./ruta.ts";
import { aBase64, construirPedidoGemini, leerRespuestaGemini } from "./extraccion.ts";
import { normalizarFactura } from "./validacion.ts";

export interface EscanearDeps {
  autorizar: (req: Request) => Promise<AutorizacionEscaneo>;
  /** Bytes del objeto en el bucket `facturas`, o null si no existe. */
  descargar: (objeto: string) => Promise<Uint8Array | null>;
  generar: (pedido: GeminiGenerateContentRequest) => Promise<GeminiGenerateContentResponse>;
  /** false si falta GEMINI_API_KEY: se corta antes de descargar nada. */
  geminiConfigurado: boolean;
  modelo: string;
  /** Headers CORS para el origen de este request. */
  cors: (req: Request) => Record<string, string>;
}

/**
 * Orígenes permitidos: `APP_ORIGIN`, uno o varios separados por coma (prod +
 * staging). Si el origen del request está en la lista se le devuelve ese; si
 * no, el primero (el navegador lo bloquea). Sin `APP_ORIGIN`, "*". La función
 * vive en _shared/cors.ts desde Rut-B14 (ola 3), sin cambios: la usa también
 * optimizar-ruta.
 */
export { crearCors } from "../_shared/cors.ts";

export function crearHandler(deps: EscanearDeps): (req: Request) => Promise<Response> {
  return async (req: Request): Promise<Response> => {
    const cors = deps.cors(req);
    const responder = (body: Record<string, unknown>, status: number) =>
      new Response(JSON.stringify(body), {
        status,
        headers: { ...cors, "Content-Type": "application/json" },
      });
    const fallar = (status: number, error: string) => responder({ success: false, error }, status);

    if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
    if (req.method !== "POST") return fallar(405, "Método no permitido.");

    const auth = await deps.autorizar(req);
    if (!auth.ok) return fallar(auth.status, auth.mensaje);

    let body: unknown;
    try {
      body = await req.json();
    } catch {
      return fallar(400, "El pedido no es un JSON válido.");
    }
    const path = typeof body === "object" && body !== null ? (body as { path?: unknown }).path : undefined;
    const ruta = validarRutaFactura(path, auth.sucursalId);
    if (!ruta.ok) return fallar(ruta.status, ruta.mensaje);

    if (!deps.geminiConfigurado) {
      console.error("[escanear-factura] falta GEMINI_API_KEY");
      return fallar(503, "El escáner de facturas no está configurado en el servidor. Avisale al administrador.");
    }

    let bytes: Uint8Array | null;
    try {
      bytes = await deps.descargar(ruta.objeto);
    } catch (err) {
      console.error("[escanear-factura] error al descargar:", err instanceof Error ? err.message : err);
      return fallar(502, "No se pudo leer el archivo subido. Probá de nuevo.");
    }
    if (!bytes) return fallar(404, "No se encontró el archivo subido. Volvé a escanear la factura.");
    if (bytes.length === 0) return fallar(400, "El archivo está vacío.");
    if (bytes.length > MAX_BYTES_FACTURA) return fallar(413, "El archivo es demasiado grande (máximo 8 MB).");

    const mime = detectarMime(bytes);
    if (!mime) {
      return fallar(415, "El archivo no es una imagen (JPG, PNG, WEBP, HEIC) ni un PDF.");
    }

    let respuesta: GeminiGenerateContentResponse;
    try {
      respuesta = await deps.generar(construirPedidoGemini(aBase64(bytes), mime));
    } catch (err) {
      // El detalle (status y cuerpo de Google) va al log, nunca al cliente.
      console.error("[escanear-factura] Gemini falló:", err instanceof Error ? err.message : err);
      return fallar(502, "El servicio que lee las facturas no respondió. Probá de nuevo en un rato.");
    }

    const lectura = leerRespuestaGemini(respuesta);
    if (!lectura.ok) {
      console.error(`[escanear-factura] respuesta inutilizable: ${lectura.motivo} (${lectura.detalle})`);
      const mensaje = lectura.motivo === "cortada"
        ? "La factura es demasiado larga para leerla de una vez. Probá escaneándola por partes."
        : "No se pudo leer la factura. Probá con una foto más nítida.";
      return fallar(502, mensaje);
    }

    const { data, advertencias } = normalizarFactura(lectura.json);
    if (data.items.length === 0 && data.pie.total == null) {
      return fallar(422, "No se reconoció una factura en el archivo. Probá con una foto más nítida y completa.");
    }

    return responder({ success: true, data, advertencias, modelo: deps.modelo }, 200);
  };
}
