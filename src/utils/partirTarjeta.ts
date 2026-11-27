/**
 * Parte la tarjeta de un pedido que no entra en una columna entera de la hoja de
 * ruta (#1715). Cada parte lleva «(cont.)» arriba y «sigue» abajo; nunca se pierde
 * un renglón, y el pie (total, deuda, entregado) va junto, en la última parte.
 */
export interface OpAlto {
  advance: number
  /** Marca el primer renglón del pie: desde ahí hasta el final no se parte. */
  pie?: boolean
}

export interface OpcionesPartir<T extends OpAlto> {
  /** Alto libre en la columna donde empieza la tarjeta. */
  disponible: number
  /** Alto de una columna entera (las partes siguientes empiezan arriba). */
  altoColumna: number
  encabezadoCont: () => T[]
  continua: () => T
}

const suma = (ops: OpAlto[]): number => ops.reduce((s, o) => s + (o.advance || 0), 0)

export function partirTarjeta<T extends OpAlto>(ops: T[], o: OpcionesPartir<T>): T[][] {
  const partes: T[][] = []
  let resto = ops.slice()
  let disp = o.disponible
  let primera = true
  while (resto.length > 0) {
    const enc = primera ? [] : o.encabezadoCont()
    if (suma(enc) + suma(resto) <= disp) {
      partes.push([...enc, ...resto])
      break
    }
    const cont = o.continua()
    const pieIdx = resto.findIndex((x) => x.pie)
    let usado = suma(enc) + cont.advance
    let i = 0
    while (i < resto.length) {
      if (i === pieIdx) break
      if (usado + (resto[i].advance || 0) > disp && i > 0) break
      usado += resto[i].advance || 0
      i += 1
    }
    if (i === pieIdx && pieIdx === 0) {
      // Sólo queda el pie y no entra ni solo: va entero igual (no se pierde).
      partes.push([...enc, ...resto])
      break
    }
    partes.push([...enc, ...resto.slice(0, i), cont])
    resto = resto.slice(i)
    disp = o.altoColumna
    primera = false
  }
  return partes
}
