import React, { useState, useMemo, ChangeEvent } from 'react';
import { ShoppingCart, Plus, Search, Eye, Calendar, Building2, Package, DollarSign, XCircle } from 'lucide-react';
import { formatPrecio } from '../../utils/formatters';
import LoadingSpinner from '../layout/LoadingSpinner';
import type { CompraDBExtended, ProveedorDBExtended, CompraItemDBExtended } from '../../types';

// =============================================================================
// CONSTANTES Y TIPOS
// =============================================================================

type EstadoCompra = 'pendiente' | 'recibida' | 'parcial' | 'cancelada';
type FiltroEstado = 'todos' | EstadoCompra;

interface EstadoConfig {
  label: string;
  color: string;
}

const ESTADOS_COMPRA: Record<EstadoCompra, EstadoConfig> = {
  pendiente: { label: 'Pendiente', color: 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-400' },
  recibida: { label: 'Recibida', color: 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400' },
  parcial: { label: 'Parcial', color: 'bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-400' },
  cancelada: { label: 'Cancelada', color: 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-400' }
};

// =============================================================================
// INTERFACES DE PROPS
// =============================================================================

export interface VistaComprasProps {
  compras: CompraDBExtended[];
  proveedores: ProveedorDBExtended[];
  loading: boolean;
  isAdmin: boolean;
  onNuevaCompra: () => void;
  onVerDetalle: (compra: CompraDBExtended) => void;
  onAnularCompra: (compraId: string) => void;
  resumen?: ResumenCompras | null;
}

interface ResumenCompras {
  totalCompras?: number;
  montoTotal?: number;
  unidadesTotales?: number;
  proveedoresUnicos?: number;
}

interface EstadisticasCompras {
  totalCompras: number;
  montoTotal: number;
  unidadesTotales: number;
  proveedoresUnicos: number;
}

// =============================================================================
// COMPONENTE PRINCIPAL
// =============================================================================

export default function VistaCompras({
  compras,
  proveedores,
  loading,
  isAdmin,
  onNuevaCompra,
  onVerDetalle,
  onAnularCompra,
  resumen: _resumen
}: VistaComprasProps): React.ReactElement {
  const [busqueda, setBusqueda] = useState<string>('');
  const [filtroEstado, setFiltroEstado] = useState<FiltroEstado>('todos');
  const [filtroProveedor, setFiltroProveedor] = useState<string>('');
  const [filtroFechaDesde, setFiltroFechaDesde] = useState<string>('');
  const [filtroFechaHasta, setFiltroFechaHasta] = useState<string>('');

  // Estadísticas
  const estadisticas = useMemo<EstadisticasCompras>(() => {
    const comprasActivas = compras.filter(c => c.estado !== 'cancelada');
    return {
      totalCompras: comprasActivas.length,
      montoTotal: comprasActivas.reduce((sum, c) => sum + (c.total || 0), 0),
      unidadesTotales: comprasActivas.reduce((sum, c) =>
        sum + (c.items || []).reduce((s: number, i: CompraItemDBExtended) => s + i.cantidad, 0), 0
      ),
      proveedoresUnicos: new Set(comprasActivas.map(c => c.proveedor_id || c.proveedor_nombre).filter(Boolean)).size
    };
  }, [compras]);

  // Filtrar compras
  const comprasFiltradas = useMemo<CompraDBExtended[]>(() => {
    return compras.filter(c => {
      // Busqueda por numero de factura o proveedor
      const matchBusqueda = !busqueda ||
        c.numero_factura?.toLowerCase().includes(busqueda.toLowerCase()) ||
        c.proveedor?.nombre?.toLowerCase().includes(busqueda.toLowerCase()) ||
        c.proveedor_nombre?.toLowerCase().includes(busqueda.toLowerCase());

      // Filtro por estado
      const matchEstado = filtroEstado === 'todos' || c.estado === filtroEstado;

      // Filtro por proveedor
      const matchProveedor = !filtroProveedor ||
        c.proveedor_id === filtroProveedor ||
        c.proveedor?.id === filtroProveedor;

      // Filtro por fecha
      const fechaCompra = c.fecha_compra || c.created_at || '';
      const matchFechaDesde = !filtroFechaDesde || fechaCompra >= filtroFechaDesde;
      const matchFechaHasta = !filtroFechaHasta || fechaCompra <= filtroFechaHasta;

      return matchBusqueda && matchEstado && matchProveedor && matchFechaDesde && matchFechaHasta;
    });
  }, [compras, busqueda, filtroEstado, filtroProveedor, filtroFechaDesde, filtroFechaHasta]);

  // Limpiar filtros
  const limpiarFiltros = (): void => {
    setBusqueda('');
    setFiltroEstado('todos');
    setFiltroProveedor('');
    setFiltroFechaDesde('');
    setFiltroFechaHasta('');
  };

  const hayFiltrosActivos = busqueda || filtroEstado !== 'todos' || filtroProveedor || filtroFechaDesde || filtroFechaHasta;

  const handleBusquedaChange = (e: ChangeEvent<HTMLInputElement>): void => {
    setBusqueda(e.target.value);
  };

  const handleEstadoChange = (e: ChangeEvent<HTMLSelectElement>): void => {
    setFiltroEstado(e.target.value as FiltroEstado);
  };

  const handleProveedorChange = (e: ChangeEvent<HTMLSelectElement>): void => {
    setFiltroProveedor(e.target.value);
  };

  const handleFechaDesdeChange = (e: ChangeEvent<HTMLInputElement>): void => {
    setFiltroFechaDesde(e.target.value);
  };

  const handleFechaHastaChange = (e: ChangeEvent<HTMLInputElement>): void => {
    setFiltroFechaHasta(e.target.value);
  };

  return (
    <div className="space-y-4">
      {/* Header */}
      <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        <div>
          <h1 className="text-2xl font-bold text-gray-800 dark:text-white">Compras</h1>
          <p className="text-sm text-gray-500 dark:text-gray-400">Gestion de compras a proveedores</p>
        </div>
        {isAdmin && (
          <button
            onClick={onNuevaCompra}
            className="flex items-center space-x-2 px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 transition-colors"
          >
            <Plus className="w-5 h-5" />
            <span>Nueva Compra</span>
          </button>
        )}
      </div>

      {/* Estadísticas */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <div className="bg-white dark:bg-gray-800 rounded-lg p-4 border dark:border-gray-700">
          <div className="flex items-center gap-3">
            <div className="p-2 bg-green-100 dark:bg-green-900/30 rounded-lg">
              <ShoppingCart className="w-5 h-5 text-green-600" />
            </div>
            <div>
              <p className="text-2xl font-bold text-gray-800 dark:text-white">{estadisticas.totalCompras}</p>
              <p className="text-xs text-gray-500">Compras</p>
            </div>
          </div>
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-lg p-4 border dark:border-gray-700">
          <div className="flex items-center gap-3">
            <div className="p-2 bg-blue-100 dark:bg-blue-900/30 rounded-lg">
              <DollarSign className="w-5 h-5 text-blue-600" />
            </div>
            <div>
              <p className="text-2xl font-bold text-gray-800 dark:text-white">{formatPrecio(estadisticas.montoTotal)}</p>
              <p className="text-xs text-gray-500">Total invertido</p>
            </div>
          </div>
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-lg p-4 border dark:border-gray-700">
          <div className="flex items-center gap-3">
            <div className="p-2 bg-purple-100 dark:bg-purple-900/30 rounded-lg">
              <Package className="w-5 h-5 text-purple-600" />
            </div>
            <div>
              <p className="text-2xl font-bold text-gray-800 dark:text-white">{estadisticas.unidadesTotales}</p>
              <p className="text-xs text-gray-500">Unidades compradas</p>
            </div>
          </div>
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-lg p-4 border dark:border-gray-700">
          <div className="flex items-center gap-3">
            <div className="p-2 bg-orange-100 dark:bg-orange-900/30 rounded-lg">
              <Building2 className="w-5 h-5 text-orange-600" />
            </div>
            <div>
              <p className="text-2xl font-bold text-gray-800 dark:text-white">{estadisticas.proveedoresUnicos}</p>
              <p className="text-xs text-gray-500">Proveedores</p>
            </div>
          </div>
        </div>
      </div>

      {/* Filtros */}
      <div className="bg-white dark:bg-gray-800 rounded-lg p-4 border dark:border-gray-700 space-y-4">
        {/* Busqueda */}
        <div className="relative">
          <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 dark:text-gray-500 w-5 h-5" />
          <input
            type="text"
            value={busqueda}
            onChange={handleBusquedaChange}
            className="w-full pl-10 pr-3 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:ring-2 focus:ring-green-500"
            placeholder="Buscar por factura o proveedor..."
          />
        </div>

        {/* Filtros en grid responsive */}
        <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
          {/* Filtro por estado */}
          <select
            value={filtroEstado}
            onChange={handleEstadoChange}
            className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:ring-2 focus:ring-green-500 text-sm"
          >
            <option value="todos">Todos estados</option>
            {Object.entries(ESTADOS_COMPRA).map(([key, { label }]) => (
              <option key={key} value={key}>{label}</option>
            ))}
          </select>

          {/* Filtro por proveedor */}
          <select
            value={filtroProveedor}
            onChange={handleProveedorChange}
            className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:ring-2 focus:ring-green-500 text-sm"
          >
            <option value="">Todos proveedores</option>
            {proveedores.map(p => (
              <option key={p.id} value={p.id}>{p.nombre}</option>
            ))}
          </select>

          {/* Fecha desde */}
          <div>
            <label className="block text-xs font-medium text-gray-500 mb-1">Desde</label>
            <input
              type="date"
              value={filtroFechaDesde}
              onChange={handleFechaDesdeChange}
              className="w-full px-2 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:ring-2 focus:ring-green-500 text-sm"
            />
          </div>

          {/* Fecha hasta */}
          <div>
            <label className="block text-xs font-medium text-gray-500 mb-1">Hasta</label>
            <input
              type="date"
              value={filtroFechaHasta}
              onChange={handleFechaHastaChange}
              className="w-full px-2 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:ring-2 focus:ring-green-500 text-sm"
            />
          </div>
        </div>

        {/* Boton limpiar */}
        {hayFiltrosActivos && (
          <button
            onClick={limpiarFiltros}
            className="w-full md:w-auto px-4 py-2 text-gray-500 hover:text-gray-700 dark:hover:text-gray-300 flex items-center justify-center gap-1 border dark:border-gray-600 rounded-lg"
          >
            <XCircle className="w-4 h-4" />
            Limpiar filtros
          </button>
        )}
      </div>

      {/* Contador de resultados */}
      {hayFiltrosActivos && (
        <div className="text-sm text-gray-600 dark:text-gray-400">
          Mostrando {comprasFiltradas.length} de {compras.length} compras
        </div>
      )}

      {/* Lista de compras */}
      {loading ? <LoadingSpinner /> : comprasFiltradas.length === 0 ? (
        <div className="text-center py-12 text-gray-500 dark:text-gray-400 bg-white dark:bg-gray-800 rounded-lg border dark:border-gray-700">
          <ShoppingCart className="w-12 h-12 mx-auto mb-3 opacity-50" />
          <p>{hayFiltrosActivos ? 'No se encontraron compras con los filtros aplicados' : 'No hay compras registradas'}</p>
          {isAdmin && !hayFiltrosActivos && (
            <button
              onClick={onNuevaCompra}
              className="mt-4 px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 transition-colors"
            >
              Registrar primera compra
            </button>
          )}
        </div>
      ) : (
        <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm overflow-x-auto">
          <table className="w-full">
            <thead className="bg-gray-50 dark:bg-gray-700/50">
              <tr>
                <th className="px-4 py-3 text-left text-sm font-medium text-gray-700 dark:text-gray-300">Fecha</th>
                <th className="px-4 py-3 text-left text-sm font-medium text-gray-700 dark:text-gray-300">Proveedor</th>
                <th className="px-4 py-3 text-left text-sm font-medium text-gray-700 dark:text-gray-300">N Factura</th>
                <th className="px-4 py-3 text-center text-sm font-medium text-gray-700 dark:text-gray-300">Items</th>
                <th className="px-4 py-3 text-center text-sm font-medium text-gray-700 dark:text-gray-300">Estado</th>
                <th className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">Total</th>
                <th className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">Acciones</th>
              </tr>
            </thead>
            <tbody className="divide-y dark:divide-gray-700">
              {comprasFiltradas.map(compra => {
                const estadoKey = (compra.estado || 'pendiente') as EstadoCompra;
                const estado = ESTADOS_COMPRA[estadoKey] || ESTADOS_COMPRA.pendiente;
                const totalItems = (compra.items || []).reduce((sum: number, i: CompraItemDBExtended) => sum + i.cantidad, 0);

                return (
                  <tr key={compra.id} className="hover:bg-gray-50 dark:hover:bg-gray-700/50 transition-colors">
                    <td className="px-4 py-3">
                      <div className="flex items-center gap-2">
                        <Calendar className="w-4 h-4 text-gray-400" />
                        <span className="text-gray-800 dark:text-white">
                          {new Date(compra.fecha_compra || compra.created_at || '').toLocaleDateString('es-AR')}
                        </span>
                      </div>
                    </td>
                    <td className="px-4 py-3">
                      <div className="flex items-center gap-2">
                        <Building2 className="w-4 h-4 text-gray-400" />
                        <span className="font-medium text-gray-800 dark:text-white">
                          {compra.proveedor?.nombre || compra.proveedor_nombre || 'Sin proveedor'}
                        </span>
                      </div>
                    </td>
                    <td className="px-4 py-3 text-gray-500 dark:text-gray-400 font-mono text-sm">
                      {compra.numero_factura || '-'}
                    </td>
                    <td className="px-4 py-3 text-center">
                      <div className="flex items-center justify-center gap-1">
                        <Package className="w-4 h-4 text-gray-400" />
                        <span className="text-gray-800 dark:text-white">{totalItems}</span>
                      </div>
                    </td>
                    <td className="px-4 py-3 text-center">
                      <span className={`px-2 py-1 rounded-full text-xs font-medium ${estado.color}`}>
                        {estado.label}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-right">
                      <span className="font-semibold text-green-600 dark:text-green-400">
                        {formatPrecio(compra.total)}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-right">
                      <div className="flex justify-end gap-1">
                        <button
                          onClick={() => onVerDetalle(compra)}
                          className="p-2 text-blue-500 hover:bg-blue-50 dark:hover:bg-blue-900/30 rounded-lg transition-colors"
                          title="Ver detalle"
                        >
                          <Eye className="w-4 h-4" />
                        </button>
                        {isAdmin && compra.estado !== 'cancelada' && (
                          <button
                            onClick={() => onAnularCompra(compra.id)}
                            className="p-2 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/30 rounded-lg transition-colors"
                            title="Anular compra"
                          >
                            <XCircle className="w-4 h-4" />
                          </button>
                        )}
                      </div>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
