/**
 * Header del panel de Clientes: envoltorio fino de `PageHeader` (#709).
 *
 *   CARTERA  ·  MARTES 22 DE ABRIL  ·  649 CLIENTES
 *   Clientes con deuda                         [actions]
 *
 * A diferencia de Pedidos, Productos y Dashboard, el sufijo del título no se
 * deriva acá: llega armado en `filtroDescriptivo` ("con deuda", "del rubro X").
 */
import React from 'react';
import { formatDiaLargo } from '../../utils/periodo';
import PageHeader from '../layout/PageHeader';

export interface ClientesViewHeaderProps {
  totalClientes: number;
  loading: boolean;
  /** Sufijo descriptivo opcional (italic). Ej: "con deuda", "del rubro Almacén". */
  filtroDescriptivo?: string | null;
  /** Slot derecha (típicamente botones de acción). */
  actions?: React.ReactNode;
}

export default function ClientesViewHeader({
  totalClientes,
  loading,
  filtroDescriptivo,
  actions,
}: ClientesViewHeaderProps): React.ReactElement {
  const now = React.useMemo(() => new Date(), []);

  // Con `loading`, PageHeader reemplaza este último crumb por "ACTUALIZANDO…".
  const conteo = `${totalClientes.toLocaleString('es-AR')} ${totalClientes === 1 ? 'CLIENTE' : 'CLIENTES'}`;

  return (
    <PageHeader
      titulo="Clientes"
      periodo={filtroDescriptivo}
      crumbs={['Cartera', formatDiaLargo(now), conteo]}
      acciones={actions}
      loading={loading}
    />
  );
}
