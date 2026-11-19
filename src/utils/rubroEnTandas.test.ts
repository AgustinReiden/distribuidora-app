/**
 * Renombrar o eliminar un rubro grande va en tandas (1596-b9, #1596): cada llamada a la RPC pasa
 * hasta TANDA_RUBRO productos y dice cuántos faltan; el front repite hasta terminar, mostrando el
 * avance. Si una tanda falla, lo hecho queda y el aviso dice cómo terminar.
 */
import { describe, it, expect, vi } from 'vitest'
import { procesarRubroEnTandas, TANDA_RUBRO, type RespuestaTandaRubro } from './rubroEnTandas'

const resp = (productos: number, faltan: number, extra: Partial<RespuestaTandaRubro> = {}): RespuestaTandaRubro =>
  ({ productos, faltan, terminado: faltan === 0, ...extra })

describe('procesarRubroEnTandas', () => {
  it('la tanda es de 5.000 productos', () => {
    expect(TANDA_RUBRO).toBe(5000)
  })

  it('repite hasta que no falta nada, y avisa el avance de cada tanda', async () => {
    const llamar = vi.fn()
      .mockResolvedValueOnce(resp(5000, 7000))
      .mockResolvedValueOnce(resp(5000, 2000))
      .mockResolvedValueOnce(resp(2000, 0))
    const avance = vi.fn()

    const fin = await procesarRubroEnTandas(llamar, 'r1', 'renombrar', avance)

    expect(llamar).toHaveBeenCalledTimes(3)
    expect(avance.mock.calls.map(c => c[0])).toEqual([
      { hechos: 5000, faltan: 7000 },
      { hechos: 10000, faltan: 2000 },
      { hechos: 12000, faltan: 0 },
    ])
    expect(fin).toEqual({ hechos: 12000 })
  })

  it('el rubro que sólo era texto: sigue con el id que le dio la primera tanda', async () => {
    const llamar = vi.fn()
      .mockResolvedValueOnce(resp(5000, 10, { id: 'nuevo-id' }))
      .mockResolvedValueOnce(resp(10, 0, { id: 'nuevo-id' }))

    await procesarRubroEnTandas(llamar, null, 'renombrar')

    expect(llamar.mock.calls.map(c => c[0])).toEqual([null, 'nuevo-id'])
  })

  it('un server de antes (sin «faltan») hace todo en una llamada', async () => {
    const llamar = vi.fn().mockResolvedValue({ productos: 300 })
    const fin = await procesarRubroEnTandas(llamar, 'r1', 'eliminar')
    expect(llamar).toHaveBeenCalledTimes(1)
    expect(fin).toEqual({ hechos: 300 })
  })

  it('si una tanda falla después de otras, dice cuánto se hizo y cómo terminar', async () => {
    const llamar = vi.fn()
      .mockResolvedValueOnce(resp(5000, 5000))
      .mockRejectedValueOnce(new Error('Sin conexión'))

    await expect(procesarRubroEnTandas(llamar, 'r1', 'renombrar')).rejects.toThrow(
      'Sin conexión. Ya se pasaron 5.000 productos y faltan 5.000: volvé a tocar «Renombrar» con el mismo nombre para terminar.',
    )
  })

  it('si falla la primera, el error llega tal cual (no se hizo nada)', async () => {
    const llamar = vi.fn().mockRejectedValueOnce(new Error('Ya existe un rubro llamado «X»'))
    await expect(procesarRubroEnTandas(llamar, 'r1', 'eliminar')).rejects.toThrow(/^Ya existe un rubro llamado «X»$/)
  })

  it('si una tanda no avanza, corta en vez de repetir sin fin', async () => {
    const llamar = vi.fn().mockResolvedValue(resp(0, 300))
    await expect(procesarRubroEnTandas(llamar, 'r1', 'eliminar')).rejects.toThrow(/no avanzó/)
    expect(llamar).toHaveBeenCalledTimes(1)
  })
})
