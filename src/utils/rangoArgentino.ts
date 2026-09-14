/**
 * Rango [desde, hasta] en hora ARGENTINA para filtrar una columna `timestamptz`
 * por día calendario.
 *
 * `created_at` es timestamptz y el día que le importa al usuario es el día
 * ARGENTINO, que es el corte que usa el reporte gerencial
 * (`created_at AT TIME ZONE 'America/Argentina/Buenos_Aires'`). Comparar contra
 * un ISO sin offset corta en UTC y manda todo lo cargado después de las 21hs
 * (hora Argentina) al día siguiente. El offset va fijo en -03:00 porque
 * Argentina no tiene horario de verano desde 2009; la zona por nombre se usa
 * en `fechaLocalISO` (formatters.ts).
 *
 * Extraído de `useMermasQuery` para reusar en cualquier query que filtre un
 * timestamptz por rango de días en hora Argentina (p.ej. `useMovimientosQuery`).
 */

export interface FiltrosRangoFecha {
  /** 'YYYY-MM-DD' en hora de Argentina. */
  desde?: string | null
  /** 'YYYY-MM-DD' en hora de Argentina, inclusive. */
  hasta?: string | null
}

export interface RangoArgentino {
  desde: string | null
  hasta: string | null
}

export function rangoArgentino(filtros?: FiltrosRangoFecha): RangoArgentino {
  return {
    desde: filtros?.desde ? `${filtros.desde}T00:00:00-03:00` : null,
    // Inclusive hasta el último microsegundo del día: es la precisión de
    // timestamptz, así que no se pierde ninguna fila del borde.
    hasta: filtros?.hasta ? `${filtros.hasta}T23:59:59.999999-03:00` : null,
  }
}
