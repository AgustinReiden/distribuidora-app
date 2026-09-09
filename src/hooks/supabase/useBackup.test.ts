/**
 * Tests del backup completo (#523).
 *
 * EL INCIDENTE
 * ------------
 * `exportarDatos` leía `pedidos` sin `limit` ni `range`. PostgREST corta en
 * 1.000 filas y devuelve un 200, así que el archivo se bajaba entero, con
 * nombre `backup_completo_<fecha>.json`, y adentro había 1.000 de los 5.555
 * pedidos que existían. El 82% no estaba. Ni error, ni conteo, ni aviso.
 *
 * Es el peor caso de la familia del truncado: los demás muestran un número mal
 * en una pantalla y alguien lo cruza contra otra fuente. Éste produce un
 * artefacto que se guarda PARA EL DÍA QUE ALGO SALGA MAL, y ese día ya es tarde
 * para descubrir que estaba incompleto desde el principio.
 *
 * QUÉ FIJAN ESTOS TESTS
 * ---------------------
 * El fake de acá abajo emula el tope de PostgREST de verdad: nunca devuelve más
 * de 1.000 filas por request, pase lo que pase. Contra ese fake se arma un
 * backup con los volúmenes de prod (5.624 pedidos, 722 clientes, 287 productos)
 * y se cuentan las filas de cada "hoja" del JSON.
 *
 * Y la otra mitad, que es la que convierte al backup en backup: si lo que se
 * bajó no coincide con el `count` de la base, NO se genera el archivo.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'

const from = vi.fn()

vi.mock('./base', () => ({
  supabase: {
    from: (...args: unknown[]) => from(...args),
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useBackup } from './useBackup'

/** Los volúmenes reales de prod al momento de escribir esto. */
const FILAS_EN_PROD: Record<string, number> = {
  pedidos: 5624,
  clientes: 722,
  productos: 287,
}

/** El tope de PostgREST. No es configurable desde el cliente: corta y ya. */
const TOPE_POSTGREST = 1000

interface OpcionesFake { /** Filas que la tabla dice tener, si difiere de las que entrega. */ countMentido?: number }

let opciones: Record<string, OpcionesFake> = {}

/**
 * Emula PostgREST: `.range(desde, hasta)` devuelve como mucho 1.000 filas
 * aunque le pidas más, y `head: true` devuelve el `count` sin filas.
 *
 * Es la pieza importante del test: si el fake devolviera todo lo pedido, el
 * bug original no se podría reproducir y el test no probaría nada.
 */
function tablaFake(tabla: string) {
  const total = FILAS_EN_PROD[tabla] ?? 0
  const filas = Array.from({ length: total }, (_, i) => ({ id: i + 1, tabla }))
  const entregables = opciones[tabla]?.countMentido != null
    ? filas.slice(0, opciones[tabla].countMentido!)
    : filas
  const count = total

  const builder: Record<string, unknown> = {}
  builder.order = () => builder
  builder.range = (desde: number, hasta: number) => {
    const pedidas = hasta - desde + 1
    const cuantas = Math.min(pedidas, TOPE_POSTGREST)
    return Promise.resolve({ data: entregables.slice(desde, desde + cuantas), error: null })
  }
  builder.select = (_cols: string, opts?: { head?: boolean; count?: string }) => {
    if (opts?.head) return Promise.resolve({ count, data: null, error: null })
    return builder
  }
  return builder
}

beforeEach(() => {
  vi.clearAllMocks()
  opciones = {}
  from.mockImplementation((tabla: string) => tablaFake(tabla))
})

describe('useBackup — el backup completo tiene que estar completo', () => {
  describe('cuenta las filas de cada hoja del archivo', () => {
    it('trae los 5.624 pedidos, no los primeros 1.000', async () => {
      const { result } = renderHook(() => useBackup())
      let backup!: Awaited<ReturnType<typeof result.current.exportarDatos>>
      await act(async () => { backup = await result.current.exportarDatos('completo') })
      expect(backup.pedidos).toHaveLength(5624)
    })

    it('trae los 722 clientes', async () => {
      // Hoy entran bajo el tope, pero están a 278 filas de empezar a truncarse.
      const { result } = renderHook(() => useBackup())
      let backup!: Awaited<ReturnType<typeof result.current.exportarDatos>>
      await act(async () => { backup = await result.current.exportarDatos('completo') })
      expect(backup.clientes).toHaveLength(722)
    })

    it('trae los 287 productos', async () => {
      const { result } = renderHook(() => useBackup())
      let backup!: Awaited<ReturnType<typeof result.current.exportarDatos>>
      await act(async () => { backup = await result.current.exportarDatos('completo') })
      expect(backup.productos).toHaveLength(287)
    })

    it('un backup parcial trae solo su tabla, completa', async () => {
      const { result } = renderHook(() => useBackup())
      let backup!: Awaited<ReturnType<typeof result.current.exportarDatos>>
      await act(async () => { backup = await result.current.exportarDatos('pedidos') })
      expect(backup.pedidos).toHaveLength(5624)
      expect(backup.clientes).toBeUndefined()
      expect(backup.productos).toBeUndefined()
    })
  })

  describe('si no puede probar que está completo, no genera el archivo', () => {
    it('tira cuando la base entrega menos filas de las que dice tener', async () => {
      // La foto de #523: la tabla dice 5.624 y solo se pueden bajar 1.000.
      opciones = { pedidos: { countMentido: TOPE_POSTGREST } }
      const { result } = renderHook(() => useBackup())
      await expect(
        act(async () => { await result.current.exportarDatos('completo') }),
      ).rejects.toThrow(/incompleto/)
    })

    it('el error dice cuántas filas se bajaron de cuántas', async () => {
      opciones = { pedidos: { countMentido: TOPE_POSTGREST } }
      const { result } = renderHook(() => useBackup())
      await expect(
        act(async () => { await result.current.exportarDatos('completo') }),
      ).rejects.toThrow(/1000 de 5624/)
    })

    it('el error dice qué tabla quedó incompleta', async () => {
      opciones = { clientes: { countMentido: 700 } }
      const { result } = renderHook(() => useBackup())
      await expect(
        act(async () => { await result.current.exportarDatos('completo') }),
      ).rejects.toThrow(/el backup de clientes/)
    })

    // Lo que hace que esto sea un backup y no un archivo con buena intención:
    // si falla, no queda un .json a medias en Descargas con cara de completo.
    it('descargarJSON no baja nada si el backup no cierra', async () => {
      opciones = { pedidos: { countMentido: TOPE_POSTGREST } }
      // Se espía el click del <a>, no `createElement`: mockear createElement
      // entero le rompe el render a React y el test falla por otra cosa.
      const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {})
      try {
        const { result } = renderHook(() => useBackup())
        await expect(
          act(async () => { await result.current.descargarJSON('completo') }),
        ).rejects.toThrow(/incompleto/)

        expect(click).not.toHaveBeenCalled()
      } finally {
        click.mockRestore()
      }
    })

    it('descargarJSON sí baja el archivo cuando el backup cierra', async () => {
      // La contracara del test anterior: sin esto, "no bajó nada" podría estar
      // pasando porque la descarga no funciona nunca.
      const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {})
      try {
        const { result } = renderHook(() => useBackup())
        await act(async () => { await result.current.descargarJSON('completo') })
        expect(click).toHaveBeenCalledTimes(1)
      } finally {
        click.mockRestore()
      }
    })
  })

  describe('no deja el botón colgado', () => {
    it('apaga `exportando` aunque el backup falle', async () => {
      opciones = { pedidos: { countMentido: TOPE_POSTGREST } }
      const { result } = renderHook(() => useBackup())
      await expect(
        act(async () => { await result.current.exportarDatos('completo') }),
      ).rejects.toThrow()
      expect(result.current.exportando).toBe(false)
    })
  })
})
