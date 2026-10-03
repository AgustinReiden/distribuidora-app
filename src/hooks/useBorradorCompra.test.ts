import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { useBorradorCompra } from './useBorradorCompra'
import { compraReducer, initialState } from '../components/modals/ModalCompra.reducer'
import type { CompraState } from '../components/modals/ModalCompra.reducer'
import { serializarBorrador, leerBorrador } from '../utils/borradorCompra'

const CLAVE = 'compra-borrador:1:u1'
const DEMORA = 500

const conNumero = (numero: string): CompraState =>
  compraReducer(initialState, { type: 'SET_NUMERO_FACTURA', payload: numero })

const montar = (clave: string | null, state: CompraState) =>
  renderHook(({ s }) => useBorradorCompra(clave, s, DEMORA), { initialProps: { s: state } })

const guardado = () => {
  const l = leerBorrador(window.localStorage.getItem(CLAVE))
  return l.tipo === 'ok' ? l.borrador.estado.numeroFactura : l.tipo
}

beforeEach(() => {
  vi.useFakeTimers()
  window.localStorage.clear()
})

afterEach(() => {
  vi.useRealTimers()
})

describe('useBorradorCompra', () => {
  it('sin borrador previo: autosave con debounce, sólo si hay algo cargado', () => {
    const { rerender } = montar(CLAVE, initialState)
    act(() => { vi.advanceTimersByTime(DEMORA) })
    expect(window.localStorage.getItem(CLAVE)).toBeNull()

    rerender({ s: conNumero('0005-00001234') })
    act(() => { vi.advanceTimersByTime(DEMORA - 1) })
    expect(window.localStorage.getItem(CLAVE)).toBeNull()
    act(() => { vi.advanceTimersByTime(1) })
    expect(guardado()).toBe('0005-00001234')
  })

  it('con un borrador al abrir: lo ofrece y NO lo pisa mientras no se decide', () => {
    window.localStorage.setItem(CLAVE, serializarBorrador(conNumero('VIEJO-1234'), new Date()))
    const { result, rerender } = montar(CLAVE, initialState)

    expect(result.current.pendiente.tipo).toBe('ok')
    rerender({ s: conNumero('NUEVO-9999') })
    act(() => { vi.advanceTimersByTime(DEMORA * 3) })
    expect(guardado()).toBe('VIEJO-1234')
  })

  it('retomar devuelve el estado y prende el autosave', () => {
    window.localStorage.setItem(CLAVE, serializarBorrador(conNumero('VIEJO-1234'), new Date()))
    const { result, rerender } = montar(CLAVE, initialState)

    let estado: CompraState | null = null
    act(() => { estado = result.current.retomar() })
    expect(estado!.numeroFactura).toBe('VIEJO-1234')
    expect(result.current.pendiente.tipo).toBe('ninguno')

    rerender({ s: conNumero('VIEJO-1234-editado') })
    act(() => { vi.advanceTimersByTime(DEMORA) })
    expect(guardado()).toBe('VIEJO-1234-editado')
  })

  it('descartar lo borra y prende el autosave', () => {
    window.localStorage.setItem(CLAVE, serializarBorrador(conNumero('VIEJO-1234'), new Date()))
    const { result } = montar(CLAVE, initialState)
    act(() => { result.current.descartarPendiente() })
    expect(window.localStorage.getItem(CLAVE)).toBeNull()
    expect(result.current.pendiente.tipo).toBe('ninguno')
  })

  it('un borrador de otra versión se ofrece, no se carga', () => {
    window.localStorage.setItem(CLAVE, JSON.stringify({ version: 999, guardadoEn: 'x', estado: {} }))
    const { result } = montar(CLAVE, initialState)
    expect(result.current.pendiente.tipo).toBe('otra_version')
    let estado: CompraState | null = initialState
    act(() => { estado = result.current.retomar() })
    expect(estado).toBeNull()
    expect(window.localStorage.getItem(CLAVE)).not.toBeNull()
  })

  it('al registrar: cancela el debounce pendiente y borra; el desmontaje no lo reescribe', () => {
    const { result, rerender, unmount } = montar(CLAVE, conNumero('0005-00001234'))
    act(() => { vi.advanceTimersByTime(DEMORA) })
    expect(guardado()).toBe('0005-00001234')

    rerender({ s: conNumero('0005-00001235') })
    act(() => { result.current.finalizar() })
    act(() => { vi.advanceTimersByTime(DEMORA * 2) })
    unmount()
    expect(window.localStorage.getItem(CLAVE)).toBeNull()
  })

  it('al desmontar escribe lo pendiente (el cambio de sucursal cierra el modal)', () => {
    const { rerender, unmount } = montar(CLAVE, initialState)
    rerender({ s: conNumero('0005-00001234') })
    unmount()
    expect(guardado()).toBe('0005-00001234')
  })

  it('sin clave (sin sucursal o usuario) no toca nada', () => {
    const { result, rerender, unmount } = montar(null, initialState)
    rerender({ s: conNumero('0005-00001234') })
    act(() => { vi.advanceTimersByTime(DEMORA) })
    unmount()
    expect(result.current.pendiente.tipo).toBe('ninguno')
    expect(window.localStorage.length).toBe(0)
  })

  it('avisa si otra pestaña modifica o borra el borrador', () => {
    const { result } = montar(CLAVE, conNumero('0005-00001234'))
    act(() => {
      window.dispatchEvent(new StorageEvent('storage', { key: CLAVE, newValue: '{"otra":1}' }))
    })
    expect(result.current.otraPestana).toBe('modificado')
    act(() => { result.current.cerrarAvisoOtraPestana() })
    act(() => {
      window.dispatchEvent(new StorageEvent('storage', { key: CLAVE, newValue: null }))
    })
    expect(result.current.otraPestana).toBe('borrado')
    // Otra clave no importa.
    act(() => { result.current.cerrarAvisoOtraPestana() })
    act(() => {
      window.dispatchEvent(new StorageEvent('storage', { key: 'otra', newValue: 'x' }))
    })
    expect(result.current.otraPestana).toBeNull()
  })

  it('mientras se decide, lo que cambia en otra pestaña actualiza la oferta', () => {
    window.localStorage.setItem(CLAVE, serializarBorrador(conNumero('VIEJO-1234'), new Date()))
    const { result } = montar(CLAVE, initialState)
    act(() => {
      window.dispatchEvent(new StorageEvent('storage', { key: CLAVE, newValue: null }))
    })
    expect(result.current.pendiente.tipo).toBe('ninguno')
  })
})
