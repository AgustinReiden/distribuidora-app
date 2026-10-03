/**
 * Qué ve cada rol en el Dashboard (WP-47, #772).
 *
 * Hasta acá nada renderizaba la VistaDashboard REAL: DashboardContainer.test la
 * mockea como un botón y DashboardContainer.stockBajo como un <div>. Este test la
 * monta con las métricas de fixture de la galería y fija, por texto y rol ARIA
 * (nunca por clase), qué secciones aparecen según las flags de rol que le pasa
 * DashboardContainer.
 *
 * Decisión del dueño del 26/09: la Tasa de entrega mide el trabajo del
 * transportista, no el del preventista, así que el preventista PURO
 * (isPreventista sin isAdmin ni isEncargado) ya no la ve. Admin, encargado y
 * preventista con admin la siguen viendo.
 *
 * Lo que NO se puede fijar acá: la grilla de las 4 métricas principales
 * (`min-[375px]:grid-cols-2` para el preventista puro). jsdom no evalúa media
 * queries y la convención del repo es no aseverar clases; queda a la vista en la
 * galería (sección Dashboard).
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import VistaDashboard from '../VistaDashboard';
import {
  METRICAS_DASHBOARD,
  TOTAL_CLIENTES_DASHBOARD,
  PRODUCTOS_STOCK_BAJO_DASHBOARD,
  AVANCE_METAS_DASHBOARD,
} from '../../../../dev/gallery/fixtures/dashboard';

type Roles = { isAdmin?: boolean; isPreventista?: boolean; isEncargado?: boolean };

const ADMIN: Roles = { isAdmin: true };
const ENCARGADO: Roles = { isEncargado: true };
const PREVENTISTA_PURO: Roles = { isPreventista: true };
const PREVENTISTA_CON_ADMIN: Roles = { isAdmin: true, isPreventista: true };

function montar(roles: Roles, extra: { loading?: boolean } = {}) {
  return render(
    <VistaDashboard
      metricas={METRICAS_DASHBOARD}
      loading={extra.loading ?? false}
      filtroPeriodo="mes"
      onCambiarPeriodo={vi.fn()}
      onRefetch={vi.fn()}
      onDescargarBackup={vi.fn(async () => {})}
      exportando={false}
      productosStockBajo={PRODUCTOS_STOCK_BAJO_DASHBOARD}
      totalClientes={TOTAL_CLIENTES_DASHBOARD}
      avanceMetas={AVANCE_METAS_DASHBOARD}
      {...roles}
    />,
  );
}

const titulo = (nombre: RegExp) => screen.getByRole('heading', { level: 1, name: nombre });
const seccion = (nombre: string) => screen.queryByRole('heading', { name: nombre });

/** Lo que se dibuja igual para todos los roles. */
function comunes() {
  expect(screen.getByText('Pedidos', { exact: true })).toBeInTheDocument();
  expect(screen.getByText('Clientes', { exact: true })).toBeInTheDocument();
  expect(seccion('Estado de pedidos')).toBeInTheDocument();
  expect(screen.getByText('Pendientes')).toBeInTheDocument();
  expect(screen.getByText('En camino')).toBeInTheDocument();
  expect(screen.getByText('Entregados')).toBeInTheDocument();
  expect(seccion('Ventas últimos 7 días')).toBeInTheDocument();
  expect(screen.getByText('2 productos con stock bajo')).toBeInTheDocument();
}

describe('VistaDashboard por rol', () => {
  describe('admin', () => {
    it('titula "Resumen" y muestra las 4 métricas principales', () => {
      montar(ADMIN);
      expect(titulo(/^Resumen/)).toBeInTheDocument();
      expect(screen.getByText('Venta entregada')).toBeInTheDocument();
      expect(screen.getByText('Pedidos', { exact: true })).toBeInTheDocument();
      expect(screen.getByText('Ticket promedio')).toBeInTheDocument();
      expect(screen.getByText('Clientes', { exact: true })).toBeInTheDocument();
    });

    it('muestra estados, gráfico de 7 días con su total, Top 5, Tasa de entrega y stock bajo', () => {
      montar(ADMIN);
      comunes();
      expect(screen.getByText(/Total:/)).toBeInTheDocument();
      expect(seccion('Top 5 productos')).toBeInTheDocument();
      expect(screen.getByText('Manaos Cola 2,25 L')).toBeInTheDocument();
      expect(seccion('Tasa de entrega')).toBeInTheDocument();
    });

    it('muestra el panel de objetivos del mes cuando hay metas', () => {
      montar(ADMIN);
      expect(screen.getByRole('heading', { name: /Mis objetivos de septiembre/ })).toBeInTheDocument();
    });
  });

  describe('encargado', () => {
    it('titula "Resumen" y sólo ve Pedidos y Clientes entre las métricas principales', () => {
      montar(ENCARGADO);
      expect(titulo(/^Resumen/)).toBeInTheDocument();
      expect(screen.queryByText('Venta entregada')).not.toBeInTheDocument();
      expect(screen.queryByText('Ticket promedio')).not.toBeInTheDocument();
      expect(screen.getByText('Pedidos', { exact: true })).toBeInTheDocument();
      expect(screen.getByText('Clientes', { exact: true })).toBeInTheDocument();
    });

    it('ve estados y gráfico de 7 días sin total, sin Top 5, y con Tasa de entrega', () => {
      montar(ENCARGADO);
      comunes();
      expect(screen.queryByText(/Total:/)).not.toBeInTheDocument();
      expect(seccion('Top 5 productos')).not.toBeInTheDocument();
      expect(seccion('Tasa de entrega')).toBeInTheDocument();
    });
  });

  describe('preventista puro', () => {
    it('titula "Mis métricas" y muestra las 4 métricas principales', () => {
      montar(PREVENTISTA_PURO);
      expect(titulo(/^Mis métricas/)).toBeInTheDocument();
      expect(screen.getByText('Venta entregada')).toBeInTheDocument();
      expect(screen.getByText('Pedidos', { exact: true })).toBeInTheDocument();
      expect(screen.getByText('Ticket promedio')).toBeInTheDocument();
      expect(screen.getByText('Clientes', { exact: true })).toBeInTheDocument();
    });

    it('muestra estados, gráfico de 7 días con su total, Top 5, stock bajo y objetivos', () => {
      montar(PREVENTISTA_PURO);
      comunes();
      expect(screen.getByText(/Total:/)).toBeInTheDocument();
      expect(seccion('Top 5 productos')).toBeInTheDocument();
      expect(screen.getByText('Manaos Cola 2,25 L')).toBeInTheDocument();
      expect(screen.getByRole('heading', { name: /Mis objetivos de septiembre/ })).toBeInTheDocument();
    });

    it('no ve la Tasa de entrega (decisión del dueño del 26/09)', () => {
      montar(PREVENTISTA_PURO);
      expect(seccion('Tasa de entrega')).not.toBeInTheDocument();
    });
  });

  describe('preventista con admin', () => {
    it('titula "Resumen" y ve las 4 métricas principales', () => {
      montar(PREVENTISTA_CON_ADMIN);
      expect(titulo(/^Resumen/)).toBeInTheDocument();
      expect(screen.getByText('Venta entregada')).toBeInTheDocument();
      expect(screen.getByText('Pedidos', { exact: true })).toBeInTheDocument();
      expect(screen.getByText('Ticket promedio')).toBeInTheDocument();
      expect(screen.getByText('Clientes', { exact: true })).toBeInTheDocument();
    });

    it('ve estados, gráfico de 7 días, Top 5, Tasa de entrega y stock bajo', () => {
      montar(PREVENTISTA_CON_ADMIN);
      comunes();
      expect(screen.getByText(/Total:/)).toBeInTheDocument();
      expect(seccion('Top 5 productos')).toBeInTheDocument();
      expect(seccion('Tasa de entrega')).toBeInTheDocument();
    });
  });

  describe('cargando', () => {
    it('muestra el spinner y ninguna sección del dashboard', () => {
      montar(PREVENTISTA_PURO, { loading: true });
      expect(screen.getByRole('status')).toHaveTextContent('Cargando...');
      expect(screen.queryByRole('heading', { level: 1 })).not.toBeInTheDocument();
      expect(seccion('Estado de pedidos')).not.toBeInTheDocument();
      expect(seccion('Tasa de entrega')).not.toBeInTheDocument();
    });
  });
});
