/**
 * Las pestañas de /reportes (WP-54, #778).
 *
 * QUE FIJA
 * --------
 * La barra de pestañas de `VistaReportes` es lo que cierra el circuito del
 * "Ver detalle" del gerencial: `linkAReportes` arma `/reportes?tab=X&desde=…` y
 * la vista tiene que (1) caer en la pestaña X, (2) no perder el período al
 * aterrizar y (3) escribir de vuelta el mismo `tab` cuando el usuario cambia de
 * pestaña. Hasta ahora nada de eso tenía un test: la barra eran 8 botones a mano.
 *
 * Qué NO fija: cómo se ve (colores, subrayado) ni qué trae cada reporte por
 * dentro. Los 8 reportes están reemplazados por un marcador de texto, así que
 * el test habla de pestañas y no depende de RPCs ni de datos.
 *
 * Sobre el ROL: `VistaReportes` no lee rol ni permisos, y acá se renderiza sin
 * ningún provider de auth. Las 8 pestañas se ofrecen siempre; quién llega a la
 * pantalla lo decide la navegación (`reportes` es sólo `admin` en
 * TopNavigation), no la barra.
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi } from 'vitest';
import type { ReactElement } from 'react';
import { MemoryRouter, useLocation, useNavigationType } from 'react-router-dom';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { linkAReportes } from '../../../utils/paramsReporte';

vi.mock('../../../hooks/supabase', () => ({
  useReportesFinancieros: () => ({
    loading: false,
    generarReporteCuentasPorCobrar: vi.fn(async () => []),
    generarReporteRentabilidad: vi.fn(async () => ({ productos: [], totales: {} })),
  }),
}));

// Cada reporte, un marcador con su id. Los `<Criterio>` y los filtros de fecha
// los pinta la propia VistaReportes y quedan reales.
vi.mock('../reportes', () => ({
  ReportePreventistas: () => <p>[contenido preventistas]</p>,
  ReporteCuentasPorCobrar: () => <p>[contenido cuentas]</p>,
  ReporteRentabilidadSection: () => <p>[contenido rentabilidad]</p>,
  ReporteVentasClientes: () => <p>[contenido clientes]</p>,
  ReporteVentasZonas: () => <p>[contenido zonas]</p>,
  ReporteValuacionInventario: () => <p>[contenido valuacion]</p>,
  ReporteStockRed: () => <p>[contenido stock-red]</p>,
  ReporteMermas: () => <p>[contenido mermas]</p>,
  FiltrosVentas: () => <p>[filtros de ventas]</p>,
  filtrosVentasIniciales: () => ({ desde: '2026-10-01', hasta: '2026-10-31', presetId: 'este-mes', preventistaId: null }),
}));

import VistaReportes from '../VistaReportes';

/** Los ids del `?tab=`, en el orden en que se ofrecen, con el rótulo visible. */
const PESTANAS = [
  { id: 'preventistas', nombre: 'Por Preventista' },
  { id: 'cuentas', nombre: 'Cuentas por Cobrar' },
  { id: 'rentabilidad', nombre: 'Rentabilidad' },
  { id: 'clientes', nombre: 'Por Cliente' },
  { id: 'zonas', nombre: 'Por Zona' },
  { id: 'valuacion', nombre: 'Valuación de Stock' },
  { id: 'stock-red', nombre: 'Stock de la Red' },
  { id: 'mermas', nombre: 'Mermas' },
] as const;

type PestanaId = (typeof PESTANAS)[number]['id'];

const NOMBRES: string[] = PESTANAS.map((p) => p.nombre);

/** El rótulo de la pestaña de un id. */
function nombreDe(id: PestanaId): string {
  return PESTANAS.find((p) => p.id === id)?.nombre ?? id;
}

/** Muestra dónde está el router, para leer la URL que la vista escribe. */
function Sonda(): ReactElement {
  const { search } = useLocation();
  const tipo = useNavigationType();
  return (
    <div>
      <span data-testid="search">{search}</span>
      <span data-testid="navegacion">{tipo}</span>
    </div>
  );
}

function renderVista(entrada: string): void {
  render(
    <MemoryRouter initialEntries={[entrada]}>
      <VistaReportes
        reportePreventistas={[]}
        reporteInicializado={true}
        loading={false}
        onCalcularReporte={vi.fn(async () => {})}
      />
      <Sonda />
    </MemoryRouter>
  );
}

/** Los controles de la barra, en orden de DOM. */
function barra(): HTMLElement[] {
  return screen.getAllByRole('tab');
}

function pestana(nombre: string): HTMLElement {
  return screen.getByRole('tab', { name: nombre });
}

/** Los rótulos de las pestañas marcadas como activas (`aria-selected`). */
function pestanasActivas(): string[] {
  return barra()
    .filter((el) => el.getAttribute('aria-selected') === 'true')
    .map((el) => el.textContent?.trim() ?? '');
}

/** Los ids de los reportes que están en pantalla. Tiene que haber exactamente uno. */
function contenidoVisible(): string[] {
  return PESTANAS.filter((p) => screen.queryByText(`[contenido ${p.id}]`) !== null).map((p) => p.id);
}

function params(): URLSearchParams {
  return new URLSearchParams(screen.getByTestId('search').textContent ?? '');
}

describe('VistaReportes — qué pestañas hay', () => {
  it('ofrece las 8, en este orden, sin depender del rol', () => {
    renderVista('/reportes');

    expect(barra().map((el) => el.textContent?.trim())).toEqual(NOMBRES);
  });

  it('es una barra de pestañas con nombre y un panel con el contenido de la activa', () => {
    renderVista('/reportes?tab=mermas');

    expect(screen.getByRole('tablist', { name: 'Tipo de reporte' })).toBeInTheDocument();
    const panel = screen.getByRole('tabpanel', { name: 'Mermas' });
    expect(panel).toHaveTextContent('[contenido mermas]');
  });
});

describe('VistaReportes — pestaña activa según ?tab=', () => {
  it.each(PESTANAS)('?tab=$id muestra "$nombre" y sólo esa', ({ id, nombre }) => {
    renderVista(`/reportes?tab=${id}`);

    expect(contenidoVisible()).toEqual([id]);
    expect(pestanasActivas()).toEqual([nombre]);
  });

  it('sin ?tab= cae en "Por Preventista"', () => {
    renderVista('/reportes');

    expect(contenidoVisible()).toEqual(['preventistas']);
    expect(pestanasActivas()).toEqual(['Por Preventista']);
  });

  it.each(['inexistente', '', 'MERMAS', 'mermas ', 'stock_red'])(
    'un ?tab=%j inválido cae en "Por Preventista" en vez de dejar la pantalla en blanco',
    (invalido) => {
      renderVista(`/reportes?tab=${encodeURIComponent(invalido)}`);

      expect(contenidoVisible()).toEqual(['preventistas']);
      expect(pestanasActivas()).toEqual(['Por Preventista']);
      expect(barra()).toHaveLength(PESTANAS.length);
    }
  );
});

describe('VistaReportes — clic en una pestaña', () => {
  it('cambia el contenido y escribe `tab` en la URL', async () => {
    const user = userEvent.setup();
    renderVista('/reportes');

    await user.click(pestana('Mermas'));
    expect(contenidoVisible()).toEqual(['mermas']);
    expect(pestanasActivas()).toEqual([nombreDe('mermas')]);
    expect(params().get('tab')).toBe('mermas');

    await user.click(pestana('Por Cliente'));
    expect(contenidoVisible()).toEqual(['clientes']);
    expect(pestanasActivas()).toEqual([nombreDe('clientes')]);
    expect(params().get('tab')).toBe('clientes');

    await user.click(pestana('Stock de la Red'));
    expect(contenidoVisible()).toEqual(['stock-red']);
    expect(pestanasActivas()).toEqual([nombreDe('stock-red')]);
    expect(params().get('tab')).toBe('stock-red');
  });

  it('un clic sobre la pestaña que ya está activa la deja como está', async () => {
    const user = userEvent.setup();
    renderVista('/reportes?tab=mermas&desde=2026-08-01&hasta=2026-08-31');

    await user.click(pestana('Mermas'));

    expect(contenidoVisible()).toEqual(['mermas']);
    expect(pestanasActivas()).toEqual(['Mermas']);
    expect(params().get('tab')).toBe('mermas');
    expect(params().get('desde')).toBe('2026-08-01');
  });

  it('volver a "Por Preventista" borra `tab` en vez de escribir el default', async () => {
    const user = userEvent.setup();
    renderVista('/reportes?tab=zonas');

    await user.click(pestana('Por Preventista'));

    expect(contenidoVisible()).toEqual(['preventistas']);
    expect(pestanasActivas()).toEqual(['Por Preventista']);
    expect(params().has('tab')).toBe(false);
  });

  it('conserva el período y la sucursal del contexto al cambiar de pestaña', async () => {
    const user = userEvent.setup();
    renderVista('/reportes?tab=rentabilidad&desde=2026-08-01&hasta=2026-08-31&suc=2');

    await user.click(pestana('Mermas'));

    const sp = params();
    expect(sp.get('tab')).toBe('mermas');
    expect(sp.get('desde')).toBe('2026-08-01');
    expect(sp.get('hasta')).toBe('2026-08-31');
    expect(sp.get('suc')).toBe('2');
  });

  it('cambia con REPLACE: la pestaña no apila historial (el back de Android)', async () => {
    const user = userEvent.setup();
    renderVista('/reportes');

    await user.click(pestana('Por Zona'));

    expect(screen.getByTestId('navegacion')).toHaveTextContent('REPLACE');
  });
});

describe('VistaReportes — teclado', () => {
  it('→ activa la siguiente pestaña y escribe `tab` en la URL; End va a la última', async () => {
    const user = userEvent.setup();
    renderVista('/reportes?tab=rentabilidad&desde=2026-08-01&hasta=2026-08-31');

    await user.tab();
    expect(pestana('Rentabilidad')).toHaveFocus();

    await user.keyboard('{ArrowRight}');
    expect(pestana('Por Cliente')).toHaveFocus();
    expect(contenidoVisible()).toEqual(['clientes']);
    expect(params().get('tab')).toBe('clientes');
    expect(params().get('desde')).toBe('2026-08-01');

    await user.keyboard('{End}');
    expect(contenidoVisible()).toEqual(['mermas']);
    expect(params().get('tab')).toBe('mermas');
  });

  it('sólo la pestaña activa es tabulable: Tab salta de la barra al contenido', async () => {
    const user = userEvent.setup();
    renderVista('/reportes?tab=rentabilidad');

    await user.tab();
    expect(pestana('Rentabilidad')).toHaveFocus();
    await user.tab();
    expect(barra()).not.toContain(document.activeElement);
  });
});

describe('VistaReportes — deep link desde el gerencial (linkAReportes)', () => {
  // Los destinos que VistaReportesGerenciales arma de verdad: preventistas,
  // rentabilidad y clientes y mermas con período; cuentas sin período (el aging
  // es al día de hoy).
  const DESTINOS: { tab: PestanaId; conPeriodo: boolean }[] = [
    { tab: 'preventistas', conPeriodo: true },
    { tab: 'rentabilidad', conPeriodo: true },
    { tab: 'clientes', conPeriodo: true },
    { tab: 'cuentas', conPeriodo: false },
    { tab: 'mermas', conPeriodo: true },
  ];

  it.each(DESTINOS)('$tab: cae en la pestaña y no toca la URL que recibió', ({ tab, conPeriodo }) => {
    const to = linkAReportes({
      tab,
      desde: conPeriodo ? '2026-08-01' : undefined,
      hasta: conPeriodo ? '2026-08-31' : undefined,
      sucursalId: 3,
    });

    renderVista(to);

    expect(contenidoVisible()).toEqual([tab]);
    expect(pestanasActivas()).toEqual([nombreDe(tab)]);
    // La vista no reescribe nada al montar: lo que llegó es lo que queda.
    expect(screen.getByTestId('search').textContent).toBe(to.slice(to.indexOf('?')));
    expect(params().get('tab')).toBe(tab);
    expect(params().get('suc')).toBe('3');
    expect(params().get('desde')).toBe(conPeriodo ? '2026-08-01' : null);
  });

  it('un deep link a una pestaña de la red (suc=red) también aterriza', () => {
    renderVista(linkAReportes({ tab: 'mermas', desde: '2026-08-01', hasta: '2026-08-31', sucursalId: null }));

    expect(contenidoVisible()).toEqual(['mermas']);
    expect(pestanasActivas()).toEqual(['Mermas']);
    expect(params().get('suc')).toBe('red');
  });
});
