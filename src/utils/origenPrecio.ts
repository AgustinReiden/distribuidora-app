/**
 * Por qué se cobró cada precio (mig 148/149).
 *
 * El 31% de los ítems entregados sale bajo lista y hasta ahora no quedaba
 * rastro de por qué: el descuento pisa `precio_unitario` y desaparece. Sin esta
 * etiqueta no hay comisión variable por descuento posible.
 *
 * La precedencia replica la del armado del pedido
 * (`PedidosContainer.ejecutarCreacionPedido`), que es donde los precios se
 * aplican de verdad:
 *
 *   bonificación → override manual → mayorista → descuento del cliente → lista
 *
 * El override manual va segundo a propósito: cuando el usuario escribe un
 * precio a mano, `resolverPreciosMayorista` deja de aplicar mayorista y
 * `aplicarDescuentoClienteItems` respeta el precio tipeado. Etiquetar eso como
 * 'mayorista' porque el producto pertenece a un grupo sería mentir sobre quién
 * decidió el precio — y la comisión reducida por descuento de volumen se
 * pagaría sobre una decisión manual.
 */

export type OrigenPrecio =
  | 'lista'
  | 'mayorista'
  | 'desc_cliente'
  | 'desc_categoria'
  | 'manual'
  | 'bonificacion'

/** Lo que el RPC `registrar_origen_precio_items` espera por ítem. */
export interface OrigenPrecioItem {
  producto_id: string
  es_bonificacion: boolean
  origen_precio: OrigenPrecio
  grupo_precio_escala_id?: string | null
}

export interface ItemParaOrigen {
  productoId: string | number
  /** Precio con el que finalmente se persiste el ítem. */
  precioUnitario: number
  esBonificacion?: boolean
  /** El usuario escribió el precio a mano. */
  precioOverride?: boolean
}

export interface ContextoOrigen {
  /** Salida de `resolverPreciosMayorista`, por productoId. */
  preciosResueltos?: Map<string, { esMayorista: boolean; escalaId?: string | null }>
  /**
   * % de descuento del cliente que aplicó a cada producto, por productoId.
   * Se calcula con `resolverDescuentoPctCliente` en el armado; acá solo se
   * consulta si fue > 0 y si vino de una regla por categoría.
   */
  descuentoClientePct?: Map<string, number>
  /** productoIds cuyo descuento salió de una regla por categoría, no del general. */
  descuentoPorCategoria?: ReadonlySet<string>
}

/**
 * Resuelve el origen de UN ítem. Exportada aparte para poder testear cada rama
 * sin armar un pedido entero.
 */
export function resolverOrigenPrecio(
  item: ItemParaOrigen,
  ctx: ContextoOrigen = {},
): { origen: OrigenPrecio; escalaId: string | null } {
  const pid = String(item.productoId)

  if (item.esBonificacion) return { origen: 'bonificacion', escalaId: null }
  if (item.precioOverride) return { origen: 'manual', escalaId: null }

  const resuelto = ctx.preciosResueltos?.get(pid)
  if (resuelto?.esMayorista) {
    return { origen: 'mayorista', escalaId: resuelto.escalaId ?? null }
  }

  const pct = ctx.descuentoClientePct?.get(pid) ?? 0
  if (pct > 0) {
    return {
      origen: ctx.descuentoPorCategoria?.has(pid) ? 'desc_categoria' : 'desc_cliente',
      escalaId: null,
    }
  }

  return { origen: 'lista', escalaId: null }
}

/**
 * Arma el payload de `registrar_origen_precio_items` para un pedido completo.
 *
 * Devuelve una fila por ítem. Los ítems repetidos del mismo producto colapsan
 * en el RPC (el UPDATE matchea por producto + es_bonificacion), lo cual es
 * correcto: comparten precio y por lo tanto origen.
 */
export function construirOrigenPrecioItems(
  items: ItemParaOrigen[],
  ctx: ContextoOrigen = {},
): OrigenPrecioItem[] {
  return items.map(item => {
    const { origen, escalaId } = resolverOrigenPrecio(item, ctx)
    return {
      producto_id: String(item.productoId),
      es_bonificacion: Boolean(item.esBonificacion),
      origen_precio: origen,
      grupo_precio_escala_id: escalaId,
    }
  })
}
