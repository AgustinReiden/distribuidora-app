/**
 * El aumento masivo contra los precios de la base, no contra el catálogo en caché
 * (FRG2-3, #1599).
 *
 * El modal calcula el precio nuevo sobre `productos`, que viene del caché (hasta
 * 10 minutos de edad) y manda precios ABSOLUTOS. Si otro admin cambió un precio
 * mientras tanto, el aumento lo pisaba sin que nadie lo notara. Decisión del
 * dueño: al confirmar se vuelven a leer los precios de lo seleccionado; si alguno
 * cambió desde que se abrió el modal, se avisa —cuáles y de cuánto a cuánto— y NO
 * se aplica hasta que el usuario confirme de nuevo, ya sobre los precios nuevos.
 */
import { formatPrecio } from './formatters'

/** Lo que se lee de la base para comparar y para recalcular. */
export interface PrecioVigente {
  id: string
  precio: number | null
  precio_sin_iva: number | null
  condicion_iva?: string | null
  porcentaje_iva?: number | null
}

/** Lo que el usuario vio al abrir (o al reconfirmar): los precios de referencia. */
export interface PrecioVisto {
  id: string
  nombre: string
  precio: number | null | undefined
  precio_sin_iva: number | null | undefined
}

export interface CambioDePrecio {
  id: string
  nombre: string
  campo: 'precio' | 'precio_sin_iva'
  de: number | null
  a: number | null
}

export interface ComparacionDePrecios {
  /** Productos cuyo precio ya no es el que se vio. */
  cambios: CambioDePrecio[]
  /** Productos que la base ya no devuelve (borrados o de otra sucursal). */
  faltan: PrecioVisto[]
}

const num = (v: number | null | undefined): number | null => (v == null ? null : Number(v))
const mismoPrecio = (a: number | null | undefined, b: number | null | undefined): boolean => {
  const x = num(a)
  const y = num(b)
  if (x === null || y === null) return x === y
  return Math.round(x * 100) === Math.round(y * 100)
}

/** Compara lo que se vio con lo que hay hoy en la base. */
export function compararPrecios(vistos: PrecioVisto[], vigentes: PrecioVigente[]): ComparacionDePrecios {
  const porId = new Map(vigentes.map(v => [String(v.id), v]))
  const cambios: CambioDePrecio[] = []
  const faltan: PrecioVisto[] = []
  for (const visto of vistos) {
    const hoy = porId.get(String(visto.id))
    if (!hoy) {
      faltan.push(visto)
      continue
    }
    if (!mismoPrecio(visto.precio, hoy.precio)) {
      cambios.push({ id: visto.id, nombre: visto.nombre, campo: 'precio', de: num(visto.precio), a: num(hoy.precio) })
    } else if (!mismoPrecio(visto.precio_sin_iva, hoy.precio_sin_iva)) {
      // Sólo el neto: el final es el mismo, pero el aumento se calcula sobre los dos.
      cambios.push({ id: visto.id, nombre: visto.nombre, campo: 'precio_sin_iva', de: num(visto.precio_sin_iva), a: num(hoy.precio_sin_iva) })
    }
  }
  return { cambios, faltan }
}

const plata = (v: number | null): string => (v === null ? 'sin precio' : formatPrecio(v))

/**
 * El aviso: cuáles productos y de cuánto a cuánto. Nombra los primeros `max` y
 * cuenta el resto, para que cien cambios no sean cien renglones.
 */
export function mensajeCambiosDePrecio(comparacion: ComparacionDePrecios, max = 5): string {
  const { cambios, faltan } = comparacion
  const partes: string[] = []
  if (cambios.length > 0) {
    const lista = cambios.slice(0, max)
      .map(c => `${c.nombre}${c.campo === 'precio_sin_iva' ? ' (neto)' : ''}: de ${plata(c.de)} a ${plata(c.a)}`)
      .join('; ')
    const resto = cambios.length > max ? ` y ${cambios.length - max} más` : ''
    const quien = cambios.length === 1 ? 'el precio de 1 producto' : `el precio de ${cambios.length} productos`
    partes.push(`Cambió ${quien} desde que abriste esta pantalla: ${lista}${resto}.`)
  }
  if (faltan.length > 0) {
    const lista = faltan.slice(0, max).map(f => f.nombre).join(', ')
    const resto = faltan.length > max ? ` y ${faltan.length - max} más` : ''
    const cuantos = faltan.length === 1 ? 'Un producto ya no está' : `${faltan.length} productos ya no están`
    partes.push(`${cuantos} en esta sucursal y se saca de la selección: ${lista}${resto}.`)
  }
  partes.push('No se aplicó nada. La vista previa ya usa los precios nuevos: revisala y volvé a apretar Aplicar para confirmar.')
  return partes.join(' ')
}
