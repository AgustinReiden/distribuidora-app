/**
 * Lectura del historial de `items` de un pedido (`pedido_historial`).
 *
 * El trigger guarda cada lado como texto JSON: un array de líneas. Desde la
 * mig 313 cada línea trae `es_bonificacion` y, en los regalos, la descripción;
 * las filas anteriores no tienen `es_bonificacion` (es una venta) y arrastran
 * claves de más (iva, neto, `_reparto`...) que acá no importan. Y el precio
 * llega a veces como `7500` y a veces como `8500.00`, por eso se compara
 * numéricamente y nunca como texto.
 */

export interface LineaHistorial {
  productoId: string
  cantidad: number
  /** null cuando la fila no lo trae: no es lo mismo que un regalo a $0. */
  precioUnitario: number | null
  esBonificacion: boolean
  descripcionRegalo: string | null
}

export type EstadoFilaHistorial = 'agregado' | 'quitado' | 'cambiado' | 'igual'

export type CambioLineaHistorial =
  | { campo: 'cantidad'; antes: number; despues: number }
  | { campo: 'precio'; antes: number; despues: number }
  | { campo: 'descripcion'; antes: string | null; despues: string | null }

export interface FilaHistorialItems {
  estado: EstadoFilaHistorial
  productoId: string
  esBonificacion: boolean
  /** Línea del lado nuevo; en un `quitado` es la que había antes. */
  linea: LineaHistorial
  /** Sólo se llena en `cambiado`. */
  cambios: CambioLineaHistorial[]
}

const aNumero = (v: unknown): number | null => {
  if (typeof v === 'number') return Number.isFinite(v) ? v : null
  if (typeof v === 'string' && v.trim() !== '') {
    const n = Number(v)
    return Number.isFinite(n) ? n : null
  }
  return null
}

/**
 * Devuelve las líneas normalizadas, o null si el texto no es un array JSON de
 * líneas reconocibles (el que llama cae a mostrar el texto tal cual).
 */
export function parsearLineasHistorial(valor: string): LineaHistorial[] | null {
  let json: unknown
  try {
    json = JSON.parse(valor)
  } catch {
    return null
  }
  if (!Array.isArray(json)) return null

  const lineas: LineaHistorial[] = []
  for (const crudo of json) {
    if (typeof crudo !== 'object' || crudo === null || Array.isArray(crudo)) return null
    const o = crudo as Record<string, unknown>
    const id = o.producto_id
    if ((typeof id !== 'number' && typeof id !== 'string') || String(id).trim() === '') return null
    const cantidad = aNumero(o.cantidad)
    if (cantidad === null) return null
    const descripcion = typeof o.descripcion_regalo === 'string' && o.descripcion_regalo.trim() !== ''
      ? o.descripcion_regalo
      : null
    lineas.push({
      productoId: String(id),
      cantidad,
      precioUnitario: aNumero(o.precio_unitario),
      esBonificacion: o.es_bonificacion === true,
      descripcionRegalo: descripcion,
    })
  }
  return lineas
}

const claveDe = (l: LineaHistorial) => `${l.productoId}|${l.esBonificacion ? 'regalo' : 'venta'}`

function cambiosEntre(antes: LineaHistorial, despues: LineaHistorial): CambioLineaHistorial[] {
  const cambios: CambioLineaHistorial[] = []
  if (antes.cantidad !== despues.cantidad) {
    cambios.push({ campo: 'cantidad', antes: antes.cantidad, despues: despues.cantidad })
  }
  // Si un lado no trae precio no hay con qué comparar: no se inventa un cambio.
  if (antes.precioUnitario !== null && despues.precioUnitario !== null && antes.precioUnitario !== despues.precioUnitario) {
    cambios.push({ campo: 'precio', antes: antes.precioUnitario, despues: despues.precioUnitario })
  }
  if (antes.descripcionRegalo !== despues.descripcionRegalo) {
    cambios.push({ campo: 'descripcion', antes: antes.descripcionRegalo, despues: despues.descripcionRegalo })
  }
  return cambios
}

/**
 * Empareja por (producto, venta/regalo). Si una clave se repite, se empareja en
 * orden de aparición y lo que sobra es agregado o quitado. Salida: ventas
 * primero y regalos después; dentro de cada grupo, el orden del lado nuevo y
 * lo quitado al final.
 */
export function compararItemsHistorial(anterior: LineaHistorial[], nuevo: LineaHistorial[]): FilaHistorialItems[] {
  const pendientes = new Map<string, LineaHistorial[]>()
  for (const l of anterior) {
    const k = claveDe(l)
    const cola = pendientes.get(k)
    if (cola) cola.push(l)
    else pendientes.set(k, [l])
  }

  const filas: FilaHistorialItems[] = []
  for (const l of nuevo) {
    const previa = pendientes.get(claveDe(l))?.shift()
    if (!previa) {
      filas.push({ estado: 'agregado', productoId: l.productoId, esBonificacion: l.esBonificacion, linea: l, cambios: [] })
      continue
    }
    const cambios = cambiosEntre(previa, l)
    filas.push({
      estado: cambios.length > 0 ? 'cambiado' : 'igual',
      productoId: l.productoId,
      esBonificacion: l.esBonificacion,
      linea: l,
      cambios,
    })
  }

  // Lo que quedó sin emparejar, en el orden en que estaba del lado anterior.
  for (const l of anterior) {
    const cola = pendientes.get(claveDe(l))
    if (cola && cola[0] === l) {
      cola.shift()
      filas.push({ estado: 'quitado', productoId: l.productoId, esBonificacion: l.esBonificacion, linea: l, cambios: [] })
    }
  }

  return [...filas.filter(f => !f.esBonificacion), ...filas.filter(f => f.esBonificacion)]
}
