import { useState, useMemo, useCallback, memo } from 'react';
import type { ChangeEvent } from 'react';
import { FileDown, Package, Truck, Printer, Loader2, CalendarDays } from 'lucide-react';
import ModalBase from './ModalBase';
import { formatPrecio, fechaLocalISO, formatFecha } from '../../utils/formatters';
import { useRecorridosHojaRutaQuery } from '../../hooks/queries';
import type { PedidoDB, PerfilDB } from '../../types';

// =============================================================================
// TIPOS
// =============================================================================

/** Tipo de exportacion */
type TipoExport = 'preparacion' | 'ruta' | 'comanda';

/** Alcance: pagina actual vs todos con filtros */
type AlcanceExport = 'pagina' | 'todos';

/** Props del componente principal */
export interface ModalExportarPDFProps {
  pedidos: PedidoDB[];
  transportistas: PerfilDB[];
  onExportarOrdenPreparacion: (pedidos: PedidoDB[]) => void;
  onExportarHojaRuta: (transportista: PerfilDB | undefined, pedidos: PedidoDB[]) => void;
  onImprimirComandas?: (pedidos: PedidoDB[]) => void;
  /** Funcion para obtener TODOS los pedidos con los filtros actuales (sin paginacion) */
  fetchAllFilteredPedidos?: () => Promise<PedidoDB[]>;
  onClose: () => void;
}

const ModalExportarPDF = memo(function ModalExportarPDF({
  pedidos,
  transportistas,
  onExportarOrdenPreparacion,
  onExportarHojaRuta,
  onImprimirComandas,
  fetchAllFilteredPedidos,
  onClose
}: ModalExportarPDFProps) {
  const [tipoExport, setTipoExport] = useState<TipoExport>('preparacion');
  const [alcance, setAlcance] = useState<AlcanceExport>('pagina');
  const [transportistaSeleccionado, setTransportistaSeleccionado] = useState<string>('');
  const [pedidosSeleccionados, setPedidosSeleccionados] = useState<string[]>([]);
  const [seleccionarTodos, setSeleccionarTodos] = useState<boolean>(false);
  const [todosLosPedidos, setTodosLosPedidos] = useState<PedidoDB[] | null>(null);
  const [cargandoTodos, setCargandoTodos] = useState(false);
  // Hoja de ruta Y comandas: se descargan desde la ruta YA armada de un día +
  // transportista (persistida en recorridos), no desde pedidos filtrados a mano.
  const [fechaRuta, setFechaRuta] = useState<string>(fechaLocalISO());
  const usaRecorrido = tipoExport === 'ruta' || tipoExport === 'comanda';
  const { data: recorridosDia = [], isLoading: cargandoRecorridos } = useRecorridosHojaRutaQuery(
    usaRecorrido ? fechaRuta : null,
  );
  const recorridoSeleccionado = useMemo(
    () => recorridosDia.find(r => r.transportistaId === transportistaSeleccionado) ?? null,
    [recorridosDia, transportistaSeleccionado],
  );

  // Pedidos base: pagina actual o todos cargados
  const pedidosBase = alcance === 'todos' && todosLosPedidos ? todosLosPedidos : pedidos;

  // Filtrar pedidos segun el tipo de exportacion
  const pedidosFiltrados = useMemo((): PedidoDB[] => {
    if (tipoExport === 'preparacion') {
      return pedidosBase.filter(p => p.estado === 'pendiente' || p.estado === 'en_preparacion');
    } else if (tipoExport === 'comanda') {
      let resultado = pedidosBase.filter(p => p.estado !== 'entregado' && p.estado !== 'cancelado');
      if (transportistaSeleccionado) {
        resultado = resultado.filter(p => p.transportista_id === transportistaSeleccionado);
      }
      return resultado;
    } else {
      // ruta
      if (!transportistaSeleccionado) return [];
      return pedidosBase.filter(p =>
        p.transportista_id === transportistaSeleccionado &&
        (p.estado === 'asignado' || p.estado === 'en_preparacion')
      );
    }
  }, [pedidosBase, tipoExport, transportistaSeleccionado]);

  // Cargar todos los pedidos cuando se selecciona "todos"
  const handleAlcanceChange = useCallback(async (nuevoAlcance: AlcanceExport) => {
    setAlcance(nuevoAlcance);
    setPedidosSeleccionados([]);
    setSeleccionarTodos(false);

    if (nuevoAlcance === 'todos' && !todosLosPedidos && fetchAllFilteredPedidos) {
      setCargandoTodos(true);
      try {
        const todos = await fetchAllFilteredPedidos();
        setTodosLosPedidos(todos);
      } catch {
        // Fallback: usar pedidos de la pagina
        setTodosLosPedidos(null);
        setAlcance('pagina');
      } finally {
        setCargandoTodos(false);
      }
    }
  }, [todosLosPedidos, fetchAllFilteredPedidos]);

  // Manejar seleccion de todos
  const handleSeleccionarTodos = (checked: boolean): void => {
    setSeleccionarTodos(checked);
    if (checked) {
      setPedidosSeleccionados(pedidosFiltrados.map(p => p.id));
    } else {
      setPedidosSeleccionados([]);
    }
  };

  // Manejar seleccion individual
  const handleTogglePedido = (pedidoId: string): void => {
    setPedidosSeleccionados(prev => {
      if (prev.includes(pedidoId)) {
        const nuevo = prev.filter(id => id !== pedidoId);
        setSeleccionarTodos(false);
        return nuevo;
      } else {
        const nuevo = [...prev, pedidoId];
        if (nuevo.length === pedidosFiltrados.length) {
          setSeleccionarTodos(true);
        }
        return nuevo;
      }
    });
  };

  // Resetear seleccion cuando cambia el tipo. Hoja de ruta y comandas eligen
  // día + transportista de la ruta armada (sin selección manual).
  const handleTipoChange = (tipo: TipoExport): void => {
    setTipoExport(tipo);
    setPedidosSeleccionados([]);
    setSeleccionarTodos(false);
    setTransportistaSeleccionado('');
  };

  const handleTransportistaChange = (id: string): void => {
    setTransportistaSeleccionado(id);
    setPedidosSeleccionados([]);
    setSeleccionarTodos(false);
  };

  // Exportar
  const handleExportar = (): void => {
    // Hoja de ruta y Comandas: usan las paradas de la ruta ya armada
    // (persistida), en su orden de entrega; sin selección manual de pedidos.
    if (usaRecorrido) {
      if (!recorridoSeleccionado || recorridoSeleccionado.paradas.length === 0) return;
      const transportista = transportistas.find(t => t.id === transportistaSeleccionado);
      if (tipoExport === 'ruta') {
        onExportarHojaRuta(transportista, recorridoSeleccionado.paradas);
      } else {
        onImprimirComandas?.(recorridoSeleccionado.paradas);
      }
      onClose();
      return;
    }

    // Orden de preparación: selección manual de pedidos.
    const fuente = alcance === 'todos' && todosLosPedidos ? todosLosPedidos : pedidos;
    const pedidosAExportar = fuente.filter(p => pedidosSeleccionados.includes(p.id));
    if (pedidosAExportar.length === 0) return;
    onExportarOrdenPreparacion(pedidosAExportar);
    onClose();
  };

  const getEstadoLabel = (e: string): string => e === 'pendiente' ? 'Pendiente' : e === 'en_preparacion' ? 'En preparacion' : e === 'asignado' ? 'En camino' : 'Entregado';
  const getEstadoColor = (e: string): string => e === 'pendiente' ? 'bg-yellow-100 text-yellow-800' : e === 'en_preparacion' ? 'bg-orange-100 text-orange-800' : e === 'asignado' ? 'bg-blue-100 text-blue-800' : 'bg-green-100 text-green-800';

  // El alcance (página/todos) solo aplica a Orden de Preparación. Hoja de Ruta
  // se descarga desde la ruta armada (día + transportista) y Comandas carga todo.
  const mostrarAlcance = tipoExport === 'preparacion' && !!fetchAllFilteredPedidos;

  return (
    <ModalBase title="Exportar Pedidos a PDF" onClose={onClose} maxWidth="max-w-2xl">
      <div className="p-4 space-y-4">
        {/* Selector de tipo de exportacion */}
        <div>
          <label className="block text-sm font-medium mb-2">Tipo de documento</label>
          <div className="grid grid-cols-3 gap-3">
            <button
              onClick={() => handleTipoChange('preparacion')}
              className={`flex items-center justify-center space-x-2 p-4 rounded-lg border-2 transition-colors ${
                tipoExport === 'preparacion'
                  ? 'border-orange-500 bg-orange-50 text-orange-700 dark:bg-orange-900/20 dark:text-orange-400'
                  : 'border-gray-200 dark:border-gray-600 hover:border-gray-300 dark:hover:border-gray-500'
              }`}
            >
              <Package className="w-6 h-6" />
              <div className="text-left">
                <p className="font-medium">Orden de Preparacion</p>
                <p className="text-xs text-gray-500 dark:text-gray-400">Para el deposito</p>
              </div>
            </button>
            <button
              onClick={() => handleTipoChange('ruta')}
              className={`flex items-center justify-center space-x-2 p-4 rounded-lg border-2 transition-colors ${
                tipoExport === 'ruta'
                  ? 'border-blue-500 bg-blue-50 text-blue-700 dark:bg-blue-900/20 dark:text-blue-400'
                  : 'border-gray-200 dark:border-gray-600 hover:border-gray-300 dark:hover:border-gray-500'
              }`}
            >
              <Truck className="w-6 h-6" />
              <div className="text-left">
                <p className="font-medium">Hoja de Ruta</p>
                <p className="text-xs text-gray-500 dark:text-gray-400">Para el transportista</p>
              </div>
            </button>
            <button
              onClick={() => handleTipoChange('comanda')}
              className={`flex items-center justify-center space-x-2 p-4 rounded-lg border-2 transition-colors ${
                tipoExport === 'comanda'
                  ? 'border-purple-500 bg-purple-50 text-purple-700 dark:bg-purple-900/20 dark:text-purple-400'
                  : 'border-gray-200 dark:border-gray-600 hover:border-gray-300 dark:hover:border-gray-500'
              }`}
            >
              <Printer className="w-6 h-6" />
              <div className="text-left">
                <p className="font-medium">Imprimir Comandas</p>
                <p className="text-xs text-gray-500 dark:text-gray-400">Duplicado por pedido</p>
              </div>
            </button>
          </div>
        </div>

        {/* Alcance: pagina actual vs todos (para preparacion y ruta) */}
        {mostrarAlcance && (
          <div>
            <label className="block text-sm font-medium mb-1">Alcance</label>
            <div className="grid grid-cols-2 gap-2">
              <button
                type="button"
                onClick={() => handleAlcanceChange('pagina')}
                className={`px-3 py-2 rounded-lg text-sm font-medium transition-colors ${
                  alcance === 'pagina'
                    ? 'bg-blue-600 text-white'
                    : 'bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600'
                }`}
              >
                Pagina actual
              </button>
              <button
                type="button"
                onClick={() => handleAlcanceChange('todos')}
                disabled={cargandoTodos}
                className={`px-3 py-2 rounded-lg text-sm font-medium transition-colors flex items-center justify-center gap-2 ${
                  alcance === 'todos'
                    ? 'bg-blue-600 text-white'
                    : 'bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600'
                }`}
              >
                {cargandoTodos && <Loader2 className="w-4 h-4 animate-spin" />}
                Todos los pedidos (con filtros)
              </button>
            </div>
          </div>
        )}

        {/* Hoja de Ruta y Comandas: se elige día + transportista con ruta armada
            y se genera desde el recorrido persistido (sin selección manual). */}
        {usaRecorrido && (
          <>
            <div>
              <label className="block text-sm font-medium mb-1 flex items-center gap-1.5">
                <CalendarDays className="w-4 h-4 text-gray-500" />
                Día de la ruta
              </label>
              <input
                type="date"
                value={fechaRuta}
                onChange={(e: ChangeEvent<HTMLInputElement>) => { setFechaRuta(e.target.value); setTransportistaSeleccionado(''); }}
                className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
              />
            </div>
            <div>
              <label className="block text-sm font-medium mb-1">Transportista</label>
              <select
                value={transportistaSeleccionado}
                onChange={(e: ChangeEvent<HTMLSelectElement>) => handleTransportistaChange(e.target.value)}
                disabled={cargandoRecorridos}
                className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
              >
                <option value="">{cargandoRecorridos ? 'Cargando rutas...' : 'Seleccionar transportista...'}</option>
                {recorridosDia.map(r => (
                  <option key={r.recorridoId} value={r.transportistaId}>
                    {r.transportistaNombre} ({r.paradas.length} paradas)
                  </option>
                ))}
              </select>
            </div>
            <div className="border rounded-lg p-4 bg-gray-50 dark:bg-gray-900 text-center">
              {cargandoRecorridos ? (
                <div className="flex items-center justify-center text-gray-500">
                  <Loader2 className="w-5 h-5 animate-spin mr-2" />Cargando rutas...
                </div>
              ) : recorridosDia.length === 0 ? (
                <div className="text-gray-500 text-sm py-2">
                  <Truck className="w-8 h-8 mx-auto mb-2 opacity-50" />
                  No hay rutas armadas para el {formatFecha(fechaRuta)}.
                </div>
              ) : recorridoSeleccionado ? (
                <p className="text-sm text-gray-700 dark:text-gray-300">
                  {tipoExport === 'ruta'
                    ? <>Se descargará la hoja de ruta de <strong>{recorridoSeleccionado.transportistaNombre}</strong> con <strong>{recorridoSeleccionado.paradas.length}</strong> paradas.</>
                    : <>Se imprimirán las comandas (duplicado por pedido) de <strong>{recorridoSeleccionado.transportistaNombre}</strong>: <strong>{recorridoSeleccionado.paradas.length}</strong> pedidos.</>}
                </p>
              ) : (
                <p className="text-sm text-gray-500">Elegí un transportista para continuar.</p>
              )}
            </div>
          </>
        )}

        {/* Lista de pedidos: solo Orden de Preparación usa selección manual.
            Hoja de Ruta y Comandas salen del recorrido armado (arriba). */}
        {tipoExport === 'preparacion' && (
          <div>
            <div className="flex justify-between items-center mb-2">
              <label className="block text-sm font-medium">
                Pedidos a exportar ({pedidosSeleccionados.length} de {pedidosFiltrados.length})
              </label>
              {pedidosFiltrados.length > 0 && (
                <label className="flex items-center space-x-2 text-sm cursor-pointer">
                  <input
                    type="checkbox"
                    checked={seleccionarTodos}
                    onChange={(e: ChangeEvent<HTMLInputElement>) => handleSeleccionarTodos(e.target.checked)}
                    className="w-4 h-4 rounded"
                  />
                  <span>Seleccionar todos</span>
                </label>
              )}
            </div>

            {cargandoTodos ? (
              <div className="flex items-center justify-center py-8 bg-gray-50 dark:bg-gray-900 rounded-lg">
                <Loader2 className="w-6 h-6 animate-spin text-blue-600 mr-2" />
                <span className="text-gray-500">Cargando pedidos...</span>
              </div>
            ) : pedidosFiltrados.length === 0 ? (
              <div className="text-center py-8 text-gray-500 bg-gray-50 rounded-lg">
                <Package className="w-10 h-10 mx-auto mb-2 opacity-50" />
                <p>No hay pedidos disponibles para exportar</p>
                <p className="text-xs mt-1">Solo se muestran pedidos pendientes o en preparacion</p>
              </div>
            ) : (
              <div className="border rounded-lg max-h-64 overflow-y-auto">
                {pedidosFiltrados.map(pedido => (
                  <div
                    key={pedido.id}
                    onClick={() => handleTogglePedido(pedido.id)}
                    className={`flex items-center p-3 border-b last:border-b-0 cursor-pointer transition-colors ${
                      pedidosSeleccionados.includes(pedido.id)
                        ? 'bg-blue-50'
                        : 'hover:bg-gray-50'
                    }`}
                  >
                    <input
                      type="checkbox"
                      checked={pedidosSeleccionados.includes(pedido.id)}
                      onChange={() => {}}
                      className="w-4 h-4 mr-3"
                    />
                    <div className="flex-1">
                      <div className="flex items-center justify-between">
                        <p className="font-medium">#{pedido.id} - {pedido.cliente?.nombre_fantasia}</p>
                        <span className={`px-2 py-0.5 rounded-full text-xs ${getEstadoColor(pedido.estado)}`}>
                          {getEstadoLabel(pedido.estado)}
                        </span>
                      </div>
                      <p className="text-sm text-gray-500">{pedido.cliente?.direccion}</p>
                      <p className="text-sm font-medium text-blue-600">{formatPrecio(pedido.total)}</p>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>
        )}
      </div>

      <div className="flex justify-between items-center p-4 border-t bg-gray-50 dark:bg-gray-800 sticky bottom-0">
        <p className="text-sm text-gray-600">
          {usaRecorrido
            ? (recorridoSeleccionado && (
                <>Total: {formatPrecio(recorridoSeleccionado.paradas.reduce((sum, p) => sum + (p.total || 0), 0))}</>
              ))
            : (pedidosSeleccionados.length > 0 && (
                <>
                  Total: {formatPrecio(
                    pedidosFiltrados
                      .filter(p => pedidosSeleccionados.includes(p.id))
                      .reduce((sum, p) => sum + (p.total || 0), 0)
                  )}
                </>
              ))}
        </p>
        <div className="flex space-x-3">
          <button onClick={onClose} className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg">
            Cancelar
          </button>
          <button
            onClick={handleExportar}
            disabled={usaRecorrido
              ? !recorridoSeleccionado || recorridoSeleccionado.paradas.length === 0
              : pedidosSeleccionados.length === 0}
            className={`flex items-center space-x-2 px-4 py-2 text-white rounded-lg disabled:opacity-50 disabled:cursor-not-allowed ${
              tipoExport === 'comanda'
                ? 'bg-purple-600 hover:bg-purple-700'
                : 'bg-green-600 hover:bg-green-700'
            }`}
          >
            {tipoExport === 'comanda' ? <Printer className="w-4 h-4" /> : <FileDown className="w-4 h-4" />}
            <span>{tipoExport === 'comanda' ? 'Imprimir Comandas' : 'Exportar PDF'}</span>
          </button>
        </div>
      </div>
    </ModalBase>
  );
});

export default ModalExportarPDF;
