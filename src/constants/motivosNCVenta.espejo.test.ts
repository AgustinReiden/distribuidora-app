import { describe, it, expect, vi } from 'vitest'
import fixture from './motivosNCVenta.espejo.json'
import { MOTIVOS_NC_VENTA, leyendaMotivoNCVenta } from '../utils/notaCreditoVenta'

// El modal importa hooks que crean el cliente de Supabase; acá sólo hace falta su schema.
vi.mock('../hooks/queries/useNotasCreditoVentaQuery', () => ({
  useNotasCreditoVentaPedidoQuery: () => ({ data: [], isLoading: false }),
  useCrearNotaCreditoVentaMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
}))

import { notaCreditoVentaSchema } from '../components/modals/ModalNotaCreditoVenta'

/**
 * PARIDAD DE LOS MOTIVOS DE UNA NOTA DE CRÉDITO DE VENTA, lado TypeScript (B16 v3 de #1603).
 *
 * El server tiene una sola lista, `nc_venta_motivos()`; `motivosNCVenta.espejo.json` es su
 * espejo. Este test afirma que el front (el catálogo y el schema del modal) dice lo mismo. El
 * lado SQL lo compara `scripts/espejo-motivos-nc-venta.mjs`. Si cambia la lista, cambian los dos.
 */
const ordenado = (xs: readonly string[]) => [...xs].sort()

describe('espejo de nc_venta_motivos()', () => {
  it('MOTIVOS_NC_VENTA tiene los mismos motivos, con lo mismo para el vendedor y la mercadería', () => {
    const delFront = MOTIVOS_NC_VENTA.map((m) => ({
      motivo: m.value,
      descuenta_vendedor: m.descuentaVendedor,
      descuenta_unidades: m.descuentaUnidades,
      mercaderia: m.mercaderia,
    }))
    const clave = (x: { motivo: string }) => x.motivo
    expect([...delFront].sort((a, b) => clave(a).localeCompare(clave(b))))
      .toEqual([...fixture.motivos].sort((a, b) => clave(a).localeCompare(clave(b))))
  })

  it('cada motivo tiene su etiqueta', () => {
    for (const m of MOTIVOS_NC_VENTA) expect(m.label.trim().length).toBeGreaterThan(0)
  })

  it('el schema del modal acepta exactamente los motivos del server', () => {
    const acepta = (motivo: string) => notaCreditoVentaSchema.safeParse({ motivo }).success
    const candidatos = [...fixture.motivos.map((m) => m.motivo), 'diferencia_precio', 'faltante_stock', 'inventado']
    expect(ordenado(candidatos.filter(acepta))).toEqual(ordenado(fixture.motivos.map((m) => m.motivo)))
  })

  it('la leyenda del modal dice si el motivo le descuenta al vendedor', () => {
    for (const m of fixture.motivos) {
      const leyenda = leyendaMotivoNCVenta(m.motivo)
      if (!m.descuenta_vendedor) {
        expect(leyenda).toBe('Este motivo no le descuenta nada al vendedor.')
      } else if (m.descuenta_unidades) {
        expect(leyenda).toMatch(/la plata y las unidades/)
      } else {
        expect(leyenda).toMatch(/la plata \(no las unidades\)/)
      }
    }
  })
})
