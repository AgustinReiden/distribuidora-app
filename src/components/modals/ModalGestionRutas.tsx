import { useState, useMemo, memo, useEffect } from 'react';
import type { ChangeEvent } from 'react';
import {
  Loader2, AlertTriangle, Check, Truck, MapPin, Route, Clock, Navigation,
  Settings, Save, FileText, ChevronDown, ChevronUp, Phone,
  DollarSign, Package, CheckCircle, Circle, Printer, ArrowRight, CalendarDays
} from 'lucide-react';
import ModalBase from './ModalBase';
import { useDepositoCoords, useSetDepositoMutation } from '../../hooks/queries';
import { fechaLocalISO, fechaHaceDias, formatFecha } from '../../utils/formatters';
import type { PedidoDB, PerfilDB } from '../../types';

// =============================================================================
// TIPOS
// =============================================================================

/** Orden optimizado para un pedido */
export interface OrdenOptimizado {
  pedido_id: string;
  orden: number;
  cliente?: string;
  direccion?: string;
}

/** Resultado de la optimizacion de ruta */
export interface RutaOptimizadaResult {
  orden_optimizado?: OrdenOptimizado[];
  distancia_total?: number;
  duracion_total?: number;
  distancia_formato?: string;
  duracion_formato?: string;
  total_pedidos?: number;
}

/** Datos para aplicar el orden optimizado */
export interface AplicarOrdenData {
  ordenOptimizado: OrdenOptimizado[];
  transportistaId: string;
  distancia: number | null;
  duracion: number | null;
}

/** Pedido con orden optimizado extendido */
interface PedidoOrdenado extends PedidoDB {
  orden_optimizado?: number;
}

/** Props del componente PedidoRutaCard */
interface PedidoRutaCardProps {
  pedido: PedidoDB;
  orden: number;
  isFirst: boolean;
  isLast: boolean;
}

/** Props del componente principal */
export interface ModalGestionRutasProps {
  transportistas: PerfilDB[];
  pedidos: PedidoDB[];
  /**
   * Arma la ruta del día: optimiza los pedidos seleccionados y la guarda en
   * un solo paso (el container encadena optimizar + aplicar_orden_ruta).
   */
  onArmarRuta: (transportistaId: string, pedidos: PedidoDB[], fecha: string) => void;
  onExportarPDF: (transportista: PerfilDB | undefined, pedidos: PedidoOrdenado[]) => void;
  onClose: () => void;
  /** true mientras se optimiza/guarda la ruta del día */
  loading: boolean;
  guardando: boolean;
  rutaOptimizada: RutaOptimizadaResult | null;
  error: string | null;
}

/** Mapa de colores para estado de pago */
type EstadoPagoColors = Record<string, string>;

/** Mapa de etiquetas para forma de pago */
type FormaPagoLabels = Record<string, string>;

/** Totales calculados */
interface Totales {
  pedidos: number;
  total: number;
  pendienteCobro: number;
  items: number;
}

// Componente para mostrar cada pedido en la lista de ruta
const PedidoRutaCard = memo(function PedidoRutaCard({ pedido, orden, isFirst, isLast }: PedidoRutaCardProps) {
  const estadoPagoColors: EstadoPagoColors = {
    pagado: 'bg-green-100 text-green-700 border-green-200',
    parcial: 'bg-yellow-100 text-yellow-700 border-yellow-200',
    pendiente: 'bg-red-100 text-red-700 border-red-200'
  };

  const formaPagoLabels: FormaPagoLabels = {
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
            <span className={`px-2 py-1 text-xs font-medium rounded-full border ${estadoPagoColors[pedido.estado_pago || 'pendiente'] || estadoPagoColors.pendiente}`}>
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
              {formaPagoLabels[pedido.forma_pago || 'efectivo'] || 'Efectivo'}
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
  onArmarRuta,
  onExportarPDF,
  onClose,
  loading,
  guardando,
  rutaOptimizada,
  error
}: ModalGestionRutasProps) {
  const [transportistaSeleccionado, setTransportistaSeleccionado] = useState<string>('');
  // Fecha de entrega de la ruta. Generalmente se arma el día anterior, así que
  // el default es mañana; se puede elegir de hoy en adelante.
  const hoyISO = fechaLocalISO();
  const [fechaEntrega, setFechaEntrega] = useState<string>(fechaHaceDias(-1));
  // Filtro de fecha: la admin marca entregados/rendición con rezago, así que
  // al armar la ruta del día siguiente quedan pedidos viejos aún en estado
  // 'asignado' que no deben entrar en la optimización.
  const [filtroCriterio, setFiltroCriterio] = useState<'asignacion' | 'pedido'>('asignacion');
  const [filtroDesde, setFiltroDesde] = useState<string>('');
  const [filtroHasta, setFiltroHasta] = useState<string>('');
  const [mostrarConfigDeposito, setMostrarConfigDeposito] = useState<boolean>(false);
  const [depositoLat, setDepositoLat] = useState<string>('');
  const [depositoLng, setDepositoLng] = useState<string>('');
  const [depositoGuardado, setDepositoGuardado] = useState<boolean>(false);
  const [vistaActiva, setVistaActiva] = useState<'optimizar' | 'resultado'>('optimizar');

  // Depósito de la sucursal (DB, mig 082) — compartido con el mapa del transportista
  const deposito = useDepositoCoords();
  const setDepositoMut = useSetDepositoMutation();

  // Cargar coordenadas del deposito en los inputs
  useEffect(() => {
    setDepositoLat(deposito.lat.toString());
    setDepositoLng(deposito.lng.toString());
  }, [deposito.lat, deposito.lng]);

  // Cambiar a vista resultado cuando hay ruta optimizada
  useEffect(() => {
    if ((rutaOptimizada?.orden_optimizado?.length ?? 0) > 0) {
      setVistaActiva('resultado');
    }
  }, [rutaOptimizada]);

  // Fecha del pedido según el criterio de filtro. Para 'asignacion' usa la
  // derivada del historial; si no existe (pedidos viejos sin registro), cae a
  // la fecha del pedido para no excluirlos silenciosamente.
  const fechaSegunCriterio = (p: PedidoDB): string | null => {
    if (filtroCriterio === 'asignacion') return p.fecha_asignacion || p.fecha || null;
    return p.fecha || null;
  };

  const filtroActivo = !!(filtroDesde || filtroHasta);

  // Pedidos que pasan el filtro de fecha (estado 'asignado' ya viene filtrado
  // del container, pero se mantiene la condición por robustez)
  const pedidosFiltrados = useMemo((): PedidoDB[] => {
    return pedidos.filter(p => {
      if (p.estado !== 'asignado') return false;
      if (!filtroActivo) return true;
      const f = fechaSegunCriterio(p);
      if (!f) return true; // sin fecha conocida: incluir antes que ocultar
      if (filtroDesde && f < filtroDesde) return false;
      if (filtroHasta && f > filtroHasta) return false;
      return true;
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pedidos, filtroActivo, filtroCriterio, filtroDesde, filtroHasta]);

  // Obtener pedidos del transportista seleccionado
  const pedidosTransportista = useMemo((): PedidoDB[] => {
    if (!transportistaSeleccionado) return [];
    return pedidosFiltrados
      .filter(p => p.transportista_id === transportistaSeleccionado)
      .sort((a, b) => (a.orden_entrega || 999) - (b.orden_entrega || 999));
  }, [pedidosFiltrados, transportistaSeleccionado]);

  // Selección de pedidos para la ruta del día (default: todos). El admin puede
  // destildar los que no van hoy (ej: entregados-no-marcados de días previos).
  const [seleccionados, setSeleccionados] = useState<Set<string>>(new Set());
  useEffect(() => {
    setSeleccionados(new Set(pedidosTransportista.map(p => p.id)));
  }, [pedidosTransportista]);

  const pedidosSeleccionados = useMemo(
    () => pedidosTransportista.filter(p => seleccionados.has(p.id)),
    [pedidosTransportista, seleccionados],
  );

  const toggleSeleccion = (id: string): void => {
    setSeleccionados(prev => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  };
  const todosSeleccionados = pedidosTransportista.length > 0 && seleccionados.size === pedidosTransportista.length;
  const toggleTodos = (): void => {
    setSeleccionados(todosSeleccionados ? new Set() : new Set(pedidosTransportista.map(p => p.id)));
  };

  // Cuántos pedidos del transportista quedaron afuera por el filtro de fecha
  const pedidosExcluidosPorFecha = useMemo((): number => {
    if (!transportistaSeleccionado || !filtroActivo) return 0;
    const totalTransportista = pedidos.filter(
      p => p.transportista_id === transportistaSeleccionado && p.estado === 'asignado'
    ).length;
    return totalTransportista - pedidosTransportista.length;
  }, [pedidos, pedidosTransportista, transportistaSeleccionado, filtroActivo]);

  // Pedidos ordenados segun la optimizacion
  const pedidosOrdenados = useMemo((): PedidoOrdenado[] => {
    if (!rutaOptimizada?.orden_optimizado) return [];
    const result: PedidoOrdenado[] = [];
    for (const item of rutaOptimizada.orden_optimizado) {
      const pedido = pedidos.find(p => p.id === item.pedido_id);
      if (pedido) {
        result.push({ ...pedido, orden_optimizado: item.orden });
      }
    }
    return result;
  }, [rutaOptimizada, pedidos]);

  // Verificar si hay pedidos sin coordenadas
  const pedidosSinCoordenadas = useMemo((): PedidoDB[] => {
    return pedidosTransportista.filter(p => !p.cliente?.latitud || !p.cliente?.longitud);
  }, [pedidosTransportista]);

  // Links a Google Maps con la ruta armada. Maps acepta máximo 9 waypoints
  // por link (+ origen + destino = 10 paradas nuevas por link), así que rutas
  // largas se parten en varios links encadenados: el destino de un link es el
  // origen del siguiente.
  const linksGoogleMaps = useMemo((): Array<{ url: string; desde: number; hasta: number }> => {
    const coords = pedidosOrdenados
      .filter(p => p.cliente?.latitud != null && p.cliente?.longitud != null)
      .map(p => `${p.cliente!.latitud},${p.cliente!.longitud}`);
    if (coords.length === 0) return [];

    const PARADAS_POR_LINK = 10; // 9 waypoints + destino
    const links: Array<{ url: string; desde: number; hasta: number }> = [];
    let origen = `${deposito.lat},${deposito.lng}`;

    for (let i = 0; i < coords.length; i += PARADAS_POR_LINK) {
      const grupo = coords.slice(i, i + PARADAS_POR_LINK);
      const destino = grupo[grupo.length - 1];
      const waypoints = grupo.slice(0, -1).join('|');
      const url = `https://www.google.com/maps/dir/?api=1&origin=${encodeURIComponent(origen)}&destination=${encodeURIComponent(destino)}${
        waypoints ? `&waypoints=${encodeURIComponent(waypoints)}` : ''
      }&travelmode=driving`;
      links.push({ url, desde: i + 1, hasta: i + grupo.length });
      origen = destino;
    }
    return links;
  }, [pedidosOrdenados, deposito.lat, deposito.lng]);

  // Calcular totales
  const totales = useMemo((): Totales => {
    const lista = vistaActiva === 'resultado' ? pedidosOrdenados : pedidosTransportista;
    return {
      pedidos: lista.length,
      total: lista.reduce((sum, p) => sum + (p.total || 0), 0),
      pendienteCobro: lista.filter(p => p.estado_pago !== 'pagado').reduce((sum, p) => sum + (p.total || 0), 0),
      items: lista.reduce((sum, p) => sum + (p.items?.length || 0), 0)
    };
  }, [vistaActiva, pedidosOrdenados, pedidosTransportista]);

  const handleArmar = (): void => {
    if (transportistaSeleccionado && pedidosSeleccionados.length > 0) {
      // Optimiza + guarda en un paso, solo con los pedidos seleccionados.
      onArmarRuta(transportistaSeleccionado, pedidosSeleccionados, fechaEntrega);
    }
  };

  const handleGuardarDeposito = (): void => {
    const lat = parseFloat(depositoLat);
    const lng = parseFloat(depositoLng);
    if (!isNaN(lat) && !isNaN(lng)) {
      setDepositoMut.mutate({ lat, lng }, {
        onSuccess: () => {
          setDepositoGuardado(true);
          setTimeout(() => setDepositoGuardado(false), 2000);
        },
      });
    }
  };

  const handleExportarPDF = (): void => {
    const transportista = transportistas.find(t => t.id === transportistaSeleccionado);
    onExportarPDF(transportista, pedidosOrdenados);
  };

  const handleVolverOptimizar = (): void => {
    setVistaActiva('optimizar');
  };

  const transportistaInfo = transportistas.find(t => t.id === transportistaSeleccionado);

  return (
    <ModalBase title="Armar ruta del día" onClose={onClose} maxWidth="max-w-4xl">
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
            Armar ruta
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
            Ruta guardada
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
              {/* Fecha de entrega de la ruta (default: mañana; de hoy en adelante) */}
              <div className="bg-blue-50 border border-blue-200 rounded-lg p-4">
                <label className="block text-sm font-medium mb-2 flex items-center gap-1.5 text-blue-900">
                  <CalendarDays className="w-4 h-4" />
                  Fecha de entrega de esta ruta
                </label>
                <div className="flex flex-wrap items-center gap-3">
                  <input
                    type="date"
                    value={fechaEntrega}
                    min={hoyISO}
                    onChange={(e: ChangeEvent<HTMLInputElement>) => setFechaEntrega(e.target.value)}
                    className="px-3 py-2 border rounded-lg text-sm"
                  />
                  <div className="flex gap-1.5">
                    <button
                      type="button"
                      onClick={() => setFechaEntrega(hoyISO)}
                      className={`px-3 py-1.5 text-xs font-medium rounded-full border ${fechaEntrega === hoyISO ? 'bg-blue-600 text-white border-blue-600' : 'bg-white text-blue-700 border-blue-200'}`}
                    >
                      Hoy
                    </button>
                    <button
                      type="button"
                      onClick={() => setFechaEntrega(fechaHaceDias(-1))}
                      className={`px-3 py-1.5 text-xs font-medium rounded-full border ${fechaEntrega === fechaHaceDias(-1) ? 'bg-blue-600 text-white border-blue-600' : 'bg-white text-blue-700 border-blue-200'}`}
                    >
                      Mañana
                    </button>
                  </div>
                  <span className="text-xs text-blue-700">
                    El transportista la verá el {formatFecha(fechaEntrega)}.
                  </span>
                </div>
              </div>

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
                          inputMode="decimal"
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
                          inputMode="decimal"
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
                        {depositoGuardado ? <Check className="w-4 h-4" /> : <Save className="w-4 h-4" />}
                        <span>{depositoGuardado ? 'Guardado!' : 'Guardar'}</span>
                      </button>
                    </div>
                  </div>
                )}
              </div>

              {/* Filtro de fecha: excluye pedidos viejos aún 'asignado' (la
                  rendición se controla con rezago) al armar la ruta del día */}
              <div className="bg-white border rounded-lg p-4">
                <label className="block text-sm font-medium mb-2 flex items-center gap-1.5">
                  <CalendarDays className="w-4 h-4 text-gray-500" />
                  Filtrar pedidos por fecha
                </label>
                <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
                  <div>
                    <label className="block text-xs text-gray-500 mb-1">Criterio</label>
                    <select
                      value={filtroCriterio}
                      onChange={(e: ChangeEvent<HTMLSelectElement>) => setFiltroCriterio(e.target.value as 'asignacion' | 'pedido')}
                      className="w-full px-3 py-2 border rounded-lg text-sm"
                    >
                      <option value="asignacion">Fecha de asignación</option>
                      <option value="pedido">Fecha del pedido (creación)</option>
                    </select>
                  </div>
                  <div>
                    <label className="block text-xs text-gray-500 mb-1">Desde</label>
                    <input
                      type="date"
                      value={filtroDesde}
                      onChange={(e: ChangeEvent<HTMLInputElement>) => setFiltroDesde(e.target.value)}
                      className="w-full px-3 py-2 border rounded-lg text-sm"
                    />
                  </div>
                  <div>
                    <label className="block text-xs text-gray-500 mb-1">Hasta</label>
                    <input
                      type="date"
                      value={filtroHasta}
                      onChange={(e: ChangeEvent<HTMLInputElement>) => setFiltroHasta(e.target.value)}
                      className="w-full px-3 py-2 border rounded-lg text-sm"
                    />
                  </div>
                </div>
                <div className="flex items-center gap-2 mt-2">
                  <button
                    type="button"
                    onClick={() => {
                      const hoy = new Date();
                      const f = `${hoy.getFullYear()}-${String(hoy.getMonth() + 1).padStart(2, '0')}-${String(hoy.getDate()).padStart(2, '0')}`;
                      setFiltroDesde(f);
                      setFiltroHasta(f);
                    }}
                    className="px-3 py-1.5 text-xs font-medium rounded-full border border-blue-200 bg-blue-50 text-blue-700 hover:bg-blue-100"
                  >
                    Hoy
                  </button>
                  {filtroActivo && (
                    <button
                      type="button"
                      onClick={() => { setFiltroDesde(''); setFiltroHasta(''); }}
                      className="px-3 py-1.5 text-xs font-medium rounded-full border border-gray-200 bg-gray-50 text-gray-600 hover:bg-gray-100"
                    >
                      Quitar filtro
                    </button>
                  )}
                  {filtroActivo && transportistaSeleccionado && pedidosExcluidosPorFecha > 0 && (
                    <span className="text-xs text-amber-700">
                      {pedidosExcluidosPorFecha} pedido{pedidosExcluidosPorFecha !== 1 ? 's' : ''} del transportista quedan afuera por el filtro
                    </span>
                  )}
                </div>
              </div>

              {/* Selector de transportista */}
              <div className="bg-white border rounded-lg p-4">
                <label className="block text-sm font-medium mb-2">Seleccionar Transportista</label>
                <select
                  value={transportistaSeleccionado}
                  onChange={(e: ChangeEvent<HTMLSelectElement>) => setTransportistaSeleccionado(e.target.value)}
                  className="w-full px-3 py-2 border rounded-lg"
                  disabled={loading}
                >
                  <option value="">Seleccionar transportista...</option>
                  {transportistas.map(t => {
                    const cantPedidos = pedidosFiltrados.filter(p =>
                      p.transportista_id === t.id
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

                  {/* Lista de pedidos: el admin elige cuáles entran en la ruta del día */}
                  {pedidosTransportista.length > 0 && (
                    <div className="bg-white border rounded-lg">
                      <div className="p-3 border-b bg-gray-50 flex items-center justify-between">
                        <h3 className="font-medium text-gray-700">
                          Pedidos del día ({pedidosSeleccionados.length}/{pedidosTransportista.length})
                        </h3>
                        <label className="flex items-center gap-2 text-sm text-gray-600 cursor-pointer select-none">
                          <input type="checkbox" checked={todosSeleccionados} onChange={toggleTodos} className="rounded" />
                          Seleccionar todos
                        </label>
                      </div>
                      <div className="max-h-60 overflow-y-auto divide-y">
                        {pedidosTransportista.map((pedido) => {
                          const checked = seleccionados.has(pedido.id);
                          return (
                            <label
                              key={pedido.id}
                              className={`flex items-center p-3 cursor-pointer ${checked ? 'hover:bg-gray-50' : 'bg-gray-50/60 opacity-60 hover:opacity-100'}`}
                            >
                              <input
                                type="checkbox"
                                checked={checked}
                                onChange={() => toggleSeleccion(pedido.id)}
                                className="rounded mr-3"
                              />
                              <div className="flex-1 min-w-0">
                                <p className="font-medium text-gray-900 truncate">
                                  #{pedido.id} - {pedido.cliente?.nombre_fantasia}
                                </p>
                                <p className="text-sm text-gray-500 truncate">{pedido.cliente?.direccion}</p>
                                <p className="text-xs text-gray-400">
                                  Pedido: {pedido.fecha || '—'}
                                  {pedido.fecha_asignacion ? ` · Asignado: ${pedido.fecha_asignacion}` : ''}
                                </p>
                              </div>
                              <div className="text-right ml-2">
                                <p className="font-medium text-gray-900">${pedido.total?.toLocaleString('es-AR')}</p>
                                {pedido.cliente?.latitud && pedido.cliente?.longitud ? (
                                  <MapPin className="w-4 h-4 text-green-500 inline" />
                                ) : (
                                  <MapPin className="w-4 h-4 text-gray-300 inline" />
                                )}
                              </div>
                            </label>
                          );
                        })}
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
                      <h3 className="font-semibold text-lg">Ruta del día guardada</h3>
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

              {/* Navegación en Google Maps con las paradas ya cargadas */}
              {linksGoogleMaps.length > 0 && (
                <div className="bg-white border rounded-lg p-4">
                  <h3 className="font-medium text-gray-700 mb-1 flex items-center gap-2">
                    <Navigation className="w-5 h-5 text-blue-600" />
                    Abrir ruta en Google Maps
                  </h3>
                  <p className="text-xs text-gray-500 mb-3">
                    Sale del depósito con las paradas en el orden optimizado. Google Maps
                    admite hasta 10 paradas por link
                    {linksGoogleMaps.length > 1
                      ? ': al terminar un tramo, abrí el siguiente (continúa desde la última parada).'
                      : '.'}
                  </p>
                  <div className="flex flex-wrap gap-2">
                    {linksGoogleMaps.map((link, i) => (
                      <a
                        key={link.url}
                        href={link.url}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="inline-flex items-center gap-2 px-4 py-2 bg-blue-600 text-white text-sm rounded-lg hover:bg-blue-700"
                      >
                        <MapPin className="w-4 h-4" />
                        {linksGoogleMaps.length === 1
                          ? 'Abrir ruta completa'
                          : `Tramo ${i + 1} (paradas ${link.desde}-${link.hasta})`}
                      </a>
                    ))}
                  </div>
                </div>
              )}

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
                onClick={handleArmar}
                disabled={!transportistaSeleccionado || loading || guardando || pedidosSeleccionados.length === 0}
                className="flex items-center space-x-2 px-5 py-2.5 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
              >
                {(loading || guardando) ? (
                  <Loader2 className="w-5 h-5 animate-spin" />
                ) : (
                  <Route className="w-5 h-5" />
                )}
                <span>
                  {loading ? 'Optimizando…' : guardando ? 'Guardando…' : `Armar ruta del día (${pedidosSeleccionados.length})`}
                </span>
              </button>
            ) : (
              <button
                onClick={handleExportarPDF}
                className="flex items-center space-x-2 px-4 py-2.5 bg-gray-600 text-white rounded-lg hover:bg-gray-700 transition-colors"
              >
                <Printer className="w-5 h-5" />
                <span>Exportar PDF</span>
              </button>
            )}
          </div>
        </div>
      </div>
    </ModalBase>
  );
});

export default ModalGestionRutas;
