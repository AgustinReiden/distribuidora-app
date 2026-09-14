import { describe, it, expect } from 'vitest';
import {
  desgloseSubunidades,
  lineaItemImpresion,
  nombreDeLaLinea,
  nombreSinConteo,
} from './lineaItem';

describe('nombreSinConteo', () => {
  it('saca el conteo inicial del bloque', () => {
    expect(nombreSinConteo('2 Botellas Manaos Pomelo 3L')).toBe('Botellas Manaos Pomelo 3L');
    expect(nombreSinConteo('2 Granadina')).toBe('Granadina');
  });

  it('deja intacta una descripción que no empieza con un conteo', () => {
    expect(nombreSinConteo('Botella Manaos 600cc')).toBe('Botella Manaos 600cc');
    // "3L" es número pegado a letra, no un conteo.
    expect(nombreSinConteo('3L Manaos Pomelo')).toBe('3L Manaos Pomelo');
  });

  it('tolera vacío y nulo', () => {
    expect(nombreSinConteo(null)).toBe('');
    expect(nombreSinConteo('   ')).toBe('');
  });
});

describe('nombreDeLaLinea', () => {
  it('para un regalo manda la descripción de la promo', () => {
    expect(nombreDeLaLinea({
      cantidad: 2,
      es_bonificacion: true,
      descripcion_regalo: '2 Botellas Manaos Pomelo 3L',
      producto: { nombre: 'Manaos Pomelo 3L' },
    })).toBe('Botellas Manaos Pomelo 3L');
  });

  it('cae al producto contenedor cuando el regalo no tiene descripción', () => {
    expect(nombreDeLaLinea({
      cantidad: 2,
      es_bonificacion: true,
      producto: { nombre: 'Manaos Pomelo 3L' },
    })).toBe('Manaos Pomelo 3L');
  });

  it('la línea de venta ignora la descripción de regalo', () => {
    expect(nombreDeLaLinea({
      cantidad: 2,
      es_bonificacion: false,
      descripcion_regalo: '2 Botellas Manaos Pomelo 3L',
      producto: { nombre: 'Manaos Pomelo 3L' },
    })).toBe('Manaos Pomelo 3L');
  });
});

describe('desgloseSubunidades', () => {
  it('parte en unidades completas y resto', () => {
    expect(desgloseSubunidades(392, 6)).toEqual({ fardos: 65, sueltas: 2 });
    expect(desgloseSubunidades(12, 6)).toEqual({ fardos: 2, sueltas: 0 });
    expect(desgloseSubunidades(3, 4)).toEqual({ fardos: 0, sueltas: 3 });
  });

  it('un factor inválido no divide por cero ni por menos de uno', () => {
    expect(desgloseSubunidades(5, 0)).toEqual({ fardos: 5, sueltas: 0 });
    expect(desgloseSubunidades(5, NaN)).toEqual({ fardos: 5, sueltas: 0 });
  });
});

describe('lineaItemImpresion', () => {
  const fraccion = {
    cantidad: 392,
    es_bonificacion: true,
    descripcion_regalo: '2 Botellas Manaos Pomelo 3L',
    unidades_por_bloque_al_crear: 6,
    promocion: { unidades_por_bloque: 12, regalo_mueve_stock: false },
    producto: { nombre: 'Manaos Pomelo 3L' },
  };

  it('el factor congelado le gana al vivo', () => {
    expect(lineaItemImpresion(fraccion))
      .toBe('392x Botellas Manaos Pomelo 3L (SUELTAS, NO FARDO = 65 FARDOS + 2) (REGALO)');
  });

  it('sin congelado usa el vivo, pero sólo si la promo no mueve stock', () => {
    const sinCongelar = { ...fraccion, unidades_por_bloque_al_crear: null };
    expect(lineaItemImpresion(sinCongelar)).toContain('= 32 FARDOS + 8');

    const mueveStock = {
      ...sinCongelar,
      promocion: { unidades_por_bloque: 12, regalo_mueve_stock: true },
    };
    // Con el gate cerrado la cantidad ya está en unidades de venta: no se parte.
    expect(lineaItemImpresion(mueveStock)).toBe('392x Botellas Manaos Pomelo 3L (REGALO)');
  });

  it('omite la equivalencia cuando no llega a una unidad completa', () => {
    const migaja = { ...fraccion, cantidad: 4 };
    expect(lineaItemImpresion(migaja))
      .toBe('4x Botellas Manaos Pomelo 3L (SUELTAS, NO FARDO) (REGALO)');
  });

  it('singulariza la equivalencia de un solo fardo', () => {
    expect(lineaItemImpresion({ ...fraccion, cantidad: 6 })).toContain('= 1 FARDO)');
  });

  it('no le pega la aclaración de bulto del producto a una cantidad en subunidades', () => {
    // La aclaración convierte unidades de venta a fardos: aplicada sobre
    // botellas sueltas contaría el bulto dos veces.
    const conBulto = {
      ...fraccion,
      producto: { nombre: 'Manaos Pomelo 3L', unidades_de_venta_por_fardo: 6, etiqueta_bulto: 'FARDO' },
    };
    expect(lineaItemImpresion(conBulto))
      .toBe('392x Botellas Manaos Pomelo 3L (SUELTAS, NO FARDO = 65 FARDOS + 2) (REGALO)');
  });

  it('el regalo de unidad entera lleva aclaración de bulto', () => {
    expect(lineaItemImpresion({
      cantidad: 12,
      es_bonificacion: true,
      producto: { nombre: 'Granadina 1L', unidades_de_venta_por_fardo: 6, etiqueta_bulto: 'FARDO' },
    })).toBe('12x Granadina 1L (2 FARDOS) (REGALO)');
  });

  it('marcarRegalo:false saca el sufijo para listas ya rotuladas', () => {
    expect(lineaItemImpresion(fraccion, { marcarRegalo: false }))
      .toBe('392x Botellas Manaos Pomelo 3L (SUELTAS, NO FARDO = 65 FARDOS + 2)');
  });

  it('la línea de venta no lleva marca de regalo', () => {
    expect(lineaItemImpresion({
      cantidad: 12,
      es_bonificacion: false,
      producto: { nombre: 'Granadina 1L', unidades_de_venta_por_fardo: 6, etiqueta_bulto: 'FARDO' },
    })).toBe('12x Granadina 1L (2 FARDOS)');
  });

  it('cae a "Producto" cuando no hay nombre', () => {
    expect(lineaItemImpresion({ cantidad: 2 })).toBe('2x Producto');
  });
});
