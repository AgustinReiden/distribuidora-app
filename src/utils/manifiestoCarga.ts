/**
 * Consolidado de carga de una ruta: cuánto de cada producto sube al camión,
 * agrupado por rubro -> subrubro. Es la cuenta del Manifiesto de Carga (#829),
 * sacada del PDF para que la pantalla de depósito (#782) muestre exactamente
 * los mismos números que el papel. El PDF (`buildManifiestoOps`) sólo la
 * dibuja; acá no hay nada de layout.
 */
import { formatAclaracionBulto } from '../lib/pdf/utils/formatBulto'
import { esRegaloSustituido, nombreDeLaLinea, nombreSinConteo, unidadDelRegalo, type ItemImpresion } from '../lib/pdf/utils/lineaItem'
import { esCantidadEnSubunidades, factorDeLaLinea } from './unidadesRegalo'

/**
 * Lo que la cuenta lee de una línea. Estructural a propósito: la cumple un
 * `PedidoItemDB` y también la línea sin precios que devuelve
 * `hojas_de_ruta_deposito` (#782), que no trae ni un monto.
 */
export interface ItemParaCarga extends ItemImpresion {
  producto_id?: string | number | null
  producto?: (NonNullable<ItemImpresion['producto']> & {
    id?: string | number | null
    categoria?: string | null
    subcategoria_id?: string | null
  }) | null
}

/** Lo que la cuenta lee de un pedido (ver `ItemParaCarga`). */
export interface PedidoParaCarga {
  canal?: string | null
  items?: ItemParaCarga[] | null
  cambio?: {
    producto_entregado_id?: string | number | null
    producto_entregado_nombre?: string | null
    cantidad_entregada?: number | null
  } | Array<{
    producto_entregado_id?: string | number | null
    producto_entregado_nombre?: string | null
    cantidad_entregada?: number | null
  }> | null
}

/** Una fila acumulada del manifiesto (venta, bonif fardos/sueltas o cambio). */
interface FilaTotal {
  nombre: string
  cantidad: number
  grupo: GrupoManifiesto
  unidades_de_venta_por_fardo?: number | null
  etiqueta_bulto?: string | null
  preConvertidoAFardos?: boolean
  /** Producto de una fila de sueltas, para desambiguar descripciones iguales. */
  producto?: string
  /** Fila de sueltas cuyo nombre es el del producto pelado, sin unidad adelante. */
  sinUnidad?: boolean
}

/** Bonif de tipo Fracción acumulada en subunidades crudas, antes de partir. */
interface FilaFraccion {
  key: string
  nombre: string
  desc: string
  upb: number
  subunidades: number
  grupo: GrupoManifiesto
  sinUnidad: boolean
}

/** Rubro sin asignar: el manifiesto lo agrupa aparte y lo pone al final. */
export const SIN_RUBRO = 'Sin rubro'

/** Rubro → subrubro de un producto, como lo agrupa el manifiesto (mig 270). */
export interface GrupoManifiesto {
  rubro: string
  subrubro: string | null
}

/** Lo que el manifiesto necesita saber de un producto para agruparlo. */
export interface ProductoCatalogoManifiesto {
  id?: string | number
  categoria?: string | null
  subcategoria_id?: string | null
}

/**
 * Opciones del manifiesto. `nombresSubrubro` traduce `subcategoria_id` a nombre
 * (el embed de la query no lo trae: dos FKs de productos a categorias darian
 * PGRST201). `productos` es el catalogo vivo: resuelve el rubro de lo que no
 * trae producto embebido, como el producto que se ENTREGA en una parada de cambio.
 */
export interface OpcionesManifiesto {
  nombresSubrubro?: Record<string, string> | Map<string, string>
  productos?: ProductoCatalogoManifiesto[]
}

/** Una línea a cargar, ya redactada: "12x" + "Manaos Pomelo 3L (2 FARDOS)". */
export interface LineaCarga {
  cantidad: number
  texto: string
}

/**
 * Un rubro -> subrubro con lo que hay que levantar de esa góndola: la venta, los
 * bonificados (cargar aparte) y lo que se entrega en paradas de cambio.
 */
export interface GrupoCarga {
  grupo: GrupoManifiesto
  ventas: LineaCarga[]
  bonificados: LineaCarga[]
  cambios: LineaCarga[]
}

const nombreDeSubrubro = (id: string | null | undefined, nombres: OpcionesManifiesto['nombresSubrubro']): string | null => {
  if (!id || !nombres) return null
  const nombre = nombres instanceof Map ? nombres.get(String(id)) : nombres[String(id)]
  return nombre?.trim() || null
}

function grupoDeProducto(
  producto: ProductoCatalogoManifiesto | null | undefined,
  opciones: OpcionesManifiesto,
): GrupoManifiesto {
  const rubro = producto?.categoria?.trim()
  if (!rubro) return { rubro: SIN_RUBRO, subrubro: null }
  return { rubro, subrubro: nombreDeSubrubro(producto?.subcategoria_id, opciones.nombresSubrubro) }
}

/**
 * Rubros en orden alfabetico con "Sin rubro" al final; dentro de cada rubro, lo
 * que no tiene subrubro primero y despues los subrubros alfabeticos.
 */
function compararGrupos(a: GrupoManifiesto, b: GrupoManifiesto): number {
  if (a.rubro !== b.rubro) {
    if (a.rubro === SIN_RUBRO) return 1
    if (b.rubro === SIN_RUBRO) return -1
    return a.rubro.localeCompare(b.rubro, 'es')
  }
  if (a.subrubro === b.subrubro) return 0
  if (a.subrubro === null) return -1
  if (b.subrubro === null) return 1
  return a.subrubro.localeCompare(b.subrubro, 'es')
}

/**
 * Suma todas las cantidades por producto entre todos los pedidos de la ruta.
 *
 * Para regalos de tipo Fracción (item.es_bonificacion + unidades_por_bloque):
 * convierte la cantidad en subunidades a "fardos completos + botellas sueltas".
 * Los fardos se suman al producto contenedor (mismo producto_id que el item).
 * Las botellas sueltas se listan en una fila aparte usando descripcion_regalo,
 * para que el chofer sepa que carga 1 fardo + N botellas individuales. Si el
 * regalo se sustituyó, la fila nombra al sustituto (nombreDeLaLinea), que es lo
 * que se carga.
 */
export function consolidarCarga(pedidos: PedidoParaCarga[], opciones: OpcionesManifiesto = {}): GrupoCarga[] {
  const catalogoPorId = new Map<string, ProductoCatalogoManifiesto>()
  ;(opciones.productos ?? []).forEach((p) => { if (p.id != null) catalogoPorId.set(String(p.id), p) })

  const totalesCompras: Record<string, FilaTotal> = {} // por producto_id (items vendidos)
  const totalesCambios: Record<string, FilaTotal> = {} // entregados de paradas de cambio (canal='cambio'), sección aparte
  const totalesBonifFardos: Record<string, FilaTotal> = {} // por producto_id (bonifs en unidades de venta / fardos)
  const totalesBonifSueltas: Record<string, FilaTotal> = {} // por descripcion_regalo (botellas/paquetes sueltos)
  // Bonifs de tipo Fracción: se acumulan en subunidades CRUDAS por producto y se
  // parten a fardos+sueltas UNA sola vez sobre el total de la ruta (ver abajo),
  // así no quedan más sueltas que un fardo por sumar restos pedido por pedido.
  const totalesBonifFraccion: Record<string, FilaFraccion> = {} // `${id}|${desc}|${upb}` → { key, nombre, desc, upb, subunidades }

  const acumular = (mapa: Record<string, FilaTotal>, key: string, nombre: string, cantidad: number, grupo: GrupoManifiesto): FilaTotal => {
    if (!mapa[key]) mapa[key] = { nombre, cantidad: 0, grupo }
    mapa[key].cantidad += cantidad
    return mapa[key]
  }

  pedidos.forEach((pedido) => {
    ;(pedido.items || []).forEach((item) => {
      const cantidad = Number(item.cantidad) || 0
      if (cantidad <= 0) return

      // String(): las claves de un Record ya se stringifican; esto sólo lo hace explícito.
      const key = String(item.producto_id ?? item.producto?.id ?? item.producto?.nombre ?? 'sin-id')
      const nombreProducto = item.producto?.nombre || 'Producto'
      // Factor de ESTA línea: congelado al crear → vivo (sólo si la promo no
      // mueve stock) → 1. Con el vivo, subir el factor de una promo de 6 a 12
      // convertía 392 botellas ya vendidas en 32 fardos en vez de 65.
      const factor = factorDeLaLinea(item)
      // Sustituido: la descripción nombra el producto ORIGINAL; la fila lleva la
      // unidad de la promo con el nombre del sustituto, igual que la tarjeta.
      const sustituido = esRegaloSustituido(item)
      const desc = sustituido ? nombreDeLaLinea(item) : nombreSinConteo(item.descripcion_regalo)
      const grupo = grupoDeProducto(
        // El catalogo vivo manda: donde esta el producto hoy en el deposito.
        (catalogoPorId.get(String(item.producto_id ?? item.producto?.id)) ?? item.producto) as ProductoCatalogoManifiesto | undefined,
        opciones,
      )

      // Compras → lista principal, con aclaración (N FARDOS) si aplica.
      if (!item.es_bonificacion) {
        const fila = acumular(totalesCompras, key, nombreProducto, cantidad, grupo)
        if (fila.unidades_de_venta_por_fardo == null) {
          fila.unidades_de_venta_por_fardo = item.producto?.unidades_de_venta_por_fardo ?? null
        }
        if (fila.etiqueta_bulto == null) {
          fila.etiqueta_bulto = item.producto?.etiqueta_bulto ?? null
        }
        return
      }

      // Bonificación de tipo Fracción: acumular en subunidades crudas. El split
      // a fardos+sueltas se hace al final sobre el total consolidado de la ruta.
      if (esCantidadEnSubunidades(item)) {
        // El factor entra en la clave: dos líneas del mismo producto con
        // factores distintos (una promo que cambió) están en unidades distintas
        // y sumarlas crudas daría cualquier cosa.
        const fkey = `${key}|${desc}|${factor}`
        if (!totalesBonifFraccion[fkey]) {
          totalesBonifFraccion[fkey] = {
            key,
            nombre: nombreProducto,
            desc: desc || nombreProducto,
            upb: factor,
            subunidades: 0,
            grupo,
            // Sin unidad que pluralizar: un sustituto cuya promo no la nombra, o
            // un regalo sin descripción, que cae al nombre del producto (#938).
            sinUnidad: sustituido ? !unidadDelRegalo(item.descripcion_regalo) : !desc,
          }
        }
        totalesBonifFraccion[fkey].subunidades += cantidad
        return
      }

      // Bonificación de unidad entera: en unidades de venta del producto.
      const fila = acumular(totalesBonifFardos, key, nombreProducto, cantidad, grupo)
      if (fila.unidades_de_venta_por_fardo == null) {
        fila.unidades_de_venta_por_fardo = item.producto?.unidades_de_venta_por_fardo ?? null
      }
      if (fila.etiqueta_bulto == null) {
        fila.etiqueta_bulto = item.producto?.etiqueta_bulto ?? null
      }
    })
  })

  // Paradas de cambio/devolución (canal='cambio'): el producto que se ENTREGA al
  // cliente también hay que cargarlo, pero va en una sección APARTE del manifiesto
  // (no se mezcla con la venta del día). El detalle vive en recorrido_cambios
  // (cargado como pedido.cambio en la hoja de ruta).
  pedidos.forEach((pedido) => {
    if (pedido.canal !== 'cambio') return
    const c = Array.isArray(pedido.cambio) ? pedido.cambio[0] : pedido.cambio
    if (!c) return
    const cantidad = Number(c.cantidad_entregada) || 0
    if (cantidad <= 0) return
    const key = String(c.producto_entregado_id ?? c.producto_entregado_nombre ?? 'cambio-sin-id')
    acumular(
      totalesCambios,
      key,
      c.producto_entregado_nombre || 'Producto',
      cantidad,
      grupoDeProducto(catalogoPorId.get(String(c.producto_entregado_id)), opciones),
    )
  })

  // Partir las fracciones consolidadas UNA vez por producto: fardos completos +
  // el resto como sueltas (a lo sumo upb-1 sueltas por producto en toda la ruta).
  Object.values(totalesBonifFraccion).forEach((f) => {
    const fardos = Math.floor(f.subunidades / f.upb)
    const sueltas = f.subunidades % f.upb
    if (fardos > 0) {
      // Clave aparte: esta cantidad ya está en fardos completos del BLOQUE de la
      // promo, mientras que una bonificación de unidad entera del mismo producto
      // está en unidades de venta. Sumarlas en la misma fila imprimía "5x
      // producto (FARDOS COMPLETOS)" mezclando 2 fardos con 3 unidades sueltas.
      const fila = acumular(totalesBonifFardos, `${f.key}|fardos`, f.nombre, fardos, f.grupo)
      fila.preConvertidoAFardos = true
    }
    if (sueltas > 0) {
      // Clave por producto Y descripción: dos sabores de un regalo repartido
      // (#831) pueden llegar con la misma descripción de la promo, y sumarlos
      // en una fila hacía cargar N botellas sin decir de qué sabor.
      const fila = acumular(totalesBonifSueltas, `bonif:${f.key}|${f.desc}`, f.desc, sueltas, f.grupo)
      fila.producto = f.nombre
      fila.sinUnidad = f.sinUnidad
    }
  })
  // Si dos filas de sueltas quedaron con el mismo texto (misma descripción,
  // distinto producto), se desambiguan con el nombre del producto.
  const textosSueltas = new Map<string, number>()
  Object.values(totalesBonifSueltas).forEach((f) => {
    textosSueltas.set(f.nombre, (textosSueltas.get(f.nombre) ?? 0) + 1)
  })
  Object.values(totalesBonifSueltas).forEach((f) => {
    if ((textosSueltas.get(f.nombre) ?? 0) > 1 && f.producto) {
      f.nombre = `${f.nombre} - ${f.producto}`
    }
  })

  const ordenar = (mapa: Record<string, FilaTotal>): FilaTotal[] => Object.values(mapa)
    .filter((t) => t.cantidad > 0)
    .sort((a, b) => a.nombre.localeCompare(b.nombre, 'es'))

  const filasCompras = ordenar(totalesCompras)
  const filasBonifFardos = ordenar(totalesBonifFardos)
  const filasBonifSueltas = ordenar(totalesBonifSueltas)
  const filasCambios = ordenar(totalesCambios)

  const lineaConAclaracion = (f: FilaTotal): string => {
    // preConvertidoAFardos: la cantidad ya está en fardos, la etiqueta va directa.
    if (f.preConvertidoAFardos) {
      return `${f.nombre} (${f.cantidad === 1 ? 'FARDO COMPLETO' : 'FARDOS COMPLETOS'})`
    }
    const aclaracion = formatAclaracionBulto(
      f.cantidad,
      f.unidades_de_venta_por_fardo,
      f.etiqueta_bulto,
    )
    return aclaracion ? `${f.nombre} ${aclaracion}` : f.nombre
  }

  // Sueltos: "Nx botellas <producto>" — el conteo inicial del regalo ("1
  // Botella"/"2 Botellas") describe UN bloque, no la cantidad de la ruta, así
  // que siempre se descarta: dejarlo puesto imprimía "3x 2 Granadina" y el
  // chofer cargaba 6. Con dos tokens ("2 Granadina") no hay palabra de unidad
  // que pluralizar, sólo el nombre: se deja tal cual.
  const nombreSuelta = (desc: string, sinUnidad = false): string => {
    const nombre = nombreSinConteo(desc)
    if (!nombre) return '(SUELTAS, NO FARDO)'
    // Nombre de producto pelado (sustituto sin unidad en la promo, o regalo sin
    // descripción): la primera palabra es del producto, no una unidad.
    if (sinUnidad) return `${nombre} (SUELTAS, NO FARDO)`
    const m = /^(\S+)\s+(.+)$/.exec(nombre)
    if (!m) return `${nombre} (SUELTAS, NO FARDO)`
    const unidad = m[1].toLowerCase()
    const plural = unidad.endsWith('s') ? unidad : `${unidad}s`
    return `${plural} ${m[2]} (SUELTAS, NO FARDO)`
  }

  // Agrupado por rubro -> subrubro para que el deposito arme la carga por
  // gondola. Las bonificaciones y los cambios van DENTRO de cada grupo (no en un
  // bloque final): el que carga esa gondola levanta todo de una vez.
  const claveGrupo = (g: GrupoManifiesto): string => `${g.rubro}\u0000${g.subrubro ?? ''}`
  const grupos = new Map<string, GrupoManifiesto>()
  ;[filasCompras, filasBonifFardos, filasBonifSueltas, filasCambios].forEach((filas) => {
    filas.forEach((f) => { if (!grupos.has(claveGrupo(f.grupo))) grupos.set(claveGrupo(f.grupo), f.grupo) })
  })
  const delGrupo = (filas: FilaTotal[], g: GrupoManifiesto): FilaTotal[] =>
    filas.filter((f) => claveGrupo(f.grupo) === claveGrupo(g))

  return Array.from(grupos.values()).sort(compararGrupos).map((g) => ({
    grupo: g,
    ventas: delGrupo(filasCompras, g).map((f) => ({ cantidad: f.cantidad, texto: lineaConAclaracion(f) })),
    bonificados: [
      ...delGrupo(filasBonifFardos, g).map((f) => ({ cantidad: f.cantidad, texto: lineaConAclaracion(f) })),
      ...delGrupo(filasBonifSueltas, g).map((f) => ({ cantidad: f.cantidad, texto: nombreSuelta(f.nombre, f.sinUnidad) })),
    ],
    cambios: delGrupo(filasCambios, g).map((f) => ({ cantidad: f.cantidad, texto: f.nombre })),
  }))
}
