import { describe, it, expect } from 'vitest';
import { labelCategoriaProductos } from './labelCategoriaProductos';

describe('labelCategoriaProductos', () => {
  it('sin filtros → periodo null', () => {
    expect(labelCategoriaProductos({
      busqueda: '',
      categoriaSeleccionada: 'todas',
      mostrarSoloStockBajo: false,
    })).toEqual({ verbo: 'Productos', periodo: null });
  });

  it('stock bajo activo → "con stock bajo" (prevalece sobre todo lo demás)', () => {
    expect(labelCategoriaProductos({
      busqueda: 'agua',
      categoriaSeleccionada: 'MANAOS',
      mostrarSoloStockBajo: true,
    })).toEqual({ verbo: 'Productos', periodo: 'con stock bajo' });
  });

  it('solo categoría seleccionada → "de <cat>" en Title Case si viene all-caps', () => {
    expect(labelCategoriaProductos({
      busqueda: '',
      categoriaSeleccionada: 'MANAOS',
      mostrarSoloStockBajo: false,
    })).toEqual({ verbo: 'Productos', periodo: 'de Manaos' });
  });

  it('categoría all-caps multi-palabra → Title Case de cada palabra', () => {
    expect(labelCategoriaProductos({
      busqueda: '',
      categoriaSeleccionada: 'PAPAS FRITAS',
      mostrarSoloStockBajo: false,
    })).toEqual({ verbo: 'Productos', periodo: 'de Papas Fritas' });
  });

  it('categoría que ya viene en case mixto → se respeta', () => {
    expect(labelCategoriaProductos({
      busqueda: '',
      categoriaSeleccionada: 'Cepillo dientes',
      mostrarSoloStockBajo: false,
    })).toEqual({ verbo: 'Productos', periodo: 'de Cepillo dientes' });
  });

  it('solo búsqueda → "que coinciden con \\"X\\""', () => {
    expect(labelCategoriaProductos({
      busqueda: 'agua',
      categoriaSeleccionada: 'todas',
      mostrarSoloStockBajo: false,
    })).toEqual({ verbo: 'Productos', periodo: 'que coinciden con "agua"' });
  });

  it('categoría + búsqueda combinadas', () => {
    expect(labelCategoriaProductos({
      busqueda: 'cola',
      categoriaSeleccionada: 'MANAOS',
      mostrarSoloStockBajo: false,
    })).toEqual({
      verbo: 'Productos',
      periodo: 'de Manaos que coinciden con "cola"',
    });
  });

  it('busqueda con solo espacios se trata como vacía', () => {
    expect(labelCategoriaProductos({
      busqueda: '   ',
      categoriaSeleccionada: 'todas',
      mostrarSoloStockBajo: false,
    })).toEqual({ verbo: 'Productos', periodo: null });
  });

  it('categoriaSeleccionada como string vacío se trata como sin filtro', () => {
    expect(labelCategoriaProductos({
      busqueda: '',
      categoriaSeleccionada: '',
      mostrarSoloStockBajo: false,
    })).toEqual({ verbo: 'Productos', periodo: null });
  });
});
