/**
 * Estado del campo "Subrubro" de la ficha del producto (#828, mig 270).
 *
 * El campo se ve SIEMPRE que haya un rubro elegido: si sólo aparecía cuando el
 * rubro ya tenía subrubros, nadie sabía que existía (en prod había 0). Lo que
 * cambia es qué se puede hacer adentro:
 *
 *  - El subrubro es una fila de `categorias` hija del rubro (`parent_id`), así
 *    que el rubro tiene que ser una fila. Hay productos cuyo rubro es sólo el
 *    texto `productos.categoria` y no existe en `categorias` (#763): a esos no
 *    se les puede colgar un hijo y el campo queda deshabilitado.
 *  - Un rubro tipeado con "+ Nueva categoría" todavía no existe, pero se crea al
 *    guardar, antes que el subrubro: se puede tipear un subrubro nuevo debajo, no
 *    elegir uno existente (no tiene).
 *  - Crear categorías es sólo de admin (RLS `mt_categorias_insert`, mig 009):
 *    quien no puede crear no ve la opción "crear".
 */
export type EstadoSubrubro =
  | { visible: false }
  | {
      visible: true
      /** El rubro no es una fila de `categorias`: no se le puede colgar un subrubro. */
      deshabilitado: true
      motivo: string
    }
  | {
      visible: true
      deshabilitado: false
      /** Hay un select con los subrubros existentes del rubro. */
      puedeElegir: boolean
      /** Se ofrece "+ Nuevo subrubro". */
      puedeCrear: boolean
    }

export const MOTIVO_RUBRO_SIN_FILA =
  'Este rubro todavía no está cargado en Categorías. Creá el rubro ahí para poder asignarle subrubros.'

export interface EntradaEstadoSubrubro {
  /** Rubro elegido en la lista ('' = ninguno). */
  rubro: string
  /** Rubro tipeado con "+ Nueva categoría"; null = se está eligiendo de la lista. */
  rubroNuevo: string | null
  /**
   * Nombres de los rubros que son fila de `categorias`. undefined = todos los de
   * la lista lo son.
   */
  rubrosConFila?: readonly string[]
  /** Cantidad de subrubros que ya tiene el rubro elegido. */
  cantidadSubrubros: number
  /** El usuario puede insertar en `categorias` (admin). */
  puedeCrear: boolean
}

export function estadoSubrubro(e: EntradaEstadoSubrubro): EstadoSubrubro {
  if (e.rubroNuevo !== null) {
    // Rubro por crear: su subrubro sólo puede ser nuevo, y sólo lo crea un admin
    // (el rubro también lo crea él, así que sin permiso no hay nada que ofrecer).
    if (!e.rubroNuevo.trim() || !e.puedeCrear) return { visible: false }
    return { visible: true, deshabilitado: false, puedeElegir: false, puedeCrear: true }
  }
  if (!e.rubro) return { visible: false }
  if (e.rubrosConFila && !e.rubrosConFila.includes(e.rubro)) {
    return { visible: true, deshabilitado: true, motivo: MOTIVO_RUBRO_SIN_FILA }
  }
  const puedeElegir = e.cantidadSubrubros > 0
  // Sin subrubros y sin permiso para crear, no hay nada que hacer en el campo.
  if (!puedeElegir && !e.puedeCrear) return { visible: false }
  return { visible: true, deshabilitado: false, puedeElegir, puedeCrear: e.puedeCrear }
}
