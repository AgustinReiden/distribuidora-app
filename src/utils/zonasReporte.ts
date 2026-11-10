/**
 * Zonas del reporte de ventas por cliente (REP-6): la clave de la fila y la
 * etiqueta que se lee. Dos zonas pueden llamarse igual en la Red (una por
 * sucursal), así que ni el nombre sirve de key ni alcanza como etiqueta.
 */
interface ZonaFila {
  zona_id?: number | null
  zona: string
  sucursal?: string | null
}

/** Clave estable de una fila de zona: el id; sin id (SIN ZONA), el nombre. */
export const claveZona = (z: ZonaFila): string =>
  z.zona_id != null ? `id:${z.zona_id}` : `nombre:${z.zona}|${z.sucursal ?? ''}`

/** El nombre; si otra del listado se llama igual y se sabe la sucursal: `Zona (Sucursal)`. */
export const etiquetaZona = (z: ZonaFila, todas: readonly ZonaFila[]): string =>
  z.sucursal && todas.filter((o) => o.zona === z.zona).length > 1 ? `${z.zona} (${z.sucursal})` : z.zona
