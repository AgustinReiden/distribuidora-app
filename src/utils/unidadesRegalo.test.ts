import { describe, it, expect } from 'vitest';
import {
  esCantidadEnSubunidades,
  formatCantidadItem,
  equivalenteEnUnidades,
} from './unidadesRegalo';

describe('esCantidadEnSubunidades', () => {
  it('es true para el regalo de una promo fraccionada', () => {
    expect(esCantidadEnSubunidades({
      cantidad: 392, es_bonificacion: true, promocion: { unidades_por_bloque: 6 },
    })).toBe(true);
  });

  it('es false para una línea de venta, aunque tenga promo', () => {
    expect(esCantidadEnSubunidades({
      cantidad: 30, es_bonificacion: false, promocion: { unidades_por_bloque: 6 },
    })).toBe(false);
  });

  it('es false para un regalo NO fraccionado (bloque 1 o sin promo)', () => {
    expect(esCantidadEnSubunidades({
      cantidad: 2, es_bonificacion: true, promocion: { unidades_por_bloque: 1 },
    })).toBe(false);
    expect(esCantidadEnSubunidades({ cantidad: 2, es_bonificacion: true })).toBe(false);
    expect(esCantidadEnSubunidades({
      cantidad: 2, es_bonificacion: true, promocion: { unidades_por_bloque: null },
    })).toBe(false);
  });
});

describe('formatCantidadItem', () => {
  it('aclara la unidad sólo en el regalo fraccionado', () => {
    expect(formatCantidadItem({
      cantidad: 392, es_bonificacion: true, promocion: { unidades_por_bloque: 6 },
    })).toBe('x392 botellas');
    expect(formatCantidadItem({ cantidad: 30 })).toBe('x30');
  });
});

describe('equivalenteEnUnidades', () => {
  it('convierte a fardos el regalo fraccionado', () => {
    // El caso que disparó todo: 392 botellas = 65,3 fardos, no 392 fardos.
    expect(equivalenteEnUnidades({
      cantidad: 392, es_bonificacion: true, promocion: { unidades_por_bloque: 6 },
    })).toBe('≈ 65,3 fardos');
  });

  it('no muestra decimales cuando el bloque cierra justo', () => {
    expect(equivalenteEnUnidades({
      cantidad: 24, es_bonificacion: true, promocion: { unidades_por_bloque: 6 },
    })).toBe('≈ 4 fardos');
    expect(equivalenteEnUnidades({
      cantidad: 6, es_bonificacion: true, promocion: { unidades_por_bloque: 6 },
    })).toBe('≈ 1 fardo');
  });

  it('devuelve null cuando la cantidad ya está en fardos', () => {
    expect(equivalenteEnUnidades({ cantidad: 30 })).toBeNull();
    expect(equivalenteEnUnidades({ cantidad: 2, es_bonificacion: true })).toBeNull();
  });
});
