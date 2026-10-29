import { describe, it, expect, vi } from 'vitest'
import fixture from './formasPago.espejo.json'
import {
  FORMAS_PAGO,
  FORMAS_PAGO_NO_DINERARIAS,
  FORMAS_PAGO_SELECCIONABLES,
} from './formasPago'
// El modal importa hooks que crean el cliente de Supabase; acá sólo hace falta su schema.
vi.mock('../hooks/queries/useUltimaFechaCajaCerradaQuery', () => ({
  useFechaMinimaPago: () => undefined,
}))

import { modalPagoSchema } from '../components/modals/ModalRegistrarPago'

/**
 * PARIDAD DE LAS FORMAS DE PAGO, lado TypeScript (#1249).
 *
 * El server tiene una sola lista, `formas_pago()`; `formasPago.espejo.json` es
 * su espejo. Este test afirma que el front (el catálogo, los selectores y el
 * schema del modal de cobro) dice lo mismo. El lado SQL lo compara
 * `scripts/espejo-formas-pago.mjs` contra prod. Si cambia la lista, cambian los dos.
 */

const formas = fixture.formas
const ordenado = (xs: readonly string[]) => [...xs].sort()

describe('espejo de formas_pago()', () => {
  it('FORMAS_PAGO_SELECCIONABLES son las que se registran y son plata', () => {
    const esperadas = formas.filter((f) => f.se_registra && f.dineraria).map((f) => f.forma)
    expect(ordenado(FORMAS_PAGO_SELECCIONABLES.map((m) => m.value))).toEqual(ordenado(esperadas))
  })

  it('FORMAS_PAGO_NO_DINERARIAS son las que no son plata', () => {
    const esperadas = formas.filter((f) => !f.dineraria).map((f) => f.forma)
    expect(ordenado(FORMAS_PAGO_NO_DINERARIAS)).toEqual(ordenado(esperadas))
  })

  it('cada forma del server tiene su etiqueta en FORMAS_PAGO', () => {
    const conEntrada = new Set(FORMAS_PAGO.map((m) => m.value as string))
    for (const f of formas) {
      expect(conEntrada.has(f.forma), `falta ${f.forma} en FORMAS_PAGO`).toBe(true)
    }
  })

  it('el schema del modal de cobro acepta exactamente las que se registran', () => {
    const acepta = (forma: string) => {
      const r = modalPagoSchema.safeParse({ monto: 100, formaPago: forma, referencia: 'ref-1' })
      if (r.success) return true
      // Tiene que fallar por la forma y no por otra cosa.
      expect(r.error.issues.some((i) => i.path[0] === 'formaPago')).toBe(true)
      return false
    }
    const aceptadas = [...formas.map((f) => f.forma), 'cuenta_corriente', 'vale_blanco', 'otros'].filter(acepta)
    const esperadas = formas.filter((f) => f.se_registra).map((f) => f.forma)
    expect(ordenado(aceptadas)).toEqual(ordenado(esperadas))
  })
})
