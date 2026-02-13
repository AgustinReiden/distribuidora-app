import { useState, useMemo, memo, useEffect } from 'react';
import type { ChangeEvent } from 'react';
import { Loader2, AlertTriangle, Check, Users, MapPin, Route, Clock, Navigation, Settings, Save } from 'lucide-react';
import ModalBase from './ModalBase';
import { getDepositoCoords, setDepositoCoords } from '../../hooks/useOptimizarRuta';
import type { ClienteDB, PerfilDB } from '../../types';
import type { RutaPreventistaResponse } from '../../hooks/useOptimizarRutaPreventista';

// =============================================================================
// TIPOS
// =============================================================================

export interface ModalOptimizarRutaPreventistaProps {
  preventistas: PerfilDB[];
  clientes: ClienteDB[];
  onOptimizar: (preventistaId: string, clientes: ClienteDB[]) => void;
  onClose: () => void;
  loading: boolean;
  rutaOptimizada: RutaPreventistaResponse | null;
  error: string | null;
}

const ModalOptimizarRutaPreventista = memo(function ModalOptimizarRutaPreventista({
  preventistas,
  clientes,
  onOptimizar,
  onClose,
  loading,
  rutaOptimizada,
  error
}: ModalOptimizarRutaPreventistaProps) {
  const [preventistaSeleccionado, setPreventistaSeleccionado] = useState<string>('');
  const [clientesExcluidos, setClientesExcluidos] = useState<Set<string>>(new Set());
  const [mostrarConfigDeposito, setMostrarConfigDeposito] = useState<boolean>(false);
  const [depositoLat, setDepositoLat] = useState<string>('');
  const [depositoLng, setDepositoLng] = useState<string>('');
  const [depositoGuardado, setDepositoGuardado] = useState<boolean>(false);

  // Load depot coords on mount
  useEffect(() => {
    const coords = getDepositoCoords();
    setDepositoLat(coords.lat.toString());
    setDepositoLng(coords.lng.toString());
  }, []);

  // Filter clients assigned to selected preventista
  const clientesPreventista = useMemo((): ClienteDB[] => {
    if (!preventistaSeleccionado) return [];
    return clientes
      .filter(c => c.preventista_id === preventistaSeleccionado && c.activo !== false)
      .sort((a, b) => (a.nombre_fantasia || '').localeCompare(b.nombre_fantasia || ''));
  }, [clientes, preventistaSeleccionado]);

  // Clients without coordinates
  const clientesSinCoordenadas = useMemo((): ClienteDB[] => {
    return clientesPreventista.filter(c => !c.latitud || !c.longitud);
  }, [clientesPreventista]);

  // Clients selected for optimization (excluding manually unchecked ones)
  const clientesParaOptimizar = useMemo((): ClienteDB[] => {
    return clientesPreventista
      .filter(c => c.latitud && c.longitud && !clientesExcluidos.has(c.id));
  }, [clientesPreventista, clientesExcluidos]);

  const toggleCliente = (clienteId: string) => {
    setClientesExcluidos(prev => {
      const next = new Set(prev);
      if (next.has(clienteId)) {
        next.delete(clienteId);
      } else {
        next.add(clienteId);
      }
      return next;
    });
  };

  const handleOptimizar = (): void => {
    if (preventistaSeleccionado && clientesParaOptimizar.length > 0) {
      onOptimizar(preventistaSeleccionado, clientesParaOptimizar);
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

  const preventistaInfo = preventistas.find(t => t.id === preventistaSeleccionado);

  return (
    <ModalBase title="Optimizar Recorrido de Preventista" onClose={onClose} maxWidth="max-w-2xl">
      <div className="p-4 space-y-4 max-h-[70vh] overflow-y-auto">
        {/* Depot config (collapsible) */}
        <div className="border dark:border-gray-600 rounded-lg">
          <button
            onClick={() => setMostrarConfigDeposito(!mostrarConfigDeposito)}
            className="w-full flex items-center justify-between p-3 hover:bg-gray-50 dark:hover:bg-gray-700 rounded-lg"
          >
            <div className="flex items-center space-x-2">
              <Settings className="w-5 h-5 text-gray-500" />
              <span className="font-medium dark:text-white">Configurar ubicacion del deposito/oficina</span>
            </div>
            <span className="text-gray-400">{mostrarConfigDeposito ? '\u25B2' : '\u25BC'}</span>
          </button>
          {mostrarConfigDeposito && (
            <div className="p-3 border-t dark:border-gray-600 bg-gray-50 dark:bg-gray-900 space-y-3">
              <p className="text-sm text-gray-600 dark:text-gray-400">
                Punto de origen para calcular las rutas del preventista.
              </p>
              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="block text-xs font-medium mb-1 dark:text-gray-300">Latitud</label>
                  <input
                    type="number"
                    step="0.000001"
                    value={depositoLat}
                    onChange={(e: ChangeEvent<HTMLInputElement>) => setDepositoLat(e.target.value)}
                    className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg text-sm dark:bg-gray-700 dark:text-white"
                    placeholder="-26.8241"
                  />
                </div>
                <div>
                  <label className="block text-xs font-medium mb-1 dark:text-gray-300">Longitud</label>
                  <input
                    type="number"
                    step="0.000001"
                    value={depositoLng}
                    onChange={(e: ChangeEvent<HTMLInputElement>) => setDepositoLng(e.target.value)}
                    className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg text-sm dark:bg-gray-700 dark:text-white"
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
                    <><Check className="w-4 h-4" /><span>Guardado!</span></>
                  ) : (
                    <><Save className="w-4 h-4" /><span>Guardar</span></>
                  )}
                </button>
              </div>
            </div>
          )}
        </div>

        {/* Preventista selector */}
        <div>
          <label className="block text-sm font-medium mb-1 dark:text-gray-300">Seleccionar Preventista</label>
          <select
            value={preventistaSeleccionado}
            onChange={(e: ChangeEvent<HTMLSelectElement>) => {
              setPreventistaSeleccionado(e.target.value);
              setClientesExcluidos(new Set());
            }}
            className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg dark:bg-gray-700 dark:text-white"
            disabled={loading}
          >
            <option value="">Seleccionar...</option>
            {preventistas.map(p => {
              const cantClientes = clientes.filter(c =>
                c.preventista_id === p.id && c.activo !== false
              ).length;
              return (
                <option key={p.id} value={p.id}>
                  {p.nombre} ({cantClientes} clientes asignados)
                </option>
              );
            })}
          </select>
        </div>

        {/* Preventista info */}
        {preventistaSeleccionado && (
          <>
            <div className="bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-lg p-3">
              <div className="flex items-center space-x-2 mb-2">
                <Users className="w-5 h-5 text-blue-600" />
                <span className="font-medium dark:text-white">{preventistaInfo?.nombre}</span>
              </div>
              <p className="text-sm text-blue-700 dark:text-blue-300">
                {clientesPreventista.length} cliente(s) asignado(s) | {clientesParaOptimizar.length} seleccionado(s) para ruta
              </p>
            </div>

            {/* Warning for clients without coordinates */}
            {clientesSinCoordenadas.length > 0 && (
              <div className="bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg p-3">
                <div className="flex items-start space-x-2">
                  <AlertTriangle className="w-5 h-5 text-yellow-600 mt-0.5" />
                  <div>
                    <p className="font-medium text-yellow-800 dark:text-yellow-300">Clientes sin coordenadas</p>
                    <p className="text-sm text-yellow-700 dark:text-yellow-400 mt-1">
                      No seran incluidos en la optimizacion:
                    </p>
                    <ul className="text-sm text-yellow-700 dark:text-yellow-400 mt-2 space-y-1">
                      {clientesSinCoordenadas.map(c => (
                        <li key={c.id}>{'\u2022'} {c.nombre_fantasia} - {c.direccion}</li>
                      ))}
                    </ul>
                  </div>
                </div>
              </div>
            )}

            {/* Client list with checkboxes */}
            {clientesPreventista.filter(c => c.latitud && c.longitud).length > 0 && (
              <div>
                <h3 className="text-sm font-medium mb-2 dark:text-gray-300">Clientes del preventista (con coordenadas):</h3>
                <div className="border dark:border-gray-600 rounded-lg max-h-48 overflow-y-auto">
                  {clientesPreventista
                    .filter(c => c.latitud && c.longitud)
                    .map(cliente => (
                      <label
                        key={cliente.id}
                        className="flex items-center p-3 border-b last:border-b-0 dark:border-gray-600 hover:bg-gray-50 dark:hover:bg-gray-700 cursor-pointer"
                      >
                        <input
                          type="checkbox"
                          checked={!clientesExcluidos.has(cliente.id)}
                          onChange={() => toggleCliente(cliente.id)}
                          className="mr-3 text-blue-600 rounded"
                        />
                        <div className="flex-1">
                          <p className="font-medium dark:text-white">{cliente.nombre_fantasia}</p>
                          <p className="text-sm text-gray-500">{cliente.direccion}</p>
                        </div>
                        <MapPin className="w-4 h-4 text-green-500" />
                      </label>
                    ))}
                </div>
              </div>
            )}
          </>
        )}

        {/* Error */}
        {error && (
          <div className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg p-3">
            <div className="flex items-center space-x-2">
              <AlertTriangle className="w-5 h-5 text-red-600" />
              <p className="text-red-700 dark:text-red-400">{error}</p>
            </div>
          </div>
        )}

        {/* Optimization result */}
        {rutaOptimizada && (rutaOptimizada.total_clientes ?? 0) > 0 && (
          <div className="bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 rounded-lg p-4">
            <div className="flex items-center space-x-2 mb-3">
              <Route className="w-5 h-5 text-green-600" />
              <span className="font-medium text-green-800 dark:text-green-300">Recorrido optimizado</span>
            </div>
            <div className="grid grid-cols-2 gap-4 mb-3">
              <div className="flex items-center space-x-2">
                <Clock className="w-4 h-4 text-gray-500" />
                <span className="text-sm dark:text-gray-300">
                  Duracion: <strong>{rutaOptimizada.duracion_formato || 'N/A'}</strong>
                </span>
              </div>
              <div className="flex items-center space-x-2">
                <Navigation className="w-4 h-4 text-gray-500" />
                <span className="text-sm dark:text-gray-300">
                  Distancia: <strong>{rutaOptimizada.distancia_formato || 'N/A'}</strong>
                </span>
              </div>
            </div>
            <p className="text-sm text-green-700 dark:text-green-400 mb-3">
              Orden de visita sugerido:
            </p>
            <div className="border border-green-300 dark:border-green-700 rounded-lg bg-white dark:bg-gray-800 max-h-40 overflow-y-auto">
              {rutaOptimizada.orden_optimizado?.map(item => (
                <div key={item.cliente_id} className="flex items-center p-2 border-b last:border-b-0 dark:border-gray-700">
                  <div className="flex items-center justify-center w-6 h-6 rounded-full bg-green-600 text-white text-xs font-bold mr-3">
                    {item.orden}
                  </div>
                  <div className="flex-1">
                    <p className="text-sm font-medium dark:text-white">{item.cliente_nombre}</p>
                    <p className="text-xs text-gray-500">{item.direccion}</p>
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}

        {rutaOptimizada && rutaOptimizada.total_clientes === 0 && (
          <div className="bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg p-3 text-center">
            <p className="text-yellow-700 dark:text-yellow-400">No hay clientes con coordenadas para optimizar</p>
          </div>
        )}
      </div>

      <div className="flex justify-between items-center p-4 border-t dark:border-gray-700 bg-gray-50 dark:bg-gray-900">
        <button onClick={onClose} className="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 rounded-lg">
          Cerrar
        </button>
        <button
          onClick={handleOptimizar}
          disabled={!preventistaSeleccionado || loading || clientesParaOptimizar.length === 0}
          className="flex items-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {loading ? (
            <Loader2 className="w-4 h-4 animate-spin" />
          ) : (
            <Route className="w-4 h-4" />
          )}
          <span>{loading ? 'Optimizando...' : 'Optimizar Recorrido'}</span>
        </button>
      </div>
    </ModalBase>
  );
});

export default ModalOptimizarRutaPreventista;
