import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { useState, useEffect, useRef } from 'react'
import { supabase, notifyError } from './base'
import type {
  PedidoClienteWithItems,
  EstadisticasCliente,
  ProductoFavorito,
  UseFichaClienteReturn,
  PedidoDB,
  ProductoDB
} from '../../types'
import { traerTodo } from '../../utils/paginacion'
import { fechaLocalISO } from '../../utils/formatters'
import { calcularVentaCliente, calcularRitmoCompra, pedidosDelVendedor, separarPagosFicha, type PagoFichaCliente } from '../../utils/ventaCliente'
import {
  NOTAS_VENTA_METRICA_SELECT,
  RPC_NOTAS_DEL_VENDEDOR,
  notaDelVendedorComoMetrica,
  type NotaCreditoVentaMetricaRow,
  type NotaDelVendedorRow,
} from '../../utils/notasCreditoVentaMetrica'
import { PRODUCTO_COLUMNAS } from '../../lib/productoColumnas'
import { PEDIDO_ITEM_COLUMNAS } from '../../lib/pedidoItemColumnas'

interface PedidoWithItems {
  id: string;
  cliente_id: string;
  estado: string;
  estado_pago?: string;
  total: number;
  monto_pagado?: number;
  created_at?: string;
  items?: Array<{
    cantidad: number;
    producto?: ProductoDB | null;
  }>;
}

interface ProductosFrecuenciaMap {
  [key: string]: ProductoFavorito;
}

const SIN_PEDIDOS: PedidoClienteWithItems[] = []

/**
 * `vendedorId`: el del preventista que mira la ficha (como el filtro del Dashboard). Su «Total
 * comprado» cuenta sólo las boletas que él vendió (tanda 6 bis, H-4); admin y encargado, sin él.
 */
export function useFichaCliente(clienteId: string | null | undefined, vendedorId?: string | null): UseFichaClienteReturn {
  const [pedidosCliente, setPedidosCliente] = useState<PedidoClienteWithItems[]>([])
  const [estadisticas, setEstadisticas] = useState<EstadisticasCliente | null>(null)
  const [loading, setLoading] = useState<boolean>(false)
  // Cantidad real de pedidos del cliente (FRT-7). `pedidosCliente` trae sólo los últimos 50:
  // la ficha usa este total para avisar que la lista está cortada.
  const [pedidosTotales, setPedidosTotales] = useState<number>(0)
  // De qué cliente es lo que hay en el estado (1563-b5). Al pasar de A a B, lo de A no
  // se muestra mientras B carga, y una respuesta de A que llega tarde no pisa a B.
  const [datosDe, setDatosDe] = useState<string | null>(null)
  // De qué cliente es el último fetch que falló (FRT-3): sin esto la ficha quedaba con
  // `estadisticas = null` y `pedidosCliente = []`, y el modal lo pintaba como "0 pedidos · $0
  // comprado".
  const [errorDe, setErrorDe] = useState<string | null>(null)
  // Número de la última petición: sólo la vigente puede escribir el estado.
  const peticionRef = useRef(0)

  const fetchDatosCliente = async (): Promise<void> => {
    if (!clienteId) return
    const mia = ++peticionRef.current
    const vigente = (): boolean => mia === peticionRef.current
    const delCliente = String(clienteId)
    setLoading(true)
    setErrorDe(null)
    try {
      // Query ligera: todos los pedidos del cliente (sólo columnas necesarias para stats)
      // Paginado aunque hoy el cliente más activo tenga ~117 pedidos: a su ritmo
      // cruza las 1.000 en unos 3 años, y cuando lo haga esto se convierte en el
      // bug de #521 —`totalCompras` saldría de los 1.000 pedidos más recientes y
      // `montoPagado` de 1.000 pagos cualesquiera, o sea dos universos
      // distintos—. La correctitud de hoy es coincidencia de volumen, no diseño.
      const todosLiviano = await traerTodo<Pick<PedidoDB, 'id' | 'cliente_id' | 'total' | 'cargo_envio' | 'estado' | 'estado_pago' | 'created_at' | 'canal' | 'fecha' | 'tipo_factura' | 'usuario_id'>>(
        () => supabase
          .from('pedidos')
          .select('id, cliente_id, total, cargo_envio, estado, estado_pago, created_at, canal, fecha, tipo_factura, usuario_id')
          .eq('cliente_id', clienteId)
          .order('created_at', { ascending: false })
          .order('id'),
        { etiqueta: 'pedidos del cliente' },
      )
      if (!vigente()) return

      // Notas de crédito de venta vigentes del cliente: el «Total comprado» es neto de ellas
      // (REP-1, tanda 6). La RLS las deja ver a admin y encargado; para un preventista vuelve
      // vacía, sin error.
      const notasRest = await traerTodo<NotaCreditoVentaMetricaRow>(
        // El tipo inferido del embed es un arreglo; PostgREST devuelve la boleta como objeto (FK a uno).
        () => supabase
          .from('notas_credito_venta')
          .select(NOTAS_VENTA_METRICA_SELECT)
          .eq('cliente_id', clienteId)
          .eq('anulada', false)
          .order('id') as never,
        { etiqueta: 'notas de crédito del cliente' },
      )
      if (!vigente()) return
      // El «Total comprado» del preventista (tanda 6 bis; decisión del dueño del 24/11) es lo que
      // ÉL le vendió al cliente (abajo, `vendedorId`), neto de las notas de esas boletas: se las da
      // la RPC (fecha, cliente y total). A admin y encargado no les da nada (las leyeron arriba):
      // las dos fuentes se suman sin repetir.
      const notasPropias = await traerTodo<NotaDelVendedorRow>(
        () => supabase.rpc(RPC_NOTAS_DEL_VENDEDOR, { p_desde: null, p_hasta: null, p_cliente_id: clienteId }),
        { etiqueta: 'notas de crédito del vendedor' },
      )
      if (!vigente()) return
      const notasCliente = [...notasRest, ...notasPropias.map(n => notaDelVendedorComoMetrica(n, null))]

      // Query pesada: últimos 50 pedidos con items (para UI + productos favoritos)
      const { data: pedidos, error: errorPedidos } = await supabase
        .from('pedidos')
        .select(`*, items:pedido_items(${PEDIDO_ITEM_COLUMNAS}, producto:productos(${PRODUCTO_COLUMNAS}))`)
        .eq('cliente_id', clienteId)
        .order('created_at', { ascending: false })
        .limit(50)
      if (errorPedidos) throw errorDeSupabase(errorPedidos, 'Sin conexión: no se pudo cargar los pedidos del cliente. Revisá la señal e intentá de nuevo.')

      if (!vigente()) return
      const pedidosTyped = (pedidos || []) as PedidoWithItems[]
      setPedidosCliente(pedidosTyped as unknown as PedidoClienteWithItems[])

      const pedidosLivianos = (todosLiviano || []) as Array<Pick<PedidoDB, 'id' | 'cliente_id' | 'total' | 'cargo_envio' | 'estado' | 'estado_pago' | 'created_at' | 'canal' | 'fecha' | 'tipo_factura' | 'usuario_id'>>
      // Sin filtrar nada (canjes y vales blancos incluidos): es lo que la query pesada
      // recorta con `.limit(50)`, así que el aviso de "lista cortada" dice la verdad.
      setPedidosTotales(pedidosLivianos.length)
      // Todas las cifras de compra salen de `calcularVentaCliente` / `calcularRitmoCompra`
      // (utils/ventaCliente): la venta es entregado, sin canje, sin vale blanco (VB,
      // consumo interno, va aparte). Lo tomado y no entregado va como "pendiente de
      // entrega", igual que el "en curso" del Dashboard. La deuda se ve en "Saldo".
      // El preventista: sólo las boletas que él vendió (la RLS le muestra también las que reparte
      // con el extra de chofer, y sus notas no le llegan: ese pedazo quedaba bruto; H-4, tanda 6 bis).
      const venta = calcularVentaCliente(pedidosDelVendedor(pedidosLivianos, vendedorId), notasCliente)
      const totalCompras = venta.totalComprado

      // Fetch pagos from the pagos table (source of truth for payments)
      const pagosCliente = await traerTodo<PagoFichaCliente>(
        () => supabase
          .from('pagos')
          .select('monto, forma_pago, de_saldo_a_favor, pedido_id')
          .eq('cliente_id', clienteId)
          .order('id'),
        { etiqueta: 'pagos del cliente' },
      )
      if (!vigente()) return
      // «Pagado» es sólo la plata cobrada (frv-B3, tanda 6): la nota de crédito y el adelanto de
      // sueldo no son plata y van aparte; lo cobrado que después se aplicó desde saldo a favor cuenta.
      const pagosFicha = separarPagosFicha(pagosCliente)
      const totalPagosRegistrados = pagosFicha.cobrado

      // Productos favoritos se calculan sobre los últimos 50 pedidos (limitación aceptada)
      const productosFrecuencia: ProductosFrecuenciaMap = {}
      pedidosTyped.forEach(p => {
        p.items?.forEach(item => {
          const nombre = item.producto?.nombre || 'Desconocido'
          if (!productosFrecuencia[nombre]) productosFrecuencia[nombre] = { nombre, cantidad: 0, veces: 0 }
          productosFrecuencia[nombre].cantidad += item.cantidad
          productosFrecuencia[nombre].veces += 1
        })
      })
      const productosFavoritos: ProductoFavorito[] = Object.values(productosFrecuencia)
        .sort((a, b) => b.cantidad - a.cantidad)
        .slice(0, 5)

      const ticketPromedio = venta.cantidadCompras > 0 ? totalCompras / venta.cantidadCompras : 0

      // Días sin comprar y frecuencia: sólo ventas, por `pedidos.fecha` (día argentino).
      const { diasDesdeUltimaCompra, frecuenciaCompra } = calcularRitmoCompra(pedidosLivianos, fechaLocalISO())

      setEstadisticas({
        totalPedidos: venta.cantidadCompras,
        totalCompras,
        pedidosPagados: venta.pedidosPagados,
        montoPagado: totalPagosRegistrados,
        notaCreditoAplicada: pagosFicha.notaCreditoAplicada,
        adelantoSueldo: pagosFicha.adelantoSueldo,
        saldoAFavorAplicado: pagosFicha.saldoAFavorAplicado,
        pedidosPendientes: venta.pedidosPendientesEntrega,
        montoPendiente: venta.pendienteEntrega,
        ticketPromedio,
        frecuenciaCompra,
        diasDesdeUltimoPedido: diasDesdeUltimaCompra,
        productosFavoritos,
        consumoInterno: venta.consumoInterno
      })
      setDatosDe(delCliente)
    } catch (e) {
      if (!vigente()) return
      setErrorDe(delCliente)
      notifyError('Error al cargar datos del cliente: ' + (e as Error).message)
    } finally {
      if (vigente()) setLoading(false)
    }
  }

  useEffect(() => {
    if (clienteId) fetchDatosCliente()
    // Al cambiar de cliente o desmontar, lo que está en vuelo queda viejo.
    // eslint-disable-next-line react-hooks/exhaustive-deps -- es un contador, no un nodo del DOM
    return () => { peticionRef.current++ }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [clienteId, vendedorId])

  // Sólo se devuelve lo que es del cliente de ahora.
  const esDelCliente = Boolean(clienteId) && datosDe === String(clienteId)
  const error = Boolean(clienteId) && errorDe === String(clienteId)

  // Con cliente y sin nada resuelto todavía (ni datos ni error) ya está cargando: en el
  // primer render, antes de que el efecto prenda `loading`, la ficha se veía con ceros.
  const estadisticasVigentes = esDelCliente ? estadisticas : null
  const cargando = Boolean(clienteId) && (loading || (estadisticasVigentes === null && !error))

  return {
    pedidosCliente: esDelCliente ? pedidosCliente : SIN_PEDIDOS,
    estadisticas: estadisticasVigentes,
    loading: cargando,
    error,
    pedidosTotales: esDelCliente ? pedidosTotales : 0,
    refetch: fetchDatosCliente,
  }
}
