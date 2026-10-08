/**
 * Qué motivos de salvedad devuelven el stock (#1022).
 *
 * Lo decide `registrar_salvedad` y nadie más: ignora el `p_devolver_stock` que
 * manda la app. Esta lista es su espejo, para que los dos modales le digan al
 * chofer lo que va a pasar. Si cambia la lista del servidor, cambia esta, y al
 * revés: por eso está fijada entera, no "contiene".
 */
import { describe, it, expect } from 'vitest'
import { MOTIVOS_SALVEDAD_DEVUELVEN_STOCK, motivoSalvedadSchema } from './schemas'

describe('MOTIVOS_SALVEDAD_DEVUELVEN_STOCK', () => {
  it('es exactamente la lista de registrar_salvedad', () => {
    expect([...MOTIVOS_SALVEDAD_DEVUELVEN_STOCK].sort()).toEqual([
      'cliente_rechaza',
      'diferencia_precio',
      'entregado_otro_cliente',
      'error_pedido',
      'otro',
    ])
  })

  it('los que no devuelven son los que se merman (dañado, vencido, faltante)', () => {
    const noDevuelven = motivoSalvedadSchema.options.filter(m => !MOTIVOS_SALVEDAD_DEVUELVEN_STOCK.has(m))
    expect(noDevuelven.sort()).toEqual(['faltante_stock', 'producto_danado', 'producto_vencido'])
  })
})
