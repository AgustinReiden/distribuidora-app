import { useState, useMemo } from 'react';
import type { ChangeEvent } from 'react';
import { Users, Plus, Edit2, Trash2, Search, MapPin, Phone, Map, FileText, Tag, Building2 } from 'lucide-react';
import LoadingSpinner from '../layout/LoadingSpinner';
import Paginacion from '../layout/Paginacion';
import type { ClienteDB } from '../../types';

const ITEMS_PER_PAGE = 18;

// =============================================================================
// INTERFACES DE PROPS
// =============================================================================

export interface VistaClientesProps {
  clientes: ClienteDB[];
  loading: boolean;
  isAdmin: boolean;
  isPreventista: boolean;
  onNuevoCliente: () => void;
  onEditarCliente: (cliente: ClienteDB) => void;
  onEliminarCliente: (id: string) => void;
  onVerFichaCliente?: (cliente: ClienteDB) => void;
}

export default function VistaClientes({
  clientes,
  loading,
  isAdmin,
  isPreventista,
  onNuevoCliente,
  onEditarCliente,
  onEliminarCliente,
  onVerFichaCliente
}: VistaClientesProps) {
  const [busqueda, setBusqueda] = useState<string>('');
  const [filtroZona, setFiltroZona] = useState<string>('todas');
  const [paginaActual, setPaginaActual] = useState(1);

  // Obtener zonas únicas
  const zonas = useMemo((): string[] => {
    const zonasSet = new Set<string>(clientes.map(c => c.zona).filter((z): z is string => Boolean(z)));
    return ['todas', ...Array.from(zonasSet).sort()];
  }, [clientes]);

  // Obtener rubros únicos
  const rubros = useMemo((): string[] => {
    const rubrosSet = new Set<string>(clientes.map(c => c.rubro).filter((r): r is string => Boolean(r)));
    return ['todos', ...Array.from(rubrosSet).sort()];
  }, [clientes]);

  const [filtroRubro, setFiltroRubro] = useState<string>('todos');

  // Filtrar clientes
  const clientesFiltrados = useMemo((): ClienteDB[] => {
    return clientes.filter((c: ClienteDB) => {
      const matchBusqueda = !busqueda ||
        c.nombre_fantasia?.toLowerCase().includes(busqueda.toLowerCase()) ||
        c.razon_social?.toLowerCase().includes(busqueda.toLowerCase()) ||
        c.direccion?.toLowerCase().includes(busqueda.toLowerCase()) ||
        c.telefono?.includes(busqueda) ||
        c.cuit?.includes(busqueda.replace(/-/g, '')) ||
        (c.codigo != null && String(c.codigo).includes(busqueda));

      const matchZona = filtroZona === 'todas' || c.zona === filtroZona;
      const matchRubro = filtroRubro === 'todos' || c.rubro === filtroRubro;

      return matchBusqueda && matchZona && matchRubro;
    });
  }, [clientes, busqueda, filtroZona, filtroRubro]);

  // Pagination
  const totalPaginas = Math.ceil(clientesFiltrados.length / ITEMS_PER_PAGE);
  const clientesPaginados = useMemo(() => {
    const inicio = (paginaActual - 1) * ITEMS_PER_PAGE;
    return clientesFiltrados.slice(inicio, inicio + ITEMS_PER_PAGE);
  }, [clientesFiltrados, paginaActual]);

  // Reset page when filters change
  const handleBusqueda = (e: ChangeEvent<HTMLInputElement>) => { setBusqueda(e.target.value); setPaginaActual(1); };
  const handleZona = (e: ChangeEvent<HTMLSelectElement>) => { setFiltroZona(e.target.value); setPaginaActual(1); };
  const handleRubro = (e: ChangeEvent<HTMLSelectElement>) => { setFiltroRubro(e.target.value); setPaginaActual(1); };

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
          <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 w-5 h-5" aria-hidden="true" />
          <input
            type="text"
            value={busqueda}
            onChange={handleBusqueda}
            className="w-full pl-10 pr-3 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white"
            placeholder="Buscar por nombre, CUIT, dirección o teléfono..."
            aria-label="Buscar clientes por nombre, CUIT, dirección o teléfono"
          />
        </div>
        {zonas.length > 1 && (
          <div>
            <label htmlFor="filtro-zona-clientes" className="sr-only">Filtrar clientes por zona</label>
            <select
              id="filtro-zona-clientes"
              value={filtroZona}
              onChange={handleZona}
              className="px-4 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            >
              {zonas.map(zona => (
                <option key={zona} value={zona}>
                  {zona === 'todas' ? 'Todas las zonas' : zona}
                </option>
              ))}
            </select>
          </div>
        )}
        {rubros.length > 1 && (
          <div>
            <label htmlFor="filtro-rubro-clientes" className="sr-only">Filtrar clientes por rubro</label>
            <select
              id="filtro-rubro-clientes"
              value={filtroRubro}
              onChange={handleRubro}
              className="px-4 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            >
              {rubros.map(rubro => (
                <option key={rubro} value={rubro}>
                  {rubro === 'todos' ? 'Todos los rubros' : rubro}
                </option>
              ))}
            </select>
          </div>
        )}
      </div>

      {/* Contador de resultados */}
      {(busqueda || filtroZona !== 'todas' || filtroRubro !== 'todos') && (
        <div className="text-sm text-gray-600 dark:text-gray-400">
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
          {clientesPaginados.map(cliente => (
            <div
              key={cliente.id}
              className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm p-4 hover:shadow-md transition-shadow"
            >
              <div className="flex justify-between items-start">
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2 flex-wrap">
                    {cliente.codigo != null && (
                      <span className="px-1.5 py-0.5 bg-blue-100 dark:bg-blue-900/30 text-blue-700 dark:text-blue-300 rounded text-xs font-mono font-semibold">
                        #{cliente.codigo}
                      </span>
                    )}
                    <h3 className="font-semibold text-lg text-gray-800 dark:text-white truncate">
                      {cliente.nombre_fantasia}
                    </h3>
                    {cliente.rubro && (
                      <span className="px-2 py-0.5 bg-purple-100 dark:bg-purple-900/30 text-purple-700 dark:text-purple-300 rounded-full text-xs flex items-center gap-1">
                        <Tag className="w-3 h-3" />
                        {cliente.rubro}
                      </span>
                    )}
                  </div>
                  <p className="text-sm text-gray-600 dark:text-gray-400 truncate flex items-center gap-1">
                    <Building2 className="w-3 h-3 flex-shrink-0" />
                    {cliente.razon_social}
                  </p>
                  {cliente.cuit && (
                    <p className="text-xs text-gray-500 dark:text-gray-400 font-mono">{cliente.cuit}</p>
                  )}
                </div>
                {isAdmin && (
                  <div className="flex space-x-1 ml-2">
                    <button
                      onClick={() => onEditarCliente(cliente)}
                      className="p-2 text-blue-500 hover:bg-blue-50 dark:hover:bg-blue-900/30 rounded-lg transition-colors"
                      aria-label={`Editar cliente ${cliente.nombre_fantasia}`}
                    >
                      <Edit2 className="w-4 h-4" aria-hidden="true" />
                    </button>
                    <button
                      onClick={() => onEliminarCliente(cliente.id)}
                      className="p-2 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/30 rounded-lg transition-colors"
                      aria-label={`Eliminar cliente ${cliente.nombre_fantasia}`}
                    >
                      <Trash2 className="w-4 h-4" aria-hidden="true" />
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
                <div className="mt-3 pt-2 border-t border-gray-100 dark:border-gray-700">
                  <span className="text-xs text-green-600 flex items-center">
                    <MapPin className="w-3 h-3 mr-1" />
                    Ubicación geocodificada
                  </span>
                </div>
              )}

              {/* Ver Ficha Button */}
              {onVerFichaCliente && (
                <button
                  onClick={() => onVerFichaCliente(cliente)}
                  className="mt-3 w-full flex items-center justify-center gap-2 px-3 py-2 bg-blue-50 dark:bg-blue-900/20 text-blue-600 dark:text-blue-400 rounded-lg hover:bg-blue-100 dark:hover:bg-blue-900/30 transition-colors text-sm font-medium"
                >
                  <FileText className="w-4 h-4" />
                  Ver Ficha de Cliente
                </button>
              )}
            </div>
          ))}
        </div>
      )}

      <Paginacion
        paginaActual={paginaActual}
        totalPaginas={totalPaginas}
        onPageChange={setPaginaActual}
        totalItems={clientesFiltrados.length}
        itemsLabel="clientes"
      />
    </div>
  );
}
