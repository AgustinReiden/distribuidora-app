import { describe, it, expect } from 'vitest';
import { adicionalConIvaDeCompra, adicionalDeCompra, conAdicionalDeCompra, costoEditadoEnFicha } from './costoFinalProducto';
import { calcularCostoReal } from './calculations';

// Números sintéticos: una gaseosa con neto 4.000, II 8,6957 %, y una compra con
// flete y pallets que dejó 5.200 de costo final.
const gaseosa = { costo_sin_iva: 4000, impuestos_internos: 8.6957, costo_real: 5200 };

describe('adicionalDeCompra', () => {
  it('es lo que el costo guardado tiene por encima de neto + II', () => {
    const base = calcularCostoReal(gaseosa.costo_sin_iva, gaseosa.impuestos_internos, 'FC');
    expect(adicionalDeCompra(gaseosa, 'FC')).toBeCloseTo(gaseosa.costo_real - base, 4);
    expect(adicionalDeCompra(gaseosa, 'FC')).toBeGreaterThan(800);
  });

  it('sin tocar el costo, la ficha muestra exactamente el costo final que dejó la compra', () => {
    const adicional = adicionalDeCompra(gaseosa, 'FC');
    const final = conAdicionalDeCompra(calcularCostoReal(gaseosa.costo_sin_iva, gaseosa.impuestos_internos, 'FC'), adicional);
    expect(final).toBeCloseTo(gaseosa.costo_real, 4);
  });

  it('si el admin corrige el neto, el flete por unidad se conserva', () => {
    const adicional = adicionalDeCompra(gaseosa, 'FC');
    const final = conAdicionalDeCompra(calcularCostoReal(5000, gaseosa.impuestos_internos, 'FC'), adicional);
    expect(final).toBeCloseTo(calcularCostoReal(5000, gaseosa.impuestos_internos, 'FC') + adicional, 4);
    expect(final).toBeGreaterThan(calcularCostoReal(5000, gaseosa.impuestos_internos, 'FC'));
  });

  it('en ZZ lo pagado ya es todo: el adicional es lo que se sumó encima, sin mirar el II de la ficha', () => {
    expect(adicionalDeCompra({ costo_sin_iva: 1000, impuestos_internos: 10, costo_real: 1100 }, 'ZZ')).toBe(100);
  });

  it('puede ser negativo: una bonificación prorrateada baja el costo final', () => {
    expect(adicionalDeCompra({ costo_sin_iva: 2000, impuestos_internos: 0, costo_real: 1934.19 }, 'FC')).toBeCloseTo(-65.81, 4);
  });

  it('sin neto o sin costo guardado no hay nada que medir', () => {
    expect(adicionalDeCompra({ costo_sin_iva: 1000, costo_real: null }, 'FC')).toBe(0);
    expect(adicionalDeCompra({ costo_sin_iva: '', costo_real: 1200 }, 'FC')).toBe(0);
    expect(adicionalDeCompra({ costo_sin_iva: 0, costo_real: 1200 }, 'FC')).toBe(0);
    expect(adicionalDeCompra(null, 'FC')).toBe(0);
  });

  it('acepta los numéricos como texto, que es como los deja el form', () => {
    expect(adicionalDeCompra({ costo_sin_iva: '1000', impuestos_internos: '0', costo_real: '1050.5' }, 'FC')).toBe(50.5);
  });
});

describe('conAdicionalDeCompra', () => {
  it('sin costo base no hay costo: el flete solo no es un costo', () => {
    expect(conAdicionalDeCompra(0, 1317.95)).toBe(0);
  });
});

describe('costoEditadoEnFicha', () => {
  it('el mismo número como texto o como número no es un cambio', () => {
    expect(costoEditadoEnFicha(gaseosa, { costo_sin_iva: '4000', impuestos_internos: '8.6957' })).toBe(false);
  });

  it('vacío y null son lo mismo: sin costo', () => {
    expect(costoEditadoEnFicha({ costo_sin_iva: null, impuestos_internos: null }, { costo_sin_iva: '', impuestos_internos: '' })).toBe(false);
  });

  it('cambiar el neto o la tasa de II es tocar el costo', () => {
    expect(costoEditadoEnFicha(gaseosa, { costo_sin_iva: 5000, impuestos_internos: gaseosa.impuestos_internos })).toBe(true);
    expect(costoEditadoEnFicha(gaseosa, { costo_sin_iva: gaseosa.costo_sin_iva, impuestos_internos: 4.1667 })).toBe(true);
  });
});

describe('adicionalConIvaDeCompra (1593-b1)', () => {
  it('es lo que el costo con IVA de la compra tiene por encima de neto + IVA + II: el flete y su IVA', () => {
    // FC A 100 al 21 % con un flete de 10 por unidad y su IVA (2,10): la compra deja 133,10.
    expect(adicionalConIvaDeCompra({ costo_sin_iva: 100, impuestos_internos: 0, porcentaje_iva: 21, costo_con_iva: 133.1, ultimo_tipo_compra: 'FC' }, 'FC')).toBe(12.1);
  });

  it('en ZZ es lo pagado por encima del neto', () => {
    expect(adicionalConIvaDeCompra({ costo_sin_iva: 100, costo_con_iva: 130, ultimo_tipo_compra: 'ZZ' }, 'ZZ')).toBe(30);
  });

  it('un producto sin cargos da 0, aunque el centavo del redondeo no cierre', () => {
    expect(adicionalConIvaDeCompra({ costo_sin_iva: 4000, impuestos_internos: 8.6957, porcentaje_iva: 21, costo_con_iva: 5187.83 }, 'FC')).toBe(0);
  });

  it('sin ninguna compra (ultimo_tipo_compra vacío) no hay cargos que conservar (N4)', () => {
    // Un importado con el costo con IVA igual al neto: corregir el neto en la ficha lo limpia.
    expect(adicionalConIvaDeCompra({ costo_sin_iva: 100, porcentaje_iva: 21, costo_con_iva: 100, ultimo_tipo_compra: null }, 'FC')).toBe(0);
  });

  it('sin neto o sin costo con IVA no hay nada que medir', () => {
    expect(adicionalConIvaDeCompra({ costo_sin_iva: null, costo_con_iva: 131 }, 'FC')).toBe(0);
    expect(adicionalConIvaDeCompra({ costo_sin_iva: 100, costo_con_iva: null }, 'FC')).toBe(0);
  });
});
