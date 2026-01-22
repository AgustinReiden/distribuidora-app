/**
 * Componente de estadísticas/resumen de pedidos
 */
import React, { memo } from 'react';
import { Clock, Package, Truck, Check, DollarSign, ShoppingCart } from 'lucide-react';
import { formatPrecio } from '../../utils/formatters';

function PedidoStats({ pedidosParaMostrar }) {
  const stats = {
    pendientes: pedidosParaMostrar.filter(p => p.estado === 'pendiente'),
    enPreparacion: pedidosParaMostrar.filter(p => p.estado === 'en_preparacion'),
    enCamino: pedidosParaMostrar.filter(p => p.estado === 'asignado'),
    entregados: pedidosParaMostrar.filter(p => p.estado === 'entregado'),
    impagos: pedidosParaMostrar.filter(p => p.estado_pago !== 'pagado'),
    total: pedidosParaMostrar
  };

  const items = [
    {
      key: 'pendientes',
      label: 'Pendientes',
      icon: Clock,
      count: stats.pendientes.length,
      total: stats.pendientes.reduce((s, p) => s + (p.total || 0), 0),
      colorClass: 'bg-yellow-50 dark:bg-yellow-900/20 border-yellow-200 dark:border-yellow-800',
      iconColor: 'text-yellow-600',
      textColor: 'text-yellow-800 dark:text-yellow-400'
    },
    {
      key: 'enPreparacion',
      label: 'En preparación',
      icon: Package,
      count: stats.enPreparacion.length,
      total: stats.enPreparacion.reduce((s, p) => s + (p.total || 0), 0),
      colorClass: 'bg-orange-50 dark:bg-orange-900/20 border-orange-200 dark:border-orange-800',
      iconColor: 'text-orange-600',
      textColor: 'text-orange-800 dark:text-orange-400'
    },
    {
      key: 'enCamino',
      label: 'En camino',
      icon: Truck,
      count: stats.enCamino.length,
      total: stats.enCamino.reduce((s, p) => s + (p.total || 0), 0),
      colorClass: 'bg-blue-50 dark:bg-blue-900/20 border-blue-200 dark:border-blue-800',
      iconColor: 'text-blue-600',
      textColor: 'text-blue-800 dark:text-blue-400'
    },
    {
      key: 'entregados',
      label: 'Entregados',
      icon: Check,
      count: stats.entregados.length,
      total: stats.entregados.reduce((s, p) => s + (p.total || 0), 0),
      colorClass: 'bg-green-50 dark:bg-green-900/20 border-green-200 dark:border-green-800',
      iconColor: 'text-green-600',
      textColor: 'text-green-800 dark:text-green-400'
    },
    {
      key: 'impagos',
      label: 'Impagos',
      icon: DollarSign,
      count: stats.impagos.length,
      total: stats.impagos.reduce((s, p) => s + (p.total || 0), 0),
      colorClass: 'bg-red-50 dark:bg-red-900/20 border-red-200 dark:border-red-800',
      iconColor: 'text-red-600',
      textColor: 'text-red-800 dark:text-red-400'
    },
    {
      key: 'total',
      label: 'Total Filtrado',
      icon: ShoppingCart,
      count: stats.total.length,
      total: stats.total.reduce((s, p) => s + (p.total || 0), 0),
      colorClass: 'bg-purple-50 dark:bg-purple-900/20 border-purple-200 dark:border-purple-800',
      iconColor: 'text-purple-600',
      textColor: 'text-purple-800 dark:text-purple-400'
    }
  ];

  return (
    <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-3">
      {items.map(item => (
        <div key={item.key} className={`border rounded-lg p-3 ${item.colorClass}`}>
          <div className="flex items-center justify-between">
            <item.icon className={`w-5 h-5 ${item.iconColor}`} />
            <span className={`text-xs ${item.iconColor}`}>{formatPrecio(item.total)}</span>
          </div>
          <p className={`text-xl font-bold ${item.iconColor}`}>{item.count}</p>
          <p className={`text-sm ${item.textColor}`}>{item.label}</p>
        </div>
      ))}
    </div>
  );
}

export default memo(PedidoStats);
