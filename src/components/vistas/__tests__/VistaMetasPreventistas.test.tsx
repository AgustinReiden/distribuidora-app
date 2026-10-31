/**
 * La fila "(sin vendedor)" (#1297) y el aviso de la venta sin costo (#1289) en
 * "Objetivos y rendimiento".
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

vi.mock('../../metas/BarraProgresoMeta', () => ({
  default: () => <div>barra de progreso</div>,
}));

import VistaMetasPreventistas from '../VistaMetasPreventistas';
import type { AvanceMeta, RendimientoPreventista } from '../../../hooks/queries';

function fila(campos: Partial<RendimientoPreventista>): RendimientoPreventista {
  return {
    preventista_id: 'u1',
    nombre: 'Christian',
    rol: 'preventista',
    pedidos: 3,
    venta: 1000,
    unidades: 10,
    margen_comercial: 400,
    venta_sin_costo: 0,
    cobertura: 2,
    clientes_nuevos: 0,
    ticket: 333,
    metas_cargadas: 0,
    metas: [],
    resumen_metas: { total: 0, cumplidas: 0, en_riesgo: 0 },
    por_marca: [],
    por_categoria: [],
    ...campos,
  };
}

function renderVista(preventistas: RendimientoPreventista[], onEditarMeta = vi.fn()) {
  return render(
    <VistaMetasPreventistas
      resultado={{ periodo: '2026-03-01', preventistas }}
      loading={false}
      periodo="2026-03-01"
      onCambiarPeriodo={vi.fn()}
      onAbrirObjetivos={vi.fn()}
      onEditarMeta={onEditarMeta}
      onEliminarMeta={vi.fn()}
    />
  );
}

describe('VistaMetasPreventistas', () => {
  it('muestra la fila "(sin vendedor)", sin id, y su venta entra en el total', () => {
    renderVista([
      fila({}),
      fila({ preventista_id: null, nombre: '(sin vendedor)', rol: null, venta: 75400, pedidos: 2 }),
    ]);

    const sinVendedor = screen.getByText('(sin vendedor)').closest('tr');
    expect(sinVendedor).toHaveTextContent('sin objetivos');
    expect(screen.queryByRole('button', { name: /Editar objetivo/i })).not.toBeInTheDocument();
    expect(screen.getByText('Venta del mes').closest('div')).toHaveTextContent('76.400');
  });

  it('un preventista con objetivos los sigue pudiendo editar con su id', async () => {
    const user = userEvent.setup();
    const onEditarMeta = vi.fn();
    const meta = { id: 7 } as unknown as AvanceMeta;
    renderVista([fila({ metas: [meta], resumen_metas: { total: 1, cumplidas: 0, en_riesgo: 0 } })], onEditarMeta);

    await user.click(screen.getByRole('button', { name: 'Editar objetivo de Christian' }));

    expect(onEditarMeta).toHaveBeenCalledWith(meta, 'u1');
  });

  it('avisa la venta sin costo al lado del margen', async () => {
    const user = userEvent.setup();
    renderVista([fila({ venta_sin_costo: 60600 })]);

    await user.click(screen.getByText('Christian'));

    expect(screen.getByText(/Margen comercial del período/)).toBeInTheDocument();
    const aviso = screen.getByText(/de la venta son productos sin costo cargado/);
    expect(aviso).toHaveTextContent('60.600');
    expect(aviso).toHaveTextContent('△');
  });

  it('sin venta sin costo no avisa nada', async () => {
    const user = userEvent.setup();
    renderVista([fila({ venta_sin_costo: 0 })]);

    await user.click(screen.getByText('Christian'));

    expect(screen.getByText(/Margen comercial del período/)).toBeInTheDocument();
    expect(screen.queryByText(/productos sin costo cargado/)).not.toBeInTheDocument();
  });
});
