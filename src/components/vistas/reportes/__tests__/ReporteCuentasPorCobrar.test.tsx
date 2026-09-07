/**
 * El export de "Cuentas por Cobrar".
 *
 * Las filas tienen dos niveles anidados —`cliente` y `aging`— y el Excel es
 * plano, así que lo que se verifica es el aplanado.
 *
 * Componente importado directo (ver #514).
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

interface HojaExcel {
  name: string;
  data: Record<string, unknown>[];
  columnWidths?: number[];
}

const mockCrearExcel = vi.fn<(hojas: HojaExcel[], filename: string) => Promise<void>>(() =>
  Promise.resolve()
);

vi.mock('../../../../utils/excel', () => ({
  createMultiSheetExcel: (hojas: HojaExcel[], filename: string) => mockCrearExcel(hojas, filename),
}));

vi.mock('../../../layout/LoadingSpinner', () => ({
  default: () => <div>cargando…</div>,
}));

import { ReporteCuentasPorCobrar } from '../ReporteCuentasPorCobrar';

const formatPrecio = (n: number): string => `$${n.toLocaleString('es-AR')}`;

const reporte = [
  {
    cliente: {
      id: '1', nombre_fantasia: 'Kiosco Luna', razon_social: 'Luna SRL',
      zona: 'ZONA 4', cuit: '30-1234-5', telefono: '381-555', activo: true,
    },
    totalDeuda: 10000, totalPagado: 4000, saldoPendiente: 6000,
    limiteCredito: 8000, creditoDisponible: 2000, pedidosPendientes: 3,
    aging: { corriente: 1000, vencido30: 2000, vencido60: 1500, vencido90: 1500 },
  },
  {
    // Cliente dado de baja: para un informe histórico TIENE que seguir
    // apareciendo, es de lo que se trata la baja lógica.
    cliente: {
      id: '2', nombre_fantasia: 'Almacén Sur', razon_social: null,
      zona: null, cuit: null, telefono: null, activo: false,
    },
    totalDeuda: 5000, totalPagado: 0, saldoPendiente: 5000,
    limiteCredito: 0, creditoDisponible: -5000, pedidosPendientes: 1,
    aging: { corriente: 0, vencido30: 0, vencido60: 0, vencido90: 5000 },
  },
];

function renderReporte(filas = reporte) {
  return render(
    <ReporteCuentasPorCobrar
      reporte={filas as never}
      loading={false}
      formatPrecio={formatPrecio}
    />
  );
}

describe('ReporteCuentasPorCobrar › export', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('exporta el resumen de aging y el detalle por cliente', async () => {
    const user = userEvent.setup();
    renderReporte();

    await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }));

    const [hojas] = mockCrearExcel.mock.calls[0];
    expect(hojas.map((h) => h.name)).toEqual(['Resumen aging', 'Por cliente']);
  });

  it('aplana cliente y aging a columnas', async () => {
    const user = userEvent.setup();
    renderReporte();

    await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }));

    const [hojas] = mockCrearExcel.mock.calls[0];
    expect(hojas[1].data[0]).toEqual({
      Cliente: 'Kiosco Luna',
      'Razón social': 'Luna SRL',
      Zona: 'ZONA 4',
      CUIT: '30-1234-5',
      Teléfono: '381-555',
      Activo: 'Sí',
      'Total facturado': 10000,
      Pagado: 4000,
      Saldo: 6000,
      Corriente: 1000,
      '1-30 días': 2000,
      '31-60 días': 1500,
      '+60 días': 1500,
      'Límite de crédito': 8000,
      'Crédito disponible': 2000,
      'Pedidos pendientes': 3,
    });
  });

  it('los clientes dados de baja siguen en el informe', async () => {
    // Un reporte de deuda que esconde al que debe y ya no opera no sirve para
    // cobrarle. La baja lógica existe justamente para que el historial lo siga
    // viendo.
    const user = userEvent.setup();
    renderReporte();

    await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }));

    const [hojas] = mockCrearExcel.mock.calls[0];
    expect(hojas[1].data).toHaveLength(2);
    expect(hojas[1].data[1]).toMatchObject({ Cliente: 'Almacén Sur', Activo: 'No', Saldo: 5000 });
  });

  it('los campos vacíos van en blanco, no como "null"', async () => {
    const user = userEvent.setup();
    renderReporte();

    await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }));

    const [hojas] = mockCrearExcel.mock.calls[0];
    expect(hojas[1].data[1]).toMatchObject({ 'Razón social': '', CUIT: '', Teléfono: '' });
    expect(hojas[1].data[1].Zona).toBe('Sin zona');
  });

  it('el resumen suma cada tramo de aging y cierra con el total', async () => {
    const user = userEvent.setup();
    renderReporte();

    await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }));

    const [hojas] = mockCrearExcel.mock.calls[0];
    expect(hojas[0].data).toEqual([
      { Tramo: 'Corriente', Monto: 1000, Clientes: 1 },
      { Tramo: '1-30 días', Monto: 2000, Clientes: 1 },
      { Tramo: '31-60 días', Monto: 1500, Clientes: 1 },
      { Tramo: '+60 días', Monto: 6500, Clientes: 2 },
      { Tramo: 'TOTAL', Monto: 11000, Clientes: 2 },
    ]);
  });

  it('el archivo se fecha con el día de hoy: la deuda es una foto, no un rango', async () => {
    const user = userEvent.setup();
    renderReporte();

    await user.click(screen.getByRole('button', { name: /Exportar a Excel/i }));

    const [, nombreArchivo] = mockCrearExcel.mock.calls[0];
    expect(nombreArchivo).toMatch(/^cuentas-por-cobrar-\d{4}-\d{2}-\d{2}$/);
  });

  it('sin deuda el botón está deshabilitado', () => {
    renderReporte([]);
    expect(screen.getByRole('button', { name: /Exportar a Excel/i })).toBeDisabled();
  });
});
