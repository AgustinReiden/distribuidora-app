import { describe, it, expect, vi } from 'vitest'
import { traerTodo, traerTodoVerificado, PAGINA_SUPABASE, TOPE_SEGURIDAD } from './paginacion'

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

describe('traerTodoVerificado', () => {
  const contarOk = (n: number) => () => Promise.resolve({ count: n, error: null })

  describe('cuando puede demostrar que trajo todo', () => {
    it('devuelve las filas si coinciden con el count', async () => {
      const { factory } = fakeTabla(filasDe(2500))
      const filas = await traerTodoVerificado(factory, {
        pagina: 1000,
        contar: contarOk(2500),
      })
      expect(filas).toHaveLength(2500)
    })

    it('sirve para una tabla vacia', async () => {
      const { factory } = fakeTabla([])
      expect(await traerTodoVerificado(factory, { contar: contarOk(0) })).toEqual([])
    })
  })

  describe('cuando NO puede, no deja generar el archivo', () => {
    // El caso de #523: la consulta devuelve 1.000 de 5.555 y nadie se entera.
    // Aca el count no coincide, asi que tiene que tirar en vez de devolver.
    it('tira si bajo menos filas que el count', async () => {
      // La foto exacta de #523: la base dice 5.555 y solo llegan 1.000.
      const { factory } = fakeTabla(filasDe(1000))
      await expect(
        traerTodoVerificado(factory, { pagina: 1000, contar: contarOk(5555) }),
      ).rejects.toThrow(/incompleto/)
    })

    it('el error dice cuantas filas se bajaron de cuantas', async () => {
      const { factory } = fakeTabla(filasDe(1000))
      await expect(
        traerTodoVerificado(factory, { pagina: 1000, contar: contarOk(5555) }),
      ).rejects.toThrow(/1000 de 5555/)
    })

    it('el error dice QUE quedo incompleto', async () => {
      const { factory } = fakeTabla(filasDe(10))
      await expect(
        traerTodoVerificado(factory, {
          etiqueta: 'el backup de pedidos',
          contar: contarOk(99),
        }),
      ).rejects.toThrow(/el backup de pedidos/)
    })

    // Una fila insertada entre el conteo y la ultima pagina tambien rompe.
    // Es a proposito: rehacer un backup es barato, uno incompleto no.
    it('tira tambien si bajo MAS filas que el count', async () => {
      const { factory } = fakeTabla(filasDe(11))
      await expect(
        traerTodoVerificado(factory, { contar: contarOk(10) }),
      ).rejects.toThrow(/incompleto/)
    })

    it('propaga el error del conteo sin llegar a paginar', async () => {
      const { factory, rangos } = fakeTabla(filasDe(10))
      await expect(
        traerTodoVerificado(factory, {
          etiqueta: 'el backup de pedidos',
          contar: () => Promise.resolve({ count: null, error: { message: 'boom' } }),
        }),
      ).rejects.toThrow('No se pudo contar el backup de pedidos: boom')
      expect(rangos).toHaveLength(0)
    })

    // Un error a mitad de la paginacion tampoco puede terminar en archivo.
    it('propaga el error de una pagina', async () => {
      const { factory } = fakeTabla(filasDe(10), { error: { message: 'boom' } })
      await expect(
        traerTodoVerificado(factory, { contar: contarOk(10) }),
      ).rejects.toThrow('boom')
    })
  })

  describe('cuando la base no da un count', () => {
    // `count: null` es "no se pudo contar", no "hay cero". Verificar contra eso
    // convertiria cualquier consulta en un fallo; se deja pasar lo que trajo
    // `traerTodo`, que ya de por si pagina hasta agotar.
    it('no inventa una verificacion si el count viene null', async () => {
      const { factory } = fakeTabla(filasDe(2500))
      const filas = await traerTodoVerificado(factory, {
        pagina: 1000,
        contar: () => Promise.resolve({ count: null, error: null }),
      })
      expect(filas).toHaveLength(2500)
    })
  })
})
