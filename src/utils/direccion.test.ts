import { describe, it, expect } from 'vitest';
import { preservarAlturaEnDireccion } from './direccion';

// Regresión del bug reportado: al elegir una sugerencia de Google en "Editar
// Cliente", la altura de la calle que tipeó el usuario se perdía y quedaba solo
// el nombre de la calle (Google geocodifica pasajes a nivel calle y abrevia el
// tipo de vía, por lo que el reemplazo por `route` no matcheaba).
describe('preservarAlturaEnDireccion', () => {
  it('preserva la altura cuando Google la pierde (geocodificó a nivel calle)', () => {
    expect(
      preservarAlturaEnDireccion(
        'Pje. Juan Padros, T4000 San Miguel de Tucumán, Tucumán, Argentina',
        'Pje. Juan Padros 1234',
      ),
    ).toBe('Pje. Juan Padros 1234, T4000 San Miguel de Tucumán, Tucumán, Argentina');
  });

  it('es robusto frente a la abreviatura del tipo de vía (Pje. vs Pasaje)', () => {
    expect(
      preservarAlturaEnDireccion(
        'Pje. Juan Padros, San Miguel de Tucumán',
        'Pasaje Juan Padros 950',
      ),
    ).toBe('Pje. Juan Padros 950, San Miguel de Tucumán');
  });

  it('funciona cuando la dirección no tiene comas', () => {
    expect(preservarAlturaEnDireccion('Eudoro Aráoz', 'eudoro araos 2135')).toBe(
      'Eudoro Aráoz 2135',
    );
  });

  it('no duplica la altura si la línea de la calle ya la tiene', () => {
    const dir = 'Pje. Juan Padros 1234, San Miguel de Tucumán';
    expect(preservarAlturaEnDireccion(dir, 'Pje. Juan Padros 1234')).toBe(dir);
  });

  it('no toca la dirección si el usuario no tipeó altura', () => {
    const dir = 'Av. Mitre, San Miguel de Tucumán';
    expect(preservarAlturaEnDireccion(dir, 'Av. Mitre')).toBe(dir);
  });

  it('toma la altura real y no el código postal (T4000)', () => {
    expect(
      preservarAlturaEnDireccion('Av. Aconquija, Yerba Buena', 'Av. Aconquija 1234 T4000'),
    ).toBe('Av. Aconquija 1234, Yerba Buena');
  });

  it('no rompe con dirección vacía', () => {
    expect(preservarAlturaEnDireccion('', 'Calle 123')).toBe('');
  });
});
