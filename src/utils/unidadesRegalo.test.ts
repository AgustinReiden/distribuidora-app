import { describe, it, expect } from 'vitest';
import {
  esCantidadEnSubunidades,
  formatCantidadItem,
  equivalenteEnUnidades,
} from './unidadesRegalo';

describe('esCantidadEnSubunidades', () => {
  it('es true para el regalo de una promo fraccionada', () => {
    expect(esCantidadEnSubunidades({
      cantidad: 392, es_bonificacion: true, promocion: { unidades_por_bloque: 6, regalo_mueve_stock: false },
    })).toBe(true);
  });

  it('es false para una línea de venta, aunque tenga promo', () => {
    expect(esCantidadEnSubunidades({
      cantidad: 30, es_bonificacion: false, promocion: { unidades_por_bloque: 6, regalo_mueve_stock: false },
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
      cantidad: 392, es_bonificacion: true, promocion: { unidades_por_bloque: 6, regalo_mueve_stock: false },
    })).toBe('x392 botellas');
    expect(formatCantidadItem({ cantidad: 30 })).toBe('x30');
  });
});

describe('equivalenteEnUnidades', () => {
  it('convierte a fardos el regalo fraccionado', () => {
    // El caso que disparó todo: 392 botellas = 65,3 fardos, no 392 fardos.
    expect(equivalenteEnUnidades({
      cantidad: 392, es_bonificacion: true, promocion: { unidades_por_bloque: 6, regalo_mueve_stock: false },
    })).toBe('≈ 65,3 fardos');
  });

  it('no muestra decimales cuando el bloque cierra justo', () => {
    expect(equivalenteEnUnidades({
      cantidad: 24, es_bonificacion: true, promocion: { unidades_por_bloque: 6, regalo_mueve_stock: false },
    })).toBe('≈ 4 fardos');
    expect(equivalenteEnUnidades({
      cantidad: 6, es_bonificacion: true, promocion: { unidades_por_bloque: 6, regalo_mueve_stock: false },
    })).toBe('≈ 1 fardo');
  });

  it('devuelve null cuando la cantidad ya está en fardos', () => {
    expect(equivalenteEnUnidades({ cantidad: 30 })).toBeNull();
    expect(equivalenteEnUnidades({ cantidad: 2, es_bonificacion: true })).toBeNull();
  });
});

/**
 * El factor congelado por ítem (mig 212) manda sobre el vivo de la promo. Sin
 * esto, editar el factor reescribía cómo se lee la cantidad de un regalo en
 * pedidos ya cerrados — el mismo bug que la 212 arregló para el reporte y que
 * seguía abierto para la pantalla y la boleta (issue #552).
 */
describe('precedencia del factor: congelado sobre vivo', () => {
  /** 392 botellas nacidas con factor 6; hoy la promo dice 12. */
  const historico = {
    cantidad: 392,
    es_bonificacion: true,
    unidades_por_bloque_al_crear: 6,
    promocion: { unidades_por_bloque: 12, regalo_mueve_stock: false },
  };

  it('convierte con el factor de cuando nació, no con el de hoy', () => {
    expect(equivalenteEnUnidades(historico)).toBe('≈ 65,3 fardos');
  });

  it('cae al vivo cuando el ítem no tiene congelado', () => {
    // Los 70 ítems que la mig 212 dejó en NULL a propósito: se comportan como
    // antes de la migración.
    expect(equivalenteEnUnidades({
      cantidad: 392, es_bonificacion: true, promocion: { unidades_por_bloque: 6, regalo_mueve_stock: false },
    })).toBe('≈ 65,3 fardos');
  });

  it('un congelado de 1 significa "no se fracciona", aunque el vivo fraccione', () => {
    // Es el caso peor de la 212: la promo pasó de unidad entera a fracción, y
    // leer el vivo multiplicaría por 12 la lectura de un regalo viejo.
    expect(esCantidadEnSubunidades({
      cantidad: 5,
      es_bonificacion: true,
      unidades_por_bloque_al_crear: 1,
      promocion: { unidades_por_bloque: 12, regalo_mueve_stock: false },
    })).toBe(false);
    expect(formatCantidadItem({
      cantidad: 5,
      es_bonificacion: true,
      unidades_por_bloque_al_crear: 1,
      promocion: { unidades_por_bloque: 12, regalo_mueve_stock: false },
    })).toBe('x5');
  });

  it('el congelado no rescata a una línea de venta', () => {
    expect(esCantidadEnSubunidades({
      cantidad: 30, es_bonificacion: false, unidades_por_bloque_al_crear: 6,
    })).toBe(false);
  });

  it('sobrevive que la promo se haya borrado, si el ítem tiene congelado', () => {
    expect(equivalenteEnUnidades({
      cantidad: 24, es_bonificacion: true, unidades_por_bloque_al_crear: 6, promocion: null,
    })).toBe('≈ 4 fardos');
  });
});

/**
 * El fallback al vivo replica la cascada COMPLETA de `factor_bonificacion`, no
 * sólo el divisor: también el gate `regalo_mueve_stock IS FALSE` (issue #534).
 * Aplica a los 70 ítems que la mig 212 dejó con el congelado en NULL.
 */
describe('el fallback vivo respeta el gate regalo_mueve_stock', () => {
  it('no fracciona si la promo mueve stock, aunque tenga divisor cargado', () => {
    // El caso peor de la 212: un flip de false → true que no limpió el divisor.
    // Sin el gate, este regalo se leería 6 veces más chico.
    expect(esCantidadEnSubunidades({
      cantidad: 12,
      es_bonificacion: true,
      promocion: { unidades_por_bloque: 6, regalo_mueve_stock: true },
    })).toBe(false);
  });

  it('tampoco fracciona si no se sabe si mueve stock', () => {
    // `IS FALSE` en SQL: NULL no es false, así que no hay fallback vivo.
    expect(esCantidadEnSubunidades({
      cantidad: 12,
      es_bonificacion: true,
      promocion: { unidades_por_bloque: 6, regalo_mueve_stock: null },
    })).toBe(false);
  });

  it('el congelado gana incluso cuando el gate vivo está cerrado', () => {
    // La línea nació fraccionada; que hoy la promo mueva stock no la reescribe.
    expect(equivalenteEnUnidades({
      cantidad: 24,
      es_bonificacion: true,
      unidades_por_bloque_al_crear: 6,
      promocion: { unidades_por_bloque: null, regalo_mueve_stock: true },
    })).toBe('≈ 4 fardos');
  });

  it('un divisor vivo en 0 cae al neutro, como el NULLIF del SQL', () => {
    expect(esCantidadEnSubunidades({
      cantidad: 12,
      es_bonificacion: true,
      promocion: { unidades_por_bloque: 0, regalo_mueve_stock: false },
    })).toBe(false);
  });
});
