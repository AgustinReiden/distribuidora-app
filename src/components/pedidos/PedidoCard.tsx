/**
 * Componente de tarjeta individual de pedido
 *
 * Soporta dos modos de operación:
 * 1. Props tradicionales: recibe handlers como props
 * 2. Contexto: usa usePedidoActions() automáticamente si está disponible
 *
 * Esto permite una migración gradual hacia el uso de contextos.
 */
import React, { useState, memo, useContext } from 'react';
import { Clock, Package, Truck, Check, Eye, ChevronDown, ChevronUp, CreditCard, User, MapPin, Phone, FileText, Building2, Timer, FileDown, LucideIcon, AlertTriangle, Gift, RefreshCw } from 'lucide-react';
const generarReciboPedido = async (pedido: any, _empresa: any = {}, options: { formato?: 'a4' | 'comanda' } = {}) => {
  const mod = await import('../../lib/pdfExport') as any
  return mod.generarReciboPedido(pedido, _empresa, options)
};
import { formatPrecio, formatFecha, formatHora, getEstadoColor, getEstadoPagoColor, getEstadoPagoLabel, getFormaPagoLabel, getFormaPagoDisplay } from '../../utils/formatters';
import { MOTIVOS_SALVEDAD_LABELS } from '../../lib/schemas';
import AccionesDropdown from './PedidoActions';
import { PedidoActionsCtx } from '../../contexts/HandlersContext';
import { useAuthData } from '../../contexts/AuthDataContext';
import { haversineMeters, formatDistancia, clasificarDistancia, SEMAFORO_COLORS } from '../../utils/geo';
import type { PedidoDB, MotivoSalvedad } from '../../types';

// =============================================================================
// PROPS INTERFACES
// =============================================================================

export interface BadgeAntiguedadProps {
  dias: number;
  estado: PedidoDB['estado'];
}

export interface EstadoStepperProps {
  estado: PedidoDB['estado'];
  tieneSalvedad?: boolean;
}

export interface PedidoCardProps {
  pedido: PedidoDB;
  isAdmin?: boolean;
  isPreventista?: boolean;
  isTransportista?: boolean;
  isEncargado?: boolean;
  onVerHistorial?: (pedido: PedidoDB) => void;
  onEditarPedido?: (pedido: PedidoDB) => void;
  onEditarNotas?: (pedido: PedidoDB) => void;
  onMarcarEnPreparacion?: (pedido: PedidoDB) => void;
  onVolverAPendiente?: (pedido: PedidoDB) => void;
  onAsignarTransportista?: (pedido: PedidoDB) => void;
  onMarcarEntregado?: (pedido: PedidoDB) => void;
  onMarcarEntregadoConSalvedad?: (pedido: PedidoDB) => void;
  onDesmarcarEntregado?: (pedido: PedidoDB) => void;
  onCancelarPedido?: (pedido: PedidoDB) => void;
  onRegistrarPago?: (pedido: PedidoDB) => void;
}

interface EstadoConfig {
  key: PedidoDB['estado'];
  label: string;
  icon: LucideIcon;
}

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

// Funcion para calcular dias de antiguedad de un pedido
function calcularDiasAntiguedad(fechaCreacion: string | undefined): number {
  if (!fechaCreacion) return 0;
  // Para fechas date-only (YYYY-MM-DD), agregar T12:00:00 para evitar
  // que JS las interprete como UTC medianoche (causa dia anterior en UTC-)
  const fecha = typeof fechaCreacion === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(fechaCreacion)
    ? new Date(fechaCreacion + 'T12:00:00')
    : new Date(fechaCreacion);
  const hoy = new Date();
  const diffTime = hoy.getTime() - fecha.getTime();
  return Math.floor(diffTime / (1000 * 60 * 60 * 24));
}

// =============================================================================
// SUB-COMPONENTS
// =============================================================================

// Componente de badge de antiguedad
function BadgeAntiguedad({ dias, estado }: BadgeAntiguedadProps): React.ReactElement | null {
  if (estado === 'entregado' || dias < 2) return null;

  const esUrgente = dias >= 3;
  const colorClass = esUrgente
    ? 'bg-red-100 text-red-700 border-red-300'
    : 'bg-amber-100 text-amber-700 border-amber-300';

  return (
    <span className={`inline-flex items-center gap-1 px-2 py-0.5 text-[12.5px] font-medium rounded-full border ${colorClass}`}>
      <Timer className="w-3.5 h-3.5" />
      {dias}d
    </span>
  );
}

// Badge: distancia entre el GPS del check-in del preventista y la dirección
// del cliente. Solo se muestra a admin (y al preventista dueño). Si no hubo
// check-in (gps_status null), no renderiza nada para no contaminar las cards
// históricas previas a la migración 040.
interface BadgeGeolocalizacionProps {
  pedido: PedidoDB;
}

function BadgeGeolocalizacion({ pedido }: BadgeGeolocalizacionProps): React.ReactElement | null {
  if (!pedido.gps_status) return null;

  // GPS fallido: mostrar chip neutro indicando el motivo.
  if (pedido.gps_status !== 'ok') {
    const motivo =
      pedido.gps_status === 'denied' ? 'GPS denegado' :
      pedido.gps_status === 'timeout' ? 'GPS sin respuesta' :
      pedido.gps_status === 'unavailable' ? 'GPS no disponible' :
      'GPS con error';
    return (
      <span
        title={motivo}
        className={`inline-flex items-center gap-1 px-2 py-0.5 text-[12.5px] font-medium rounded-full border border-gray-200 ${SEMAFORO_COLORS.sin_dato.bg}`}
      >
        <MapPin className="w-3.5 h-3.5" />
        Sin GPS
      </span>
    );
  }

  // GPS ok: si el cliente no tiene coordenadas, no podemos calcular distancia.
  const clienteLat = pedido.cliente?.latitud;
  const clienteLng = pedido.cliente?.longitud;
  const pedidoLat = pedido.gps_lat;
  const pedidoLng = pedido.gps_lng;

  if (clienteLat == null || clienteLng == null || pedidoLat == null || pedidoLng == null) {
    return (
      <span
        title="Cliente sin coordenadas cargadas"
        className={`inline-flex items-center gap-1 px-2 py-0.5 text-[12.5px] font-medium rounded-full border border-gray-200 ${SEMAFORO_COLORS.sin_dato.bg}`}
      >
        <MapPin className="w-3.5 h-3.5" />
        s/ref
      </span>
    );
  }

  const metros = haversineMeters(
    { lat: Number(pedidoLat), lng: Number(pedidoLng) },
    { lat: Number(clienteLat), lng: Number(clienteLng) },
  );
  const clasif = clasificarDistancia(metros);
  const cfg = SEMAFORO_COLORS[clasif];

  return (
    <span
      title={`${cfg.label} · ${formatDistancia(metros)}`}
      className={`inline-flex items-center gap-1 px-2 py-0.5 text-[12.5px] font-medium rounded-full border border-transparent ${cfg.bg}`}
    >
      <MapPin className="w-3.5 h-3.5" />
      {formatDistancia(metros)}
    </span>
  );
}

// Componente de stepper de estado
function EstadoStepper({ estado, tieneSalvedad }: EstadoStepperProps): React.ReactElement {
  const estados: EstadoConfig[] = [
    { key: 'pendiente', label: 'Pendiente', icon: Clock },
    { key: 'en_preparacion', label: 'Preparando', icon: Package },
    { key: 'asignado', label: 'En camino', icon: Truck },
    { key: 'entregado', label: tieneSalvedad ? 'Con Salvedad' : 'Entregado', icon: tieneSalvedad ? AlertTriangle : Check },
  ];

  const estadoIndex = estados.findIndex(e => e.key === estado);

  return (
    <div className="flex items-center space-x-1 text-xs">
      {estados.map((e, idx) => {
        const isCompleted = idx <= estadoIndex;
        const isCurrent = idx === estadoIndex;
        const IconComponent = e.icon;
        const isEntregadoConSalvedad = isCurrent && estado === 'entregado' && tieneSalvedad;
        return (
          <React.Fragment key={e.key}>
            <div className={`flex items-center space-x-1 px-2 py-1 rounded ${
              isEntregadoConSalvedad ? 'bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-400' :
              isCurrent ? getEstadoColor(estado) :
              isCompleted ? 'bg-gray-200 text-gray-600' :
              'bg-gray-100 text-gray-400'
            }`}>
              <IconComponent className="w-3 h-3" />
              <span className="hidden sm:inline">{e.label}</span>
            </div>
            {idx < estados.length - 1 && (
              <div className={`w-4 h-0.5 ${isCompleted ? 'bg-gray-400' : 'bg-gray-200'}`} />
            )}
          </React.Fragment>
        );
      })}
    </div>
  );
}

// =============================================================================
// MAIN COMPONENT
// =============================================================================

function PedidoCard({
  pedido,
  isAdmin,
  isPreventista,
  isTransportista,
  isEncargado,
  onVerHistorial,
  onEditarPedido,
  onEditarNotas,
  onMarcarEnPreparacion,
  onVolverAPendiente,
  onAsignarTransportista,
  onMarcarEntregado,
  onMarcarEntregadoConSalvedad,
  onDesmarcarEntregado,
  onCancelarPedido,
  onRegistrarPago,
}: PedidoCardProps): React.ReactElement {
  const [expandido, setExpandido] = useState<boolean>(false);
  const tieneSalvedad = pedido.salvedades && pedido.salvedades.length > 0;

  // Intentar usar contexto si está disponible (migración gradual)
  const pedidoActions = useContext(PedidoActionsCtx);
  const { user } = useAuthData();

  // Usar handlers del contexto si están disponibles, de lo contrario usar props
  const handleVerHistorial = onVerHistorial ?? pedidoActions?.handleVerHistorial;
  const handleEditarPedido = onEditarPedido ?? pedidoActions?.handleEditarPedido;
  const handleMarcarEnPreparacion = onMarcarEnPreparacion ?? pedidoActions?.handleMarcarEnPreparacion;
  const handleVolverAPendiente = onVolverAPendiente ?? pedidoActions?.handleVolverAPendiente;
  const handleMarcarEntregado = onMarcarEntregado ?? pedidoActions?.handleMarcarEntregado;
  const handleDesmarcarEntregado = onDesmarcarEntregado ?? pedidoActions?.handleDesmarcarEntregado;
  const handleRegistrarPago = onRegistrarPago ?? pedidoActions?.handleRegistrarPago;
  const diasAntiguedad = calcularDiasAntiguedad(pedido.fecha || pedido.created_at);
  const fechaCreacionLabel = formatFecha(pedido.fecha || pedido.created_at);
  const horaCreacion = pedido.created_at ? formatHora(pedido.created_at) : null;
  const mostrarEntrega = pedido.fecha_entrega_programada
    && pedido.estado !== 'entregado'
    && pedido.estado !== 'cancelado';

  return (
    <div className="group bg-white dark:bg-gray-800 border border-stone-200/80 dark:border-gray-700 rounded-xl shadow-warm hover:shadow-warm-md hover:-translate-y-px hover:border-stone-300 dark:hover:border-gray-600 transition-[transform,box-shadow,border-color] duration-200 overflow-hidden">

      {/* ╔══ ZONA 1: META-LINE editorial (todos los datos secundarios en una línea) ══╗
           Nota: el ID conserva tracking editorial; el resto del texto va en case
           natural (más legible) con peso medium. Tamaño 13px — antes era 11px,
           se leía con esfuerzo. */}
      <div className="px-5 pt-4 flex flex-wrap items-center gap-x-2.5 gap-y-1 text-[13px] text-stone-500 dark:text-stone-400">
        <span className="tabular-nums font-semibold uppercase tracking-wide text-stone-600 dark:text-stone-300">#{pedido.id}</span>
        <span className="text-stone-300 dark:text-stone-600" aria-hidden="true">·</span>
        <span className="font-medium">{fechaCreacionLabel}</span>
        {horaCreacion && (
          <>
            <span className="text-stone-300 dark:text-stone-600" aria-hidden="true">·</span>
            <span className="inline-flex items-center gap-1 font-medium" title="Hora de creación">
              <Clock className="w-3.5 h-3.5" />
              {horaCreacion}
            </span>
          </>
        )}
        {mostrarEntrega && (
          <>
            <span className="text-stone-300 dark:text-stone-600" aria-hidden="true">·</span>
            <span className="inline-flex items-center gap-1 font-medium text-orange-600 dark:text-orange-400" title="Entrega programada">
              <Truck className="w-3.5 h-3.5" />
              entrega {formatFecha(pedido.fecha_entrega_programada)}
            </span>
          </>
        )}
        <BadgeAntiguedad dias={diasAntiguedad} estado={pedido.estado} />
        {(isAdmin || (isPreventista && user?.id === pedido.usuario_id)) && (
          <BadgeGeolocalizacion pedido={pedido} />
        )}
      </div>

      {/* ╔══ ZONA 2: HEADER PRINCIPAL — cliente prominente + estado a la derecha ══╗ */}
      <div className="px-5 pt-2 flex items-start justify-between gap-3">
        <div className="min-w-0 flex-1">
          <h3 className="text-lg font-semibold text-stone-900 dark:text-white leading-tight break-words">
            {pedido.cliente?.nombre_fantasia || 'Sin cliente'}
          </h3>
          {pedido.cliente?.direccion && (
            <p className="mt-1 text-sm text-stone-500 dark:text-gray-400 flex items-start gap-1.5">
              <MapPin className="w-3.5 h-3.5 mt-0.5 flex-shrink-0 text-stone-400 dark:text-stone-500" aria-hidden="true" />
              {/* Mobile: deja que la dirección wrappee a 2 líneas (line-clamp-2)
                  para que el operador la vea entera. Desktop: trunca a 1 línea. */}
              <span className="line-clamp-2 sm:line-clamp-none sm:truncate">{pedido.cliente.direccion}</span>
            </p>
          )}
        </div>

        {/* DESKTOP: stepper + badges + dropdown a la derecha */}
        <div className="hidden sm:flex items-start gap-2 flex-shrink-0">
          <div className="flex flex-col items-end gap-2">
            <EstadoStepper estado={pedido.estado} tieneSalvedad={tieneSalvedad} />
            <div className="flex items-center gap-1.5 flex-wrap justify-end">
              {pedido.estado_pago && (
                <span className={`px-2.5 py-1 rounded-full text-[12.5px] font-semibold ${getEstadoPagoColor(pedido.estado_pago)}`}>
                  {getEstadoPagoLabel(pedido.estado_pago)}
                </span>
              )}
              {pedido.tipo_factura === 'FC' && (
                <span className="px-2 py-0.5 rounded text-[11px] font-bold tracking-wider bg-blue-100 text-blue-700 dark:bg-blue-900/40 dark:text-blue-300">
                  FC
                </span>
              )}
            </div>
          </div>
          <AccionesDropdown
            pedido={pedido}
            isAdmin={isAdmin}
            isPreventista={isPreventista}
            isTransportista={isTransportista}
            isEncargado={isEncargado}
            currentUserId={user?.id}
            onHistorial={handleVerHistorial}
            onEditar={handleEditarPedido}
            onEditarNotas={onEditarNotas}
            onPreparar={handleMarcarEnPreparacion}
            onVolverAPendiente={handleVolverAPendiente}
            onAsignar={onAsignarTransportista}
            onEntregado={handleMarcarEntregado}
            onEntregadoConSalvedad={onMarcarEntregadoConSalvedad}
            onRevertir={handleDesmarcarEntregado}
            onCancelarPedido={onCancelarPedido}
            onRegistrarPago={handleRegistrarPago}
          />
        </div>

        {/* MOBILE: solo el dropdown a la derecha del header. El stepper y los
            badges van a una fila propia abajo, para que cliente y dirección
            tengan todo el ancho disponible. */}
        <div className="sm:hidden flex-shrink-0 -mt-1">
          <AccionesDropdown
            pedido={pedido}
            isAdmin={isAdmin}
            isPreventista={isPreventista}
            isTransportista={isTransportista}
            isEncargado={isEncargado}
            currentUserId={user?.id}
            onHistorial={handleVerHistorial}
            onEditar={handleEditarPedido}
            onEditarNotas={onEditarNotas}
            onPreparar={handleMarcarEnPreparacion}
            onVolverAPendiente={handleVolverAPendiente}
            onAsignar={onAsignarTransportista}
            onEntregado={handleMarcarEntregado}
            onEntregadoConSalvedad={onMarcarEntregadoConSalvedad}
            onRevertir={handleDesmarcarEntregado}
            onCancelarPedido={onCancelarPedido}
            onRegistrarPago={handleRegistrarPago}
          />
        </div>
      </div>

      {/* ╔══ ZONA 2b (mobile only): Stepper + badges de pago/FC ══╗ */}
      <div className="sm:hidden px-5 mt-3 flex items-center justify-between gap-2 flex-wrap">
        <EstadoStepper estado={pedido.estado} tieneSalvedad={tieneSalvedad} />
        <div className="flex items-center gap-1.5 flex-wrap">
          {pedido.estado_pago && (
            <span className={`px-2.5 py-1 rounded-full text-[12.5px] font-semibold ${getEstadoPagoColor(pedido.estado_pago)}`}>
              {getEstadoPagoLabel(pedido.estado_pago)}
            </span>
          )}
          {pedido.tipo_factura === 'FC' && (
            <span className="px-2 py-0.5 rounded text-[11px] font-bold tracking-wider bg-blue-100 text-blue-700 dark:bg-blue-900/40 dark:text-blue-300">
              FC
            </span>
          )}
        </div>
      </div>

      {/* ╔══ ZONA 3: PERSONAS (compactas, en una sola fila) ══╗ */}
      {(pedido.usuario?.nombre || pedido.transportista || (pedido.estado === 'cancelado' && pedido.motivo_cancelacion)) && (
        <div className="px-5 mt-3 flex flex-wrap items-center gap-1.5">
          {pedido.usuario?.nombre && (
            <span
              className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-[13px] bg-purple-50 text-purple-700 border border-purple-200/60 dark:bg-purple-900/20 dark:text-purple-300 dark:border-purple-800/40"
              title="Pedido cargado por"
            >
              <User className="w-3.5 h-3.5" />
              <span className="font-medium">{pedido.usuario.nombre}</span>
            </span>
          )}
          {pedido.transportista && (
            <span
              className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-[13px] bg-orange-50 text-orange-700 border border-orange-200/60 dark:bg-orange-900/20 dark:text-orange-300 dark:border-orange-800/40"
              title="Transportista asignado"
            >
              <Truck className="w-3.5 h-3.5" />
              <span className="font-medium">{pedido.transportista.nombre}</span>
            </span>
          )}
          {pedido.estado === 'cancelado' && pedido.motivo_cancelacion && (
            <span className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-[13px] bg-red-50 text-red-700 border border-red-200/60 dark:bg-red-900/20 dark:text-red-300 dark:border-red-800/40">
              <AlertTriangle className="w-3.5 h-3.5" />
              <span className="font-medium truncate max-w-xs">{pedido.motivo_cancelacion}</span>
            </span>
          )}
        </div>
      )}

      {/* ╔══ ZONA 4: PRODUCTOS ══╗ */}
      <div className="px-5 mt-4">
        {/* Divider editorial: gradiente sutil */}
        <div className="h-px bg-gradient-to-r from-transparent via-stone-200 dark:via-gray-700 to-transparent" aria-hidden="true" />
        <div className="mt-3 flex flex-wrap items-center gap-1.5">
          {pedido.items?.slice(0, 3).map(i => (
            <span
              key={i.id}
              className="inline-flex items-baseline gap-1 px-2.5 py-1 bg-stone-50 dark:bg-gray-700/70 border border-stone-200/80 dark:border-gray-700 rounded-md text-[13px] text-stone-700 dark:text-gray-300"
            >
              <span className="truncate max-w-[22ch]">{i.producto?.nombre}</span>
              <span className="tabular-nums text-stone-500 dark:text-gray-400 font-semibold">×{i.cantidad}</span>
            </span>
          ))}
          {pedido.items && pedido.items.length > 3 && (
            <span className="text-[13px] text-stone-500 dark:text-gray-400 font-medium">
              +{pedido.items.length - 3} más
            </span>
          )}
        </div>
      </div>

      {/* ╔══ ZONA 5: FOOTER (total destacado en su propio compartimento) ══╗ */}
      <div className="mt-4 px-5 py-3.5 bg-gradient-to-br from-stone-50/70 via-stone-50/40 to-blue-50/30 dark:from-gray-900/50 dark:via-gray-900/30 dark:to-blue-900/10 border-t border-stone-200/70 dark:border-gray-700/60 flex flex-wrap items-end justify-between gap-3">
        <div className="min-w-0">
          <p className="text-[11px] font-semibold uppercase tracking-[0.14em] text-stone-500 dark:text-stone-400 leading-none">
            Total
          </p>
          <p
            className="mt-1 text-2xl text-blue-700 dark:text-blue-300 tabular-nums leading-none"
            style={{ fontWeight: 800, letterSpacing: '-0.03em' }}
          >
            {formatPrecio(pedido.total)}
          </p>
          {pedido.estado_pago === 'parcial' && (
            <p className="mt-1.5 text-[13px] font-medium text-amber-700 dark:text-amber-400 tabular-nums">
              Pagado: {formatPrecio(pedido.monto_pagado || 0)} de {formatPrecio(pedido.total)}
            </p>
          )}
          {(pedido.forma_pago || (pedido.pagos && pedido.pagos.length > 0)) && (
            <p className="mt-1.5 text-[13px] text-stone-500 dark:text-gray-400 flex items-center gap-1.5">
              <CreditCard className="w-3.5 h-3.5" aria-hidden="true" />
              {getFormaPagoDisplay(pedido)}
            </p>
          )}
        </div>
        <div className="flex items-center gap-3">
          {pedido.estado_pago === 'pagado' && (
            <ReciboDropdown pedido={pedido} />
          )}
          <button
            onClick={() => setExpandido(!expandido)}
            className="inline-flex items-center gap-1.5 text-sm font-semibold text-blue-700 dark:text-blue-300 hover:text-blue-800 dark:hover:text-blue-200 hover:gap-2 transition-[gap,color] duration-200"
            aria-expanded={expandido}
            aria-controls={`pedido-detalle-${pedido.id}`}
            aria-label={expandido ? 'Ocultar detalle del pedido' : 'Ver detalle del pedido'}
          >
            <Eye className="w-4 h-4" aria-hidden="true" />
            {expandido ? 'Ocultar detalle' : 'Ver detalle'}
            {expandido ? <ChevronUp className="w-4 h-4" aria-hidden="true" /> : <ChevronDown className="w-4 h-4" aria-hidden="true" />}
          </button>
        </div>
      </div>

      {/* Contenido expandido del pedido */}
      {expandido && (
        <div id={`pedido-detalle-${pedido.id}`} className="px-5 pt-4 pb-5 border-t border-stone-200 dark:border-gray-700 space-y-4 animate-fadeIn">
          {/* Informacion del cliente */}
          <div className="p-3 bg-gray-50 dark:bg-gray-700/50 rounded-lg">
            <h4 className="text-sm font-semibold text-gray-700 dark:text-gray-300 mb-2 flex items-center gap-2">
              <User className="w-4 h-4" />
              Informacion del Cliente
            </h4>
            <div className="space-y-1 text-sm">
              <p className="font-medium text-gray-900 dark:text-white">{pedido.cliente?.nombre_fantasia}</p>
              {pedido.cliente?.razon_social && (
                <p className="text-gray-600 dark:text-gray-400 flex items-center gap-1">
                  <Building2 className="w-3 h-3" />
                  {pedido.cliente.razon_social}
                </p>
              )}
              {pedido.cliente?.cuit && (
                <p className="text-gray-500 dark:text-gray-400 text-xs font-mono">CUIT: {pedido.cliente.cuit}</p>
              )}
              <p className="text-gray-600 dark:text-gray-400 flex items-center gap-1">
                <MapPin className="w-3 h-3" />
                {pedido.cliente?.direccion}
              </p>
              {pedido.cliente?.telefono && (
                <p className="text-gray-600 dark:text-gray-400 flex items-center gap-1">
                  <Phone className="w-3 h-3" />
                  <a href={`tel:${pedido.cliente.telefono}`} className="text-blue-600 hover:underline">
                    {pedido.cliente.telefono}
                  </a>
                  {pedido.cliente?.contacto && <span className="text-gray-400">({pedido.cliente.contacto})</span>}
                </p>
              )}
            </div>
          </div>

          {/* Lista detallada de productos */}
          <div className="p-3 bg-gray-50 dark:bg-gray-700/50 rounded-lg">
            <h4 className="text-sm font-semibold text-gray-700 dark:text-gray-300 mb-2 flex items-center gap-2">
              <Package className="w-4 h-4" />
              Productos ({pedido.items?.length || 0})
            </h4>
            <div className="space-y-2">
              {pedido.items?.map(item => {
                const salvedadItem = pedido.salvedades?.find(s => String(s.producto_id) === String(item.producto_id));
                const cantidadOriginal = salvedadItem ? item.cantidad + salvedadItem.cantidad_afectada : item.cantidad;
                // Item con sustitucion de regalo: la marca queda como
                // "[Sustituido por: X]" en descripcion_regalo (lo agrega
                // sustituir_regalo_pedido y el trigger pre-insert). Para la
                // tarjeta queremos mostrar el nombre actual del producto +
                // un badge "Sustituido" pequeno + tooltip con la descripcion.
                const esSustituido = Boolean(
                  item.es_bonificacion
                  && item.descripcion_regalo
                  && item.descripcion_regalo.includes('[Sustituido por:')
                );
                return (
                <div key={item.id} className={`flex justify-between items-center py-2 border-b dark:border-gray-600 last:border-0 ${salvedadItem ? 'border-l-2 border-l-amber-400 pl-2 -ml-1' : ''} ${item.es_bonificacion ? 'bg-green-50 dark:bg-green-900/20 rounded px-2 -mx-1' : ''}`}>
                  <div className="flex-1">
                    <p className="font-medium text-gray-900 dark:text-white flex items-center gap-1.5 flex-wrap">
                      {item.es_bonificacion && <Gift className="w-4 h-4 text-green-600 flex-shrink-0" />}
                      {item.es_bonificacion
                        ? (esSustituido
                            ? (item.producto?.nombre || 'Regalo sustituido')
                            : (item.descripcion_regalo || item.producto?.nombre || 'Regalo'))
                        : (item.producto?.nombre || 'Producto')}
                      {item.es_bonificacion && <span className="text-xs bg-green-100 dark:bg-green-800 text-green-700 dark:text-green-300 px-1.5 py-0.5 rounded-full font-medium">REGALO</span>}
                      {esSustituido && (
                        <span
                          className="inline-flex items-center gap-1 text-xs bg-orange-100 dark:bg-orange-900/40 text-orange-700 dark:text-orange-300 px-1.5 py-0.5 rounded-full font-medium"
                          title={item.descripcion_regalo || ''}
                        >
                          <RefreshCw className="w-3 h-3" />
                          Sustituido
                        </span>
                      )}
                      {salvedadItem && (
                        <span className="text-xs bg-amber-100 dark:bg-amber-900/40 text-amber-700 dark:text-amber-300 px-1.5 py-0.5 rounded-full font-medium">
                          {MOTIVOS_SALVEDAD_LABELS[salvedadItem.motivo as MotivoSalvedad] || salvedadItem.motivo}
                        </span>
                      )}
                    </p>
                    {!item.es_bonificacion && <p className="text-xs text-gray-500">{formatPrecio(item.precio_unitario)} c/u</p>}
                    {salvedadItem && (
                      <p className="text-xs text-amber-600 dark:text-amber-400">
                        Pedido: {cantidadOriginal} → Entregado: {item.cantidad} ({salvedadItem.cantidad_afectada} no entregadas)
                      </p>
                    )}
                  </div>
                  <div className="text-right">
                    <p className="font-semibold text-gray-700 dark:text-gray-300">x{item.cantidad}</p>
                    {!item.es_bonificacion && <p className="text-sm font-bold text-blue-600">{formatPrecio(item.subtotal || item.precio_unitario * item.cantidad)}</p>}
                    {item.es_bonificacion && <p className="text-sm font-bold text-green-600">$0</p>}
                    {salvedadItem && (
                      <p className="text-xs text-red-500 dark:text-red-400">-{formatPrecio(salvedadItem.monto_afectado)}</p>
                    )}
                  </div>
                </div>
                );
              })}
              <div className="flex justify-between items-center pt-2 border-t-2 dark:border-gray-600">
                <p className="font-bold text-gray-900 dark:text-white">Total</p>
                <p className="text-xl font-bold text-blue-600">{formatPrecio(pedido.total)}</p>
              </div>
            </div>
          </div>

          {/* Salvedades */}
          {tieneSalvedad && (
            <div className="p-3 bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 rounded-lg">
              <h4 className="text-sm font-semibold text-amber-700 dark:text-amber-300 mb-2 flex items-center gap-2">
                <AlertTriangle className="w-4 h-4" />
                Salvedades ({pedido.salvedades?.length})
              </h4>
              <div className="space-y-2">
                {pedido.salvedades?.map(salvedad => {
                  const productoItem = pedido.items?.find(i => i.producto_id === salvedad.producto_id);
                  const motivoLabel = MOTIVOS_SALVEDAD_LABELS[salvedad.motivo as MotivoSalvedad] || salvedad.motivo;
                  return (
                    <div key={salvedad.id} className="flex justify-between items-center py-2 border-b border-amber-200 dark:border-amber-700 last:border-0">
                      <div className="flex-1">
                        <p className="font-medium text-amber-900 dark:text-amber-100">
                          {productoItem?.producto?.nombre || 'Producto'}
                        </p>
                        <p className="text-xs text-amber-700 dark:text-amber-300">
                          {motivoLabel} - {salvedad.cantidad_afectada} unidad(es)
                        </p>
                        <span className={`inline-block mt-1 px-2 py-0.5 rounded-full text-xs ${
                          salvedad.estado_resolucion === 'pendiente'
                            ? 'bg-amber-200 text-amber-800 dark:bg-amber-800 dark:text-amber-200'
                            : 'bg-green-200 text-green-800 dark:bg-green-800 dark:text-green-200'
                        }`}>
                          {salvedad.estado_resolucion === 'pendiente' ? 'Pendiente de resolver' : 'Resuelta'}
                        </span>
                      </div>
                      <div className="text-right">
                        <p className="text-sm font-bold text-red-600 dark:text-red-400">
                          -{formatPrecio(salvedad.monto_afectado)}
                        </p>
                      </div>
                    </div>
                  );
                })}
                <div className="flex justify-between items-center pt-2 border-t border-amber-300 dark:border-amber-600">
                  <p className="text-sm font-medium text-amber-800 dark:text-amber-200">Total afectado:</p>
                  <p className="text-sm font-bold text-red-600 dark:text-red-400">
                    -{formatPrecio(pedido.salvedades?.reduce((sum, s) => sum + s.monto_afectado, 0) || 0)}
                  </p>
                </div>
              </div>
            </div>
          )}

          {/* Motivo de cancelacion */}
          {pedido.estado === 'cancelado' && pedido.motivo_cancelacion && (
            <div className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
              <h4 className="text-sm font-semibold text-red-700 dark:text-red-300 mb-1 flex items-center gap-2">
                <AlertTriangle className="w-4 h-4" />
                Motivo de cancelacion
              </h4>
              <p className="text-sm text-red-800 dark:text-red-200 whitespace-pre-wrap">{pedido.motivo_cancelacion}</p>
            </div>
          )}

          {/* Notas */}
          {pedido.notas && (
            <div className="p-3 bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg">
              <h4 className="text-sm font-semibold text-yellow-700 dark:text-yellow-300 mb-1 flex items-center gap-2">
                <FileText className="w-4 h-4" />
                Notas
              </h4>
              <p className="text-sm text-yellow-800 dark:text-yellow-200 whitespace-pre-wrap">{pedido.notas}</p>
            </div>
          )}

          {/* Info de pago y transporte */}
          <div className="grid grid-cols-2 gap-3">
            <div className="p-3 bg-gray-50 dark:bg-gray-700/50 rounded-lg">
              <p className="text-xs text-gray-500 dark:text-gray-400">Forma de pago</p>
              <p className="font-medium text-gray-900 dark:text-white flex items-center gap-1">
                <CreditCard className="w-4 h-4" />
                {getFormaPagoDisplay(pedido)}
              </p>
              {/* Desglose cuando el pago fue combinado: muestra cuanto se cobro
                  por cada forma sin abrir el modal de pagos. */}
              {(() => {
                const pagos = pedido.pagos || [];
                const formas = Array.from(new Set(pagos.map(p => p.forma_pago).filter(Boolean)));
                if (formas.length < 2) return null;
                const desglose = formas.map(f => ({
                  forma: f,
                  monto: pagos.filter(p => p.forma_pago === f).reduce((s, p) => s + (p.monto || 0), 0),
                }));
                return (
                  <div className="mt-1.5 pt-1.5 border-t border-gray-200 dark:border-gray-600 space-y-0.5 text-xs text-gray-600 dark:text-gray-400">
                    {desglose.map(d => (
                      <div key={d.forma} className="flex justify-between">
                        <span>{getFormaPagoLabel(d.forma)}</span>
                        <span className="font-medium">{formatPrecio(d.monto)}</span>
                      </div>
                    ))}
                  </div>
                );
              })()}
            </div>
            <div className="p-3 bg-gray-50 dark:bg-gray-700/50 rounded-lg">
              <p className="text-xs text-gray-500 dark:text-gray-400">Transportista</p>
              <p className="font-medium text-gray-900 dark:text-white flex items-center gap-1">
                <Truck className="w-4 h-4" />
                {pedido.transportista?.nombre || 'Sin asignar'}
              </p>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

// Dropdown para elegir formato de recibo
function ReciboDropdown({ pedido }: { pedido: PedidoDB }) {
  const [open, setOpen] = React.useState(false);
  const ref = React.useRef<HTMLDivElement>(null);

  React.useEffect(() => {
    function handleClickOutside(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    }
    if (open) document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [open]);

  const handleExport = async (formato: 'a4' | 'comanda') => {
    setOpen(false);
    if (pedido.cliente) {
      await generarReciboPedido(pedido, pedido.cliente, { formato });
    }
  };

  return (
    <div className="relative" ref={ref}>
      <button
        onClick={() => setOpen(!open)}
        className="flex items-center gap-1 px-3 py-1.5 text-sm bg-green-50 dark:bg-green-900/30 text-green-600 dark:text-green-400 rounded-lg hover:bg-green-100 dark:hover:bg-green-900/50 transition-colors"
        title="Descargar recibo PDF"
      >
        <FileDown className="w-4 h-4" />
        <span className="hidden sm:inline">Recibo</span>
        <ChevronDown className="w-3 h-3" />
      </button>
      {open && (
        <div className="absolute right-0 bottom-full mb-1 w-44 bg-white dark:bg-gray-800 rounded-lg shadow-lg border dark:border-gray-700 z-50 overflow-hidden">
          <button
            onClick={() => handleExport('a4')}
            className="w-full px-3 py-2.5 text-left text-sm hover:bg-gray-50 dark:hover:bg-gray-700 dark:text-white border-b dark:border-gray-700"
          >
            <p className="font-medium">Hoja A4</p>
            <p className="text-xs text-gray-500 dark:text-gray-400">Formato profesional</p>
          </button>
          <button
            onClick={() => handleExport('comanda')}
            className="w-full px-3 py-2.5 text-left text-sm hover:bg-gray-50 dark:hover:bg-gray-700 dark:text-white"
          >
            <p className="font-medium">Comanda</p>
            <p className="text-xs text-gray-500 dark:text-gray-400">Ticket 75mm</p>
          </button>
        </div>
      )}
    </div>
  );
}

export default memo(PedidoCard);
