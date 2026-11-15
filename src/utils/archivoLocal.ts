/**
 * Un archivo de Storage mostrado desde una URL `blob:` del propio documento
 * (INF-7, #1563).
 *
 * El visor de la factura escaneada cargaba la URL firmada de Storage
 * (`https://<ref>.supabase.co/storage/…`) en un `<img>` o un `<iframe>`, y la CSP
 * no deja ninguna de las dos cosas: `img-src` no nombra a Supabase y no hay
 * `frame-src`, así que cae en `default-src 'self'`. La revisión quedaba en blanco.
 *
 * Se baja con `fetch` —`connect-src` ya deja hablar con Supabase— y se muestra
 * como `blob:`. Así la CSP no tiene que abrir `*.supabase.co` a imágenes ni a
 * frames: la imagen entra con el `img-src blob:` que ya está, y el PDF sólo pide
 * `frame-src 'self' blob:`.
 */

/** El tipo con el que se muestra una factura: el PDF lo fija la extensión. */
export function tipoDeArchivoFactura(ruta: string): string | undefined {
  return ruta.toLowerCase().endsWith('.pdf') ? 'application/pdf' : undefined
}

/**
 * Baja `url` y devuelve una URL `blob:` con su contenido. Quien la pide la libera
 * con `URL.revokeObjectURL` cuando deja de mostrarla.
 *
 * `tipo` pisa el `Content-Type` de la respuesta: si Storage contesta un PDF como
 * `application/octet-stream`, el `<iframe>` lo descargaría en vez de mostrarlo.
 */
export async function urlLocalDeArchivo(
  url: string,
  tipo?: string,
  bajar: typeof fetch = fetch,
): Promise<string> {
  const respuesta = await bajar(url)
  if (!respuesta.ok) throw new Error(`No se pudo bajar el archivo (HTTP ${respuesta.status})`)
  const contenido = await respuesta.blob()
  const blob = tipo && contenido.type !== tipo ? new Blob([contenido], { type: tipo }) : contenido
  return URL.createObjectURL(blob)
}
