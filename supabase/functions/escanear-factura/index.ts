// Edge Function: escanear-factura
//
// Lee una factura de proveedor (foto o PDF) con Gemini y devuelve los datos
// estructurados (schema v2) más advertencias de cuadre. Reemplaza al workflow
// de n8n, que era público, sin auth y con la key en el workflow.
//
// Request (POST): { path } — objeto del bucket `facturas` que el front acaba de
//   subir, con la forma `<sucursal_id>/<uuid>.<ext>` (ver ruta.ts).
// Response 200: { success: true, data: FacturaV2, advertencias, modelo }
// Error:        { success: false, error } con 4xx/5xx (mensajes para el usuario).
//
// Variables de entorno:
//   - GEMINI_API_KEY        (secret, ya existe — la usa también el bot)
//   - FACTURA_GEMINI_MODEL  (opcional) — default en extraccion.ts
//   - APP_ORIGIN            (opcional) — origen(es) del front para CORS
//   - SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY (auto)
//
// Autorización: JWT + rol admin/encargado en la sucursal activa (auth.ts),
// ANTES de descargar nada o de llamar a Gemini.

import { serve } from "std/http/server.ts";
import { callGemini } from "../_shared/gemini/client.ts";
import { getServiceRoleClient } from "../_shared/supabase.ts";
import { autorizarEscaneo, crearDepsAutorizacionEscaneo } from "./auth.ts";
import { crearCors, crearHandler } from "./handler.ts";
import { modeloFactura } from "./extraccion.ts";
import { BUCKET_FACTURAS } from "./ruta.ts";

const depsAuth = crearDepsAutorizacionEscaneo();
const modelo = modeloFactura((k) => Deno.env.get(k));

const handler = crearHandler({
  autorizar: (req) => autorizarEscaneo(req, depsAuth),
  descargar: async (objeto) => {
    const { data, error } = await getServiceRoleClient().storage.from(BUCKET_FACTURAS).download(objeto);
    if (error || !data) return null;
    return new Uint8Array(await data.arrayBuffer());
  },
  generar: (pedido) => callGemini(pedido, { model: modelo }),
  geminiConfigurado: !!Deno.env.get("GEMINI_API_KEY"),
  modelo,
  cors: crearCors(Deno.env.get("APP_ORIGIN")),
});

serve(handler);
