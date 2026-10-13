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
 */
import type { GrupoPrecioConDetalles } from '../types'
import { condicionesDeProducto } from './condicionesMayoristas'
import { describirReglaEscala } from './describirReglaEscala'
import { formatPrecio } from './formatters'
import {
  esEscalaCombinada,
  resolverPreciosMayorista,
  type GrupoPrecioInfo,
} from './precioMayorista'
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
  /** Nombre del rubro, o `TITULO_SIN_CATEGORIA` para los productos sin rubro. */
  rubro: string
  subrubro: string | null
  /** La sección de los productos sin rubro: va siempre al final. */
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
  idsActivos: Set<string>
  nombresActivos: Map<string, string>
}

function contextoCondiciones(
  grupos: readonly GrupoPrecioConDetalles[],
  productos: readonly ProductoListaPrecios[],
): ContextoCondiciones {
  const activos = productos.filter(esProductoOperativo)
  return {
    grupos: grupos.filter(g => g.activo),
    idsActivos: new Set(activos.map(p => String(p.id))),
    nombresActivos: new Map(activos.map(p => [String(p.id), p.nombre.trim()])),
  }
}

interface LineaEscala {
  cantidad: number
  precio: number
  /** Sabores activos que suman para esta escala, contando al producto. */
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

  const condiciones = condicionesDeProducto(ctx.grupos as GrupoPrecioConDetalles[], pid)
  if (condiciones.length === 0) return []

  // Cada condición como la ve el motor del pedido, con sus sabores activos.
  const porGrupo = condiciones.map(c => {
    const grupo = ctx.grupos.find(g => String(g.id) === c.grupoId)!
    const productoIds = grupo.productos.map(p => String(p.producto_id))
    const info: GrupoPrecioInfo = {
      grupoId: c.grupoId,
      grupoNombre: c.grupoNombre,
      escalas: c.escalas.filter(e => e.activo).map(e => e.escala),
      productoIds,
    }
    return { info, sabores: productoIds.filter(id => ctx.idsActivos.has(id)).length }
  })

  const precioCon = (infos: GrupoPrecioInfo[], cantidad: number): number =>
    resolverPreciosMayorista(
      [{ productoId: pid, cantidad, precioUnitario: precioLista }],
      new Map([[pid, infos]]),
    ).get(pid)!.precioResuelto

  // Los umbrales son las cantidades de las escalas clásicas. Una combinada pide
  // varios sabores distintos o mínimos por sabor: no se alcanza cargando sólo
  // este producto, y se describe aparte con su regla completa.
  const escalasActivas = condiciones.flatMap(c => c.escalas.filter(e => e.activo))
  const umbrales = [...new Set(
    escalasActivas.filter(e => !esEscalaCombinada(e.escala)).map(e => e.cantidadMinima),
  )].sort((a, b) => a - b)

  const lineas: LineaEscala[] = []
  let anterior: LineaEscala | null = null
  for (const cantidad of umbrales) {
    const precio = precioCon(porGrupo.map(g => g.info), cantidad)
    if (!(precio < precioLista)) continue
    const sabores = Math.max(
      ...porGrupo.filter(g => precioCon([g.info], cantidad) === precio).map(g => g.sabores),
    )
    // Mismo precio y sin sumar sabores: la escala no cambia nada para el cliente.
    if (anterior && precio === anterior.precio && sabores <= anterior.sabores) continue
    anterior = { cantidad, precio, sabores }
    lineas.push(anterior)
  }

  const textos: string[] = []
  const saboresUnicos = new Set(lineas.map(l => l.sabores))
  if (saboresUnicos.size === 1) {
    // Todas suman con los mismos sabores: el surtido se dice una vez, al final.
    textos.push(...lineas.map(l => textoEscala(l, false)))
    const [sabores] = saboresUnicos
    if (sabores > 1) textos.push(`surtido con ${sabores} sabores`)
  } else {
    textos.push(...lineas.map(l => textoEscala(l, true)))
  }

  const combinadas = escalasActivas
    .filter(e => esEscalaCombinada(e.escala) && e.precioEfectivo < precioLista)
    .sort((a, b) => a.cantidadMinima - b.cantidadMinima)
  for (const e of combinadas) {
    textos.push(describirReglaEscala(e.escala, { nombresProductos: ctx.nombresActivos }))
  }

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
    const clave = rubro === null ? '\u0000sin-categoria' : `${rubro}\u0000${subrubro ?? ''}`

    let seccion = secciones.get(clave)
    if (!seccion) {
      seccion = {
        rubro: rubro ?? TITULO_SIN_CATEGORIA,
        subrubro,
        sinCategoria: rubro === null,
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
