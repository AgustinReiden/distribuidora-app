/**
 * El nombre de una zona es único por sucursal (decisión D13 del dueño, 25/11; ola 3 de #1603, T9).
 *
 * Se compara sin mirar mayúsculas ni los espacios de los bordes: «Centro», «CENTRO» y « Centro »
 * son la misma zona. Es la regla de los rubros y del código de producto (`codigoProducto.ts`), y la
 * del índice único del server (`zonas_nombre_unico_por_sucursal`, sobre `upper(btrim(nombre))`).
 * El trigger `zonas_nombre_unico()` da el mensaje con la zona que ya existe; este espejo sólo
 * adelanta el aviso con las zonas que la pantalla ya tiene cargadas.
 *
 * Espejo exacto en lo que importa: `btrim` saca sólo espacios (no tabuladores), igual que acá. Para
 * letras fuera del ASCII, `upper` del server sigue la collation de la base; la que decide es la base.
 */

/** La clave con la que se compara: sin los espacios de los bordes y en mayúsculas. */
export function claveNombreZona(nombre: string | null | undefined): string {
  return (nombre ?? '').replace(/^ +| +$/g, '').toUpperCase()
}

/** La zona que ya tiene ese nombre (sin contar `exceptoId`, la que se renombra), o undefined. */
export function zonaConMismoNombre<Z extends { id: string | number; nombre: string }>(
  zonas: readonly Z[],
  nombre: string,
  exceptoId?: string | number | null,
): Z | undefined {
  const clave = claveNombreZona(nombre)
  if (clave === '') return undefined
  return zonas.find(z => String(z.id) !== String(exceptoId ?? '') && claveNombreZona(z.nombre) === clave)
}

/** El aviso cuando el nombre ya existe: nombra la zona que ya está, como el server. */
export function mensajeZonaRepetida(existente: { nombre: string; activo?: boolean | null }): string {
  const desactivada = existente.activo === false ? ' (desactivada)' : ''
  return `Ya existe la zona «${existente.nombre}» en esta sucursal${desactivada}: no se distinguen mayúsculas ni espacios. Usá esa zona o elegí otro nombre.`
}

/**
 * ¿El rechazo es el del nombre repetido que da el trigger del server? Trae el nombre de la zona que
 * ya existe, así que se muestra tal cual. Un 23505 del índice sin ese mensaje (dos altas cruzadas)
 * no lo es.
 */
export function esZonaRepetidaDelServer(error: unknown): boolean {
  if (!error || typeof error !== 'object') return false
  const e = error as { code?: unknown; message?: unknown }
  return String(e.code ?? '') === '23505' && typeof e.message === 'string' && e.message.startsWith('Ya existe la zona «')
}
