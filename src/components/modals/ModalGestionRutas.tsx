import React, { useState, useMemo, memo, useEffect } from 'react';
import {
  Loader2, AlertTriangle, Check, Truck, MapPin, Route, Clock, Navigation,
  Settings, Save, FileText, Download, ChevronDown, ChevronUp, Phone,
  DollarSign, Package, CheckCircle, Circle, Printer, ArrowRight
} from 'lucide-react';
import ModalBase from './ModalBase';
import { getDepositoCoords, setDepositoCoords } from '../../hooks/useOptimizarRuta';

// Componente para mostrar cada pedido en la lista de ruta
const PedidoRutaCard = memo(function PedidoRutaCard({ pedido, orden, isFirst, isLast }) {
  const estadoPagoColors = {
    pagado: 'bg-green-100 text-green-700 border-green-200',
    parcial: 'bg-yellow-100 text-yellow-700 border-yellow-200',
    pendiente: 'bg-red-100 text-red-700 border-red-200'
  };

  const formaPagoLabels = {
    efectivo: 'Efectivo',
    transferencia: 'Transferencia',
    cheque: 'Cheque',
    cuenta_corriente: 'Cta. Corriente',
    tarjeta: 'Tarjeta'
  };

  return (
    <div className="relative">
      {/* Linea de conexion */}
      {!isLast && (
        <div className="absolute left-6 top-16 bottom-0 w-0.5 bg-blue-200" style={{ height: 'calc(100% - 3rem)' }} />
      )}

      <div className="flex gap-4 p-4 bg-white rounded-xl border border-gray-200 shadow-sm hover:shadow-md transition-shadow">
        {/* Numero de orden */}
        <div className="flex flex-col items-center">
          <div className={`w-12 h-12 rounded-full flex items-center justify-center text-white font-bold text-lg ${isFirst ? 'bg-green-500' : isLast ? 'bg-red-500' : 'bg-blue-500'}`}>
            {orden}
          </div>
          {!isLast && <ArrowRight className="w-4 h-4 text-blue-300 mt-2 rotate-90" />}
        </div>

        {/* Info del pedido */}
        <div className="flex-1 min-w-0">
          <div className="flex items-start justify-between gap-2 mb-2">
            <div>
              <h4 className="font-semibold text-gray-900 truncate">
                {pedido.cliente?.nombre_fantasia || 'Cliente'}
              </h4>
              <p className="text-sm text-gray-500">Pedido #{pedido.id}</p>
            </div>
            <span className={`px-2 py-1 text-xs font-medium rounded-full border ${estadoPagoColors[pedido.estado_pago] || estadoPagoColors.pendiente}`}>
              {pedido.estado_pago === 'pagado' ? 'Pagado' : pedido.estado_pago === 'parcial' ? 'Parcial' : 'Pendiente'}
            </span>
          </div>

          <div className="space-y-1.5 text-sm">
            <div className="flex items-center gap-2 text-gray-600">
              <MapPin className="w-4 h-4 text-gray-400 flex-shrink-0" />
              <span className="truncate">{pedido.cliente?.direccion || 'Sin direccion'}</span>
            </div>

            {pedido.cliente?.telefono && (
              <div className="flex items-center gap-2 text-gray-600">
                <Phone className="w-4 h-4 text-gray-400 flex-shrink-0" />
                <span>{pedido.cliente.telefono}</span>
              </div>
            )}

            <div className="flex items-center gap-4">
              <div className="flex items-center gap-2 text-gray-600">
                <DollarSign className="w-4 h-4 text-gray-400" />
                <span className="font-medium">${pedido.total?.toLocaleString('es-AR')}</span>
              </div>
              <div className="flex items-center gap-2 text-gray-500">
                <Package className="w-4 h-4 text-gray-400" />
                <span>{pedido.items?.length || 0} items</span>
              </div>
            </div>

            <div className="text-xs text-gray-500">
              {formaPagoLabels[pedido.forma_pago] || 'Efectivo'}
            </div>
          </div>

          {pedido.notas && (
            <div className="mt-2 p-2 bg-yellow-50 rounded-lg border border-yellow-100">
              <p className="text-xs text-yellow-700 italic">"{pedido.notas}"</p>
            </div>
          )}
        </div>
      </div>
    </div>
  );
});

// Componente principal del modal
const ModalGestionRutas = memo(function ModalGestionRutas({
  transportistas,
  pedidos,
  onOptimizar,
  onAplicarOrden,
  onExportarPDF,
  onClose,
  loading,
  guardando,
  rutaOptimizada,
  error
}) {
  const [transportistaSeleccionado, setTransportistaSeleccionado] = useState('');
  const [mostrarConfigDeposito, setMostrarConfigDeposito] = useState(false);
  const [depositoLat, setDepositoLat] = useState('');
  const [depositoLng, setDepositoLng] = useState('');
  const [depositoGuardado, setDepositoGuardado] = useState(false);
  const [vistaActiva, setVistaActiva] = useState('optimizar'); // 'optimizar' | 'resultado'

  // Cargar coordenadas del deposito al montar
  useEffect(() => {
    const coords = getDepositoCoords();
    setDepositoLat(coords.lat.toString());
    setDepositoLng(coords.lng.toString());
  }, []);

  // Cambiar a vista resultado cuando hay ruta optimizada
  useEffect(() => {
    if (rutaOptimizada?.orden_optimizado?.length > 0) {
      setVistaActiva('resultado');
    }
  }, [rutaOptimizada]);

  // Obtener pedidos del transportista seleccionado
  const pedidosTransportista = useMemo(() => {
    if (!transportistaSeleccionado) return [];
    return pedidos
      .filter(p => p.transportista_id === transportistaSeleccionado && p.estado === 'asignado')
      .sort((a, b) => (a.orden_entrega || 999) - (b.orden_entrega || 999));
  }, [pedidos, transportistaSeleccionado]);

  // Pedidos ordenados segun la optimizacion
  const pedidosOrdenados = useMemo(() => {
    if (!rutaOptimizada?.orden_optimizado) return [];
    return rutaOptimizada.orden_optimizado.map(item => {
      const pedido = pedidos.find(p => p.id === item.pedido_id);
      return { ...pedido, orden_optimizado: item.orden };
    }).filter(Boolean);
  }, [rutaOptimizada, pedidos]);

  // Verificar si hay pedidos sin coordenadas
  const pedidosSinCoordenadas = useMemo(() => {
    return pedidosTransportista.filter(p => !p.cliente?.latitud || !p.cliente?.longitud);
  }, [pedidosTransportista]);

  // Calcular totales
  const totales = useMemo(() => {
    const lista = vistaActiva === 'resultado' ? pedidosOrdenados : pedidosTransportista;
    return {
      pedidos: lista.length,
      total: lista.reduce((sum, p) => sum + (p.total || 0), 0),
      pendienteCobro: lista.filter(p => p.estado_pago !== 'pagado').reduce((sum, p) => sum + (p.total || 0), 0),
      items: lista.reduce((sum, p) => sum + (p.items?.length || 0), 0)
    };
  }, [vistaActiva, pedidosOrdenados, pedidosTransportista]);

  const handleOptimizar = () => {
    if (transportistaSeleccionado) {
      onOptimizar(transportistaSeleccionado, pedidos);
    }
  };

  const handleGuardarDeposito = () => {
    const lat = parseFloat(depositoLat);
    const lng = parseFloat(depositoLng);
    if (!isNaN(lat) && !isNaN(lng)) {
      setDepositoCoords(lat, lng);
      setDepositoGuardado(true);
      setTimeout(() => setDepositoGuardado(false), 2000);
    }
  };

  const handleAplicar = () => {
    if (rutaOptimizada?.orden_optimizado) {
      onAplicarOrden({
        ordenOptimizado: rutaOptimizada.orden_optimizado,
        transportistaId: transportistaSeleccionado,
        distancia: rutaOptimizada.distancia_total || null,
        duracion: rutaOptimizada.duracion_total || null
      });
    }
  };

  const handleExportarPDF = () => {
    const transportista = transportistas.find(t => t.id === transportistaSeleccionado);
    onExportarPDF(transportista, pedidosOrdenados);
  };

  const handleVolverOptimizar = () => {
    setVistaActiva('optimizar');
  };

  const transportistaInfo = transportistas.find(t => t.id === transportistaSeleccionado);

  return (
    <ModalBase title="Gestion de Rutas de Entrega" onClose={onClose} maxWidth="max-w-4xl">
      <div className="flex flex-col h-[75vh]">
        {/* Tabs de navegacion */}
        <div className="flex border-b bg-gray-50 px-4">
          <button
            onClick={handleVolverOptimizar}
            className={`px-4 py-3 text-sm font-medium border-b-2 transition-colors ${
              vistaActiva === 'optimizar'
                ? 'border-blue-500 text-blue-600'
                : 'border-transparent text-gray-500 hover:text-gray-700'
            }`}
          >
            <Route className="w-4 h-4 inline mr-2" />
            Optimizar Ruta
          </button>
          <button
            onClick={() => rutaOptimizada?.orden_optimizado && setVistaActiva('resultado')}
            disabled={!rutaOptimizada?.orden_optimizado}
            className={`px-4 py-3 text-sm font-medium border-b-2 transition-colors ${
              vistaActiva === 'resultado'
                ? 'border-green-500 text-green-600'
                : 'border-transparent text-gray-500 hover:text-gray-700 disabled:opacity-50'
            }`}
          >
            <CheckCircle className="w-4 h-4 inline mr-2" />
            Ruta Optimizada
            {rutaOptimizada?.orden_optimizado && (
              <span className="ml-2 px-2 py-0.5 bg-green-100 text-green-700 text-xs rounded-full">
                {rutaOptimizada.orden_optimizado.length}
              </span>
            )}
          </button>
        </div>

        {/* Contenido principal */}
        <div className="flex-1 overflow-y-auto p-4">
          {vistaActiva === 'optimizar' ? (
            <div className="space-y-4">
              {/* Configuracion del deposito (colapsable) */}
              <div className="border rounded-lg bg-white">
                <button
                  onClick={() => setMostrarConfigDeposito(!mostrarConfigDeposito)}
                  className="w-full flex items-center justify-between p-3 hover:bg-gray-50 rounded-lg"
                >
                  <div className="flex items-center space-x-2">
                    <Settings className="w-5 h-5 text-gray-500" />
                    <span className="font-medium">Configurar ubicacion del deposito</span>
                  </div>
                  {mostrarConfigDeposito ? <ChevronUp className="w-5 h-5 text-gray-400" /> : <ChevronDown className="w-5 h-5 text-gray-400" />}
                </button>
                {mostrarConfigDeposito && (
                  <div className="p-4 border-t bg-gray-50 space-y-3">
                    <p className="text-sm text-gray-600">
                      Ingresa las coordenadas de tu deposito. Este sera el punto de origen y destino de la ruta.
                    </p>
                    <div className="grid grid-cols-2 gap-3">
                      <div>
                        <label className="block text-xs font-medium mb-1">Latitud</label>
                        <input
                          type="number"
                          step="0.000001"
                          value={depositoLat}
                          onChange={e => setDepositoLat(e.target.value)}
                          className="w-full px-3 py-2 border rounded-lg text-sm"
                          placeholder="-26.8241"
                        />
                      </div>
                      <div>
                        <label className="block text-xs font-medium mb-1">Longitud</label>
                        <input
                          type="number"
                          step="0.000001"
                          value={depositoLng}
                          onChange={e => setDepositoLng(e.target.value)}
                          className="w-full px-3 py-2 border rounded-lg text-sm"
                          placeholder="-65.2226"
                        />
                      </div>
                    </div>
                    <div className="flex items-center justify-between">
                      <p className="text-xs text-gray-500">
                        Tip: Busca tu direccion en Google Maps, click derecho y copia las coordenadas
                      </p>
                      <button
                        onClick={handleGuardarDeposito}
                        className="flex items-center space-x-2 px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 text-sm"
                      >
                        {depositoGuardado ? <Check className="w-4 h-4" /> : <Save className="w-4 h-4" />}
                        <span>{depositoGuardado ? 'Guardado!' : 'Guardar'}</span>
                      </button>
                    </div>
                  </div>
                )}
              </div>

              {/* Selector de transportista */}
              <div className="bg-white border rounded-lg p-4">
                <label className="block text-sm font-medium mb-2">Seleccionar Transportista</label>
                <select
                  value={transportistaSeleccionado}
                  onChange={e => setTransportistaSeleccionado(e.target.value)}
                  className="w-full px-3 py-2 border rounded-lg"
                  disabled={loading}
                >
                  <option value="">Seleccionar transportista...</option>
                  {transportistas.map(t => {
                    const cantPedidos = pedidos.filter(p =>
                      p.transportista_id === t.id && p.estado === 'asignado'
                    ).length;
                    return (
                      <option key={t.id} value={t.id}>
                        {t.nombre} ({cantPedidos} pedidos asignados)
                      </option>
                    );
                  })}
                </select>
              </div>

              {/* Info del transportista */}
              {transportistaSeleccionado && (
                <>
                  <div className="bg-gradient-to-r from-blue-500 to-blue-600 rounded-xl p-4 text-white">
                    <div className="flex items-center justify-between">
                      <div className="flex items-center space-x-3">
                        <div className="w-12 h-12 bg-white/20 rounded-full flex items-center justify-center">
                          <Truck className="w-6 h-6" />
                        </div>
                        <div>
                          <h3 className="font-semibold text-lg">{transportistaInfo?.nombre}</h3>
                          <p className="text-blue-100 text-sm">{pedidosTransportista.length} entregas asignadas</p>
                        </div>
                      </div>
                      <div className="text-right">
                        <p className="text-2xl font-bold">${totales.total.toLocaleString('es-AR')}</p>
                        <p className="text-blue-100 text-sm">Total a cobrar</p>
                      </div>
                    </div>
                  </div>

                  {/* Advertencia de pedidos sin coordenadas */}
                  {pedidosSinCoordenadas.length > 0 && (
                    <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-4">
                      <div className="flex items-start space-x-3">
                        <AlertTriangle className="w-5 h-5 text-yellow-600 mt-0.5" />
                        <div>
                          <p className="font-medium text-yellow-800">Pedidos sin coordenadas</p>
                          <p className="text-sm text-yellow-700 mt-1">
                            Los siguientes clientes no tienen coordenadas y no seran incluidos en la optimizacion:
                          </p>
                          <ul className="text-sm text-yellow-700 mt-2 space-y-1">
                            {pedidosSinCoordenadas.map(p => (
                              <li key={p.id} className="flex items-center gap-2">
                                <Circle className="w-2 h-2" />
                                #{p.id} - {p.cliente?.nombre_fantasia}
                              </li>
                            ))}
                          </ul>
                        </div>
                      </div>
                    </div>
                  )}

                  {/* Lista de pedidos actuales */}
                  {pedidosTransportista.length > 0 && (
                    <div className="bg-white border rounded-lg">
                      <div className="p-3 border-b bg-gray-50">
                        <h3 className="font-medium text-gray-700">Pedidos asignados (orden actual)</h3>
                      </div>
                      <div className="max-h-60 overflow-y-auto divide-y">
                        {pedidosTransportista.map((pedido) => (
                          <div key={pedido.id} className="flex items-center p-3 hover:bg-gray-50">
                            <div className="flex items-center justify-center w-8 h-8 rounded-full bg-gray-100 mr-3">
                              {pedido.orden_entrega ? (
                                <span className="text-sm font-bold text-blue-600">{pedido.orden_entrega}</span>
                              ) : (
                                <span className="text-xs text-gray-400">-</span>
                              )}
                            </div>
                            <div className="flex-1 min-w-0">
                              <p className="font-medium text-gray-900 truncate">
                                #{pedido.id} - {pedido.cliente?.nombre_fantasia}
                              </p>
                              <p className="text-sm text-gray-500 truncate">{pedido.cliente?.direccion}</p>
                            </div>
                            <div className="text-right ml-2">
                              <p className="font-medium text-gray-900">${pedido.total?.toLocaleString('es-AR')}</p>
                              {pedido.cliente?.latitud && pedido.cliente?.longitud ? (
                                <MapPin className="w-4 h-4 text-green-500 inline" />
                              ) : (
                                <MapPin className="w-4 h-4 text-gray-300 inline" />
                              )}
                            </div>
                          </div>
                        ))}
                      </div>
                    </div>
                  )}
                </>
              )}

              {/* Error */}
              {error && (
                <div className="bg-red-50 border border-red-200 rounded-lg p-4">
                  <div className="flex items-center space-x-2">
                    <AlertTriangle className="w-5 h-5 text-red-600" />
                    <p className="text-red-700">{error}</p>
                  </div>
                </div>
              )}
            </div>
          ) : (
            /* Vista de resultado */
            <div className="space-y-4">
              {/* Header con info de la ruta */}
              <div className="bg-gradient-to-r from-green-500 to-green-600 rounded-xl p-4 text-white">
                <div className="flex items-center justify-between mb-3">
                  <div className="flex items-center space-x-3">
                    <div className="w-12 h-12 bg-white/20 rounded-full flex items-center justify-center">
                      <Route className="w-6 h-6" />
                    </div>
                    <div>
                      <h3 className="font-semibold text-lg">Ruta Optimizada</h3>
                      <p className="text-green-100 text-sm">{transportistaInfo?.nombre}</p>
                    </div>
                  </div>
                </div>
                <div className="grid grid-cols-4 gap-4 mt-4">
                  <div className="bg-white/10 rounded-lg p-3 text-center">
                    <Clock className="w-5 h-5 mx-auto mb-1" />
                    <p className="text-xl font-bold">{rutaOptimizada?.duracion_formato || 'N/A'}</p>
                    <p className="text-xs text-green-100">Duracion</p>
                  </div>
                  <div className="bg-white/10 rounded-lg p-3 text-center">
                    <Navigation className="w-5 h-5 mx-auto mb-1" />
                    <p className="text-xl font-bold">{rutaOptimizada?.distancia_formato || 'N/A'}</p>
                    <p className="text-xs text-green-100">Distancia</p>
                  </div>
                  <div className="bg-white/10 rounded-lg p-3 text-center">
                    <Package className="w-5 h-5 mx-auto mb-1" />
                    <p className="text-xl font-bold">{pedidosOrdenados.length}</p>
                    <p className="text-xs text-green-100">Entregas</p>
                  </div>
                  <div className="bg-white/10 rounded-lg p-3 text-center">
                    <DollarSign className="w-5 h-5 mx-auto mb-1" />
                    <p className="text-xl font-bold">${totales.total.toLocaleString('es-AR')}</p>
                    <p className="text-xs text-green-100">Total</p>
                  </div>
                </div>
              </div>

              {/* Resumen de cobros */}
              <div className="bg-white border rounded-lg p-4">
                <div className="flex items-center justify-between">
                  <div>
                    <p className="text-sm text-gray-500">Pendiente de cobro</p>
                    <p className="text-xl font-bold text-red-600">${totales.pendienteCobro.toLocaleString('es-AR')}</p>
                  </div>
                  <div className="text-right">
                    <p className="text-sm text-gray-500">Ya cobrado</p>
                    <p className="text-xl font-bold text-green-600">${(totales.total - totales.pendienteCobro).toLocaleString('es-AR')}</p>
                  </div>
                </div>
              </div>

              {/* Lista de entregas ordenadas */}
              <div>
                <h3 className="font-medium text-gray-700 mb-3 flex items-center gap-2">
                  <FileText className="w-5 h-5" />
                  Orden de Entregas
                </h3>
                <div className="space-y-3">
                  {pedidosOrdenados.map((pedido, index) => (
                    <PedidoRutaCard
                      key={pedido.id}
                      pedido={pedido}
                      orden={index + 1}
                      isFirst={index === 0}
                      isLast={index === pedidosOrdenados.length - 1}
                    />
                  ))}
                </div>
              </div>
            </div>
          )}
        </div>

        {/* Footer con acciones */}
        <div className="flex justify-between items-center p-4 border-t bg-gray-50">
          <button
            onClick={onClose}
            className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg transition-colors"
          >
            Cerrar
          </button>

          <div className="flex space-x-3">
            {vistaActiva === 'optimizar' ? (
              <button
                onClick={handleOptimizar}
                disabled={!transportistaSeleccionado || loading || pedidosTransportista.length === 0}
                className="flex items-center space-x-2 px-5 py-2.5 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
              >
                {loading ? (
                  <Loader2 className="w-5 h-5 animate-spin" />
                ) : (
                  <Route className="w-5 h-5" />
                )}
                <span>{loading ? 'Calculando ruta...' : 'Optimizar Ruta'}</span>
              </button>
            ) : (
              <>
                <button
                  onClick={handleExportarPDF}
                  disabled={guardando}
                  className="flex items-center space-x-2 px-4 py-2.5 bg-gray-600 text-white rounded-lg hover:bg-gray-700 disabled:opacity-50 transition-colors"
                >
                  <Printer className="w-5 h-5" />
                  <span>Exportar PDF</span>
                </button>
                <button
                  onClick={handleAplicar}
                  disabled={guardando}
                  className="flex items-center space-x-2 px-5 py-2.5 bg-green-600 text-white rounded-lg hover:bg-green-700 disabled:opacity-50 transition-colors"
                >
                  {guardando ? (
                    <Loader2 className="w-5 h-5 animate-spin" />
                  ) : (
                    <Check className="w-5 h-5" />
                  )}
                  <span>{guardando ? 'Guardando...' : 'Aplicar Orden'}</span>
                </button>
              </>
            )}
          </div>
        </div>
      </div>
    </ModalBase>
  );
});

export default ModalGestionRutas;
