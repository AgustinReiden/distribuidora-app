/**
 * El catálogo de secciones del digest y sus helpers de presentación.
 *
 * El test que importa es el primero: la lista de claves tiene que ser la misma
 * que la del CHECK `bot_digest_config_secciones_ck` en la base y la de
 * `SECCIONES` en `supabase/functions/telegram-digest/secciones.ts`. Si se
 * desalinean, una sección se puede guardar y no mostrarse (o al revés,
 * mostrarse en el panel y que el CHECK rechace el guardado).
 */
import { describe, it, expect } from 'vitest';
import {
  DIAS_SEMANA,
  SECCIONES_DIGEST,
  formatHora,
  labelSeccion,
  resumirDias,
} from './digestSecciones';

// Copia literal del CHECK de la migración. La misma lista está en
// supabase/functions/tests/secciones.test.ts, del otro lado del mostrador.
const SECCIONES_EN_LA_BASE = [
  'ventas',
  'top_clientes',
  'top_productos',
  'stock_critico',
  'deuda',
  'pendientes_entrega',
  'pendientes_pago',
  'recorridos',
  'rendiciones',
  'vencimientos',
];

describe('SECCIONES_DIGEST', () => {
  it('tiene exactamente las claves de la lista blanca de la base', () => {
    expect(SECCIONES_DIGEST.map((s) => s.key).sort()).toEqual([...SECCIONES_EN_LA_BASE].sort());
  });

  it('ninguna sección se queda sin etiqueta ni sin detalle', () => {
    for (const s of SECCIONES_DIGEST) {
      expect(s.label.length).toBeGreaterThan(0);
      expect(s.detalle.length).toBeGreaterThan(0);
    }
  });
});

describe('DIAS_SEMANA', () => {
  it('va de 1 a 7 en orden ISO, con lunes primero y domingo último', () => {
    expect(DIAS_SEMANA.map((d) => d.iso)).toEqual([1, 2, 3, 4, 5, 6, 7]);
    expect(DIAS_SEMANA[0].largo).toBe('lunes');
    expect(DIAS_SEMANA[6].largo).toBe('domingo');
  });
});

describe('formatHora', () => {
  it('pone el cero adelante y los minutos en punto', () => {
    expect(formatHora(0)).toBe('00:00');
    expect(formatHora(7)).toBe('07:00');
    expect(formatHora(19)).toBe('19:00');
  });
});

describe('resumirDias', () => {
  it('los siete días se dicen en una palabra', () => {
    expect(resumirDias([1, 2, 3, 4, 5, 6, 7])).toBe('todos los días');
  });

  it('reconoce la semana laboral y el fin de semana', () => {
    expect(resumirDias([1, 2, 3, 4, 5])).toBe('lun a vie');
    expect(resumirDias([6, 7])).toBe('fines de semana');
  });

  it('una selección suelta se lista ordenada, sin importar el orden de clic', () => {
    expect(resumirDias([5, 1, 3])).toBe('Lun, Mié, Vie');
  });

  it('sin días lo dice en vez de devolver vacío', () => {
    expect(resumirDias([])).toBe('ningún día');
  });

  it('cuatro días consecutivos NO son "lun a vie"', () => {
    // El atajo de la semana laboral exige los cinco: si no, "lun a jue" se
    // leería como que también recibe el viernes.
    expect(resumirDias([1, 2, 3, 4])).toBe('Lun, Mar, Mié, Jue');
  });
});

describe('labelSeccion', () => {
  it('traduce la clave a la etiqueta del panel', () => {
    expect(labelSeccion('stock_critico')).toBe('Stock crítico');
  });

  it('una clave desconocida se muestra cruda en vez de desaparecer', () => {
    // Pasa con una fila vieja cuya sección se sacó del catálogo: mejor que el
    // admin vea algo raro a que la fila parezca tener una sección menos.
    expect(labelSeccion('seccion_vieja')).toBe('seccion_vieja');
  });
});
