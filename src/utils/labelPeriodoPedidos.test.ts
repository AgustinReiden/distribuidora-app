import { describe, it, expect } from 'vitest';
import { labelPeriodoPedidos } from './labelPeriodoPedidos';

// Fecha base estable para todos los tests: viernes 15 de mayo de 2026, 14:00 ART.
// Usamos UTC-3 implícita porque `fechaLocalISO` formatea TZ Argentina.
// El día 15/05 en hora local Buenos Aires corresponde a 17:00 UTC.
const NOW = new Date('2026-05-15T17:00:00.000Z');

describe('labelPeriodoPedidos', () => {
  it('sin filtros → periodo null', () => {
    expect(labelPeriodoPedidos(null, null, NOW)).toEqual({
      verbo: 'Pedidos',
      periodo: null,
    });
  });

  it('rango = hoy → "del día"', () => {
    expect(labelPeriodoPedidos('2026-05-15', '2026-05-15', NOW)).toEqual({
      verbo: 'Pedidos',
      periodo: 'del día',
    });
  });

  it('rango = ayer → "de ayer"', () => {
    expect(labelPeriodoPedidos('2026-05-14', '2026-05-14', NOW)).toEqual({
      verbo: 'Pedidos',
      periodo: 'de ayer',
    });
  });

  it('rango = mañana → "de mañana"', () => {
    expect(labelPeriodoPedidos('2026-05-16', '2026-05-16', NOW)).toEqual({
      verbo: 'Pedidos',
      periodo: 'de mañana',
    });
  });

  it('mes actual completo (primer al último día) → "del mes"', () => {
    expect(labelPeriodoPedidos('2026-05-01', '2026-05-31', NOW)).toEqual({
      verbo: 'Pedidos',
      periodo: 'del mes',
    });
  });

  it('primer día del mes actual sin hasta → "del mes"', () => {
    expect(labelPeriodoPedidos('2026-05-01', null, NOW)).toEqual({
      verbo: 'Pedidos',
      periodo: 'del mes',
    });
  });

  it('mes pasado completo → "de <mes>"', () => {
    expect(labelPeriodoPedidos('2026-04-01', '2026-04-30', NOW)).toEqual({
      verbo: 'Pedidos',
      periodo: 'de abril',
    });
  });

  it('mes de otro año → incluye el año', () => {
    expect(labelPeriodoPedidos('2025-12-01', '2025-12-31', NOW)).toEqual({
      verbo: 'Pedidos',
      periodo: 'de diciembre de 2025',
    });
  });

  it('rango custom mismo mes → "del X al Y de <mes>"', () => {
    expect(labelPeriodoPedidos('2026-05-10', '2026-05-23', NOW)).toEqual({
      verbo: 'Pedidos',
      periodo: 'del 10 al 23 de mayo',
    });
  });

  it('rango custom meses distintos → "del X de <mes> al Y de <mes>"', () => {
    expect(labelPeriodoPedidos('2026-04-25', '2026-05-05', NOW)).toEqual({
      verbo: 'Pedidos',
      periodo: 'del 25 de abril al 5 de mayo',
    });
  });

  it('solo fechaDesde (no es 1° del mes) → "desde el X de <mes>"', () => {
    expect(labelPeriodoPedidos('2026-05-10', null, NOW)).toEqual({
      verbo: 'Pedidos',
      periodo: 'desde el 10 de mayo',
    });
  });

  it('solo fechaHasta → "hasta el X de <mes>"', () => {
    expect(labelPeriodoPedidos(null, '2026-05-23', NOW)).toEqual({
      verbo: 'Pedidos',
      periodo: 'hasta el 23 de mayo',
    });
  });

  it('rango de un solo día arbitrario (no hoy/ayer/mañana) → "del X de <mes>"', () => {
    expect(labelPeriodoPedidos('2026-05-03', '2026-05-03', NOW)).toEqual({
      verbo: 'Pedidos',
      periodo: 'del 3 de mayo',
    });
  });

  describe('con fechaEntregaProgramada (prioridad sobre rango de creación)', () => {
    it('fechaEntregaProgramada = hoy → "para entregar hoy"', () => {
      expect(
        labelPeriodoPedidos(
          { fechaDesde: null, fechaHasta: null, fechaEntregaProgramada: '2026-05-15' },
          undefined,
          NOW,
        ),
      ).toEqual({ verbo: 'Pedidos', periodo: 'para entregar hoy' });
    });

    it('fechaEntregaProgramada = mañana → "para entregar mañana"', () => {
      expect(
        labelPeriodoPedidos(
          { fechaDesde: null, fechaHasta: null, fechaEntregaProgramada: '2026-05-16' },
          undefined,
          NOW,
        ),
      ).toEqual({ verbo: 'Pedidos', periodo: 'para entregar mañana' });
    });

    it('fechaEntregaProgramada = ayer → "que entregamos ayer"', () => {
      expect(
        labelPeriodoPedidos(
          { fechaDesde: null, fechaHasta: null, fechaEntregaProgramada: '2026-05-14' },
          undefined,
          NOW,
        ),
      ).toEqual({ verbo: 'Pedidos', periodo: 'que entregamos ayer' });
    });

    it('fechaEntregaProgramada custom → "para entregar el X de <mes>"', () => {
      expect(
        labelPeriodoPedidos(
          { fechaDesde: null, fechaHasta: null, fechaEntregaProgramada: '2026-05-22' },
          undefined,
          NOW,
        ),
      ).toEqual({ verbo: 'Pedidos', periodo: 'para entregar el 22 de mayo' });
    });

    it('fechaEntregaProgramada prevalece sobre rango de creación', () => {
      expect(
        labelPeriodoPedidos(
          {
            fechaDesde: '2026-04-01',
            fechaHasta: '2026-04-30',
            fechaEntregaProgramada: '2026-05-15',
          },
          undefined,
          NOW,
        ),
      ).toEqual({ verbo: 'Pedidos', periodo: 'para entregar hoy' });
    });
  });
});
