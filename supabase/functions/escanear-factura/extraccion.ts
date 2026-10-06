// Pedido a Gemini para leer una factura de proveedor: prompt, responseSchema
// (structured output) y lectura de la respuesta. Puro: no llama a la red.

import type {
  GeminiGenerateContentRequest,
  GeminiGenerateContentResponse,
} from "../_shared/gemini/types.ts";

/**
 * Default del modelo. Se puede cambiar sin re-deploy con el secret
 * `FACTURA_GEMINI_MODEL` (separado de `GEMINI_MODEL`, que es el del bot: el
 * escaneo quiere un modelo con buena visión y el bot uno con buen tool calling,
 * y no tienen por qué moverse juntos).
 */
export const MODELO_FACTURA_DEFAULT = "gemini-3.8-flash";

export function modeloFactura(env: (k: string) => string | undefined): string {
  const v = env("FACTURA_GEMINI_MODEL")?.trim();
  return v ? v : MODELO_FACTURA_DEFAULT;
}

const NUM_NULL = { type: "NUMBER", nullable: true } as const;
const STR_NULL = { type: "STRING", nullable: true } as const;

/** Schema v2 (subset OpenAPI 3.0 que acepta Gemini en `responseSchema`). */
export const RESPONSE_SCHEMA = {
  type: "OBJECT",
  properties: {
    tipoComprobante: { type: "STRING", enum: ["A", "B", "C", "remito", "otro"] },
    puntoVenta: STR_NULL,
    numero: STR_NULL,
    fechaEmision: { type: "STRING", nullable: true, description: "YYYY-MM-DD" },
    proveedor: {
      type: "OBJECT",
      properties: { nombre: STR_NULL, cuit: STR_NULL },
      required: ["nombre", "cuit"],
    },
    condicionVenta: STR_NULL,
    items: {
      type: "ARRAY",
      items: {
        type: "OBJECT",
        properties: {
          codigo: STR_NULL,
          descripcion: { type: "STRING" },
          cantidad: NUM_NULL,
          unidad: { type: "STRING", nullable: true, enum: ["bulto", "unidad"] },
          unidadesPorBulto: NUM_NULL,
          precioUnitarioNeto: NUM_NULL,
          bonificacionPct: NUM_NULL,
          importeNeto: NUM_NULL,
          alicuotaIva: NUM_NULL,
          impuestoInternoMonto: NUM_NULL,
          legible: { type: "BOOLEAN" },
        },
        required: [
          "codigo",
          "descripcion",
          "cantidad",
          "unidad",
          "unidadesPorBulto",
          "precioUnitarioNeto",
          "bonificacionPct",
          "importeNeto",
          "alicuotaIva",
          "impuestoInternoMonto",
          "legible",
        ],
      },
    },
    pie: {
      type: "OBJECT",
      properties: {
        netoGravado: NUM_NULL,
        noGravado: NUM_NULL,
        exento: NUM_NULL,
        iva: {
          type: "ARRAY",
          items: {
            type: "OBJECT",
            properties: { alicuota: { type: "NUMBER" }, monto: { type: "NUMBER" } },
            required: ["alicuota", "monto"],
          },
        },
        impuestosInternos: {
          type: "ARRAY",
          items: {
            type: "OBJECT",
            properties: { tasa: NUM_NULL, monto: { type: "NUMBER" } },
            required: ["tasa", "monto"],
          },
        },
        percepcionIva: NUM_NULL,
        percepcionIibb: NUM_NULL,
        otrosTributos: NUM_NULL,
        descuentosPie: {
          type: "ARRAY",
          items: {
            type: "OBJECT",
            properties: { descripcion: { type: "STRING" }, monto: { type: "NUMBER" } },
            required: ["descripcion", "monto"],
          },
        },
        total: NUM_NULL,
      },
      required: [
        "netoGravado",
        "noGravado",
        "exento",
        "iva",
        "impuestosInternos",
        "percepcionIva",
        "percepcionIibb",
        "otrosTributos",
        "descuentosPie",
        "total",
      ],
    },
    confianza: { type: "NUMBER" },
  },
  required: [
    "tipoComprobante",
    "puntoVenta",
    "numero",
    "fechaEmision",
    "proveedor",
    "condicionVenta",
    "items",
    "pie",
    "confianza",
  ],
} as const;

export const PROMPT_FACTURA = `Sos un asistente que transcribe comprobantes de compra de proveedores argentinos para una distribuidora de alimentos y bebidas. Leé el comprobante adjunto (foto o PDF) y devolvé SOLO el JSON del schema.

Reglas generales:
- Transcribí, no calcules. Cada número sale del papel. Si un dato no se lee con seguridad, poné null; nunca lo inventes ni lo deduzcas de otros.
- Los números van como número JSON con punto decimal. En Argentina "1.234,56" es mil doscientos treinta y cuatro con 56: devolvé 1234.56.
- El comprobante tiene DOS razones sociales: la del EMISOR (arriba, el proveedor que vende) y la del cliente (la distribuidora que compra, en "Señor/es" o "Cliente"). "proveedor" es SIEMPRE el emisor, con su CUIT. No uses el CUIT del cliente.

Cabecera:
- tipoComprobante: la letra del recuadro central. "A", "B" o "C" para facturas. "remito" para remitos, presupuestos, notas de pedido o documentos "no válidos como factura" (incluye los marcados X o ZZ). "otro" para cualquier otra cosa (nota de crédito, ticket, recibo) o si no se distingue.
- puntoVenta y numero: del formato "0005-00455160" el punto de venta es "0005" y el número "00455160". Como texto, con los ceros.
- fechaEmision: la fecha de emisión en formato YYYY-MM-DD (la del papel está en DD/MM/AAAA).
- condicionVenta: tal cual figura ("Contado", "Cuenta corriente", "30 días", etc.), o null.

Líneas (items), una por renglón de producto, en el orden del papel:
- descripcion: EXACTAMENTE como está impresa, sin corregir ni expandir abreviaturas.
- codigo: el código o artículo del proveedor si está impreso; si no, null.
- cantidad: la cantidad facturada tal como figura.
- unidad: "bulto" si la cantidad está en bultos/cajas/packs/fardos, "unidad" si está en unidades sueltas, null si no se sabe.
- unidadesPorBulto: si la descripción o una columna dice cuántas unidades trae el bulto (por ejemplo "x12", "x 6 u", "pack 8"), ese número; si no, null.
- precioUnitarioNeto: el precio unitario impreso de la línea, ANTES de la bonificación. En factura A es sin IVA; en B, C o remito es el precio tal como figura.
- bonificacionPct: la bonificación o descuento de la línea como PORCENTAJE (10 significa 10%). NO son unidades sin cargo. Si la línea no tiene bonificación, 0. Si la bonificación está impresa sólo como monto en pesos, null.
- importeNeto: el importe o subtotal de la línea impreso (ya con su bonificación aplicada).
- alicuotaIva: la alícuota de IVA de la línea (21, 10.5, 27 o 0). Si no figura por línea pero el comprobante tiene una sola alícuota, usá esa. En B, C o remito, null.
- impuestoInternoMonto: el monto de impuestos internos de la línea si está impreso por línea; si no, null.
- legible: false si alguno de los datos de la línea no se lee con claridad.

Pie:
- netoGravado, noGravado, exento: los subtotales impresos (null si no figuran).
- iva: una entrada por cada alícuota de IVA discriminada, con su monto. Vacío si no se discrimina IVA.
- impuestosInternos: una entrada por tasa si están abiertos (tasa en %, o null si no se indica), o una sola con el total.
- percepcionIva (percepción de IVA, RG 2408/3337), percepcionIibb (percepción de Ingresos Brutos de cualquier provincia), otrosTributos (cualquier otro tributo impreso): los montos, o null.
- descuentosPie: descuentos o bonificaciones que se restan al pie y no están en una línea (por ejemplo "Bonif. promo 3000cc"), con su descripción tal cual y el monto como número positivo.
- total: el importe total del comprobante.

confianza: de 0 a 1, qué tan seguro estás de la transcripción completa (baja si la imagen está borrosa, cortada o inclinada).`;

export function construirPedidoGemini(
  base64: string,
  mimeType: string,
): GeminiGenerateContentRequest {
  return {
    contents: [
      {
        role: "user",
        parts: [
          { inlineData: { mimeType, data: base64 } },
          { text: PROMPT_FACTURA },
        ],
      },
    ],
    generationConfig: {
      temperature: 0,
      // Una factura larga (60+ renglones) con el JSON v2 ronda los 10k tokens.
      maxOutputTokens: 32768,
      responseMimeType: "application/json",
      responseSchema: RESPONSE_SCHEMA as unknown as Record<string, unknown>,
    },
  };
}

export type LecturaRespuesta =
  | { ok: true; json: unknown }
  | { ok: false; motivo: "bloqueada" | "cortada" | "vacia" | "json_invalido"; detalle: string };

/** Saca el JSON del primer candidato. No valida la forma: eso es de validacion.ts. */
export function leerRespuestaGemini(res: GeminiGenerateContentResponse): LecturaRespuesta {
  if (res.promptFeedback?.blockReason) {
    return { ok: false, motivo: "bloqueada", detalle: res.promptFeedback.blockReason };
  }
  const cand = res.candidates?.[0];
  if (!cand) return { ok: false, motivo: "vacia", detalle: "sin candidatos" };
  if (cand.finishReason === "MAX_TOKENS") {
    return { ok: false, motivo: "cortada", detalle: "MAX_TOKENS" };
  }
  if (cand.finishReason && cand.finishReason !== "STOP") {
    return { ok: false, motivo: "bloqueada", detalle: cand.finishReason };
  }
  const texto = (cand.content?.parts ?? [])
    .map((p) => ("text" in p && typeof p.text === "string" ? p.text : ""))
    .join("")
    .trim();
  if (!texto) return { ok: false, motivo: "vacia", detalle: "sin texto" };
  // Algunos modelos envuelven igual en ```json aunque se pida application/json.
  const limpio = texto.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
  try {
    return { ok: true, json: JSON.parse(limpio) };
  } catch (e) {
    return { ok: false, motivo: "json_invalido", detalle: String(e).slice(0, 200) };
  }
}

/** base64 sin `data:` y sin depender de std (8 MB en trozos para no reventar el stack). */
export function aBase64(bytes: Uint8Array): string {
  let bin = "";
  const CHUNK = 0x8000;
  for (let i = 0; i < bytes.length; i += CHUNK) {
    bin += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
  }
  return btoa(bin);
}
