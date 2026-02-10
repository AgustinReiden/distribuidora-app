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
import { Clock, Package, Truck, Check, Eye, ChevronDown, ChevronUp, CreditCard, User, MapPin, Phone, FileText, Building2, Timer, FileDown, LucideIcon, AlertTriangle } from 'lucide-react';
const generarReciboPedido = async (...args: Parameters<typeof import('../../lib/pdfExport').generarReciboPedido>) => {
  const mod = await import('../../lib/pdfExport')
  return mod.generarReciboPedido(...args)
};
import { formatPrecio, formatFecha, getEstadoColor, getEstadoPagoColor, getEstadoPagoLabel, getFormaPagoLabel } from '../../utils/formatters';
import { MOTIVOS_SALVEDAD_LABELS } from '../../lib/schemas';
import AccionesDropdown from './PedidoActions';
import { PedidoActionsCtx } from '../../contexts/HandlersContext';
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
  onVerHistorial?: (pedido: PedidoDB) => void;
  onEditarPedido?: (pedido: PedidoDB) => void;
  onMarcarEnPreparacion?: (pedido: PedidoDB) => void;
  onVolverAPendiente?: (pedido: PedidoDB) => void;
  onAsignarTransportista?: (pedido: PedidoDB) => void;
  onMarcarEntregado?: (pedido: PedidoDB) => void;
  onMarcarEntregadoConSalvedad?: (pedido: PedidoDB) => void;
  onDesmarcarEntregado?: (pedido: PedidoDB) => void;
  onEliminarPedido?: (pedidoId: string) => void;
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
  const fecha = new Date(fechaCreacion);
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
    <span className={`inline-flex items-center gap-1 px-2 py-0.5 text-xs font-medium rounded-full border ${colorClass}`}>
      <Timer className="w-3 h-3" />
      {dias}d
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
  onVerHistorial,
  onEditarPedido,
  onMarcarEnPreparacion,
  onVolverAPendiente,
  onAsignarTransportista,
  onMarcarEntregado,
  onMarcarEntregadoConSalvedad,
  onDesmarcarEntregado,
  onEliminarPedido
}: PedidoCardProps): React.ReactElement {
  const [expandido, setExpandido] = useState<boolean>(false);
  const tieneSalvedad = pedido.salvedades && pedido.salvedades.length > 0;

  // Intentar usar contexto si está disponible (migración gradual)
  const pedidoActions = useContext(PedidoActionsCtx);

  // Usar handlers del contexto si están disponibles, de lo contrario usar props
  const handleVerHistorial = onVerHistorial ?? pedidoActions?.handleVerHistorial;
  const handleEditarPedido = onEditarPedido ?? pedidoActions?.handleEditarPedido;
  const handleMarcarEnPreparacion = onMarcarEnPreparacion ?? pedidoActions?.handleMarcarEnPreparacion;
  const handleVolverAPendiente = onVolverAPendiente ?? pedidoActions?.handleVolverAPendiente;
  const handleMarcarEntregado = onMarcarEntregado ?? pedidoActions?.handleMarcarEntregado;
  const handleDesmarcarEntregado = onDesmarcarEntregado ?? pedidoActions?.handleDesmarcarEntregado;
  const handleEliminarPedido = onEliminarPedido ?? (pedidoActions?.handleEliminarPedido ? (id: string) => pedidoActions.handleEliminarPedido(id) : undefined);

  return (
    <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm p-4 hover:shadow-md transition-shadow">
      {/* Header del pedido */}
      <div className="flex justify-between items-start">
        <div className="flex-1">
          <div className="flex items-start justify-between">
            <div>
              <h3 className="font-semibold text-lg text-gray-800 dark:text-white">
                {pedido.cliente?.nombre_fantasia || 'Sin cliente'}
              </h3>
              <p className="text-sm text-gray-500 dark:text-gray-400">{pedido.cliente?.direccion}</p>
              <p className="text-sm text-gray-400 dark:text-gray-500 mt-1 flex items-center gap-2">
                <span>#{pedido.id} - {formatFecha(pedido.created_at)}</span>
                <BadgeAntiguedad dias={calcularDiasAntiguedad(pedido.created_at)} estado={pedido.estado} />
              </p>
            </div>
          </div>
          {pedido.transportista && (
            <div className="mt-2 inline-flex items-center px-2 py-1 bg-orange-100 text-orange-700 rounded-full text-sm">
              <Truck className="w-4 h-4 mr-1" />
              {pedido.transportista.nombre}
            </div>
          )}
        </div>

        {/* Acciones */}
        <div className="flex items-start space-x-2">
          <div className="flex flex-col items-end gap-2">
            <EstadoStepper estado={pedido.estado} tieneSalvedad={tieneSalvedad} />
            {pedido.estado_pago && (
              <span className={`px-3 py-1 rounded-full text-xs font-medium ${getEstadoPagoColor(pedido.estado_pago)}`}>
                {getEstadoPagoLabel(pedido.estado_pago)}
              </span>
            )}
          </div>
          <AccionesDropdown
            pedido={pedido}
            isAdmin={isAdmin}
            isPreventista={isPreventista}
            isTransportista={isTransportista}
            onHistorial={handleVerHistorial}
            onEditar={handleEditarPedido}
            onPreparar={handleMarcarEnPreparacion}
            onVolverAPendiente={handleVolverAPendiente}
            onAsignar={onAsignarTransportista}
            onEntregado={handleMarcarEntregado}
            onEntregadoConSalvedad={onMarcarEntregadoConSalvedad}
            onRevertir={handleDesmarcarEntregado}
            onEliminar={handleEliminarPedido}
          />
        </div>
      </div>

      {/* Resumen del pedido */}
      <div className="mt-3 pt-3 border-t dark:border-gray-700">
        <div className="flex flex-wrap items-center gap-2 mb-2">
          {pedido.items?.slice(0, 3).map(i => (
            <span key={i.id} className="inline-block px-2 py-0.5 bg-gray-100 dark:bg-gray-700 rounded text-xs dark:text-gray-300">
              {i.producto?.nombre} x{i.cantidad}
            </span>
          ))}
          {pedido.items && pedido.items.length > 3 && (
            <span className="text-xs text-gray-500">+{pedido.items.length - 3} mas</span>
          )}
        </div>

        <div className="flex flex-wrap justify-between items-center gap-2">
          <div className="flex flex-col">
            <p className="text-lg font-bold text-blue-600">{formatPrecio(pedido.total)}</p>
            {pedido.forma_pago && (
              <p className="text-xs text-gray-500 flex items-center">
                <CreditCard className="w-3 h-3 mr-1" />
                {getFormaPagoLabel(pedido.forma_pago)}
              </p>
            )}
          </div>
          <div className="flex items-center gap-2">
            {pedido.estado_pago === 'pagado' && (
              <button
                onClick={() => pedido.cliente && generarReciboPedido(pedido, pedido.cliente)}
                className="flex items-center gap-1 px-3 py-1.5 text-sm bg-green-50 dark:bg-green-900/30 text-green-600 dark:text-green-400 rounded-lg hover:bg-green-100 dark:hover:bg-green-900/50 transition-colors"
                title="Descargar recibo PDF"
              >
                <FileDown className="w-4 h-4" />
                <span className="hidden sm:inline">Recibo PDF</span>
              </button>
            )}
            <button
              onClick={() => setExpandido(!expandido)}
              className="flex items-center gap-1 px-3 py-1.5 text-sm bg-blue-50 dark:bg-blue-900/30 text-blue-600 dark:text-blue-400 rounded-lg hover:bg-blue-100 dark:hover:bg-blue-900/50 transition-colors"
              aria-expanded={expandido}
              aria-controls={`pedido-detalle-${pedido.id}`}
              aria-label={expandido ? 'Ocultar detalle del pedido' : 'Ver detalle del pedido'}
            >
              <Eye className="w-4 h-4" aria-hidden="true" />
              {expandido ? 'Ocultar' : 'Ver detalle'}
              {expandido ? <ChevronUp className="w-4 h-4" aria-hidden="true" /> : <ChevronDown className="w-4 h-4" aria-hidden="true" />}
            </button>
          </div>
        </div>
      </div>

      {/* Contenido expandido del pedido */}
      {expandido && (
        <div id={`pedido-detalle-${pedido.id}`} className="mt-4 pt-4 border-t dark:border-gray-700 space-y-4 animate-fadeIn">
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
              {pedido.items?.map(item => (
                <div key={item.id} className="flex justify-between items-center py-2 border-b dark:border-gray-600 last:border-0">
                  <div className="flex-1">
                    <p className="font-medium text-gray-900 dark:text-white">{item.producto?.nombre || 'Producto'}</p>
                    <p className="text-xs text-gray-500">{formatPrecio(item.precio_unitario)} c/u</p>
                  </div>
                  <div className="text-right">
                    <p className="font-semibold text-gray-700 dark:text-gray-300">x{item.cantidad}</p>
                    <p className="text-sm font-bold text-blue-600">{formatPrecio(item.subtotal || item.precio_unitario * item.cantidad)}</p>
                  </div>
                </div>
              ))}
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
                {getFormaPagoLabel(pedido.forma_pago)}
              </p>
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

export default memo(PedidoCard);
