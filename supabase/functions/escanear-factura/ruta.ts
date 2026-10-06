// Guarda de la ruta del archivo y del tipo de contenido. Puro (testeable).
//
// El front sube a `facturas/<sucursal_id>/<uuid>.<ext>` (bucket `facturas`,
// objeto `<sucursal_id>/<uuid>.<ext>`). La función descarga con service role,
// o sea SIN la RLS del bucket: si aceptara cualquier ruta, un encargado de una
// sucursal podría hacer leer al modelo —y recibir transcripta— la factura que
// subió otra sucursal. Por eso la ruta tiene que tener exactamente esa forma y
// el prefijo tiene que ser la sucursal activa del caller (resuelta en auth.ts).
//
// Las subidas viejas (`facturas/<timestamp>_<nombre>`, antes de este cambio)
// no tienen sucursal y quedan afuera a propósito: el escaneo se hace sobre lo
// que se acaba de subir, nunca sobre un archivo viejo.

export const BUCKET_FACTURAS = "facturas";
/** Mismo tope que el bucket (mig 239) y que MAX_ARCHIVO_FACTURA en ModalCompra.tsx. */
export const MAX_BYTES_FACTURA = 8 * 1024 * 1024;

const RUTA_RE =
  /^(\d{1,18})\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png|webp|heic|pdf)$/;

export type ResultadoRuta =
  | { ok: true; objeto: string }
  | { ok: false; status: 400 | 403; mensaje: string };

export function validarRutaFactura(path: unknown, sucursalId: number): ResultadoRuta {
  if (typeof path !== "string" || !path) {
    return { ok: false, status: 400, mensaje: "Falta la ruta del archivo de la factura." };
  }
  const m = path.match(RUTA_RE);
  if (!m) {
    return { ok: false, status: 400, mensaje: "La ruta del archivo de la factura no es válida." };
  }
  if (Number(m[1]) !== sucursalId) {
    return {
      ok: false,
      status: 403,
      mensaje: "El archivo no pertenece a tu sucursal activa.",
    };
  }
  return { ok: true, objeto: path };
}

export type MimeFactura = "image/jpeg" | "image/png" | "image/webp" | "image/heic" | "application/pdf";

const MARCAS_HEIC = new Set(["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"]);

function ascii(b: Uint8Array, desde: number, hasta: number): string {
  return String.fromCharCode(...b.subarray(desde, hasta));
}

/**
 * Tipo real por los primeros bytes, no por la extensión ni por lo que diga el
 * storage: es lo que se le declara a Gemini como `mimeType`. null = no es un
 * formato soportado.
 */
export function detectarMime(b: Uint8Array): MimeFactura | null {
  if (b.length >= 5 && ascii(b, 0, 5) === "%PDF-") return "application/pdf";
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return "image/jpeg";
  if (
    b.length >= 8 && b[0] === 0x89 && ascii(b, 1, 4) === "PNG" && b[4] === 0x0d && b[5] === 0x0a &&
    b[6] === 0x1a && b[7] === 0x0a
  ) return "image/png";
  if (b.length >= 12 && ascii(b, 0, 4) === "RIFF" && ascii(b, 8, 12) === "WEBP") return "image/webp";
  if (b.length >= 12 && ascii(b, 4, 8) === "ftyp" && MARCAS_HEIC.has(ascii(b, 8, 12))) return "image/heic";
  return null;
}
