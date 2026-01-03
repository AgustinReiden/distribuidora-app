import React, { useState, useMemo } from 'react';
import { Users, Plus, Edit2, Trash2, Search, MapPin, Phone, Map } from 'lucide-react';
import LoadingSpinner from '../layout/LoadingSpinner';

export default function VistaClientes({
  clientes,
  loading,
  isAdmin,
  isPreventista,
  onNuevoCliente,
  onEditarCliente,
  onEliminarCliente
}) {
  const [busqueda, setBusqueda] = useState('');
  const [filtroZona, setFiltroZona] = useState('todas');

  // Obtener zonas únicas
  const zonas = useMemo(() => {
    const zonasSet = new Set(clientes.map(c => c.zona).filter(Boolean));
    return ['todas', ...Array.from(zonasSet).sort()];
  }, [clientes]);

  // Filtrar clientes
  const clientesFiltrados = useMemo(() => {
    return clientes.filter(c => {
      const matchBusqueda = !busqueda ||
        c.nombre_fantasia?.toLowerCase().includes(busqueda.toLowerCase()) ||
        c.nombre?.toLowerCase().includes(busqueda.toLowerCase()) ||
        c.direccion?.toLowerCase().includes(busqueda.toLowerCase()) ||
        c.telefono?.includes(busqueda);

      const matchZona = filtroZona === 'todas' || c.zona === filtroZona;

      return matchBusqueda && matchZona;
    });
  }, [clientes, busqueda, filtroZona]);

  return (
    <div className="space-y-4">
      {/* Header */}
      <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        <div>
          <h1 className="text-2xl font-bold text-gray-800 dark:text-white">Clientes</h1>
          <p className="text-sm text-gray-500 dark:text-gray-400">{clientes.length} clientes registrados</p>
        </div>
        {(isAdmin || isPreventista) && (
          <button
            onClick={onNuevoCliente}
            className="flex items-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors"
          >
            <Plus className="w-5 h-5" />
            <span>Nuevo Cliente</span>
          </button>
        )}
      </div>

      {/* Filtros */}
      <div className="flex flex-col sm:flex-row gap-4">
        <div className="relative flex-1">
          <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 w-5 h-5" />
          <input
            type="text"
            value={busqueda}
            onChange={e => setBusqueda(e.target.value)}
            className="w-full pl-10 pr-3 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white"
            placeholder="Buscar por nombre, dirección o teléfono..."
          />
        </div>
        {zonas.length > 1 && (
          <select
            value={filtroZona}
            onChange={e => setFiltroZona(e.target.value)}
            className="px-4 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500"
          >
            {zonas.map(zona => (
              <option key={zona} value={zona}>
                {zona === 'todas' ? 'Todas las zonas' : zona}
              </option>
            ))}
          </select>
        )}
      </div>

      {/* Contador de resultados */}
      {(busqueda || filtroZona !== 'todas') && (
        <div className="text-sm text-gray-600">
          Mostrando {clientesFiltrados.length} de {clientes.length} clientes
        </div>
      )}

      {/* Lista de clientes */}
      {loading ? <LoadingSpinner /> : clientesFiltrados.length === 0 ? (
        <div className="text-center py-12 text-gray-500">
          <Users className="w-12 h-12 mx-auto mb-3 opacity-50" />
          <p>{busqueda || filtroZona !== 'todas' ? 'No se encontraron clientes con esos criterios' : 'No hay clientes'}</p>
        </div>
      ) : (
        <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
          {clientesFiltrados.map(cliente => (
            <div
              key={cliente.id}
              className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm p-4 hover:shadow-md transition-shadow"
            >
              <div className="flex justify-between items-start">
                <div className="flex-1 min-w-0">
                  <h3 className="font-semibold text-lg text-gray-800 dark:text-white truncate">
                    {cliente.nombre_fantasia}
                  </h3>
                  <p className="text-sm text-gray-600 dark:text-gray-400 truncate">{cliente.nombre}</p>
                </div>
                {isAdmin && (
                  <div className="flex space-x-1 ml-2">
                    <button
                      onClick={() => onEditarCliente(cliente)}
                      className="p-2 text-blue-500 hover:bg-blue-50 rounded-lg transition-colors"
                      title="Editar"
                    >
                      <Edit2 className="w-4 h-4" />
                    </button>
                    <button
                      onClick={() => onEliminarCliente(cliente.id)}
                      className="p-2 text-red-500 hover:bg-red-50 rounded-lg transition-colors"
                      title="Eliminar"
                    >
                      <Trash2 className="w-4 h-4" />
                    </button>
                  </div>
                )}
              </div>

              <div className="mt-3 space-y-2 text-sm text-gray-500 dark:text-gray-400">
                <div className="flex items-start space-x-2">
                  <MapPin className="w-4 h-4 mt-0.5 flex-shrink-0 text-gray-400 dark:text-gray-500" />
                  <span className="break-words">{cliente.direccion}</span>
                </div>
                {cliente.telefono && (
                  <div className="flex items-center space-x-2">
                    <Phone className="w-4 h-4 flex-shrink-0 text-gray-400" />
                    <a
                      href={`tel:${cliente.telefono}`}
                      className="text-blue-600 hover:underline"
                    >
                      {cliente.telefono}
                    </a>
                  </div>
                )}
                {cliente.zona && (
                  <div className="flex items-center space-x-2">
                    <Map className="w-4 h-4 flex-shrink-0 text-gray-400" />
                    <span className="px-2 py-0.5 bg-gray-100 dark:bg-gray-700 rounded-full text-xs">
                      {cliente.zona}
                    </span>
                  </div>
                )}
              </div>

              {/* Indicador de coordenadas */}
              {cliente.latitud && cliente.longitud && (
                <div className="mt-3 pt-2 border-t">
                  <span className="text-xs text-green-600 flex items-center">
                    <MapPin className="w-3 h-3 mr-1" />
                    Ubicación geocodificada
                  </span>
                </div>
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
