import { describe, it, expect, vi } from 'vitest'
import { traerTodo, PAGINA_SUPABASE, TOPE_SEGURIDAD } from './paginacion'

/**
 * Simula el builder de supabase-js: `.range(desde, hasta)` devuelve una porción
 * y es thenable. Cada llamada a la factory tiene que dar un builder nuevo,
 * igual que en la vida real.
 */
function fakeTabla(filas: unknown[], opts: { error?: { message: string } } = {}) {
  const rangos: Array<[number, number]> = []
  const factory = () => ({
    range: (desde: number, hasta: number) => {
      rangos.push([desde, hasta])
      if (opts.error) return Promise.resolve({ data: null, error: opts.error })
      return Promise.resolve({ data: filas.slice(desde, hasta + 1), error: null })
    },
  })
  return { factory, rangos }
}

const filasDe = (n: number) => Array.from({ length: n }, (_, i) => ({ id: i }))

describe('traerTodo', () => {
  describe('trae todo, no lo que entre en una página', () => {
    it('junta varias páginas hasta agotar', async () => {
      // El caso que motiva todo esto: 2.500 filas con un tope de 1.000 por
      // request. Sin paginar llegan 1.000 y nadie se entera.
      const { factory } = fakeTabla(filasDe(2500))
      const filas = await traerTodo(factory, { pagina: 1000 })
      expect(filas).toHaveLength(2500)
    })

    it('pide páginas contiguas y sin solapar', async () => {
      const { factory, rangos } = fakeTabla(filasDe(2500))
      await traerTodo(factory, { pagina: 1000 })
      expect(rangos).toEqual([[0, 999], [1000, 1999], [2000, 2999]])
    })

    it('conserva el orden en que vienen las filas', async () => {
      const { factory } = fakeTabla(filasDe(2500))
      const filas = await traerTodo<{ id: number }>(factory, { pagina: 1000 })
      expect(filas[0].id).toBe(0)
      expect(filas[1500].id).toBe(1500)
      expect(filas[2499].id).toBe(2499)
    })
  })

  describe('sabe cuándo parar', () => {
    it('una página incompleta significa que no hay más: no pide otra', async () => {
      const { factory, rangos } = fakeTabla(filasDe(1500))
      await traerTodo(factory, { pagina: 1000 })
      expect(rangos).toHaveLength(2)
    })

    it('con menos de una página hace una sola request', async () => {
      const { factory, rangos } = fakeTabla(filasDe(10))
      const filas = await traerTodo(factory, { pagina: 1000 })
      expect(filas).toHaveLength(10)
      expect(rangos).toHaveLength(1)
    })

    it('sin filas devuelve vacío sin romper', async () => {
      const { factory } = fakeTabla([])
      expect(await traerTodo(factory, { pagina: 1000 })).toEqual([])
    })

    // El borde que a mano se escribe mal: un múltiplo exacto del tamaño de
    // página necesita una request de más para saber que ya no hay nada.
    it('un múltiplo exacto de la página pide una vez más y corta', async () => {
      const { factory, rangos } = fakeTabla(filasDe(2000))
      const filas = await traerTodo(factory, { pagina: 1000 })
      expect(filas).toHaveLength(2000)
      expect(rangos).toEqual([[0, 999], [1000, 1999], [2000, 2999]])
    })
  })

  describe('falla ruidosamente, nunca en silencio', () => {
    it('propaga el error de la base', async () => {
      const { factory } = fakeTabla(filasDe(10), { error: { message: 'boom' } })
      await expect(traerTodo(factory)).rejects.toThrow('boom')
    })

    it('el error dice QUÉ se estaba trayendo', async () => {
      // Un "Database error" pelado no sirve en un export de siete consultas.
      const { factory } = fakeTabla(filasDe(10), { error: { message: 'boom' } })
      await expect(traerTodo(factory, { etiqueta: 'cobranzas' })).rejects.toThrow(
        'Error cargando cobranzas: boom',
      )
    })

    // Un tope que se alcanza y devuelve lo que juntó sería exactamente el bug
    // que esto viene a arreglar, pero con otro número.
    it('si se pasa del tope de seguridad tira, no devuelve una lista corta', async () => {
      const { factory } = fakeTabla(filasDe(5000))
      await expect(
        traerTodo(factory, { pagina: 100, tope: 300, etiqueta: 'pedidos' })
      ).rejects.toThrow(/pedidos/)
    })

    it('el error del tope dice cuántas filas se esperaban como máximo', async () => {
      const { factory } = fakeTabla(filasDe(5000))
      await expect(
        traerTodo(factory, { pagina: 100, tope: 300 })
      ).rejects.toThrow(/300/)
    })
  })

  describe('valores por defecto', () => {
    it('la página por defecto es el tope de PostgREST', () => {
      expect(PAGINA_SUPABASE).toBe(1000)
    })

    it('el tope de seguridad deja margen para años de crecimiento', () => {
      // Hoy la tabla más grande que se pagina son ~5.500 pedidos.
      expect(TOPE_SEGURIDAD).toBeGreaterThanOrEqual(100000)
    })

    it('usa la página por defecto si no se le pasa ninguna', async () => {
      const { factory, rangos } = fakeTabla(filasDe(5))
      await traerTodo(factory)
      expect(rangos[0]).toEqual([0, PAGINA_SUPABASE - 1])
    })
  })

  describe('la factory se llama de nuevo en cada página', () => {
    it('no reutiliza el builder, que en supabase-js es de un solo uso', async () => {
      const factory = vi.fn(() => ({
        range: (desde: number, hasta: number) =>
          Promise.resolve({ data: filasDe(2500).slice(desde, hasta + 1), error: null }),
      }))
      await traerTodo(factory, { pagina: 1000 })
      expect(factory).toHaveBeenCalledTimes(3)
    })
  })
})
