import React, { useState, useMemo, memo, useEffect } from 'react';
import type { ChangeEvent } from 'react';
import { Loader2, AlertTriangle, Check, Truck, MapPin, Route, Clock, Navigation, Settings, Save } from 'lucide-react';
import ModalBase from './ModalBase';
import { getDepositoCoords, setDepositoCoords } from '../../hooks/useOptimizarRuta';
import type { PedidoDB, PerfilDB } from '../../types';

// =============================================================================
// TIPOS
// =============================================================================

/** Orden optimizado para un pedido */
export interface OrdenOptimizadoItem {
  pedido_id: string;
  orden: number;
  cliente?: string;
  direccion?: string;
}

/** Resultado de la optimizacion de ruta */
export interface RutaOptimizadaResult {
  orden_optimizado?: OrdenOptimizadoItem[];
  distancia_total?: number;
  duracion_total?: number;
  distancia_formato?: string;
  duracion_formato?: string;
  total_pedidos?: number;
}

/** Props del componente principal */
export interface ModalOptimizarRutaProps {
  transportistas: PerfilDB[];
  pedidos: PedidoDB[];
  onOptimizar: (transportistaId: string, pedidos: PedidoDB[]) => void;
  onAplicarOrden: (ordenOptimizado: OrdenOptimizadoItem[]) => void;
  onClose: () => void;
  loading: boolean;
  rutaOptimizada: RutaOptimizadaResult | null;
  error: string | null;
}

const ModalOptimizarRuta = memo(function ModalOptimizarRuta({
  transportistas,
  pedidos,
  onOptimizar,
  onAplicarOrden,
  onClose,
  loading,
  rutaOptimizada,
  error
}: ModalOptimizarRutaProps) {
  const [transportistaSeleccionado, setTransportistaSeleccionado] = useState<string>('');
  const [mostrarConfigDeposito, setMostrarConfigDeposito] = useState<boolean>(false);
  const [depositoLat, setDepositoLat] = useState<string>('');
  const [depositoLng, setDepositoLng] = useState<string>('');
  const [depositoGuardado, setDepositoGuardado] = useState<boolean>(false);

  // Cargar coordenadas del deposito al montar
  useEffect(() => {
    const coords = getDepositoCoords();
    setDepositoLat(coords.lat.toString());
    setDepositoLng(coords.lng.toString());
  }, []);

  // Obtener pedidos del transportista seleccionado
  const pedidosTransportista = useMemo((): PedidoDB[] => {
    if (!transportistaSeleccionado) return [];
    return pedidos
      .filter(p => p.transportista_id === transportistaSeleccionado && p.estado === 'asignado')
      .sort((a, b) => (a.orden_entrega || 999) - (b.orden_entrega || 999));
  }, [pedidos, transportistaSeleccionado]);

  // Verificar si hay pedidos sin coordenadas
  const pedidosSinCoordenadas = useMemo((): PedidoDB[] => {
    return pedidosTransportista.filter(p => !p.cliente?.latitud || !p.cliente?.longitud);
  }, [pedidosTransportista]);

  const handleOptimizar = (): void => {
    if (transportistaSeleccionado) {
      // Pasar los pedidos completos para que el hook extraiga las coordenadas
      onOptimizar(transportistaSeleccionado, pedidos);
    }
  };

  const handleGuardarDeposito = (): void => {
    const lat = parseFloat(depositoLat);
    const lng = parseFloat(depositoLng);
    if (!isNaN(lat) && !isNaN(lng)) {
      setDepositoCoords(lat, lng);
      setDepositoGuardado(true);
      setTimeout(() => setDepositoGuardado(false), 2000);
    }
  };

  const handleAplicar = (): void => {
    if (rutaOptimizada?.orden_optimizado) {
      onAplicarOrden(rutaOptimizada.orden_optimizado);
    }
  };

  const transportistaInfo = transportistas.find(t => t.id === transportistaSeleccionado);

  return (
    <ModalBase title="Optimizar Ruta de Entregas" onClose={onClose} maxWidth="max-w-2xl">
      <div className="p-4 space-y-4 max-h-[70vh] overflow-y-auto">
        {/* Configuracion del deposito (colapsable) */}
        <div className="border rounded-lg">
          <button
            onClick={() => setMostrarConfigDeposito(!mostrarConfigDeposito)}
            className="w-full flex items-center justify-between p-3 hover:bg-gray-50 rounded-lg"
          >
            <div className="flex items-center space-x-2">
              <Settings className="w-5 h-5 text-gray-500" />
              <span className="font-medium">Configurar ubicacion del deposito/galpon</span>
            </div>
            <span className="text-gray-400">{mostrarConfigDeposito ? '▲' : '▼'}</span>
          </button>
          {mostrarConfigDeposito && (
            <div className="p-3 border-t bg-gray-50 space-y-3">
              <p className="text-sm text-gray-600">
                Ingresa las coordenadas de tu deposito o galpon. Este sera el punto de origen para calcular las rutas.
              </p>
              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="block text-xs font-medium mb-1">Latitud</label>
                  <input
                    type="number"
                    step="0.000001"
                    value={depositoLat}
                    onChange={(e: ChangeEvent<HTMLInputElement>) => setDepositoLat(e.target.value)}
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
                    onChange={(e: ChangeEvent<HTMLInputElement>) => setDepositoLng(e.target.value)}
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
                  {depositoGuardado ? (
                    <>
                      <Check className="w-4 h-4" />
                      <span>Guardado!</span>
                    </>
                  ) : (
                    <>
                      <Save className="w-4 h-4" />
                      <span>Guardar</span>
                    </>
                  )}
                </button>
              </div>
            </div>
          )}
        </div>

        {/* Selector de transportista */}
        <div>
          <label className="block text-sm font-medium mb-1">Seleccionar Transportista</label>
          <select
            value={transportistaSeleccionado}
            onChange={(e: ChangeEvent<HTMLSelectElement>) => setTransportistaSeleccionado(e.target.value)}
            className="w-full px-3 py-2 border rounded-lg"
            disabled={loading}
          >
            <option value="">Seleccionar...</option>
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

        {/* Info del transportista y sus pedidos */}
        {transportistaSeleccionado && (
          <>
            <div className="bg-blue-50 border border-blue-200 rounded-lg p-3">
              <div className="flex items-center space-x-2 mb-2">
                <Truck className="w-5 h-5 text-blue-600" />
                <span className="font-medium">{transportistaInfo?.nombre}</span>
              </div>
              <p className="text-sm text-blue-700">
                {pedidosTransportista.length} pedido(s) asignado(s)
              </p>
            </div>

            {/* Advertencia de pedidos sin coordenadas */}
            {pedidosSinCoordenadas.length > 0 && (
              <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-3">
                <div className="flex items-start space-x-2">
                  <AlertTriangle className="w-5 h-5 text-yellow-600 mt-0.5" />
                  <div>
                    <p className="font-medium text-yellow-800">Pedidos sin coordenadas</p>
                    <p className="text-sm text-yellow-700 mt-1">
                      Los siguientes clientes no tienen coordenadas registradas y no seran incluidos en la optimizacion:
                    </p>
                    <ul className="text-sm text-yellow-700 mt-2 space-y-1">
                      {pedidosSinCoordenadas.map(p => (
                        <li key={p.id}>• #{p.id} - {p.cliente?.nombre_fantasia}</li>
                      ))}
                    </ul>
                  </div>
                </div>
              </div>
            )}

            {/* Lista de pedidos actuales */}
            {pedidosTransportista.length > 0 && (
              <div>
                <h3 className="text-sm font-medium mb-2">Pedidos del transportista:</h3>
                <div className="border rounded-lg max-h-48 overflow-y-auto">
                  {pedidosTransportista.map((pedido, _index) => (
                    <div key={pedido.id} className="flex items-center p-3 border-b last:border-b-0 hover:bg-gray-50">
                      <div className="flex items-center justify-center w-8 h-8 rounded-full bg-gray-100 mr-3">
                        {pedido.orden_entrega ? (
                          <span className="text-sm font-bold text-blue-600">{pedido.orden_entrega}</span>
                        ) : (
                          <span className="text-xs text-gray-400">-</span>
                        )}
                      </div>
                      <div className="flex-1">
                        <p className="font-medium">#{pedido.id} - {pedido.cliente?.nombre_fantasia}</p>
                        <p className="text-sm text-gray-500">{pedido.cliente?.direccion}</p>
                      </div>
                      {pedido.cliente?.latitud && pedido.cliente?.longitud ? (
                        <span title="Con coordenadas"><MapPin className="w-4 h-4 text-green-500" /></span>
                      ) : (
                        <span title="Sin coordenadas"><MapPin className="w-4 h-4 text-gray-300" /></span>
                      )}
                    </div>
                  ))}
                </div>
              </div>
            )}
          </>
        )}

        {/* Error */}
        {error && (
          <div className="bg-red-50 border border-red-200 rounded-lg p-3">
            <div className="flex items-center space-x-2">
              <AlertTriangle className="w-5 h-5 text-red-600" />
              <p className="text-red-700">{error}</p>
            </div>
          </div>
        )}

        {/* Resultado de la optimizacion */}
        {rutaOptimizada && (rutaOptimizada.total_pedidos ?? 0) > 0 && (
          <div className="bg-green-50 border border-green-200 rounded-lg p-4">
            <div className="flex items-center space-x-2 mb-3">
              <Route className="w-5 h-5 text-green-600" />
              <span className="font-medium text-green-800">Ruta optimizada</span>
            </div>
            <div className="grid grid-cols-2 gap-4 mb-3">
              <div className="flex items-center space-x-2">
                <Clock className="w-4 h-4 text-gray-500" />
                <span className="text-sm">
                  Duracion: <strong>{rutaOptimizada.duracion_formato || 'N/A'}</strong>
                </span>
              </div>
              <div className="flex items-center space-x-2">
                <Navigation className="w-4 h-4 text-gray-500" />
                <span className="text-sm">
                  Distancia: <strong>{rutaOptimizada.distancia_formato || 'N/A'}</strong>
                </span>
              </div>
            </div>
            <p className="text-sm text-green-700 mb-3">
              Nuevo orden de entrega sugerido:
            </p>
            <div className="border border-green-300 rounded-lg bg-white max-h-40 overflow-y-auto">
              {rutaOptimizada.orden_optimizado?.map((item, _index) => (
                <div key={item.pedido_id} className="flex items-center p-2 border-b last:border-b-0">
                  <div className="flex items-center justify-center w-6 h-6 rounded-full bg-green-600 text-white text-xs font-bold mr-3">
                    {item.orden}
                  </div>
                  <div className="flex-1">
                    <p className="text-sm font-medium">#{item.pedido_id} - {item.cliente}</p>
                    <p className="text-xs text-gray-500">{item.direccion}</p>
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}

        {rutaOptimizada && rutaOptimizada.total_pedidos === 0 && (
          <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-3 text-center">
            <p className="text-yellow-700">No hay pedidos con coordenadas para optimizar</p>
          </div>
        )}
      </div>

      <div className="flex justify-between items-center p-4 border-t bg-gray-50">
        <button onClick={onClose} className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg">
          Cerrar
        </button>
        <div className="flex space-x-3">
          <button
            onClick={handleOptimizar}
            disabled={!transportistaSeleccionado || loading || pedidosTransportista.length === 0}
            className="flex items-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {loading ? (
              <Loader2 className="w-4 h-4 animate-spin" />
            ) : (
              <Route className="w-4 h-4" />
            )}
            <span>{loading ? 'Optimizando...' : 'Optimizar Ruta'}</span>
          </button>
          {rutaOptimizada?.orden_optimizado && (
            <button
              onClick={handleAplicar}
              disabled={loading}
              className="flex items-center space-x-2 px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 disabled:opacity-50"
            >
              <Check className="w-4 h-4" />
              <span>Aplicar Orden</span>
            </button>
          )}
        </div>
      </div>
    </ModalBase>
  );
});

export default ModalOptimizarRuta;
