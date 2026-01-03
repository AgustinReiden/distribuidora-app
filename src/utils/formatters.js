// Utilidades de formateo para la aplicación

export const formatPrecio = (p) =>
  new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS' }).format(p || 0);

export const formatFecha = (f) =>
  f ? new Date(f).toLocaleDateString('es-AR', {
    day: '2-digit',
    month: '2-digit',
    hour: '2-digit',
    minute: '2-digit'
  }) : '';

export const getEstadoColor = (e) =>
  e === 'pendiente' ? 'bg-yellow-100 text-yellow-800' :
  e === 'en_preparacion' ? 'bg-orange-100 text-orange-800' :
  e === 'asignado' ? 'bg-blue-100 text-blue-800' :
  'bg-green-100 text-green-800';

export const getEstadoLabel = (e) =>
  e === 'pendiente' ? 'Pendiente' :
  e === 'en_preparacion' ? 'En preparación' :
  e === 'asignado' ? 'En camino' :
  'Entregado';

export const getRolColor = (r) =>
  r === 'admin' ? 'bg-purple-100 text-purple-700' :
  r === 'transportista' ? 'bg-orange-100 text-orange-700' :
  'bg-blue-100 text-blue-700';

export const getRolLabel = (r) =>
  r === 'admin' ? 'Admin' :
  r === 'transportista' ? 'Transportista' :
  'Preventista';

export const getEstadoPagoColor = (estado) =>
  estado === 'pagado' ? 'bg-green-100 text-green-800' :
  estado === 'parcial' ? 'bg-yellow-100 text-yellow-800' :
  'bg-red-100 text-red-800';

export const getEstadoPagoLabel = (estado) =>
  estado === 'pagado' ? 'Pagado' :
  estado === 'parcial' ? 'Pago Parcial' :
  'Pago Pendiente';

export const getFormaPagoLabel = (forma) =>
  forma === 'efectivo' ? 'Efectivo' :
  forma === 'transferencia' ? 'Transferencia' :
  forma === 'cheque' ? 'Cheque' :
  forma === 'cuenta_corriente' ? 'Cta. Cte.' :
  forma === 'tarjeta' ? 'Tarjeta' :
  forma;

export const ITEMS_PER_PAGE = 10;
