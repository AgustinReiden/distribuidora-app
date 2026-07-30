import { useState, useEffect, useMemo } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import type { LucideIcon } from 'lucide-react'
import { User, MapPin, Phone, CreditCard, ShoppingBag, TrendingUp, DollarSign, Clock, Package, ChevronDown, ChevronUp, FileText, Plus, AlertTriangle, CheckCircle, Tag, Building2, Percent, ArrowLeftRight, Trash2 } from 'lucide-react'
import ModalBase from './ModalBase'
import { useFichaCliente, usePagos } from '../../hooks/supabase'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useNotification } from '../../contexts/NotificationContext'
import { puedeVerSaldoCliente, puedeVerHistorialVentasCliente, puedeRegistrarPagoCliente, puedeAnularPago } from '../../lib/permisos'
import { formatPrecio as formatCurrency, formatFecha as formatDate, getEstadoColor, getEstadoPagoColor } from '../../utils/formatters'
import { logger } from '../../utils/logger'
import type { ClienteDB, PedidoDB, PagoDBWithUsuario, ResumenCuenta, EstadisticasCliente, PedidoClienteWithItems } from '../../types'

// =============================================================================
// TIPOS
// =============================================================================

/** Tipo de tab activa */
type ActiveTab = 'resumen' | 'pedidos' | 'pagos';

/** Props del componente principal */
export interface ModalFichaClienteProps {
  cliente: ClienteDB | null;
  onClose: () => void;
  onRegistrarPago?: (cliente: ClienteDB) => void;
  onVerPedido?: (pedido: PedidoDB) => void;
  /** Abre el modal de cambio/devolución como parada con el cliente fijo. */
  onCambioEnRuta?: (cliente: ClienteDB) => void;
}

/** Colores de tarjeta estadistica */
type StatCardColor = 'blue' | 'green' | 'purple' | 'red' | 'gray';

/** Props del componente StatCard */
interface StatCardProps {
  icon: LucideIcon;
  label: string;
  value: string | number;
  color: StatCardColor;
}

/** Tab de navegacion */
interface TabItem {
  id: ActiveTab;
  label: string;
  icon: LucideIcon;
}

export default function ModalFichaCliente({ cliente, onClose, onRegistrarPago, onVerPedido, onCambioEnRuta }: ModalFichaClienteProps) {
  const { pedidosCliente, estadisticas, loading } = useFichaCliente(cliente?.id)
  const { pagos, loading: loadingPagos, fetchPagosCliente, obtenerResumenCuenta, eliminarPago } = usePagos()
  const { perfil } = useAuthData()
  const notify = useNotification()
  const queryClient = useQueryClient()
  const rol = perfil?.rol
  const verSaldo = puedeVerSaldoCliente(rol)
  const verHistorialVentas = puedeVerHistorialVentasCliente(rol)
  const puedeRegistrarPago = puedeRegistrarPagoCliente(rol)
  const puedeAnular = puedeAnularPago(rol)
  const [resumenCuenta, setResumenCuenta] = useState<ResumenCuenta | null>(null)
  const [activeTab, setActiveTab] = useState<ActiveTab>('resumen')
  const [expandedPedido, setExpandedPedido] = useState<string | null>(null)
  // Anulacion de pagos (solo admin): confirmacion inline dentro del modal.
  const [anulandoId, setAnulandoId] = useState<string | null>(null)
  const [procesandoAnular, setProcesandoAnular] = useState<boolean>(false)


  useEffect(() => {
    if (cliente?.id) {
      fetchPagosCliente(cliente.id)
      obtenerResumenCuenta(cliente.id)
        .then((res: ResumenCuenta | null) => setResumenCuenta(res))
        .catch((err: Error) => {
          logger.error('Error al obtener resumen de cuenta:', err.message)
          setResumenCuenta(null)
        })
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cliente?.id])

  const saldoActual = useMemo((): number => {
    // Saldo = deuda real (resumenCuenta es la fuente de verdad). montoPendiente
    // ahora representa pedidos sin entregar, no deuda — no sirve como fallback.
    if (resumenCuenta?.saldo_actual !== undefined) return resumenCuenta.saldo_actual
    return 0
  }, [resumenCuenta])

  // Anular un pago (admin). El borrado dispara los triggers que revierten el
  // saldo del cliente (mig 086) y recalculan el pedido (mig 035). No lo bloquea
  // el guard de caja cerrada (ese solo aplica a INSERT/UPDATE, no a DELETE).
  const handleConfirmarAnular = async (pagoId: string | number): Promise<void> => {
    if (!cliente?.id) return
    setProcesandoAnular(true)
    try {
      await eliminarPago(String(pagoId))
      await fetchPagosCliente(cliente.id)
      const res = await obtenerResumenCuenta(cliente.id)
      setResumenCuenta(res)
      queryClient.invalidateQueries({ queryKey: ['clientes'] })
      notify.success('Pago anulado. Se ajustó el saldo del cliente.')
      setAnulandoId(null)
    } catch (err) {
      notify.error(err instanceof Error ? err.message : 'No se pudo anular el pago')
    } finally {
      setProcesandoAnular(false)
    }
  }

  const limiteCredito: number = cliente?.limite_credito || 0
  const creditoDisponible: number = limiteCredito - saldoActual
  const porcentajeUsado: number = limiteCredito > 0 ? (saldoActual / limiteCredito * 100) : 0
  const excedido: boolean = saldoActual > limiteCredito && limiteCredito > 0

  if (!cliente) return null

  return (
    <ModalBase title="Ficha Cliente" description={cliente.nombre_fantasia} onClose={onClose} maxWidth="max-w-4xl">
      <div className="flex flex-col">
        {/* Header */}
        <div className="px-5 pt-5 pb-5 border-b border-gray-200 dark:border-gray-700">
          <div className="flex items-start gap-4">
            <div className="w-16 h-16 bg-gradient-to-br from-blue-500 to-blue-600 rounded-xl flex items-center justify-center shrink-0">
              <User className="w-8 h-8 text-white" />
            </div>
            <div className="flex-1">
              <div className="flex items-center gap-3 flex-wrap">
                <h2 className="text-2xl font-bold text-gray-900 dark:text-white">{cliente.nombre_fantasia}</h2>
                {cliente.rubro && (
                  <span className="px-2 py-1 bg-purple-100 dark:bg-purple-900/30 text-purple-700 dark:text-purple-300 rounded-full text-xs font-medium flex items-center gap-1">
                    <Tag className="w-3 h-3" />
                    {cliente.rubro}
                  </span>
                )}
                {(cliente.descuento_porcentaje ?? 0) > 0 && (
                  <span className="px-2 py-1 bg-emerald-100 dark:bg-emerald-900/30 text-emerald-700 dark:text-emerald-300 rounded-full text-xs font-medium flex items-center gap-1" title="Descuento precargado por el administrador">
                    <Percent className="w-3 h-3" />
                    Dto. {cliente.descuento_porcentaje}%
                  </span>
                )}
              </div>
              <p className="text-gray-600 dark:text-gray-400 flex items-center gap-1">
                <Building2 className="w-4 h-4" />
                {cliente.razon_social}
              </p>
              {cliente.cuit && (
                <p className="text-sm text-gray-500 dark:text-gray-400 mt-1">
                  CUIT: <span className="font-mono">{cliente.cuit}</span>
                </p>
              )}
              <div className="flex items-center gap-4 mt-2 text-sm text-gray-500 dark:text-gray-400 flex-wrap">
                {cliente.direccion && (
                  <span className="flex items-center gap-1">
                    <MapPin className="w-4 h-4" />
                    {cliente.direccion}
                  </span>
                )}
                {cliente.telefono && (
                  <span className="flex items-center gap-1">
                    <Phone className="w-4 h-4" />
                    {cliente.telefono}
                    {cliente.contacto && (
                      <span className="text-gray-400">({cliente.contacto})</span>
                    )}
                  </span>
                )}
              </div>
              {cliente.horarios_atencion && (
                <div className="flex items-center gap-1 mt-2 text-sm text-gray-500 dark:text-gray-400">
                  <Clock className="w-4 h-4" />
                  <span>{cliente.horarios_atencion}</span>
                </div>
              )}
            </div>
          </div>

          {/* Account Balance Card */}
          {verSaldo && (
          <div className={`mt-4 p-4 rounded-xl ${excedido ? 'bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800' : 'bg-blue-50 dark:bg-blue-900/20'}`}>
            <div className="flex items-center justify-between">
              <div>
                <p className="text-sm text-gray-600 dark:text-gray-400">Saldo Cuenta Corriente</p>
                <p className={`text-3xl font-bold ${saldoActual > 0 ? 'text-red-600 dark:text-red-400' : 'text-green-600 dark:text-green-400'}`}>
                  {formatCurrency(Math.abs(saldoActual))}
                </p>
                {saldoActual > 0 && <p className="text-sm text-gray-500">Debe</p>}
                {saldoActual < 0 && <p className="text-sm text-green-600 dark:text-green-400 font-medium">A favor</p>}
                {saldoActual === 0 && <p className="text-sm text-gray-500">Sin deuda</p>}
              </div>
              <div className="text-right">
                <p className="text-sm text-gray-600 dark:text-gray-400">Límite de Crédito</p>
                <p className="text-xl font-semibold text-gray-900 dark:text-white">{formatCurrency(limiteCredito)}</p>
                {limiteCredito > 0 && (
                  <p className={`text-sm ${excedido ? 'text-red-600' : 'text-green-600'}`}>
                    Disponible: {formatCurrency(Math.max(0, creditoDisponible))}
                  </p>
                )}
              </div>
              {puedeRegistrarPago && (
                <button
                  onClick={() => onRegistrarPago?.(cliente)}
                  className="ml-4 px-4 py-2 bg-green-600 hover:bg-green-700 text-white rounded-lg flex items-center gap-2"
                  title={saldoActual > 0 ? 'Registrar pago del cliente' : 'Registrar pago anticipado / saldo a favor'}
                >
                  <Plus className="w-4 h-4" />
                  Registrar Pago
                </button>
              )}
              {onCambioEnRuta && (
                <button
                  onClick={() => onCambioEnRuta(cliente)}
                  className="ml-2 px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white rounded-lg flex items-center gap-2"
                  title="Agregar un cambio/devolución como parada del recorrido"
                >
                  <ArrowLeftRight className="w-4 h-4" />
                  Cambio/devolución
                </button>
              )}
            </div>
            {limiteCredito > 0 && (
              <div className="mt-3">
                <div className="h-2 bg-gray-200 dark:bg-gray-700 rounded-full overflow-hidden">
                  <div
                    className={`h-full transition-all ${porcentajeUsado > 100 ? 'bg-red-500' : porcentajeUsado > 80 ? 'bg-yellow-500' : 'bg-green-500'}`}
                    style={{ width: `${Math.min(100, porcentajeUsado)}%` }}
                  />
                </div>
                <p className="text-xs text-gray-500 mt-1">{Math.max(0, porcentajeUsado).toFixed(0)}% del crédito utilizado</p>
              </div>
            )}
            {excedido && (
              <div className="mt-2 flex items-center gap-2 text-red-600 dark:text-red-400">
                <AlertTriangle className="w-4 h-4" />
                <span className="text-sm font-medium">Cliente excedió el límite de crédito</span>
              </div>
            )}
          </div>
          )}
        </div>

        {/* Tabs (taco no ve la pestaña Pagos) */}
        <div className="flex border-b border-gray-200 dark:border-gray-700 px-5">
          {(([
            { id: 'resumen', label: 'Resumen', icon: TrendingUp },
            { id: 'pedidos', label: 'Pedidos', icon: ShoppingBag },
            ...(verSaldo ? [{ id: 'pagos' as ActiveTab, label: 'Pagos', icon: DollarSign }] : [])
          ]) as TabItem[]).map(tab => (
            <button
              key={tab.id}
              onClick={() => setActiveTab(tab.id)}
              className={`flex-1 px-4 py-3 flex items-center justify-center gap-2 font-medium transition-colors ${
                activeTab === tab.id
                  ? 'text-blue-600 border-b-2 border-blue-600 bg-blue-50/50 dark:bg-blue-900/20'
                  : 'text-gray-500 hover:text-gray-700 dark:hover:text-gray-300'
              }`}
            >
              <tab.icon className="w-4 h-4" />
              {tab.label}
            </button>
          ))}
        </div>

        {/* Content */}
        <div className="flex-1 overflow-y-auto px-5 py-5">
          {loading || loadingPagos ? (
            <div className="flex items-center justify-center h-48">
              <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-blue-600" />
            </div>
          ) : activeTab === 'resumen' ? (
            <div className="space-y-6">
              {/* Stats Grid */}
              <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
                <StatCard
                  icon={ShoppingBag}
                  label="Total Pedidos"
                  value={estadisticas?.totalPedidos || 0}
                  color="blue"
                />
                {verHistorialVentas && (
                  <>
                    <StatCard
                      icon={DollarSign}
                      label="Total Compras"
                      value={formatCurrency(estadisticas?.totalCompras || 0)}
                      color="green"
                    />
                    <StatCard
                      icon={TrendingUp}
                      label="Ticket Promedio"
                      value={formatCurrency(estadisticas?.ticketPromedio || 0)}
                      color="purple"
                    />
                  </>
                )}
                <StatCard
                  icon={Clock}
                  label="Días sin Comprar"
                  value={estadisticas?.diasDesdeUltimoPedido ?? 'N/A'}
                  color={(estadisticas?.diasDesdeUltimoPedido ?? 0) > 30 ? 'red' : 'gray'}
                />
              </div>

              {/* Payment Status (oculto para preventista_taco) */}
              {verSaldo && (
              <div className="grid grid-cols-2 gap-4">
                <div className="p-4 bg-green-50 dark:bg-green-900/20 rounded-xl">
                  <div className="flex items-center gap-2 text-green-600 dark:text-green-400 mb-2">
                    <CheckCircle className="w-5 h-5" />
                    <span className="font-medium">Pagado</span>
                  </div>
                  <p className="text-2xl font-bold text-green-700 dark:text-green-300">
                    {formatCurrency(estadisticas?.montoPagado || 0)}
                  </p>
                  <p className="text-sm text-green-600">{estadisticas?.pedidosPagados || 0} pedidos</p>
                </div>
                <div className="p-4 bg-yellow-50 dark:bg-yellow-900/20 rounded-xl">
                  <div className="flex items-center gap-2 text-yellow-600 dark:text-yellow-400 mb-2">
                    <Clock className="w-5 h-5" />
                    <span className="font-medium">Pendiente</span>
                  </div>
                  <p className="text-2xl font-bold text-yellow-700 dark:text-yellow-300">
                    {formatCurrency(estadisticas?.montoPendiente || 0)}
                  </p>
                  <p className="text-sm text-yellow-600">{estadisticas?.pedidosPendientes || 0} pedidos</p>
                </div>
              </div>
              )}

              {/* Favorite Products */}
              {(estadisticas?.productosFavoritos?.length ?? 0) > 0 && estadisticas && (
                <div>
                  <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-3 flex items-center gap-2">
                    <Package className="w-5 h-5" />
                    Productos Favoritos
                  </h3>
                  <div className="space-y-2">
                    {estadisticas.productosFavoritos?.map((prod, idx) => (
                      <div key={idx} className="flex items-center justify-between p-3 bg-gray-50 dark:bg-gray-700/50 rounded-lg">
                        <span className="font-medium text-gray-900 dark:text-white">{prod.nombre}</span>
                        <div className="text-right">
                          <span className="text-blue-600 dark:text-blue-400 font-semibold">{prod.cantidad} unidades</span>
                          <span className="text-gray-500 text-sm ml-2">({prod.veces} pedidos)</span>
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
              )}

              {/* Credit Info (oculto para preventista_taco) */}
              {verSaldo && (
              <div className="p-4 bg-gray-50 dark:bg-gray-700/50 rounded-xl">
                <h3 className="font-semibold text-gray-900 dark:text-white mb-2 flex items-center gap-2">
                  <CreditCard className="w-5 h-5" />
                  Información de Crédito
                </h3>
                <div className="grid grid-cols-2 gap-4 text-sm">
                  <div>
                    <span className="text-gray-500">Límite de Crédito:</span>
                    <span className="ml-2 font-medium">{formatCurrency(limiteCredito)}</span>
                  </div>
                  <div>
                    <span className="text-gray-500">Días de Crédito:</span>
                    <span className="ml-2 font-medium">{cliente.dias_credito || 30} días</span>
                  </div>
                  {(cliente.descuento_porcentaje ?? 0) > 0 && (
                    <div>
                      <span className="text-gray-500">Descuento:</span>
                      <span className="ml-2 font-medium text-emerald-600">{cliente.descuento_porcentaje}%</span>
                    </div>
                  )}
                  <div>
                    <span className="text-gray-500">Frecuencia de Compra:</span>
                    <span className="ml-2 font-medium">{(estadisticas?.frecuenciaCompra || 0).toFixed(1)} pedidos/mes</span>
                  </div>
                </div>
              </div>
              )}

              {/* Notas del cliente */}
              {cliente.notas && (
                <div className="p-4 bg-yellow-50 dark:bg-yellow-900/20 rounded-xl">
                  <h3 className="font-semibold text-gray-900 dark:text-white mb-2 flex items-center gap-2">
                    <FileText className="w-5 h-5 text-yellow-600" />
                    Notas
                  </h3>
                  <p className="text-sm text-gray-700 dark:text-gray-300 whitespace-pre-wrap">{cliente.notas}</p>
                </div>
              )}
            </div>
          ) : activeTab === 'pedidos' ? (
            <div className="space-y-3">
              {pedidosCliente.length === 0 ? (
                <div className="text-center py-12 text-gray-500">
                  <ShoppingBag className="w-12 h-12 mx-auto mb-3 opacity-50" />
                  <p>Este cliente no tiene pedidos</p>
                </div>
              ) : (
                pedidosCliente.map(pedido => (
                  <div key={pedido.id} className="border border-gray-200 dark:border-gray-700 rounded-xl overflow-hidden">
                    <div
                      className="p-4 flex items-center justify-between cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-700/50"
                      onClick={() => setExpandedPedido(expandedPedido === pedido.id ? null : pedido.id)}
                    >
                      <div className="flex items-center gap-4">
                        <div className="text-center">
                          <p className="text-xs text-gray-500">Pedido</p>
                          <p className="font-bold text-lg">#{pedido.id}</p>
                        </div>
                        <div>
                          <p className="text-sm text-gray-500">{formatDate(pedido.created_at)}</p>
                          <div className="flex gap-2 mt-1">
                            <span className={`px-2 py-0.5 rounded text-xs font-medium ${getEstadoColor(pedido.estado)}`}>
                              {pedido.estado}
                            </span>
                            <span className={`px-2 py-0.5 rounded text-xs font-medium ${getEstadoPagoColor(pedido.estado_pago)}`}>
                              {pedido.estado_pago}
                            </span>
                          </div>
                        </div>
                      </div>
                      <div className="flex items-center gap-4">
                        {verHistorialVentas && (
                          <p className="text-xl font-bold text-gray-900 dark:text-white">
                            {formatCurrency(pedido.total)}
                          </p>
                        )}
                        {expandedPedido === pedido.id ? <ChevronUp className="w-5 h-5" /> : <ChevronDown className="w-5 h-5" />}
                      </div>
                    </div>
                    {expandedPedido === pedido.id && (
                      <div className="px-4 pb-4 border-t border-gray-100 dark:border-gray-700">
                        <table className="w-full mt-3 text-sm">
                          <thead>
                            <tr className="text-gray-500 text-left">
                              <th className="pb-2">Producto</th>
                              <th className="pb-2 text-right">Cant.</th>
                              {verHistorialVentas && <th className="pb-2 text-right">Precio</th>}
                              {verHistorialVentas && <th className="pb-2 text-right">Subtotal</th>}
                            </tr>
                          </thead>
                          <tbody>
                            {pedido.items?.map(item => (
                              <tr key={item.id} className="border-t border-gray-100 dark:border-gray-700">
                                <td className="py-2">{item.producto?.nombre || 'Producto'}</td>
                                <td className="py-2 text-right">{item.cantidad}</td>
                                {verHistorialVentas && <td className="py-2 text-right">{formatCurrency(item.precio_unitario)}</td>}
                                {verHistorialVentas && <td className="py-2 text-right font-medium">{formatCurrency(item.subtotal)}</td>}
                              </tr>
                            ))}
                          </tbody>
                        </table>
                        {onVerPedido && (
                          <button
                            onClick={() => onVerPedido(pedido)}
                            className="mt-3 text-blue-600 hover:text-blue-700 text-sm flex items-center gap-1"
                          >
                            <FileText className="w-4 h-4" />
                            Ver detalle completo
                          </button>
                        )}
                      </div>
                    )}
                  </div>
                ))
              )}
            </div>
          ) : activeTab === 'pagos' ? (
            <div className="space-y-3">
              <div className="flex justify-between items-center mb-4">
                <h3 className="font-semibold text-gray-900 dark:text-white">Historial de Pagos</h3>
                {puedeRegistrarPago && (
                  <button
                    onClick={() => onRegistrarPago?.(cliente)}
                    className="px-3 py-1.5 bg-green-600 hover:bg-green-700 text-white rounded-lg text-sm flex items-center gap-1"
                  >
                    <Plus className="w-4 h-4" />
                    Nuevo Pago
                  </button>
                )}
              </div>
              {pagos.length === 0 ? (
                <div className="text-center py-12 text-gray-500">
                  <DollarSign className="w-12 h-12 mx-auto mb-3 opacity-50" />
                  <p>No hay pagos registrados</p>
                </div>
              ) : (
                pagos.map(pago => (
                  <div key={pago.id} className="p-4 bg-gray-50 dark:bg-gray-700/50 rounded-xl">
                    <div className="flex items-center justify-between">
                      <div>
                        <p className="font-semibold text-gray-900 dark:text-white">
                          {formatCurrency(pago.monto)}
                        </p>
                        <p className="text-sm text-gray-500">
                          {formatDate(pago.created_at)} • {pago.forma_pago}
                          {pago.referencia && ` • Ref: ${pago.referencia}`}
                        </p>
                        {pago.notas && <p className="text-sm text-gray-400 mt-1">{pago.notas}</p>}
                      </div>
                      <div className="flex items-start gap-3">
                        <div className="text-right text-sm text-gray-500">
                          {pago.usuario?.nombre || 'Sistema'}
                          {pago.pedido_id && <p>Pedido #{pago.pedido_id}</p>}
                        </div>
                        {puedeAnular && anulandoId !== String(pago.id) && (
                          <button
                            onClick={() => setAnulandoId(String(pago.id))}
                            className="p-1.5 text-gray-400 hover:text-red-600 hover:bg-red-50 dark:hover:bg-red-900/20 rounded-lg transition-colors"
                            title="Anular pago"
                          >
                            <Trash2 className="w-4 h-4" />
                          </button>
                        )}
                      </div>
                    </div>
                    {anulandoId === String(pago.id) && (
                      <div className="mt-3 p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
                        <p className="text-sm text-red-700 dark:text-red-300 mb-2 flex items-start gap-2">
                          <AlertTriangle className="w-4 h-4 mt-0.5 shrink-0" />
                          <span>
                            ¿Anular este pago de <strong>{formatCurrency(pago.monto)}</strong>?{' '}
                            {pago.pedido_id
                              ? 'Se revertirá la imputación al pedido y se ajustará el saldo del cliente.'
                              : 'Es un pago a cuenta / saldo a favor: se ajustará el saldo del cliente.'}
                          </span>
                        </p>
                        <div className="flex gap-2 justify-end">
                          <button
                            onClick={() => setAnulandoId(null)}
                            disabled={procesandoAnular}
                            className="px-3 py-1.5 text-sm rounded-lg border border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-700 disabled:opacity-50"
                          >
                            Cancelar
                          </button>
                          <button
                            onClick={() => { void handleConfirmarAnular(pago.id) }}
                            disabled={procesandoAnular}
                            className="px-3 py-1.5 text-sm rounded-lg bg-red-600 hover:bg-red-700 text-white disabled:opacity-50"
                          >
                            {procesandoAnular ? 'Anulando…' : 'Sí, anular'}
                          </button>
                        </div>
                      </div>
                    )}
                  </div>
                ))
              )}
            </div>
          ) : null}
        </div>
      </div>
    </ModalBase>
  )
}

function StatCard({ icon: Icon, label, value, color }: StatCardProps) {
  const colorClasses: Record<StatCardColor, string> = {
    blue: 'bg-blue-50 dark:bg-blue-900/20 text-blue-600 dark:text-blue-400',
    green: 'bg-green-50 dark:bg-green-900/20 text-green-600 dark:text-green-400',
    purple: 'bg-purple-50 dark:bg-purple-900/20 text-purple-600 dark:text-purple-400',
    red: 'bg-red-50 dark:bg-red-900/20 text-red-600 dark:text-red-400',
    gray: 'bg-gray-50 dark:bg-gray-700/50 text-gray-600 dark:text-gray-400'
  }

  return (
    <div className={`p-4 rounded-xl ${colorClasses[color] || colorClasses.gray}`}>
      <Icon className="w-5 h-5 mb-2" />
      <p className="text-xs opacity-75">{label}</p>
      <p className="text-xl font-bold">{value}</p>
    </div>
  )
}
