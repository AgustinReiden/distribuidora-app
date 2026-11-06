/**
 * Cómo se distinguen dos filas que se llaman igual en los rankings del gerencial
 * (#1472, REP-F-1).
 *
 * `reporte_gerencial` agrupa "Top clientes" y "Top productos" por id: dos clientes que se
 * llaman "Kiosco" son dos filas. Si el nombre se repite en la lista, cada fila lleva un
 * detalle que la distingue: la razón social del cliente o la sucursal del producto (en la
 * Red, el mismo artículo de dos sucursales son dos productos). Si eso tampoco alcanza
 * (vacío, igual al nombre o repetido entre ellas), el id. Un nombre que no se repite va
 * sin detalle.
 */

export interface FilaTop {
  id: number | null
  nombre: string
  /** Lo que distingue a la fila si el nombre se repite: razón social o sucursal. */
  detalle?: string | null
}

const norm = (s: string | null | undefined): string => (s ?? '').trim().toLocaleLowerCase('es')

/** El detalle de cada fila, en el mismo orden; `null` si su nombre no se repite. */
export function detallesTop(filas: FilaTop[]): (string | null)[] {
  const porNombre = new Map<string, number>()
  for (const f of filas) porNombre.set(norm(f.nombre), (porNombre.get(norm(f.nombre)) ?? 0) + 1)

  const candidato = filas.map(f => {
    if ((porNombre.get(norm(f.nombre)) ?? 0) < 2) return null
    const d = f.detalle?.trim()
    return d && norm(d) !== norm(f.nombre) ? d : null
  })

  // Dos filas del mismo nombre con el mismo detalle no se distinguen: van con el id.
  const usados = new Map<string, number>()
  filas.forEach((f, i) => {
    const c = candidato[i]
    if (c !== null) {
      const k = `${norm(f.nombre)}\u0000${norm(c)}`
      usados.set(k, (usados.get(k) ?? 0) + 1)
    }
  })

  return filas.map((f, i) => {
    if ((porNombre.get(norm(f.nombre)) ?? 0) < 2) return null
    const c = candidato[i]
    if (c !== null && usados.get(`${norm(f.nombre)}\u0000${norm(c)}`) === 1) return c
    return f.id === null ? null : `#${f.id}`
  })
}

/** El nombre con su detalle, para el Excel: "Kiosco (Pérez Juan)". */
export function nombresTop(filas: FilaTop[]): string[] {
  const det = detallesTop(filas)
  return filas.map((f, i) => (det[i] ? `${f.nombre} (${det[i]})` : f.nombre))
}
