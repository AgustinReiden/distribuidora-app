import { describe, it, expect } from 'vitest'
import { vendedoresElegibles } from './vendedoresComision'

describe('vendedoresElegibles', () => {
  describe('quién entra en la lista', () => {
    it('incluye a todo el padrón aunque no haya vendido nunca', () => {
      // El bug que arregla: la fuente era quien vendió EN EL PERÍODO
      // CONSULTADO, así que un admin sin ventas no aparecía nunca y no había
      // forma de cargarle una regla.
      const lista = vendedoresElegibles(
        [
          { id: 'a', nombre: 'Admin Sin Ventas' },
          { id: 'e', nombre: 'Encargado Sin Ventas' },
          { id: 'p', nombre: 'Preventista Sin Ventas' },
        ],
        [],
      )

      expect(lista.map(v => v.id)).toEqual(['a', 'e', 'p'])
    })

    it('incluye a quien vendió aunque no esté en el padrón', () => {
      // Christian: preventista inactivo, $804.249 acumulados. Sale del padrón
      // por `activo = false`, pero tiene que poder editársele la regla.
      const lista = vendedoresElegibles(
        [{ id: 'p', nombre: 'Activo' }],
        [{ id: 'x', nombre: 'Christian' }],
      )

      expect(lista.map(v => v.nombre)).toEqual(['Activo', 'Christian'])
    })

    it('la lista NO cambia al cambiar el período: el padrón es el piso', () => {
      // Julio tiene 2 pedidos en todo el año. Mirando un mes sin ventas suyas
      // el RPC no lo devuelve, y antes desaparecía del desplegable.
      const padron = [{ id: 'julio', nombre: 'Julio' }, { id: 'ana', nombre: 'Ana' }]

      const conVentas = vendedoresElegibles(padron, [{ id: 'julio', nombre: 'Julio' }])
      const sinVentas = vendedoresElegibles(padron, [])

      expect(sinVentas.map(v => v.id)).toEqual(conVentas.map(v => v.id))
    })
  })

  describe('dedupe', () => {
    it('no duplica a quien está en las dos fuentes', () => {
      const lista = vendedoresElegibles(
        [{ id: 'a', nombre: 'Ana' }],
        [{ id: 'a', nombre: 'Ana' }],
      )

      expect(lista).toHaveLength(1)
    })

    it('ante el mismo id, el nombre del padrón le gana al del RPC', () => {
      // El padrón es la fuente viva de `perfiles`; el resultado del RPC es una
      // foto del período consultado.
      const lista = vendedoresElegibles(
        [{ id: 'a', nombre: 'Ana Actualizada' }],
        [{ id: 'a', nombre: 'Ana Vieja' }],
      )

      expect(lista[0].nombre).toBe('Ana Actualizada')
    })
  })

  describe('orden', () => {
    it('ordena por nombre y no por monto ni por fuente', () => {
      const lista = vendedoresElegibles(
        [{ id: '1', nombre: 'Zulema' }, { id: '2', nombre: 'Ana' }],
        [{ id: '3', nombre: 'Marcelo' }],
      )

      expect(lista.map(v => v.nombre)).toEqual(['Ana', 'Marcelo', 'Zulema'])
    })

    it('ordena en español: los acentos no van al final', () => {
      // Con un sort de strings crudo, 'Ágata' cae después de 'Zulema'.
      const lista = vendedoresElegibles(
        [{ id: '1', nombre: 'Zulema' }, { id: '2', nombre: 'Ágata' }, { id: '3', nombre: 'Ñuke' }],
        [],
      )

      expect(lista.map(v => v.nombre)).toEqual(['Ágata', 'Ñuke', 'Zulema'])
    })

    it('ignora mayúsculas y minúsculas', () => {
      const lista = vendedoresElegibles(
        [{ id: '1', nombre: 'zulema' }, { id: '2', nombre: 'Ana' }],
        [],
      )

      expect(lista.map(v => v.nombre)).toEqual(['Ana', 'zulema'])
    })
  })

  describe('nombre legible siempre', () => {
    it('sin nombre cae al email', () => {
      const lista = vendedoresElegibles([{ id: 'a', nombre: null, email: 'ana@x.com' }], [])
      expect(lista[0].nombre).toBe('ana@x.com')
    })

    it('un nombre en blanco no se toma por bueno', () => {
      const lista = vendedoresElegibles([{ id: 'a', nombre: '   ', email: 'ana@x.com' }], [])
      expect(lista[0].nombre).toBe('ana@x.com')
    })

    it('sin nombre ni email cae a un rótulo legible, nunca a undefined', () => {
      const lista = vendedoresElegibles([{ id: 'a' }], [])
      expect(lista[0].nombre).toBe('Sin nombre')
    })

    it('nunca devuelve undefined en el nombre', () => {
      const lista = vendedoresElegibles(
        [{ id: 'a', nombre: null, email: null }, { id: 'b', nombre: undefined }],
        [{ id: 'c', nombre: '' }],
      )
      expect(lista.every(v => typeof v.nombre === 'string' && v.nombre.length > 0)).toBe(true)
    })
  })

  describe('bordes', () => {
    it('sin ninguna fuente devuelve lista vacía', () => {
      expect(vendedoresElegibles([], [])).toEqual([])
    })

    it('tolera fuentes nulas', () => {
      expect(vendedoresElegibles(null, undefined)).toEqual([])
    })
  })
})
