import React, { useState, useMemo, ChangeEvent } from 'react';
import { Building2, Plus, Search, Edit2, Trash2, Phone, Mail, MapPin, ToggleLeft, ToggleRight, ShoppingBag, FileText, BadgePercent } from 'lucide-react';
import { Button } from '../ui/Button';
import LoadingSpinner from '../layout/LoadingSpinner';
import Paginacion from '../layout/Paginacion';
import { formatPrecio } from '../../utils/formatters';
import type { ProveedorDBExtended, CompraDBExtended } from '../../types';

const ITEMS_PER_PAGE = 15;

// =============================================================================
// INTERFACES DE PROPS
// =============================================================================

export interface VistaProveedoresProps {
  proveedores: ProveedorDBExtended[];
  compras: CompraDBExtended[];
  loading: boolean;
  isAdmin: boolean;
  onNuevoProveedor: () => void;
  onEditarProveedor: (proveedor: ProveedorDBExtended) => void;
  onEliminarProveedor: (id: string) => void;
  onToggleActivo: (proveedor: ProveedorDBExtended) => void;
  /** #908: promociones de compra del proveedor. Sin la prop, no hay botón. */
  onPromocionesProveedor?: (proveedor: ProveedorDBExtended) => void;
}

interface EstadisticaProveedor {
  totalCompras: number;
  montoTotal: number;
  ultimaCompra: Date | null;
}

type FiltroActivo = 'todos' | 'activos' | 'inactivos';

interface ResumenProveedores {
  total: number;
  activos: number;
  inactivos: number;
}

// =============================================================================
// COMPONENTE PRINCIPAL
// =============================================================================

export default function VistaProveedores({
  proveedores,
  compras,
  loading,
  isAdmin,
  onNuevoProveedor,
  onEditarProveedor,
  onEliminarProveedor,
  onToggleActivo,
  onPromocionesProveedor
}: VistaProveedoresProps): React.ReactElement {
  const [busqueda, setBusqueda] = useState<string>('');
  const [filtroActivo, setFiltroActivo] = useState<FiltroActivo>('todos');
  const [paginaActual, setPaginaActual] = useState(1);

  // Estadísticas por proveedor
  const estadisticasProveedores = useMemo<Record<string, EstadisticaProveedor>>(() => {
    const stats: Record<string, EstadisticaProveedor> = {};
    (compras || []).forEach(compra => {
      const proveedorId = compra.proveedor_id;
      if (proveedorId) {
        if (!stats[proveedorId]) {
          stats[proveedorId] = { totalCompras: 0, montoTotal: 0, ultimaCompra: null };
        }
        stats[proveedorId].totalCompras += 1;
        stats[proveedorId].montoTotal += compra.total || 0;
        const fechaCompra = new Date(compra.fecha_compra || compra.created_at || '');
        if (!stats[proveedorId].ultimaCompra || fechaCompra > stats[proveedorId].ultimaCompra) {
          stats[proveedorId].ultimaCompra = fechaCompra;
        }
      }
    });
    return stats;
  }, [compras]);

  // Filtrar proveedores
  const proveedoresFiltrados = useMemo<ProveedorDBExtended[]>(() => {
    return proveedores.filter(p => {
      const matchBusqueda = !busqueda ||
        p.nombre?.toLowerCase().includes(busqueda.toLowerCase()) ||
        p.cuit?.toLowerCase().includes(busqueda.toLowerCase()) ||
        p.contacto?.toLowerCase().includes(busqueda.toLowerCase());

      const matchActivo = filtroActivo === 'todos' ||
        (filtroActivo === 'activos' && p.activo !== false) ||
        (filtroActivo === 'inactivos' && p.activo === false);

      return matchBusqueda && matchActivo;
    });
  }, [proveedores, busqueda, filtroActivo]);

  // Pagination. La query trae todos los proveedores: se pagina acá, sobre la
  // lista ya filtrada, así el total que cuenta Paginacion es el del filtro.
  const totalPaginas = Math.ceil(proveedoresFiltrados.length / ITEMS_PER_PAGE);
  // Si la lista se achica (se borró el último de la última página) la página
  // guardada puede quedar más allá del final: se recorta en vez de mostrar una
  // página vacía y sin control para volver.
  const pagina = Math.min(paginaActual, Math.max(1, totalPaginas));
  const proveedoresPaginados = useMemo<ProveedorDBExtended[]>(() => {
    const inicio = (pagina - 1) * ITEMS_PER_PAGE;
    return proveedoresFiltrados.slice(inicio, inicio + ITEMS_PER_PAGE);
  }, [proveedoresFiltrados, pagina]);

  // Resumen general
  const resumen = useMemo<ResumenProveedores>(() => ({
    total: proveedores.length,
    activos: proveedores.filter(p => p.activo !== false).length,
    inactivos: proveedores.filter(p => p.activo === false).length
  }), [proveedores]);

  const handleBusquedaChange = (e: ChangeEvent<HTMLInputElement>): void => {
    setBusqueda(e.target.value);
    setPaginaActual(1);
  };

  const handleFiltroActivo = (filtro: FiltroActivo): void => {
    setFiltroActivo(filtro);
    setPaginaActual(1);
  };

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        <div>
          <h1 className="text-2xl font-bold text-gray-800 dark:text-white">Proveedores</h1>
          <p className="text-sm text-gray-500 dark:text-gray-400">
            {resumen.activos} activos de {resumen.total} proveedores
          </p>
        </div>
        {isAdmin && (
          <Button
            onClick={onNuevoProveedor}
            variant="primary"
            size="md"
          >
            <Plus className="w-5 h-5" />
            <span>Nuevo Proveedor</span>
          </Button>
        )}
      </div>

      {/* Estadísticas rápidas */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        <div
          onClick={() => handleFiltroActivo('todos')}
          className={`bg-white dark:bg-gray-800 rounded-lg p-4 border dark:border-gray-700 cursor-pointer transition-all ${
            filtroActivo === 'todos' ? 'ring-2 ring-blue-500' : 'hover:border-blue-300'
          }`}
        >
          <div className="flex items-center gap-3">
            <div className="p-2 bg-blue-100 dark:bg-blue-900/30 rounded-lg">
              <Building2 className="w-5 h-5 text-blue-600" />
            </div>
            <div>
              <p className="text-2xl font-bold text-gray-800 dark:text-white">{resumen.total}</p>
              <p className="text-xs text-gray-500">Total proveedores</p>
            </div>
          </div>
        </div>
        <div
          onClick={() => handleFiltroActivo('activos')}
          className={`bg-white dark:bg-gray-800 rounded-lg p-4 border dark:border-gray-700 cursor-pointer transition-all ${
            filtroActivo === 'activos' ? 'ring-2 ring-green-500' : 'hover:border-green-300'
          }`}
        >
          <div className="flex items-center gap-3">
            <div className="p-2 bg-green-100 dark:bg-green-900/30 rounded-lg">
              <ToggleRight className="w-5 h-5 text-green-600" />
            </div>
            <div>
              <p className="text-2xl font-bold text-gray-800 dark:text-white">{resumen.activos}</p>
              <p className="text-xs text-gray-500">Activos</p>
            </div>
          </div>
        </div>
        <div
          onClick={() => handleFiltroActivo('inactivos')}
          className={`bg-white dark:bg-gray-800 rounded-lg p-4 border dark:border-gray-700 cursor-pointer transition-all ${
            filtroActivo === 'inactivos' ? 'ring-2 ring-gray-500' : 'hover:border-gray-400'
          }`}
        >
          <div className="flex items-center gap-3">
            <div className="p-2 bg-gray-100 dark:bg-gray-700 rounded-lg">
              <ToggleLeft className="w-5 h-5 text-gray-500" />
            </div>
            <div>
              <p className="text-2xl font-bold text-gray-800 dark:text-white">{resumen.inactivos}</p>
              <p className="text-xs text-gray-500">Inactivos</p>
            </div>
          </div>
        </div>
      </div>

      {/* Buscador */}
      <div className="relative">
        <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 w-5 h-5" />
        <input
          type="text"
          value={busqueda}
          onChange={handleBusquedaChange}
          className="w-full pl-10 pr-4 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:ring-2 focus:ring-blue-500"
          placeholder="Buscar por nombre, CUIT o contacto..."
        />
      </div>

      {/* Lista de proveedores */}
      {loading ? <LoadingSpinner /> : proveedoresFiltrados.length === 0 ? (
        <div className="text-center py-12 bg-white dark:bg-gray-800 rounded-lg border dark:border-gray-700">
          <Building2 className="w-12 h-12 mx-auto mb-3 text-gray-400 opacity-50" />
          <p className="text-gray-500 dark:text-gray-400">
            {busqueda || filtroActivo !== 'todos' ? 'No se encontraron proveedores' : 'No hay proveedores registrados'}
          </p>
          {isAdmin && !busqueda && filtroActivo === 'todos' && (
            <Button
              onClick={onNuevoProveedor}
              variant="primary"
              size="md"
              className="mt-4"
            >
              Agregar primer proveedor
            </Button>
          )}
        </div>
      ) : (
        <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
          {proveedoresPaginados.map(proveedor => {
            const stats = estadisticasProveedores[proveedor.id] || { totalCompras: 0, montoTotal: 0, ultimaCompra: null };
            const esActivo = proveedor.activo !== false;

            return (
              <div
                key={proveedor.id}
                className={`bg-white dark:bg-gray-800 rounded-xl border dark:border-gray-700 overflow-hidden transition-all hover:shadow-lg ${
                  !esActivo ? 'opacity-60' : ''
                }`}
              >
                {/* Header del card */}
                <div className={`p-4 ${esActivo ? 'bg-gradient-to-r from-blue-500 to-blue-600' : 'bg-gray-400'}`}>
                  <div className="flex items-start justify-between">
                    <div className="flex items-center gap-3">
                      <div className="p-2 bg-white/20 rounded-lg">
                        <Building2 className="w-6 h-6 text-white" />
                      </div>
                      <div>
                        <h3 className="font-semibold text-white truncate max-w-[180px]">
                          {proveedor.nombre}
                        </h3>
                        {proveedor.cuit && (
                          <p className="text-sm text-white/80">CUIT: {proveedor.cuit}</p>
                        )}
                      </div>
                    </div>
                    {!esActivo && (
                      <span className="px-2 py-1 bg-white/20 rounded text-xs text-white">
                        Inactivo
                      </span>
                    )}
                  </div>
                </div>

                {/* Contenido del card */}
                <div className="p-4 space-y-3">
                  {/* Contacto */}
                  {proveedor.contacto && (
                    <div className="flex items-center gap-2 text-sm text-gray-600 dark:text-gray-400">
                      <FileText className="w-4 h-4 flex-shrink-0" />
                      <span className="truncate">{proveedor.contacto}</span>
                    </div>
                  )}

                  {proveedor.telefono && (
                    <div className="flex items-center gap-2 text-sm text-gray-600 dark:text-gray-400">
                      <Phone className="w-4 h-4 flex-shrink-0" />
                      <span>{proveedor.telefono}</span>
                    </div>
                  )}

                  {proveedor.email && (
                    <div className="flex items-center gap-2 text-sm text-gray-600 dark:text-gray-400">
                      <Mail className="w-4 h-4 flex-shrink-0" />
                      <span className="truncate">{proveedor.email}</span>
                    </div>
                  )}

                  {proveedor.direccion && (
                    <div className="flex items-center gap-2 text-sm text-gray-600 dark:text-gray-400">
                      <MapPin className="w-4 h-4 flex-shrink-0" />
                      <span className="truncate">{proveedor.direccion}</span>
                    </div>
                  )}

                  {/* Estadísticas de compras */}
                  <div className="pt-3 border-t dark:border-gray-700">
                    <div className="flex items-center justify-between text-sm">
                      <div className="flex items-center gap-1 text-gray-500">
                        <ShoppingBag className="w-4 h-4" />
                        <span>{stats.totalCompras || 0} compras</span>
                      </div>
                      <span className="font-medium text-green-600">
                        {formatPrecio(stats.montoTotal)}
                      </span>
                    </div>
                    {stats.ultimaCompra && (
                      <p className="text-xs text-gray-400 mt-1">
                        Ultima: {stats.ultimaCompra.toLocaleDateString('es-AR')}
                      </p>
                    )}
                  </div>

                  {/* Notas */}
                  {proveedor.notas && (
                    <div className="pt-2 border-t dark:border-gray-700">
                      <p className="text-xs text-gray-500 dark:text-gray-400 line-clamp-2">
                        {proveedor.notas}
                      </p>
                    </div>
                  )}
                </div>

                {/* Acciones */}
                {isAdmin && (
                  <div className="px-4 pb-4 flex gap-2">
                    <button
                      onClick={() => onToggleActivo(proveedor)}
                      className={`flex-1 flex items-center justify-center gap-1 px-3 py-2 rounded-lg text-sm transition-colors ${
                        esActivo
                          ? 'bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-400 hover:bg-gray-200 dark:hover:bg-gray-600'
                          : 'bg-green-100 dark:bg-green-900/30 text-green-600 hover:bg-green-200 dark:hover:bg-green-900/50'
                      }`}
                    >
                      {esActivo ? <ToggleLeft className="w-4 h-4" /> : <ToggleRight className="w-4 h-4" />}
                      {esActivo ? 'Desactivar' : 'Activar'}
                    </button>
                    {onPromocionesProveedor && (
                      <Button
                        onClick={() => onPromocionesProveedor(proveedor)}
                        variant="ghost"
                        size="iconSm"
                        className="text-amber-700 dark:text-amber-400 hover:bg-amber-50 dark:hover:bg-amber-900/30"
                        title="Promociones de compra"
                        aria-label={`Promociones de compra de ${proveedor.nombre}`}
                      >
                        <BadgePercent className="w-4 h-4" />
                      </Button>
                    )}
                    <Button
                      onClick={() => onEditarProveedor(proveedor)}
                      variant="ghost"
                      size="iconSm"
                      className="text-blue-500 dark:text-blue-400 hover:bg-blue-50 dark:hover:bg-blue-900/30"
                      title="Editar"
                    >
                      <Edit2 className="w-4 h-4" />
                    </Button>
                    <Button
                      onClick={() => onEliminarProveedor(proveedor.id)}
                      variant="ghost"
                      size="iconSm"
                      className="text-red-500 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-900/30"
                      title="Eliminar"
                    >
                      <Trash2 className="w-4 h-4" />
                    </Button>
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}

      <Paginacion
        paginaActual={pagina}
        totalPaginas={totalPaginas}
        onPageChange={setPaginaActual}
        totalItems={proveedoresFiltrados.length}
        itemsLabel="proveedores"
      />
    </div>
  );
}
