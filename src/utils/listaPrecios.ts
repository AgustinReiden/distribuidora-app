/**
 * Lista de precios para el cliente: productos activos de la sucursal, por rubro
 * → subrubro, con su precio y su condición mayorista. Es lo que imprime el PDF
 * de `lib/pdf/listaPrecios.ts`.
 *
 * La lista NO lleva stock, costos, código, proveedor ni promociones, y eso no
 * depende de que el PDF se acuerde de no imprimirlos: la entrada sólo tiene
 * lugar para lo que hace falta (`ProductoListaPrecios`) y la salida se arma
 * campo por campo. Un dato nuevo en la lista es una decisión del dueño.
 *
 * La condición mayorista dice lo que el PEDIDO cobra: cada línea es el precio
 * que da `resolverPreciosMayorista` \u2014el mismo motor que usa la carga del
 * pedido\u2014 al cargar esa cantidad del producto. Así una escala que no baja el
 * precio no aparece (decisión del dueño, 2026-10-13: PAMPERITO tiene 6 y 12 u.
 * a $890, y con 12 u. el pedido cobra $890 igual), y una escala de más cantidad
 * que dentro de su grupo resulta más cara sí aparece, porque es lo que se cobra.
 *
 * Dos decisiones más del dueño (2026-10-13, #1120):
 *  - Con un mínimo de venta mayor que la primera escala, las escalas arrancan
 *    en el mínimo: el pedido no deja cargar menos. El mínimo no se muestra como
 *    dato, sólo mueve dónde empieza la primera línea.
 *  - La lista no mira promociones. Si el pedido dispara una promo sobre el
 *    producto, cobra precio de lista + regalo; quien arma el pedido puede
 *    quitar la promo y entonces cobra el mayorista que dice la lista.
 */
import type { GrupoPrecioConDetalles } from '../types'
import { condicionesDeProducto } from './condicionesMayoristas'
import { describirReglaEscala } from './describirReglaEscala'
import { formatPrecio } from './formatters'
import { resolverPreciosMayorista, type GrupoPrecioInfo } from './precioMayorista'
import { esProductoOperativo } from './productosOperativos'

/** Lo único que la lista lee de un producto. */
export interface ProductoListaPrecios {
  id: string | number
  nombre: string
  /** Precio de venta, con IVA incluido (`productos.precio`). */
  precio: number | string | null
  activo?: boolean | null
  /** Rubro: el texto de `productos.categoria`, como lo agrupa el manifiesto. */
  categoria?: string | null
  subcategoria_id?: string | number | null
  /**
   * Mínimo de venta (`productos.cantidad_minima_venta`). No se muestra: sólo
   * hace que las escalas arranquen en él (#1120).
   */
  cantidad_minima_venta?: number | string | null
}

export interface EntradaListaPrecios {
  productos: readonly ProductoListaPrecios[]
  grupos: readonly GrupoPrecioConDetalles[]
  /** subcategoria_id → nombre del subrubro (filas de `categorias` con `parent_id`). */
  nombresSubrubro?: ReadonlyMap<string, string> | Readonly<Record<string, string>>
}

export interface FilaListaPrecios {
  nombre: string
  precio: number
  /** Una línea por escala, en orden de cantidad; vacía si no tiene condición. */
  condicion: string[]
}

export interface SeccionListaPrecios {
  /** Nombre del rubro, o `TITULO_SIN_CATEGORIA` para la sección "Otros". */
  rubro: string
  subrubro: string | null
  /**
   * La sección "Otros": los productos sin rubro y los del rubro que se llama
   * "Otros", juntos (#1120). Va siempre al final.
   */
  sinCategoria: boolean
  filas: FilaListaPrecios[]
}

export const TITULO_SIN_CATEGORIA = 'Otros'

const compararTexto = (a: string, b: string) => a.localeCompare(b, 'es', { numeric: true })

// =============================================================================
// Condición mayorista
// =============================================================================

interface ContextoCondiciones {
  /** Sólo los grupos que aplican precio: el mismo criterio que `fetchPricingMap`. */
  grupos: GrupoPrecioConDetalles[]
  /**
   * Los sabores que la lista ofrece: activos y con precio. Un sabor que no está
   * en la lista no puede contarse para el surtido ni nombrarse en una regla.
   */
  idsListables: Set<string>
  nombresListables: Map<string, string>
}

const esListable = (p: ProductoListaPrecios): boolean =>
  esProductoOperativo(p) && Number(p.precio) > 0

function contextoCondiciones(
  grupos: readonly GrupoPrecioConDetalles[],
  productos: readonly ProductoListaPrecios[],
): ContextoCondiciones {
  const listables = productos.filter(esListable)
  return {
    grupos: grupos.filter(g => g.activo),
    idsListables: new Set(listables.map(p => String(p.id))),
    nombresListables: new Map(listables.map(p => [String(p.id), p.nombre.trim()])),
  }
}

interface LineaEscala {
  cantidad: number
  precio: number
  /** Sabores listables que suman para esta escala, contando al producto. */
  sabores: number
}

function textoEscala(linea: LineaEscala, conSurtido: boolean): string {
  const base = `Desde ${linea.cantidad} u. ${formatPrecio(linea.precio)} c/u`
  return conSurtido && linea.sabores > 1 ? `${base}, surtido con ${linea.sabores} sabores` : base
}

function condicionEnContexto(producto: ProductoListaPrecios, ctx: ContextoCondiciones): string[] {
  const pid = String(producto.id)
  const precioLista = Number(producto.precio)
  if (!(precioLista > 0)) return []
  // Por debajo del mínimo de venta el pedido no deja cargar: ninguna línea
  // puede empezar antes (#1120).
  const minimoVenta = Math.max(1, Number(producto.cantidad_minima_venta) || 1)

  const condiciones = condicionesDeProducto(ctx.grupos as GrupoPrecioConDetalles[], pid)
  if (condiciones.length === 0) return []

  // Cada condición como la ve el motor del pedido, con sus sabores listables.
  const porGrupo = condiciones.map(c => {
    const grupo = ctx.grupos.find(g => String(g.id) === c.grupoId)!
    const productoIds = grupo.productos.map(p => String(p.producto_id))
    const escalas = c.escalas.filter(e => e.activo)
    const info: GrupoPrecioInfo = {
      grupoId: c.grupoId,
      grupoNombre: c.grupoNombre,
      escalas: escalas.map(e => e.escala),
      productoIds,
    }
    return { info, escalas, sabores: productoIds.filter(id => ctx.idsListables.has(id)).length }
  })

  const precioCon = (infos: GrupoPrecioInfo[], cantidad: number): number =>
    resolverPreciosMayorista(
      [{ productoId: pid, cantidad, precioUnitario: precioLista }],
      new Map([[pid, infos]]),
    ).get(pid)!.precioResuelto

  // Los umbrales salen de toda escala que el producto alcanza SOLO: todas menos
  // las que piden varios sabores distintos. Si la escala le pide a este producto
  // un mínimo mayor que su cantidad, el umbral es ese mínimo. En cada umbral el
  // precio es el que cobra el pedido, venga de la escala que venga.
  const escalasActivas = porGrupo.flatMap(g => g.escalas.map(e => ({ e, sabores: g.sabores })))
  const umbrales = [...new Set(
    escalasActivas
      .filter(({ e }) => e.escala.minProductosDistintos <= 1)
      .map(({ e }) => Math.max(e.cantidadMinima, e.escala.minimosPorProducto.get(pid)?.cantidad ?? 0, minimoVenta)),
  )].sort((a, b) => a - b)

  const lineas: LineaEscala[] = []
  let anterior: LineaEscala | null = null
  for (const cantidad of umbrales) {
    const precio = precioCon(porGrupo.map(g => g.info), cantidad)
    const conDescuento = precio < precioLista
    // Hasta el primer descuento no hay nada que decir. Después, si una escala
    // mayor vuelve al precio de lista (dentro del grupo manda la de más
    // cantidad, aunque sea más cara), la lista tiene que decirlo.
    if (!conDescuento && !anterior) continue
    const sabores = conDescuento
      ? Math.max(...porGrupo.filter(g => precioCon([g.info], cantidad) === precio).map(g => g.sabores))
      : 1
    // Mismo precio y sin sumar sabores: la escala no cambia nada para el cliente.
    if (anterior && precio === anterior.precio && sabores <= anterior.sabores) continue
    anterior = { cantidad, precio, sabores }
    lineas.push(anterior)
  }

  // Una escala que pide varios sabores distintos no se alcanza con este producto
  // solo: va con su regla completa. Si no hay en la lista sabores suficientes
  // para cumplirla, no se puede alcanzar nunca y no se muestra. La regla no
  // nombra sabores que la lista no ofrece.
  const reglas = escalasActivas
    .filter(({ e, sabores }) =>
      e.escala.minProductosDistintos > 1 &&
      sabores >= e.escala.minProductosDistintos &&
      e.precioEfectivo < precioLista)
    .sort((a, b) => a.e.cantidadMinima - b.e.cantidadMinima)
    .map(({ e }) => describirReglaEscala(
      {
        ...e.escala,
        minimosPorProducto: new Map(
          [...e.escala.minimosPorProducto].filter(([id]) => ctx.idsListables.has(id)),
        ),
      },
      { nombresProductos: ctx.nombresListables },
    ))

  const textos: string[] = []
  const saboresUnicos = new Set(lineas.map(l => l.sabores))
  if (saboresUnicos.size === 1 && reglas.length === 0) {
    // Todas suman con los mismos sabores: el surtido se dice una vez, al final.
    // Con una regla aparte no: se leería como parte de esa regla.
    textos.push(...lineas.map(l => textoEscala(l, false)))
    const [sabores] = saboresUnicos
    if (sabores > 1) textos.push(`surtido con ${sabores} sabores`)
  } else {
    textos.push(...lineas.map(l => textoEscala(l, true)))
  }
  textos.push(...reglas)
  return textos
}

/**
 * Líneas de la condición mayorista de un producto. `productos` es el catálogo de
 * la sucursal: dice qué sabores están activos para contar el surtido.
 */
export function condicionMayorista(
  producto: ProductoListaPrecios,
  grupos: readonly GrupoPrecioConDetalles[],
  productos: readonly ProductoListaPrecios[],
): string[] {
  return condicionEnContexto(producto, contextoCondiciones(grupos, productos))
}

// =============================================================================
// Secciones
// =============================================================================

function nombreDeSubrubro(
  id: ProductoListaPrecios['subcategoria_id'],
  nombres: EntradaListaPrecios['nombresSubrubro'],
): string | null {
  if (id == null || id === '' || !nombres) return null
  const nombre = nombres instanceof Map
    ? nombres.get(String(id))
    : (nombres as Readonly<Record<string, string>>)[String(id)]
  return nombre?.trim() || null
}

/**
 * Rubros en orden alfabético con "Otros" al final; dentro de cada rubro, lo que
 * no tiene subrubro primero y después los subrubros alfabéticos (el mismo orden
 * que el manifiesto de carga). Las filas, alfabéticas por nombre.
 */
function compararSecciones(a: SeccionListaPrecios, b: SeccionListaPrecios): number {
  if (a.sinCategoria !== b.sinCategoria) return a.sinCategoria ? 1 : -1
  if (a.rubro !== b.rubro) return compararTexto(a.rubro, b.rubro)
  if (a.subrubro === b.subrubro) return 0
  if (a.subrubro === null) return -1
  if (b.subrubro === null) return 1
  return compararTexto(a.subrubro, b.subrubro)
}

export function armarListaPrecios(entrada: EntradaListaPrecios): SeccionListaPrecios[] {
  const ctx = contextoCondiciones(entrada.grupos, entrada.productos)
  const secciones = new Map<string, SeccionListaPrecios>()

  for (const producto of entrada.productos) {
    if (!esProductoOperativo(producto)) continue
    // Sin precio no se puede vender (es el aviso rojo de Productos): no se lista.
    const precio = Number(producto.precio)
    if (!(precio > 0)) continue

    const rubro = producto.categoria?.trim() || null
    const subrubro = rubro ? nombreDeSubrubro(producto.subcategoria_id, entrada.nombresSubrubro) : null
    // Un rubro que se llama "Otros" va con los sin rubro: dos secciones "Otros"
    // confunden al cliente (#1120). Sus subrubros siguen siendo subrubros.
    const esOtros = rubro === null || rubro.toLocaleLowerCase('es') === TITULO_SIN_CATEGORIA.toLocaleLowerCase('es')
    const clave = esOtros ? `\u0000otros\u0000${subrubro ?? ''}` : `${rubro}\u0000${subrubro ?? ''}`

    let seccion = secciones.get(clave)
    if (!seccion) {
      seccion = {
        rubro: esOtros || rubro === null ? TITULO_SIN_CATEGORIA : rubro,
        subrubro,
        sinCategoria: esOtros,
        filas: [],
      }
      secciones.set(clave, seccion)
    }
    seccion.filas.push({
      nombre: producto.nombre.trim(),
      precio,
      condicion: condicionEnContexto(producto, ctx),
    })
  }

  const ordenadas = [...secciones.values()].sort(compararSecciones)
  for (const seccion of ordenadas) seccion.filas.sort((a, b) => compararTexto(a.nombre, b.nombre))
  return ordenadas
}
