/**
 * Tests de `useBottomInset`: pisa `--bottom-inset` en `<html>` mientras recibe un
 * valor y, al dejar de recibirlo o al desmontarse, deja lo que había antes.
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { useBottomInset } from './useBottomInset'

const PROPIEDAD = '--bottom-inset'
const INSET_MAPA = 'calc(10rem + env(safe-area-inset-bottom))'

function estiloHtml(): CSSStyleDeclaration {
  return document.documentElement.style
}

function valorEnHtml(): string {
  return estiloHtml().getPropertyValue(PROPIEDAD)
}

function propiedadPresente(): boolean {
  return Array.from(estiloHtml()).includes(PROPIEDAD)
}

describe('useBottomInset', () => {
  beforeEach(() => estiloHtml().removeProperty(PROPIEDAD))
  afterEach(() => estiloHtml().removeProperty(PROPIEDAD))

  it('con un valor, lo pone como --bottom-inset en <html>', () => {
    renderHook(() => useBottomInset(INSET_MAPA))

    expect(valorEnHtml()).toBe(INSET_MAPA)
  })

  it('con null no pisa nada', () => {
    estiloHtml().setProperty(PROPIEDAD, '2rem')

    renderHook(() => useBottomInset(null))

    expect(valorEnHtml()).toBe('2rem')
  })

  it('al pasar a null vuelve al valor que había antes', () => {
    estiloHtml().setProperty(PROPIEDAD, '2rem')
    const { rerender } = renderHook(
      ({ valor }: { valor: string | null }) => useBottomInset(valor),
      { initialProps: { valor: INSET_MAPA as string | null } },
    )
    expect(valorEnHtml()).toBe(INSET_MAPA)

    rerender({ valor: null })

    expect(valorEnHtml()).toBe('2rem')
  })

  it('al pasar a null sin valor previo, la propiedad desaparece del style', () => {
    const { rerender } = renderHook(
      ({ valor }: { valor: string | null }) => useBottomInset(valor),
      { initialProps: { valor: INSET_MAPA as string | null } },
    )
    expect(propiedadPresente()).toBe(true)

    rerender({ valor: null })

    expect(propiedadPresente()).toBe(false)
    expect(valorEnHtml()).toBe('')
  })

  it('al desmontar vuelve al valor que había antes', () => {
    estiloHtml().setProperty(PROPIEDAD, '2rem')
    const { unmount } = renderHook(() => useBottomInset(INSET_MAPA))
    expect(valorEnHtml()).toBe(INSET_MAPA)

    unmount()

    expect(valorEnHtml()).toBe('2rem')
  })

  it('al desmontar sin valor previo, la propiedad desaparece del style', () => {
    const { unmount } = renderHook(() => useBottomInset(INSET_MAPA))
    expect(propiedadPresente()).toBe(true)

    unmount()

    expect(propiedadPresente()).toBe(false)
    expect(valorEnHtml()).toBe('')
  })

  it('si el valor cambia, al desmontar vuelve al de antes del primero, no al intermedio', () => {
    estiloHtml().setProperty(PROPIEDAD, '2rem')
    const { rerender, unmount } = renderHook(
      ({ valor }: { valor: string | null }) => useBottomInset(valor),
      { initialProps: { valor: '5rem' as string | null } },
    )

    rerender({ valor: INSET_MAPA })
    expect(valorEnHtml()).toBe(INSET_MAPA)

    unmount()

    expect(valorEnHtml()).toBe('2rem')
  })
})
