import { describe, it, expect } from 'vitest';
import { fechaQueFiltra, pedidoEnRangoDeFechas } from './filtroFechaPedidos';

// El caso real que motivó esto: cargado el sábado, movido a pedido=lunes y
// entrega=martes. Filtrando "hoy martes" tiene que aparecer, y la fila tiene
// que decir que apareció por la fecha de ENTREGA, no por la de pedido.
const PEDIDO_REPROGRAMADO = { fecha: '2026-08-10', fecha_entrega_programada: '2026-08-11' };

describe('fechaQueFiltra', () => {
  it('en modo entrega manda la fecha de entrega programada', () => {
    expect(fechaQueFiltra(PEDIDO_REPROGRAMADO, 'entrega'))
      .toEqual({ columna: 'entrega', valor: '2026-08-11' });
  });

  it('en modo pedido manda la fecha de pedido', () => {
    expect(fechaQueFiltra(PEDIDO_REPROGRAMADO, 'pedido'))
      .toEqual({ columna: 'pedido', valor: '2026-08-10' });
  });

  it('sin fecha de entrega, el modo entrega cae a la de pedido y lo reporta', () => {
    // Es el fallback que hacía que resaltar "entrega" fuera mentira.
    expect(fechaQueFiltra({ fecha: '2026-08-10', fecha_entrega_programada: null }, 'entrega'))
      .toEqual({ columna: 'pedido', valor: '2026-08-10' });
  });

  it('sin ninguna fecha no hay columna que resaltar', () => {
    expect(fechaQueFiltra({ fecha: null, fecha_entrega_programada: null }, 'entrega'))
      .toEqual({ columna: null, valor: null });
    expect(fechaQueFiltra({}, 'pedido'))
      .toEqual({ columna: null, valor: null });
  });
});

describe('pedidoEnRangoDeFechas', () => {
  it('el pedido reprogramado entra al filtrar el martes por entrega', () => {
    expect(pedidoEnRangoDeFechas(PEDIDO_REPROGRAMADO, 'entrega', '2026-08-11', '2026-08-11')).toBe(true);
  });

  it('y NO entra al filtrar el martes por fecha de pedido', () => {
    expect(pedidoEnRangoDeFechas(PEDIDO_REPROGRAMADO, 'pedido', '2026-08-11', '2026-08-11')).toBe(false);
  });

  it('entra al filtrar el lunes por fecha de pedido', () => {
    expect(pedidoEnRangoDeFechas(PEDIDO_REPROGRAMADO, 'pedido', '2026-08-10', '2026-08-10')).toBe(true);
  });

  it('un pedido sin fechas se muestra igual, no se esconde', () => {
    expect(pedidoEnRangoDeFechas({}, 'entrega', '2026-08-11', '2026-08-11')).toBe(true);
  });

  it('rango abierto de un lado', () => {
    expect(pedidoEnRangoDeFechas(PEDIDO_REPROGRAMADO, 'entrega', '2026-08-01', '')).toBe(true);
    expect(pedidoEnRangoDeFechas(PEDIDO_REPROGRAMADO, 'entrega', '', '2026-08-05')).toBe(false);
  });

  it('los bordes del rango son inclusivos', () => {
    expect(pedidoEnRangoDeFechas(PEDIDO_REPROGRAMADO, 'entrega', '2026-08-11', '2026-08-20')).toBe(true);
    expect(pedidoEnRangoDeFechas(PEDIDO_REPROGRAMADO, 'entrega', '2026-08-01', '2026-08-11')).toBe(true);
  });
});
