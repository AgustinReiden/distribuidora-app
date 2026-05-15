import { useState, useMemo } from 'react';
import type { ChangeEvent } from 'react';
import { Users, Plus, Edit2, Trash2, Search, MapPin, Phone, FileText, Tag, Building2 } from 'lucide-react';
import LoadingSpinner from '../layout/LoadingSpinner';
import Paginacion from '../layout/Paginacion';
import ClientesViewHeader from '../clientes/ClientesViewHeader';
import ClienteStats from '../clientes/ClienteStats';
import { useZonasEstandarizadasQuery } from '../../hooks/queries';
import { puedeVerSaldoCliente } from '../../lib/permisos';
import { useAuthData } from '../../contexts/AuthDataContext';
import { formatPrecio } from '../../utils/formatters';
import { cn } from '../../lib/utils';
import type { ClienteDB } from '../../types';

const ITEMS_PER_PAGE = 18;

/** Normalizar texto: colapsar espacios (incluyendo non-breaking space), trim, lowercase */
const normalizeSearch = (s: string | null | undefined): string =>
  s?.replace(/\s+/g, ' ').trim().toLowerCase() ?? '';

// =============================================================================
// INTERFACES DE PROPS
// =============================================================================

export interface VistaClientesProps {
  clientes: ClienteDB[];
  loading: boolean;
  isAdmin: boolean;
  isPreventista: boolean;
  isEncargado: boolean;
  onNuevoCliente: () => void;
  onEditarCliente: (cliente: ClienteDB) => void;
  onEliminarCliente: (id: string) => void;
  onVerFichaCliente?: (cliente: ClienteDB) => void;
  /** Solo se pasa cuando el usuario es admin (gating en el container). */
  onGestionarZonas?: () => void;
}

// =============================================================================
// COMPONENT
// =============================================================================

export default function VistaClientes({
  clientes,
  loading,
  isAdmin,
  isPreventista,
  isEncargado,
  onNuevoCliente,
  onEditarCliente,
  onEliminarCliente,
  onVerFichaCliente,
  onGestionarZonas
}: VistaClientesProps) {
  const { perfil } = useAuthData();
  const verSaldo = puedeVerSaldoCliente(perfil?.rol);

  const [busqueda, setBusqueda] = useState<string>('');
  const [paginaActual, setPaginaActual] = useState(1);

  const rubros = useMemo((): string[] => {
    const rubrosSet = new Set<string>(clientes.map(c => c.rubro).filter((r): r is string => Boolean(r)));
    return ['todos', ...Array.from(rubrosSet).sort()];
  }, [clientes]);

  const [filtroRubro, setFiltroRubro] = useState<string>('todos');
  // '' = todas las zonas (incluye clientes sin zona). Filtramos por id de zona
  // estandarizada — ignoramos el campo legado `zona` (texto).
  const [filtroZonaId, setFiltroZonaId] = useState<string>('');
  const [filtroSaldo, setFiltroSaldo] = useState<'todos' | 'deben' | 'no_deben'>('todos');

  const { data: zonas = [] } = useZonasEstandarizadasQuery();

  const clientesFiltrados = useMemo((): ClienteDB[] => {
    const busquedaNorm = normalizeSearch(busqueda);
    return clientes.filter((c: ClienteDB) => {
      const matchBusqueda = !busquedaNorm ||
        normalizeSearch(c.nombre_fantasia).includes(busquedaNorm) ||
        normalizeSearch(c.razon_social).includes(busquedaNorm) ||
        normalizeSearch(c.direccion).includes(busquedaNorm) ||
        c.telefono?.includes(busqueda.trim()) ||
        c.cuit?.includes(busqueda.replace(/[-\s]/g, '')) ||
        (c.codigo != null && String(c.codigo).includes(busqueda.trim()));

      const matchRubro = filtroRubro === 'todos' || c.rubro === filtroRubro;

      const matchZona = !filtroZonaId || (c.zona_id != null && String(c.zona_id) === filtroZonaId);

      const saldo = c.saldo_cuenta ?? 0;
      const matchSaldo =
        filtroSaldo === 'todos' ||
        (filtroSaldo === 'deben' && saldo > 0) ||
        (filtroSaldo === 'no_deben' && saldo <= 0);

      return matchBusqueda && matchRubro && matchZona && matchSaldo;
    });
  }, [clientes, busqueda, filtroRubro, filtroZonaId, filtroSaldo]);

  const totalPaginas = Math.ceil(clientesFiltrados.length / ITEMS_PER_PAGE);
  const clientesPaginados = useMemo(() => {
    const inicio = (paginaActual - 1) * ITEMS_PER_PAGE;
    return clientesFiltrados.slice(inicio, inicio + ITEMS_PER_PAGE);
  }, [clientesFiltrados, paginaActual]);

  const handleBusqueda = (e: ChangeEvent<HTMLInputElement>) => { setBusqueda(e.target.value); setPaginaActual(1); };
  const handleRubro = (e: ChangeEvent<HTMLSelectElement>) => { setFiltroRubro(e.target.value); setPaginaActual(1); };
  const handleZona = (e: ChangeEvent<HTMLSelectElement>) => { setFiltroZonaId(e.target.value); setPaginaActual(1); };
  const handleSaldo = (e: ChangeEvent<HTMLSelectElement>) => {
    setFiltroSaldo(e.target.value as 'todos' | 'deben' | 'no_deben');
    setPaginaActual(1);
  };

  const filtrosActivos = !!(busqueda || filtroRubro !== 'todos' || filtroZonaId !== '' || filtroSaldo !== 'todos');

  // Compone un sufijo descriptivo italic para el header (ej: "con deuda", "del
  // rubro Almacén", "de Centro"). Prioriza por especificidad: saldo > rubro >
  // zona > búsqueda libre.
  const filtroDescriptivo = useMemo((): string | null => {
    if (filtroSaldo === 'deben') return 'con deuda';
    if (filtroSaldo === 'no_deben') return 'al día';
    if (filtroRubro !== 'todos') return `del rubro ${filtroRubro}`;
    if (filtroZonaId) {
      const z = zonas.find(z => String(z.id) === filtroZonaId);
      return z ? `de ${z.nombre}` : null;
    }
    if (busqueda.trim()) return `que coinciden con "${busqueda.trim()}"`;
    return null;
  }, [filtroSaldo, filtroRubro, filtroZonaId, busqueda, zonas]);

  const canCreate = isAdmin || isPreventista || isEncargado;

  return (
    <div className="space-y-4">
      {/* Header editorial */}
      <ClientesViewHeader
        totalClientes={clientes.length}
        loading={loading}
        filtroDescriptivo={filtroDescriptivo}
        actions={
          <div className="flex flex-wrap items-center gap-2 justify-end">
            {isAdmin && onGestionarZonas && (
              <button
                onClick={onGestionarZonas}
                className={cn(
                  'inline-flex items-center gap-2.5 h-11 px-5 rounded-lg text-[14px] font-medium',
                  'bg-white dark:bg-gray-800 text-stone-700 dark:text-gray-200',
                  'border border-stone-200/80 dark:border-gray-700',
                  'shadow-warm',
                  'hover:bg-stone-50 dark:hover:bg-gray-700/50 hover:border-stone-300 dark:hover:border-gray-600 hover:-translate-y-px hover:shadow-warm-md',
                  'active:translate-y-0 active:shadow-warm',
                  'transition-[transform,box-shadow,background-color,border-color] duration-150',
                )}
              >
                <MapPin className="w-[18px] h-[18px] text-purple-600" aria-hidden="true" />
                <span>Gestionar Zonas</span>
              </button>
            )}
            {canCreate && (
              <button
                onClick={onNuevoCliente}
                className={cn(
                  'group relative inline-flex items-center gap-2.5 h-11 px-6 rounded-lg text-[14px] font-semibold',
                  'text-white',
                  'bg-gradient-to-br from-green-500 to-green-600',
                  'shadow-[0_2px_8px_-2px_rgb(34_197_94/0.45),inset_0_1px_0_rgb(255_255_255/0.12)]',
                  'hover:from-green-500 hover:to-green-700 hover:-translate-y-px hover:shadow-[0_6px_16px_-4px_rgb(34_197_94/0.55),inset_0_1px_0_rgb(255_255_255/0.18)]',
                  'active:translate-y-0 active:shadow-[0_2px_4px_-2px_rgb(34_197_94/0.4)]',
                  'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-green-500/40 focus-visible:ring-offset-2 focus-visible:ring-offset-stone-50 dark:focus-visible:ring-offset-gray-900',
                  'transition-[transform,box-shadow,background] duration-200',
                )}
              >
                <span
                  className="absolute inset-0 rounded-lg bg-gradient-to-br from-white/10 to-transparent opacity-0 group-hover:opacity-100 transition-opacity duration-200 pointer-events-none"
                  aria-hidden="true"
                />
                <Plus className="relative w-[18px] h-[18px]" aria-hidden="true" />
                <span className="relative">Nuevo cliente</span>
              </button>
            )}
          </div>
        }
      />

      {/* Filtros */}
      <div className="flex flex-col sm:flex-row gap-2 items-stretch">
        <div className="relative flex-1">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-stone-400" aria-hidden="true" />
          <input
            type="text"
            value={busqueda}
            onChange={handleBusqueda}
            className="w-full h-10 sm:h-9 pl-9 pr-3 rounded-lg border text-sm bg-white dark:bg-gray-800 text-gray-700 dark:text-gray-200 border-stone-200 dark:border-gray-700 placeholder:text-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500/40 focus:border-blue-400"
            placeholder="Buscar por nombre, CUIT, dirección o teléfono..."
            aria-label="Buscar clientes por nombre, CUIT, dirección o teléfono"
          />
        </div>
        {rubros.length > 1 && (
          <div>
            <label htmlFor="filtro-rubro-clientes" className="sr-only">Filtrar clientes por rubro</label>
            <select
              id="filtro-rubro-clientes"
              value={filtroRubro}
              onChange={handleRubro}
              className="h-10 sm:h-9 pl-3 pr-8 rounded-lg border text-sm appearance-none bg-white dark:bg-gray-800 text-gray-700 dark:text-gray-200 border-stone-200 dark:border-gray-700 focus:outline-none focus:ring-2 focus:ring-blue-500/40 focus:border-blue-400"
            >
              {rubros.map(rubro => (
                <option key={rubro} value={rubro}>
                  {rubro === 'todos' ? 'Todos los rubros' : rubro}
                </option>
              ))}
            </select>
          </div>
        )}
        {zonas.length > 0 && (
          <div>
            <label htmlFor="filtro-zona-clientes" className="sr-only">Filtrar clientes por zona</label>
            <select
              id="filtro-zona-clientes"
              value={filtroZonaId}
              onChange={handleZona}
              className="h-10 sm:h-9 pl-3 pr-8 rounded-lg border text-sm appearance-none bg-white dark:bg-gray-800 text-gray-700 dark:text-gray-200 border-stone-200 dark:border-gray-700 focus:outline-none focus:ring-2 focus:ring-blue-500/40 focus:border-blue-400"
            >
              <option value="">Todas las zonas</option>
              {zonas.map(z => (
                <option key={z.id} value={z.id}>{z.nombre}</option>
              ))}
            </select>
          </div>
        )}
        <div>
          <label htmlFor="filtro-saldo-clientes" className="sr-only">Filtrar clientes por estado de cuenta</label>
          <select
            id="filtro-saldo-clientes"
            value={filtroSaldo}
            onChange={handleSaldo}
            className="h-10 sm:h-9 pl-3 pr-8 rounded-lg border text-sm appearance-none bg-white dark:bg-gray-800 text-gray-700 dark:text-gray-200 border-stone-200 dark:border-gray-700 focus:outline-none focus:ring-2 focus:ring-blue-500/40 focus:border-blue-400"
          >
            <option value="todos">Estado de cuenta: Todos</option>
            <option value="deben">Deben</option>
            <option value="no_deben">No deben</option>
          </select>
        </div>
      </div>

      {/* Stats */}
      <ClienteStats clientes={clientes} />

      {/* Contador de resultados (solo si hay filtros activos) */}
      {filtrosActivos && (
        <div className="text-xs font-medium uppercase tracking-[0.1em] text-stone-500 dark:text-stone-400">
          Mostrando {clientesFiltrados.length.toLocaleString('es-AR')} de {clientes.length.toLocaleString('es-AR')} clientes
        </div>
      )}

      {/* Lista de clientes */}
      {loading ? <LoadingSpinner /> : clientesFiltrados.length === 0 ? (
        <div className="text-center py-12 text-stone-500">
          <Users className="w-12 h-12 mx-auto mb-3 opacity-50" />
          <p>{filtrosActivos ? 'No se encontraron clientes con esos criterios' : 'No hay clientes'}</p>
        </div>
      ) : (
        <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
          {clientesPaginados.map((cliente, idx) => (
            <ClienteCard
              key={cliente.id}
              cliente={cliente}
              idx={idx}
              isAdmin={isAdmin}
              verSaldo={verSaldo}
              onEditar={() => onEditarCliente(cliente)}
              onEliminar={() => onEliminarCliente(cliente.id)}
              onVerFicha={onVerFichaCliente ? () => onVerFichaCliente(cliente) : undefined}
            />
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

// =============================================================================
// CLIENTE CARD
// =============================================================================

interface ClienteCardProps {
  cliente: ClienteDB;
  idx: number;
  isAdmin: boolean;
  verSaldo: boolean;
  onEditar: () => void;
  onEliminar: () => void;
  onVerFicha?: () => void;
}

function ClienteCard({ cliente, idx, isAdmin, verSaldo, onEditar, onEliminar, onVerFicha }: ClienteCardProps) {
  const saldo = cliente.saldo_cuenta ?? 0;
  const saldoColor =
    saldo > 0 ? 'text-rose-700 dark:text-rose-300'
    : saldo < 0 ? 'text-emerald-700 dark:text-emerald-300'
    : 'text-stone-500 dark:text-stone-400';

  return (
    <div
      className="group bg-white dark:bg-gray-800 border border-stone-200/80 dark:border-gray-700 rounded-xl shadow-warm hover:shadow-warm-md hover:-translate-y-px hover:border-stone-300 dark:hover:border-gray-600 transition-[transform,box-shadow,border-color] duration-200 overflow-hidden flex flex-col"
      style={{
        animation: 'card-in 0.32s cubic-bezier(0.22, 1, 0.36, 1) both',
        animationDelay: `${Math.min(idx, 12) * 40}ms`,
      }}
    >
      {/* Crumb + acciones admin */}
      <div className="px-4 pt-3 flex items-center justify-between gap-2">
        <div className="text-[10.5px] font-semibold uppercase tracking-[0.18em] text-stone-500 dark:text-stone-400 flex items-center gap-0 min-w-0 flex-wrap">
          {cliente.codigo != null && (
            <span className="tabular-nums">#{cliente.codigo}</span>
          )}
          {cliente.codigo != null && cliente.rubro && (
            <span
              className="inline-block w-1 h-1 rounded-full bg-amber-500/70 align-middle mx-2"
              aria-hidden="true"
            />
          )}
          {cliente.rubro && (
            <span className="inline-flex items-center gap-1 truncate">
              <Tag className="w-3 h-3" aria-hidden="true" />
              {cliente.rubro}
            </span>
          )}
        </div>
        {isAdmin && (
          <div className="flex gap-0.5 flex-shrink-0">
            <button
              onClick={onEditar}
              className="p-1.5 text-stone-500 hover:text-blue-600 hover:bg-blue-50 dark:hover:bg-blue-900/30 rounded-md transition-colors"
              aria-label={`Editar cliente ${cliente.nombre_fantasia}`}
            >
              <Edit2 className="w-3.5 h-3.5" aria-hidden="true" />
            </button>
            <button
              onClick={onEliminar}
              className="p-1.5 text-stone-500 hover:text-rose-600 hover:bg-rose-50 dark:hover:bg-rose-900/30 rounded-md transition-colors"
              aria-label={`Eliminar cliente ${cliente.nombre_fantasia}`}
            >
              <Trash2 className="w-3.5 h-3.5" aria-hidden="true" />
            </button>
          </div>
        )}
      </div>

      {/* Nombre fantasía */}
      <h3 className="px-4 mt-1 text-lg font-semibold text-stone-900 dark:text-white leading-tight break-words">
        {cliente.nombre_fantasia}
      </h3>

      {/* Razón social */}
      {cliente.razon_social && (
        <p className="px-4 mt-0.5 text-sm text-stone-500 dark:text-stone-400 flex items-center gap-1.5 min-w-0">
          <Building2 className="w-3.5 h-3.5 flex-shrink-0" aria-hidden="true" />
          <span className="truncate">{cliente.razon_social}</span>
        </p>
      )}

      {/* CUIT */}
      {cliente.cuit && (
        <p className="px-4 mt-0.5 text-xs text-stone-400 dark:text-stone-500 font-mono tabular-nums">
          {cliente.cuit}
        </p>
      )}

      {/* Contacto */}
      <div className="px-4 mt-2 space-y-1.5 text-sm text-stone-600 dark:text-stone-300">
        {cliente.direccion && (
          <div className="flex items-start gap-1.5">
            <MapPin className="w-4 h-4 mt-0.5 flex-shrink-0 text-stone-400 dark:text-stone-500" aria-hidden="true" />
            <span className="break-words">{cliente.direccion}</span>
          </div>
        )}
        {cliente.telefono && (
          <div className="flex items-center gap-1.5">
            <Phone className="w-4 h-4 flex-shrink-0 text-stone-400" aria-hidden="true" />
            <a href={`tel:${cliente.telefono}`} className="text-blue-600 dark:text-blue-400 hover:underline">
              {cliente.telefono}
            </a>
          </div>
        )}
      </div>

      {/* Geo pill */}
      {cliente.latitud != null && cliente.longitud != null && (
        <span className="ml-4 mt-2 inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[11px] font-medium bg-emerald-50 text-emerald-700 border border-emerald-200/60 dark:bg-emerald-900/20 dark:text-emerald-300 dark:border-emerald-800/40 self-start">
          <MapPin className="w-3 h-3" aria-hidden="true" />
          Geolocalizado
        </span>
      )}

      {/* Spacer para empujar el footer abajo */}
      <div className="flex-1 min-h-[12px]" />

      {/* Footer con gradient + saldo + botón Ver Ficha */}
      <div className="mt-3 px-4 py-3 bg-gradient-to-br from-stone-50/70 via-stone-50/40 to-blue-50/30 dark:from-gray-900/50 dark:via-gray-900/30 dark:to-blue-900/10 border-t border-stone-200/70 dark:border-gray-700/60 flex items-end justify-between gap-2">
        {verSaldo ? (
          <div className="min-w-0">
            <p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-stone-500 dark:text-stone-400 leading-none">
              Saldo
            </p>
            <p
              className={`mt-1 text-base tabular-nums leading-none truncate ${saldoColor}`}
              style={{ fontWeight: 800, letterSpacing: '-0.025em' }}
              title={saldo > 0 ? 'Cliente con deuda' : saldo < 0 ? 'Saldo a favor del cliente' : 'Sin saldo pendiente'}
            >
              {formatPrecio(saldo)}
            </p>
          </div>
        ) : (
          <div className="flex-1" />
        )}
        {onVerFicha && (
          <button
            onClick={onVerFicha}
            className="inline-flex items-center gap-1.5 h-8 px-3 rounded-lg text-xs font-semibold bg-white dark:bg-gray-800 border border-stone-200/80 dark:border-gray-700 text-stone-700 dark:text-gray-200 shadow-warm hover:shadow-warm-md hover:-translate-y-px hover:border-stone-300 dark:hover:border-gray-600 transition-[transform,box-shadow,border-color] duration-150 flex-shrink-0"
          >
            <FileText className="w-3.5 h-3.5" aria-hidden="true" />
            Ver ficha
          </button>
        )}
      </div>
    </div>
  );
}
