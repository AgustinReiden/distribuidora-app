import { describe, expect, it } from 'vitest';
import { tilesMapa } from './tilesMapa';

describe('tilesMapa', () => {
  it('con key usa CARTO Voyager y le agrega ?key=', () => {
    const t = tilesMapa('cb1_abc');
    expect(t.url).toBe(
      'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png?key=cb1_abc',
    );
    expect(t.subdomains).toBe('abcd');
    expect(t.attribution).toContain('CARTO');
    expect(t.attribution).toContain('OpenStreetMap');
  });

  it('sin key cae a OpenStreetMap, nunca a CARTO sin key (marca de agua)', () => {
    for (const key of [undefined, '', '   ']) {
      const t = tilesMapa(key);
      expect(t.url).not.toContain('cartocdn');
      // La CSP habilita *.tile.openstreetmap.org: el host tiene que llevar subdominio.
      expect(t.url).toBe('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png');
      expect(t.attribution).not.toContain('CARTO');
    }
  });

  it('recorta espacios de la key', () => {
    expect(tilesMapa('  cb1_abc \n').url).toMatch(/\?key=cb1_abc$/);
  });
});
