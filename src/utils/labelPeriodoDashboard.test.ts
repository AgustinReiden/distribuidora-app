import { describe, it, expect } from 'vitest';
import { labelPeriodoDashboard } from './labelPeriodoDashboard';

describe('labelPeriodoDashboard', () => {
  it('hoy → "del día"', () => {
    expect(labelPeriodoDashboard({ filtroPeriodo: 'hoy' })).toEqual({
      verbo: 'Resumen',
      periodo: 'del día',
    });
  });

  it('semana → "de la semana"', () => {
    expect(labelPeriodoDashboard({ filtroPeriodo: 'semana' })).toEqual({
      verbo: 'Resumen',
      periodo: 'de la semana',
    });
  });

  it('mes → "del mes"', () => {
    expect(labelPeriodoDashboard({ filtroPeriodo: 'mes' })).toEqual({
      verbo: 'Resumen',
      periodo: 'del mes',
    });
  });

  it('anio → "del año"', () => {
    expect(labelPeriodoDashboard({ filtroPeriodo: 'anio' })).toEqual({
      verbo: 'Resumen',
      periodo: 'del año',
    });
  });

  it('historico → periodo null', () => {
    expect(labelPeriodoDashboard({ filtroPeriodo: 'historico' })).toEqual({
      verbo: 'Resumen',
      periodo: null,
    });
  });

  it('personalizado sin fechas → "personalizado"', () => {
    expect(labelPeriodoDashboard({ filtroPeriodo: 'personalizado' })).toEqual({
      verbo: 'Resumen',
      periodo: 'personalizado',
    });
  });

  it('personalizado con rango mismo mes → "del X al Y de <mes>"', () => {
    expect(labelPeriodoDashboard({
      filtroPeriodo: 'personalizado',
      fechaDesde: '2026-05-10',
      fechaHasta: '2026-05-23',
    })).toEqual({
      verbo: 'Resumen',
      periodo: 'del 10 al 23 de mayo',
    });
  });

  it('personalizado con rango distinto mes → "del X de <mes> al Y de <mes>"', () => {
    expect(labelPeriodoDashboard({
      filtroPeriodo: 'personalizado',
      fechaDesde: '2026-04-25',
      fechaHasta: '2026-05-05',
    })).toEqual({
      verbo: 'Resumen',
      periodo: 'del 25 de abril al 5 de mayo',
    });
  });

  it('personalizado un solo día → "del X de <mes>"', () => {
    expect(labelPeriodoDashboard({
      filtroPeriodo: 'personalizado',
      fechaDesde: '2026-05-15',
      fechaHasta: '2026-05-15',
    })).toEqual({
      verbo: 'Resumen',
      periodo: 'del 15 de mayo',
    });
  });

  it('personalizado solo fechaDesde → "desde el X de <mes>"', () => {
    expect(labelPeriodoDashboard({
      filtroPeriodo: 'personalizado',
      fechaDesde: '2026-05-10',
      fechaHasta: null,
    })).toEqual({
      verbo: 'Resumen',
      periodo: 'desde el 10 de mayo',
    });
  });

  it('personalizado solo fechaHasta → "hasta el X de <mes>"', () => {
    expect(labelPeriodoDashboard({
      filtroPeriodo: 'personalizado',
      fechaDesde: null,
      fechaHasta: '2026-05-23',
    })).toEqual({
      verbo: 'Resumen',
      periodo: 'hasta el 23 de mayo',
    });
  });

  it('verbo "Mis métricas" para preventista', () => {
    expect(labelPeriodoDashboard({ filtroPeriodo: 'hoy' }, 'Mis métricas')).toEqual({
      verbo: 'Mis métricas',
      periodo: 'del día',
    });
  });
});
