/**
 * Hook reactivo para resolución de promociones + precios mayoristas
 *
 * La secuencia promo → mayorista → descuento del cliente NO vive acá: vive en
 * `utils/orquestacionPrecios.ts`, que está sincronizado byte a byte con la copia
 * del bot de Telegram. Este hook sólo conecta las queries (pricingMap, promoMap,
 * mínimos de venta) con esa función pura y expone los nudges, que son de la app.
 */
import { useMemo } from 'react'
import { usePricingMapQuery } from './queries/useGruposPrecioQuery'
import { usePromoMapQuery } from './queries/usePromocionesQuery'
import { useMinimosVentaQuery } from './queries/useProductosQuery'
import {
  calcularFaltanteParaTier,
  construirMOQMap,
  obtenerMOQ,
  validarMOQPedido,
  type ItemPedido,
  type MinimosProducto,
  type PrecioResuelto,
  type FaltanteParaTier,
  type ViolacionMOQ,
} from '../utils/precioMayorista'
import {
  calcularFaltanteParaBonificacion,
  type BonificacionResult,
  type PromoMap,
  type PromoResolucion,
} from '../utils/promociones'
import {
  orquestarPrecios,
  type ItemResuelto,
  type ParteRegalo,
  type RegaloOverride,
} from '../utils/orquestacionPrecios'
import type { ClienteConDescuentos, ProductoConCategoria } from '../utils/descuentoCliente'
import { useCombosVigentesQuery, type FotoCombo } from './queries/useCombosQuery'
import type { ComboAplicado, ComboVigente } from '../utils/combos'
import { aplicarCombosAlPedido, combinarCombosConFotos, type LineaConCombo } from '../utils/combosPedido'
import type { PricingMap } from '../utils/precioMayorista'
import { sugerirCombos, type EntradaSugerencias, type SugerenciaCombo } from '../utils/comboSugerencia'
import { entradaDeConsulta, resumirDatosDePrecio, type DatosDePrecio, type EntradaDatoDePrecio } from '../utils/datosDePrecio'

/** Item del pedido ya resuelto (compra o regalo). Alias del tipo de la orquestación. */
export type ItemPedidoConPromo = ItemResuelto

export type { ParteRegalo, RegaloOverride }

/**
 * Cliente + catálogo para la tercera capa (descuento general / por categoría).
 * Es opcional: las pantallas que sólo muestran promo + mayorista (edición de un
 * pedido ya guardado, por ejemplo) no lo pasan y el hook se queda en dos capas.
 */
export interface ContextoDescuentoCliente {
  cliente?: ClienteConDescuentos | null
  productos?: ProductoConCategoria[]
}

/** Combos del pedido (#1191). Sin esto, el hook arma los combos vigentes de la fecha. */
export interface OpcionesCombos {
  /** false: el pedido no lleva combos (un vale blanco). */
  habilitados?: boolean
  /** Edición: el pedido, para no contar sus propios combos contra el tope. */
  pedidoId?: string
  /** Edición: la foto de los combos que el pedido ya tiene (pedido_combos). */
  fotos?: FotoCombo[]
  /** Edición: las promos de las que el pedido ya tiene regalo, que siguen resolviendo aunque se hayan apagado (#1300). */
  promosDelPedido?: readonly string[]
  /**
   * ¿Un error de las promos bloquea aunque haya un dato en memoria? Sí por defecto: la edición
   * (VTA-2) y el cambio de cliente son online y borrarían o inventarían regalos. El alta lo
   * pone en false (decisión del dueño, #1559): con mala señal y las promos de hace unos
   * minutos en memoria, se confirma con esas promos; sólo bloquea la falta de dato.
   */
  promosFallanConDato?: boolean
  /**
   * Sugerencia (#1194): sin esto no se calcula. `precioDe` da el precio de
   * lista de un producto que no está en el carrito; `puedeAgregar` decide stock
   * y política (`mostrar_sin_stock`); `descartados`, los combos que el usuario
   * descartó para este pedido.
   */
  sugerencias?: Pick<EntradaSugerencias, 'precioDe' | 'puedeAgregar' | 'descartados'>
}

interface UsePromocionPedidoReturn {
  /** Mapa de productoId → precio resuelto (mayorista) */
  preciosResueltos: Map<string, PrecioResuelto>
  /** Nudges de mayorista */
  faltantes: FaltanteParaTier[]
  /** Resolución de promociones, con los overrides de regalo aplicados (un reparto = N bonificaciones) */
  promoResolucion: PromoResolucion
  /** Bonificaciones como las calcula la promo, antes de los overrides (una por promo) */
  bonificacionesBase?: BonificacionResult[]
  /** promoIds cuyo reparto del regalo no cierra: bloquean el confirmar */
  regalosInvalidos?: string[]
  /** Promos vigentes por productoId (para saber qué productos tiene cada promo) */
  promoMap?: PromoMap
  /** Nudges de bonificación */
  faltantesBonificacion: Array<{ productoId: string; promoNombre: string; faltante: number; bonificacion: number }>
  /** Items finales con bonificaciones añadidas, SIN el descuento del cliente */
  itemsFinales: ItemPedidoConPromo[]
  /** Total calculado correctamente con promos, SIN el descuento del cliente */
  totalFinal: number
  /** Total original sin ningún descuento */
  totalOriginal: number
  /** Ahorro total (sin contar el descuento del cliente) */
  ahorro: number
  /** Si hay al menos un item con precio mayorista o promo */
  hayDescuento: boolean
  /**
   * Los mismos `itemsFinales` con el descuento del cliente ya aplicado. Es lo
   * que hay que persistir. Sin `contextoDescuento`, es igual a `itemsFinales`.
   */
  itemsConDescuentoCliente: ItemPedidoConPromo[]
  /** Total con las tres capas aplicadas. Es el total que se guarda. */
  totalConDescuentoCliente: number
  /** El descuento del cliente bajó al menos un precio */
  hayDescuentoCliente: boolean
  /** Promo/mayorista o descuento del cliente: alguno bajó un precio */
  hayDescuentoTotal: boolean
  /** % de descuento del cliente por productoId (para `construirOrigenPrecioItems`) */
  descuentoClientePct: Map<string, number>
  /** productoIds cuyo descuento salió de una regla por categoría, no del general */
  descuentoPorCategoria: Set<string>
  /** Loading */
  isLoading: boolean
  /** La consulta de promos falló (#1152: el alta con fecha atrasada lo avisa). */
  promosError: boolean
  /** Hay promoMap: cargado alguna vez para esta fecha de referencia. Sin señal
   *  y sin cache queda en false (la query queda pausada, no en loading). */
  promosCargadas: boolean
  /**
   * Mapa MOQ de los items QUE YA ESTÁN EN EL CARRITO (`construirMOQMap` itera
   * `items`). Para un producto del catálogo todavía no agregado da `undefined`;
   * para eso está `minimosProducto`.
   */
  moqMap: Map<string, number>
  /**
   * Mínimo de venta de TODOS los productos (mig 147). Es lo que hay que
   * consultar en el listado del catálogo, con `obtenerMOQ(id, minimosProducto)`:
   * usar `moqMap` ahí devolvía undefined y el producto entraba al carrito con
   * cantidad 1, en violación de su propio mínimo y con el confirmar bloqueado.
   */
  minimosProducto?: MinimosProducto
  /** Violaciones MOQ */
  violacionesMOQ: ViolacionMOQ[]
  /** Condiciones mayoristas (para quien arma los combos sobre otras líneas, como la edición). */
  pricingMap?: PricingMap
  /** Los combos que se pueden armar: los vigentes y, en la edición, la foto de los que el pedido ya tiene. */
  combos: ComboVigente[]
  /** Los combos que se armaron sobre `itemsConDescuentoCliente`. */
  combosAplicados: ComboAplicado[]
  /**
   * `itemsConDescuentoCliente` con cada producto partido en la parte que entra
   * en un combo y la que queda suelta. Es lo que hay que persistir.
   */
  lineasConCombos: LineaConCombo[]
  /** Total con las tres capas y los combos. Es el total que se guarda. */
  totalConCombos: number
  /** Cuánto bajaron los combos el total. */
  ahorroCombos: number
  /** Combos a los que les falta poco (#1194): qué agregar y cuánto ahorra. Vacío sin `opcionesCombos.sugerencias`. */
  sugerenciasCombos: SugerenciaCombo[]
  /**
   * FRV-1 (#1559): las consultas de las que depende el precio (promos, escalas, mínimos de
   * venta y combos), cada una con su estado. Quien confirma un pedido no lo hace con una
   * cargando o caída: la cuenta no falla, sale a precio de lista. Quien tiene otra consulta
   * propia (la foto de combos de la edición) la suma a esta lista.
   */
  entradasDatosPrecio: EntradaDatoDePrecio[]
  /** `entradasDatosPrecio` resumido: qué carga, qué falló y qué quedó sin pedir por falta de señal. */
  datosPrecio: DatosDePrecio
  /** Vuelve a pedir las que fallaron o quedaron sin pedir. */
  reintentarDatosPrecio: () => void
}

export function usePromocionPedido(
  items: ItemPedido[],
  fechaReferencia?: string,
  /** Override del regalo por promoId. El admin puede elegir otro producto
   *  para la bonificación al crear el pedido, o repartirla en varios sabores
   *  (paridad con "Cambiar regalo" de la edición). */
  overridesRegalo?: Record<string, RegaloOverride>,
  /** Ids de promos que el usuario quitó a mano (crear/editar). Se excluyen de la
   *  resolución: sin regalo y con los disparadores liberados para mayorista. */
  promosEliminadas?: ReadonlySet<string>,
  /** Cliente + catálogo para aplicar la tercera capa de precio. */
  contextoDescuento?: ContextoDescuentoCliente,
  /** Combos (#1191): habilitados, y en la edición el pedido y su foto. */
  opcionesCombos?: OpcionesCombos,
): UsePromocionPedidoReturn {
  const consultaPricing = usePricingMapQuery()
  const { data: pricingMap, isLoading: loadingPricing } = consultaPricing
  const consultaPromos = usePromoMapQuery(fechaReferencia, opcionesCombos?.promosDelPedido)
  const { data: promoMap, isLoading: loadingPromos, isError: errorPromos } = consultaPromos
  // Mínimo de venta propio del producto (mig 147), independiente de las
  // condiciones mayoristas.
  const consultaMinimos = useMinimosVentaQuery()
  const { data: minimosProducto } = consultaMinimos
  const combosHabilitados = opcionesCombos?.habilitados !== false
  const consultaCombos = useCombosVigentesQuery(
    fechaReferencia, opcionesCombos?.pedidoId, combosHabilitados)
  const { data: combosVigentes, isLoading: loadingCombos } = consultaCombos

  // Se desestructura para depender de los valores y no de la identidad del
  // objeto literal, que cambia en cada render del componente que llama.
  const cliente = contextoDescuento?.cliente ?? null
  const productos = contextoDescuento?.productos

  // Promo → mayorista → descuento del cliente, en una sola pasada y con la
  // misma función que usa el bot.
  const orquestacion = useMemo(
    () => orquestarPrecios({
      items,
      promoMap,
      pricingMap,
      productos,
      cliente,
      promosEliminadas,
      overridesRegalo,
    }),
    [items, promoMap, pricingMap, productos, cliente, promosEliminadas, overridesRegalo],
  )

  // Nudges de mayorista: sobre los items que la promo no reclamó, igual que la
  // resolución de precios.
  const faltantes = useMemo(() => {
    if (!pricingMap || pricingMap.size === 0 || items.length === 0) return []
    const itemsSinPromo = items.filter(
      i => !orquestacion.promoResolucion.productosConPromo.has(String(i.productoId))
    )
    return calcularFaltanteParaTier(itemsSinPromo, pricingMap)
  }, [items, pricingMap, orquestacion.promoResolucion.productosConPromo])

  const faltantesBonificacion = useMemo(() => {
    if (!promoMap || promoMap.size === 0 || items.length === 0) return []
    return calcularFaltanteParaBonificacion(items, promoMap)
  }, [items, promoMap])

  // MOQ — el mínimo de venta es del producto (mig 147/169), independiente
  // de que tenga o no una condición mayorista.
  const moqMap = useMemo(() => {
    if (items.length === 0) return new Map<string, number>()
    return construirMOQMap(items, minimosProducto)
  }, [items, minimosProducto])

  const violacionesMOQ = useMemo(() => {
    if (items.length === 0) return []
    return validarMOQPedido(items, minimosProducto)
  }, [items, minimosProducto])

  // Combos (#1191): una capa aparte, encima de la orquestación (que es la del
  // bot y no los arma). Parte cada producto en combo y suelta.
  const fotos = opcionesCombos?.fotos
  const combos = useMemo(
    () => (combosHabilitados ? combinarCombosConFotos(combosVigentes ?? [], fotos ?? []) : []),
    [combosHabilitados, combosVigentes, fotos],
  )
  const resultadoCombos = useMemo(
    () => aplicarCombosAlPedido({
      itemsBase: items,
      lineas: orquestacion.items,
      productosConPromo: orquestacion.promoResolucion.productosConPromo,
      pricingMap,
      productos,
      cliente,
      combos,
    }),
    [items, orquestacion, pricingMap, productos, cliente, combos],
  )

  // Sugerencia (#1194): "agregá X y te queda el combo Y". El ahorro sale de
  // cotizar el carrito con lo agregado con la MISMA cuenta de arriba
  // (orquestación + combos), así que es el que el pedido va a dar.
  const sugerencias = opcionesCombos?.sugerencias
  const sugerenciasCombos = useMemo<SugerenciaCombo[]>(() => {
    if (!sugerencias || combos.length === 0 || items.length === 0) return []
    const cotizar = (otros: ItemPedido[]) => {
      const o = orquestarPrecios({ items: otros, promoMap, pricingMap, productos, cliente, promosEliminadas, overridesRegalo })
      return aplicarCombosAlPedido({
        itemsBase: otros,
        lineas: o.items,
        productosConPromo: o.promoResolucion.productosConPromo,
        pricingMap,
        productos,
        cliente,
        combos,
      })
    }
    return sugerirCombos({
      items,
      combos,
      actual: resultadoCombos,
      cotizar,
      precioDe: sugerencias.precioDe,
      descartados: sugerencias.descartados,
      // Lo agregado no puede dejar el producto bajo su mínimo de venta: el
      // confirmar quedaría bloqueado por algo que sugirió la app.
      puedeAgregar: (pid, agregar, total) =>
        total >= obtenerMOQ(pid, minimosProducto) && sugerencias.puedeAgregar(pid, agregar, total),
    })
  }, [sugerencias, combos, items, resultadoCombos, promoMap, pricingMap, productos, cliente, promosEliminadas, overridesRegalo, minimosProducto])

  // FRV-1 (#1559): qué falta para preciar. Las promos siguen por defecto la regla de VTA-2: un
  // error las bloquea aunque haya un dato viejo (el alta lo cambia con `promosFallanConDato`).
  // Las otras bloquean sin dato: con uno de hace unos minutos la cuenta sigue siendo la de la
  // lista que vio el usuario.
  const entradasDatosPrecio: EntradaDatoDePrecio[] = [
    entradaDeConsulta('las promociones', consultaPromos, opcionesCombos?.promosFallanConDato !== false),
    entradaDeConsulta('las escalas mayoristas', consultaPricing),
    entradaDeConsulta('los mínimos de venta', consultaMinimos),
    ...(combosHabilitados ? [entradaDeConsulta('los combos', consultaCombos)] : []),
  ]
  const datosPrecio = resumirDatosDePrecio(entradasDatosPrecio)
  const reintentarDatosPrecio = () => {
    const pendientes: Array<[string, { refetch?: () => unknown }]> = [
      ['las promociones', consultaPromos],
      ['las escalas mayoristas', consultaPricing],
      ['los mínimos de venta', consultaMinimos],
      ['los combos', consultaCombos],
    ]
    for (const [nombre, q] of pendientes) {
      const e = entradasDatosPrecio.find(x => x.nombre === nombre)
      if (e && (e.fallo || (!e.hayDato && !e.cargando))) void q.refetch?.()
    }
  }

  return {
    preciosResueltos: orquestacion.preciosResueltos,
    faltantes,
    promoResolucion: orquestacion.promoResolucion,
    bonificacionesBase: orquestacion.bonificacionesBase,
    regalosInvalidos: orquestacion.regalosInvalidos,
    promoMap: promoMap ?? undefined,
    faltantesBonificacion,
    itemsFinales: orquestacion.itemsSinDescuentoCliente,
    totalFinal: orquestacion.totalSinDescuentoCliente,
    totalOriginal: orquestacion.totalOriginal,
    ahorro: orquestacion.totalOriginal - orquestacion.totalSinDescuentoCliente,
    hayDescuento: orquestacion.hayDescuentoPrecios,
    itemsConDescuentoCliente: orquestacion.items,
    totalConDescuentoCliente: orquestacion.total,
    hayDescuentoCliente: orquestacion.hayDescuentoCliente,
    hayDescuentoTotal: orquestacion.hayDescuentoPrecios || orquestacion.hayDescuentoCliente,
    descuentoClientePct: orquestacion.descuentoClientePct,
    descuentoPorCategoria: orquestacion.descuentoPorCategoria,
    isLoading: loadingPricing || loadingPromos || (combosHabilitados && loadingCombos),
    promosError: errorPromos === true,
    promosCargadas: promoMap !== undefined,
    moqMap,
    minimosProducto,
    violacionesMOQ,
    pricingMap: pricingMap ?? undefined,
    combos,
    combosAplicados: resultadoCombos.aplicados,
    lineasConCombos: resultadoCombos.lineas,
    totalConCombos: resultadoCombos.total,
    ahorroCombos: resultadoCombos.ahorro,
    sugerenciasCombos,
    entradasDatosPrecio,
    datosPrecio,
    reintentarDatosPrecio,
  }
}
