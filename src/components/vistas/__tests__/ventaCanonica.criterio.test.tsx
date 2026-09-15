/**
 * Las dos pantallas declaran la MISMA venta.
 *
 * QUE FIJA
 * --------
 * Hasta la mig 241, "cuánto vendió Fulano" tenía cuatro respuestas y cada
 * pantalla lo confesaba en su `<Criterio>`: Reportes decía "no cancelados, sin
 * filtro de canal", Gerenciales decía "entregados del canal app", y los dos
 * agregaban que **no coinciden**. La 241 fijó la definición canónica —pedidos
 * `entregado`, cualquier canal de venta (app o bot), por `pedidos.fecha`— así
 * que ahora los números cierran y esa advertencia sería mentira.
 *
 * Este test existe porque el `<Criterio>` es texto suelto en el JSX: no lo mira
 * ni `tsc` ni el linter, y es justamente lo que un admin lee para decidir si
 * dos números que no le cierran son un bug o dos preguntas distintas. Si
 * alguien vuelve a mover la definición en SQL, esto se pone rojo y lo obliga a
 * mover también lo que la pantalla promete.
 *
 * Las vistas se importan DIRECTO, no por el container (lazy, flake del #514).
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi } from 'vitest';
import { MemoryRouter } from 'react-router-dom';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

vi.mock('../../../lib/supabase', () => ({
  supabase: { rpc: vi.fn(), from: vi.fn() },
}));

vi.mock('../../../utils/excel', () => ({ createMultiSheetExcel: vi.fn() }));

vi.mock('../../../hooks/supabase', () => ({
  useReportesFinancieros: () => ({
    loading: false,
    generarReporteCuentasPorCobrar: vi.fn(async () => []),
    generarReporteRentabilidad: vi.fn(async () => ({ productos: [], totales: {} })),
  }),
}));

vi.mock('../reportes-gerenciales/charts', () => ({
  EvolucionChart: () => <div />, DiarioChart: () => <div />, VendedoresChart: () => <div />,
  CategoriasChart: () => <div />, WaterfallChart: () => <div />, CobranzaDonut: () => <div />,
  BonifPromosChart: () => <div />, MermasMotivoChart: () => <div />,
}));

vi.mock('../../../hooks/queries/useReporteGerencialQuery', () => ({
  usePosicionFiscalQuery: () => ({ data: null, isLoading: false }),
}));

import VistaReportes from '../VistaReportes';
import VistaReportesGerenciales from '../VistaReportesGerenciales';
import type { ReporteGerencial } from '../../../hooks/queries/useReporteGerencialQuery';

/** Todos los `<Criterio>` de la pantalla, como un solo texto. */
function criterios(): string {
  return screen
    .getAllByRole('note')
    .map((n) => n.textContent ?? '')
    .join(' \n ');
}

function reporteGerencial(): ReporteGerencial {
  return {
    meta: {
      sucursal_id: 1, sucursal_nombre: 'Tucumán', desde: '2026-08-01', hasta: '2026-08-31',
      generado_at: '2026-09-15T12:00:00Z', incluye_no_entregados: false,
    },
    kpis: {
      venta: 18085420, pedidos: 120, clientes: 60, ticket: 150000, clientes_nuevos: 2,
      cmv: 12000000, bonif: 240000, unidades: 5000, unidades_bonif: 100,
      margen_comercial: 3600000, margen_neto: 3360000, base_comision: 18085420,
      comision_pct_default: 2, mermas: 50000, compras: 9000000, ingreso_sin_costo: 0,
    },
    mensual: [],
    vendedores: [
      {
        id: 'u-juan', nombre: 'Juan', rol: 'preventista', pedidos: 100, venta: 15121320,
        margen_comercial: 3000000, bonif: 200000, base_nc: 15121320,
      },
    ],
    categorias: [], top_productos: [],
    top_clientes: [{ cliente: 'Kiosco El Sol', pedidos: 12, venta: 900000 }],
    cobranza: { formas: [], cobrado: 0, pendiente: 0 },
    serie_diaria: [], flags: { ingreso_sin_costo: 0, pct_sin_costo: 0 },
  } as unknown as ReporteGerencial;
}

describe('El criterio de venta que declaran las dos pantallas', () => {
  it('/reportes → "Por Preventista" dice entregados, cualquier canal, fecha del pedido', () => {
    render(
      <MemoryRouter initialEntries={['/reportes?tab=preventistas']}>
        <VistaReportes
          reportePreventistas={[]}
          reporteInicializado={true}
          loading={false}
          onCalcularReporte={vi.fn(async () => {})}
        />
      </MemoryRouter>
    );

    const texto = criterios();
    expect(texto).toMatch(/entregados/i);
    expect(texto).toMatch(/cualquier canal de venta/i);
    expect(texto).toMatch(/fecha del pedido/i);
    // La definición vieja, y la advertencia de que las pantallas no cierran.
    expect(texto).not.toMatch(/no cancelados/i);
    expect(texto).not.toMatch(/canal app/i);
    expect(texto).not.toMatch(/da más que/i);
  });

  it('/reportes → "Rentabilidad" ya no filtra por created_at', () => {
    render(
      <MemoryRouter initialEntries={['/reportes?tab=rentabilidad']}>
        <VistaReportes
          reportePreventistas={[]}
          reporteInicializado={true}
          loading={false}
          onCalcularReporte={vi.fn(async () => {})}
        />
      </MemoryRouter>
    );

    const texto = criterios();
    expect(texto).toMatch(/fecha del\s+pedido/i);
    expect(texto).not.toMatch(/created_at/i);
    expect(texto).not.toMatch(/fecha de carga/i);
    expect(texto).not.toMatch(/no cierra/i);
  });

  it('/reportes-gerenciales → "Equipo comercial" declara la misma venta, sin la advertencia', async () => {
    const periodo = {
      key: 'ago', label: 'Agosto 2026', desde: '2026-08-01', hasta: '2026-08-31',
      esMes: true, periodoMes: '2026-08-01', parcial: false,
    };
    render(
      <MemoryRouter initialEntries={['/reportes-gerenciales']}>
        <VistaReportesGerenciales
          reporte={reporteGerencial()}
          loading={false}
          error={null}
          sucursalSel={1}
          periodoSel={periodo}
          opcionesSucursal={[{ id: 1, nombre: 'Tucumán' }]}
          opcionesPeriodo={[periodo]}
          onSucursal={vi.fn()}
          onPeriodo={vi.fn()}
          onRango={vi.fn()}
          incluirNoEntregados={false}
          onIncluirNoEntregados={vi.fn()}
          comparar={false}
          onComparar={vi.fn()}
          metas={null}
          metasEditable={false}
          onGuardarMeta={vi.fn()}
          guardandoMeta={false}
          analisis={null}
          comisionCalculada={302426}
          comisionPorVendedor={null}
        />
      </MemoryRouter>
    );

    // "Equipo comercial" vive detrás del colapsable: los gráficos montan recién
    // al abrirlo (perf), así que el <Criterio> tampoco está en el DOM hasta acá.
    await userEvent.click(screen.getByRole('button', { name: /Ver detalle completo/ }));

    const texto = criterios();
    expect(texto).toMatch(/entregados/i);
    expect(texto).toMatch(/cualquier canal de venta/i);
    expect(texto).not.toMatch(/canal\s+app/i);
    expect(texto).not.toMatch(/No coincide con/i);
    expect(texto).not.toMatch(/miden cosas distintas/i);
  });
});
