import React, { useState, useMemo } from 'react';
import { Building2, Plus, Search, Edit2, Trash2, Phone, Mail, MapPin, ToggleLeft, ToggleRight, ShoppingBag, FileText } from 'lucide-react';
import LoadingSpinner from '../layout/LoadingSpinner';

export default function VistaProveedores({
  proveedores,
  compras,
  loading,
  isAdmin,
  onNuevoProveedor,
  onEditarProveedor,
  onEliminarProveedor,
  onToggleActivo
}) {
  const [busqueda, setBusqueda] = useState('');
  const [filtroActivo, setFiltroActivo] = useState('todos');

  // Estadísticas por proveedor
  const estadisticasProveedores = useMemo(() => {
    const stats = {};
    (compras || []).forEach(compra => {
      const proveedorId = compra.proveedor_id;
      if (proveedorId) {
        if (!stats[proveedorId]) {
          stats[proveedorId] = { totalCompras: 0, montoTotal: 0, ultimaCompra: null };
        }
        stats[proveedorId].totalCompras += 1;
        stats[proveedorId].montoTotal += compra.total || 0;
        const fechaCompra = new Date(compra.fecha_compra);
        if (!stats[proveedorId].ultimaCompra || fechaCompra > stats[proveedorId].ultimaCompra) {
          stats[proveedorId].ultimaCompra = fechaCompra;
        }
      }
    });
    return stats;
  }, [compras]);

  // Filtrar proveedores
  const proveedoresFiltrados = useMemo(() => {
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

  // Resumen general
  const resumen = useMemo(() => ({
    total: proveedores.length,
    activos: proveedores.filter(p => p.activo !== false).length,
    inactivos: proveedores.filter(p => p.activo === false).length
  }), [proveedores]);

  const formatPrecio = (precio) => {
    return new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS' }).format(precio || 0);
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
          <button
            onClick={onNuevoProveedor}
            className="flex items-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors"
          >
            <Plus className="w-5 h-5" />
            <span>Nuevo Proveedor</span>
          </button>
        )}
      </div>

      {/* Estadísticas rápidas */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        <div
          onClick={() => setFiltroActivo('todos')}
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
          onClick={() => setFiltroActivo('activos')}
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
          onClick={() => setFiltroActivo('inactivos')}
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
          onChange={e => setBusqueda(e.target.value)}
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
            <button
              onClick={onNuevoProveedor}
              className="mt-4 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors"
            >
              Agregar primer proveedor
            </button>
          )}
        </div>
      ) : (
        <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
          {proveedoresFiltrados.map(proveedor => {
            const stats = estadisticasProveedores[proveedor.id] || {};
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
                        Última: {stats.ultimaCompra.toLocaleDateString('es-AR')}
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
                    <button
                      onClick={() => onEditarProveedor(proveedor)}
                      className="p-2 text-blue-500 hover:bg-blue-50 dark:hover:bg-blue-900/30 rounded-lg transition-colors"
                      title="Editar"
                    >
                      <Edit2 className="w-4 h-4" />
                    </button>
                    <button
                      onClick={() => onEliminarProveedor(proveedor.id)}
                      className="p-2 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/30 rounded-lg transition-colors"
                      title="Eliminar"
                    >
                      <Trash2 className="w-4 h-4" />
                    </button>
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
