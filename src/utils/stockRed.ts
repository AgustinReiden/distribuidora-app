/**
 * "Stock de la red": emparejar el mismo producto entre sucursales.
 *
 * No hay clave que una un producto de Tucumán con "el mismo" de Taco Pozo:
 * son filas independientes, con ids distintos y sin tabla de equivalencias.
 * `productos.codigo` tampoco es UNIQUE. Así que el emparejado es una
 * HEURÍSTICA, y se elige la más conservadora que ya usa la app: el criterio
 * estricto de `sugerirMatchProducto` (código exacto y, si no hay, nombre
 * exacto normalizado — nada parcial). De ahí sale `normalizarTexto`, para que
 * las dos pantallas normalicen igual.
 *
 * Consecuencia medida (2026-09-08, 176 productos en Tucumán y 111 en Taco
 * Pozo): sólo emparejan 10. El resto NO es un error del emparejado: son
 * catálogos distintos. Por eso esta función devuelve los `sinPar` como
 * ciudadanos de primera y la vista los muestra en su propia sección — un
 * emparejado laxo (por prefijo, por palabras) inventaría pares que nadie
 * verificó y sería peor que no emparejar.
 */
import { normalizarTexto } from './matchProducto'

/** Una fila de `productos` de cualquier sucursal, como la devuelve el RPC. */
export interface ProductoRed {
  producto_id: number
  sucursal_id: number
  sucursal_nombre: string
  nombre: string
  codigo: string | null
  categoria: string
  stock: number
  costo_promedio: number | null
  costo_reposicion: number | null
  ultimo_tipo_compra: 'FC' | 'ZZ' | null
  precio: number
}

/** El mismo producto visto en una o más sucursales. */
export interface FilaRed {
  /** Key estable para React: sucursal + id del primer producto del grupo. */
  clave: string
  nombre: string
  codigo: string | null
  categoria: string
  porSucursal: Record<number, ProductoRed | undefined>
  /** Ids de sucursal donde aparece, en el orden en que se recorrieron. */
  sucursales: number[]
  /**
   * El código o el nombre coincidían con MÁS DE UN candidato: no se emparejó
   * a ninguno a propósito. Elegir el primero sería inventar una equivalencia.
   */
  ambiguo: boolean
}

export interface RedEmparejada {
  /** Aparece en dos o más sucursales. */
  emparejados: FilaRed[]
  /** Aparece en una sola sucursal (o quedó sin emparejar por ambiguo). */
  sinPar: FilaRed[]
}

function indexar(mapa: Map<string, FilaRed[]>, clave: string, fila: FilaRed): void {
  const actual = mapa.get(clave)
  if (actual) {
    if (!actual.includes(fila)) actual.push(fila)
  } else {
    mapa.set(clave, [fila])
  }
}

function porNombreEs(a: FilaRed, b: FilaRed): number {
  return a.nombre.localeCompare(b.nombre, 'es')
}

/**
 * Agrupa los productos de varias sucursales en filas comparables.
 *
 * @param productos - Filas de todas las sucursales del alcance.
 * @param sucursalIds - Orden de recorrido. La primera sucursal aporta el
 *   nombre y la categoría con que se muestra cada fila; el orden no cambia qué
 *   empareja con qué, sólo la etiqueta. Si va vacío se usa el orden de
 *   aparición.
 */
export function emparejarRed(productos: ProductoRed[], sucursalIds: number[] = []): RedEmparejada {
  const orden = sucursalIds.length > 0
    ? sucursalIds
    : [...new Set(productos.map((p) => p.sucursal_id))]

  const filas: FilaRed[] = []
  const porCodigo = new Map<string, FilaRed[]>()
  const porNombre = new Map<string, FilaRed[]>()

  for (const sucursalId of orden) {
    for (const p of productos.filter((x) => x.sucursal_id === sucursalId)) {
      const cod = normalizarTexto(p.codigo)
      const nom = normalizarTexto(p.nombre)
      // Una fila que ya tiene un producto de esta sucursal no es candidata:
      // cada producto se empareja una sola vez.
      const libres = (arr: FilaRed[] | undefined): FilaRed[] =>
        (arr ?? []).filter((f) => f.porSucursal[sucursalId] === undefined)

      // El código manda; el nombre es el desempate, igual que en
      // sugerirMatchProducto.
      let candidatas = cod ? libres(porCodigo.get(cod)) : []
      if (candidatas.length === 0 && nom) candidatas = libres(porNombre.get(nom))

      let fila: FilaRed
      if (candidatas.length === 1) {
        fila = candidatas[0]
      } else {
        fila = {
          clave: `${sucursalId}-${p.producto_id}`,
          nombre: p.nombre,
          codigo: p.codigo ?? null,
          categoria: p.categoria,
          porSucursal: {},
          sucursales: [],
          ambiguo: candidatas.length > 1,
        }
        filas.push(fila)
      }

      fila.porSucursal[sucursalId] = p
      fila.sucursales.push(sucursalId)
      if (cod) indexar(porCodigo, cod, fila)
      if (nom) indexar(porNombre, nom, fila)
    }
  }

  return {
    emparejados: filas.filter((f) => f.sucursales.length > 1).sort(porNombreEs),
    sinPar: filas.filter((f) => f.sucursales.length === 1).sort(porNombreEs),
  }
}

/** Texto sobre el que filtra el buscador: nombre + código + categoría. */
export function coincideBusqueda(fila: FilaRed, busqueda: string): boolean {
  const q = normalizarTexto(busqueda)
  if (!q) return true
  const partes = [fila.nombre, fila.codigo, fila.categoria]
  for (const p of Object.values(fila.porSucursal)) {
    if (p) partes.push(p.nombre, p.codigo)
  }
  return partes.some((t) => normalizarTexto(t).includes(q))
}

/** ¿La fila tiene stock en alguna de las sucursales donde aparece? */
export function tieneStock(fila: FilaRed): boolean {
  return Object.values(fila.porSucursal).some((p) => (p?.stock ?? 0) !== 0)
}
