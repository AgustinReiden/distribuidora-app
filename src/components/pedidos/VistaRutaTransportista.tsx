/**
 * Vista de ruta para transportista
 */
import React, { useState, useMemo, memo } from 'react';
import { Route, Truck, Check, MapPin, Phone, ChevronDown, ChevronUp, Navigation } from 'lucide-react';
import { formatPrecio, formatFecha, getFormaPagoLabel } from '../../utils/formatters';
import type { PedidoDB, ClienteDB, ProductoDB, PedidoItemDB } from '../../types';

// =============================================================================
// INTERFACES DE PROPS Y TIPOS
// =============================================================================

export interface VistaRutaTransportistaProps {
  pedidos: PedidoDB[] | null;
  onMarcarEntregado: (pedido: PedidoDB) => void;
  userId: string;
  clientes: ClienteDB[];
  productos: ProductoDB[];
}

interface PedidoEnriquecido extends PedidoDB {
  cliente: ClienteDB | null;
  items: Array<PedidoItemDB & { producto: ProductoDB | null }>;
}

interface EntregaRutaCardProps {
  pedido: PedidoEnriquecido;
  orden: number;
  onMarcarEntregado: (pedido: PedidoEnriquecido) => void;
}

// =============================================================================
// COMPONENTE: EntregaRutaCard
// =============================================================================

function EntregaRutaCard({ pedido, orden, onMarcarEntregado }: EntregaRutaCardProps): React.ReactElement {
  const [expandido, setExpandido] = useState<boolean>(false);

  const estadoPagoColors: Record<string, string> = {
    pagado: 'bg-green-100 text-green-700 border-green-200',
    parcial: 'bg-yellow-100 text-yellow-700 border-yellow-200',
    pendiente: 'bg-red-100 text-red-700 border-red-200'
  };

  const estadoPago = pedido.estado_pago || 'pendiente';

  return (
    <div className={`bg-white dark:bg-gray-800 rounded-xl border shadow-sm ${
      pedido.estado === 'entregado'
        ? 'border-green-300 dark:border-green-700 bg-green-50 dark:bg-green-900/20'
        : 'border-gray-200 dark:border-gray-700'
    }`}>
      {/* Header de la tarjeta */}
      <div className="p-4">
        <div className="flex items-start gap-3">
          {/* Numero de orden */}
          <div className={`w-9 h-9 rounded-full flex items-center justify-center text-white font-bold text-sm flex-shrink-0 ${
            pedido.estado === 'entregado' ? 'bg-green-500' : 'bg-blue-500'
          }`}>
            {pedido.estado === 'entregado' ? <Check className="w-4 h-4" /> : orden}
          </div>

          {/* Info principal */}
          <div className="flex-1 min-w-0">
            <div className="flex items-start justify-between gap-2">
              <div>
                <h3 className="font-bold text-gray-900 dark:text-white">
                  {pedido.cliente?.nombre_fantasia || 'Cliente'}
                </h3>
                <p className="text-sm text-gray-500 dark:text-gray-400">Pedido #{pedido.id}</p>
              </div>
              <span className={`px-2 py-0.5 text-xs font-medium rounded-full border ${estadoPagoColors[estadoPago] || estadoPagoColors.pendiente}`}>
                {estadoPago === 'pagado' ? 'PAGADO' : estadoPago === 'parcial' ? 'PARCIAL' : 'PEND'}
              </span>
            </div>

            {/* Direccion con link a maps */}
            <a
              href={`https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(pedido.cliente?.direccion || '')}`}
              target="_blank"
              rel="noopener noreferrer"
              className="flex items-start gap-2 mt-2 text-blue-600 dark:text-blue-400 hover:underline"
            >
              <MapPin className="w-4 h-4 mt-0.5 flex-shrink-0" />
              <span className="text-sm">{pedido.cliente?.direccion || 'Sin direccion'}</span>
            </a>

            {/* Telefono */}
            {pedido.cliente?.telefono && (
              <a
                href={`tel:${pedido.cliente.telefono}`}
                className="flex items-center gap-2 mt-1 text-gray-600 dark:text-gray-400 hover:text-blue-600"
              >
                <Phone className="w-4 h-4" />
                <span className="text-sm">{pedido.cliente.telefono}</span>
              </a>
            )}

            {/* Total y forma de pago */}
            <div className="flex items-center gap-4 mt-3">
              <span className="text-lg font-bold text-gray-900 dark:text-white">
                {formatPrecio(pedido.total)}
              </span>
              <span className="text-sm text-gray-500 dark:text-gray-400">
                {getFormaPagoLabel(pedido.forma_pago || '')}
              </span>
            </div>
          </div>
        </div>

        {/* Boton expandir/colapsar */}
        <button
          onClick={() => setExpandido(!expandido)}
          className="w-full flex items-center justify-center gap-1 mt-3 pt-2 border-t dark:border-gray-700 text-gray-500 hover:text-gray-700 dark:hover:text-gray-300 text-sm"
        >
          <span>{expandido ? 'Ver menos' : 'Ver productos'}</span>
          {expandido ? <ChevronUp className="w-4 h-4" /> : <ChevronDown className="w-4 h-4" />}
        </button>
      </div>

      {/* Contenido expandido */}
      {expandido && (
        <div className="px-4 pb-4 border-t dark:border-gray-700">
          <div className="mt-3">
            <p className="text-xs font-medium text-gray-500 dark:text-gray-400 mb-2">PRODUCTOS:</p>
            <div className="space-y-2">
              {pedido.items?.map(item => (
                <div key={item.id} className="flex justify-between text-sm bg-gray-50 dark:bg-gray-700 p-2 rounded">
                  <span className="text-gray-700 dark:text-gray-300">
                    {item.cantidad}x {item.producto?.nombre || 'Producto sin nombre'}
                  </span>
                  <span className="text-gray-500">{formatPrecio(item.subtotal || item.precio_unitario * item.cantidad)}</span>
                </div>
              ))}
            </div>
          </div>

          {pedido.notas && (
            <div className="mt-3 p-2 bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded">
              <p className="text-xs text-yellow-700 dark:text-yellow-300">
                <strong>Nota:</strong> {pedido.notas}
              </p>
            </div>
          )}
        </div>
      )}

      {/* Boton de marcar entregado */}
      {pedido.estado === 'asignado' && (
        <div className="p-3 bg-gray-50 dark:bg-gray-900 border-t dark:border-gray-700 rounded-b-xl">
          <button
            onClick={() => onMarcarEntregado(pedido)}
            className="w-full py-3 bg-green-600 hover:bg-green-700 text-white font-semibold rounded-lg transition-colors flex items-center justify-center gap-2"
          >
            <Check className="w-5 h-5" />
            Marcar como Entregado
          </button>
        </div>
      )}

      {pedido.estado === 'entregado' && (
        <div className="p-3 bg-green-100 dark:bg-green-900/30 border-t border-green-200 dark:border-green-800 rounded-b-xl">
          <p className="text-center text-green-700 dark:text-green-400 font-medium flex items-center justify-center gap-2">
            <Check className="w-5 h-5" />
            Entregado
          </p>
        </div>
      )}
    </div>
  );
}

// =============================================================================
// COMPONENTE PRINCIPAL
// =============================================================================

function VistaRutaTransportista({
  pedidos,
  onMarcarEntregado,
  userId,
  clientes,
  productos
}: VistaRutaTransportistaProps): React.ReactElement {
  // Enriquecer pedidos con datos de clientes y productos
  const pedidosEnriquecidos = useMemo<PedidoEnriquecido[]>(() => {
    if (!pedidos) return [];

    return pedidos.map(pedido => {
      let cliente: ClienteDB | null = null;
      if (pedido.cliente_id && clientes && clientes.length > 0) {
        cliente = clientes.find(c => c.id === pedido.cliente_id) || null;
      }
      if (!cliente && pedido.cliente && pedido.cliente.nombre_fantasia) {
        cliente = pedido.cliente;
      }

      const itemsEnriquecidos = (pedido.items || []).map(item => {
        let producto: ProductoDB | null = null;
        if (item.producto_id && productos && productos.length > 0) {
          producto = productos.find(p => p.id === item.producto_id) || null;
        }
        if (!producto && item.producto && item.producto.nombre) {
          producto = item.producto;
        }
        return { ...item, producto };
      });

      return { ...pedido, cliente, items: itemsEnriquecidos } as PedidoEnriquecido;
    });
  }, [pedidos, clientes, productos]);

  // Filtrar solo pedidos asignados a este transportista y ordenar
  const pedidosOrdenados = useMemo<PedidoEnriquecido[]>(() => {
    return pedidosEnriquecidos
      .filter(p =>
        (p.estado === 'asignado' || p.estado === 'entregado') &&
        p.transportista_id === userId
      )
      .sort((a, b) => {
        if (a.estado === 'asignado' && b.estado === 'entregado') return -1;
        if (a.estado === 'entregado' && b.estado === 'asignado') return 1;
        return (a.orden_entrega || 999) - (b.orden_entrega || 999);
      });
  }, [pedidosEnriquecidos, userId]);

  const entregasPendientes = pedidosOrdenados.filter(p => p.estado === 'asignado').length;
  const entregasCompletadas = pedidosOrdenados.filter(p => p.estado === 'entregado').length;
  const totalACobrar = pedidosOrdenados.filter(p => p.estado === 'asignado').reduce((sum, p) => sum + (p.total || 0), 0);
  const totalPendienteCobro = pedidosOrdenados.filter(p => p.estado === 'asignado' && p.estado_pago !== 'pagado').reduce((sum, p) => sum + (p.total || 0), 0);

  const handleMarcarEntregado = (pedido: PedidoEnriquecido): void => {
    onMarcarEntregado(pedido as PedidoDB);
  };

  if (pedidosOrdenados.length === 0) {
    return (
      <div className="text-center py-12">
        <Truck className="w-16 h-16 mx-auto text-gray-300 dark:text-gray-600 mb-4" />
        <h3 className="text-xl font-semibold text-gray-600 dark:text-gray-400 mb-2">Sin entregas asignadas</h3>
        <p className="text-gray-500 dark:text-gray-500">No tienes entregas pendientes por el momento</p>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Header con resumen */}
      <div className="bg-gradient-to-r from-blue-600 to-blue-700 rounded-2xl p-6 text-white shadow-lg">
        <div className="flex items-center gap-3 mb-4">
          <div className="w-14 h-14 bg-white/20 rounded-full flex items-center justify-center">
            <Route className="w-8 h-8" />
          </div>
          <div>
            <h2 className="text-2xl font-bold">Mi Ruta de Hoy</h2>
            <p className="text-blue-100">{formatFecha(new Date())}</p>
          </div>
        </div>

        <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
          <div className="bg-white/10 rounded-xl p-3 text-center">
            <p className="text-3xl font-bold">{entregasPendientes}</p>
            <p className="text-sm text-blue-100">Pendientes</p>
          </div>
          <div className="bg-white/10 rounded-xl p-3 text-center">
            <p className="text-3xl font-bold">{entregasCompletadas}</p>
            <p className="text-sm text-blue-100">Completadas</p>
          </div>
          <div className="bg-white/10 rounded-xl p-3 text-center">
            <p className="text-xl font-bold">{formatPrecio(totalACobrar)}</p>
            <p className="text-sm text-blue-100">Total</p>
          </div>
          <div className="bg-white/10 rounded-xl p-3 text-center">
            <p className="text-xl font-bold">{formatPrecio(totalPendienteCobro)}</p>
            <p className="text-sm text-blue-100">Por cobrar</p>
          </div>
        </div>
      </div>

      {/* Barra de progreso */}
      <div className="bg-white dark:bg-gray-800 rounded-xl p-4 border dark:border-gray-700">
        <div className="flex items-center justify-between mb-2">
          <span className="text-sm font-medium text-gray-700 dark:text-gray-300">Progreso del dia</span>
          <span className="text-sm text-gray-500 dark:text-gray-400">
            {entregasCompletadas} de {pedidosOrdenados.length} entregas
          </span>
        </div>
        <div className="w-full bg-gray-200 dark:bg-gray-700 rounded-full h-3">
          <div
            className="bg-green-500 h-3 rounded-full transition-all duration-500"
            style={{ width: `${(entregasCompletadas / pedidosOrdenados.length) * 100}%` }}
          />
        </div>
      </div>

      {/* Lista de entregas */}
      <div>
        <h3 className="text-lg font-semibold text-gray-800 dark:text-white mb-4 flex items-center gap-2">
          <Navigation className="w-5 h-5 text-blue-600" />
          Orden de Entregas
        </h3>
        <div className="space-y-4">
          {pedidosOrdenados.map((pedido, index) => (
            <EntregaRutaCard
              key={pedido.id}
              pedido={pedido}
              orden={pedido.orden_entrega || index + 1}
              onMarcarEntregado={handleMarcarEntregado}
            />
          ))}
        </div>
      </div>
    </div>
  );
}

export default memo(VistaRutaTransportista);
