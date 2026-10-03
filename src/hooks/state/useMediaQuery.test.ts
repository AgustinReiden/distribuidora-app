/**
 * useMediaQuery: el valor inicial sale de `matchMedia` en el primer render, el
 * evento `change` lo actualiza, y sin `matchMedia` es `false`.
 *
 * `matchMedia` se reemplaza por uno controlable: cada `MediaQueryList` guarda
 * sus listeners de `change` y `cambiarAncho` los dispara, como hace el
 * navegador al cruzar el corte.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { act, renderHook } from '@testing-library/react';
import { useMediaQuery, CONSULTA_CELULAR } from './useMediaQuery';

type Listener = (evento: { matches: boolean }) => void;

let ancho = 375;
let listas: Array<{ query: string; listeners: Set<Listener> }> = [];
const matchMediaOriginal = window.matchMedia;

/** Lo justo para las dos formas de query que se usan: min-width y su `not all and`. */
function evaluar(query: string): boolean {
  const min = /\(min-width:\s*(\d+(?:\.\d+)?)px\)/.exec(query);
  const coincide = min ? ancho >= Number(min[1]) : false;
  return /^\s*not\s+all\s+and\s/.test(query) ? !coincide : coincide;
}

function instalarMatchMedia(): void {
  window.matchMedia = vi.fn((query: string) => {
    const listeners = new Set<Listener>();
    listas.push({ query, listeners });
    return {
      get matches() {
        return evaluar(query);
      },
      media: query,
      onchange: null,
      addEventListener: vi.fn((_tipo: string, l: Listener) => listeners.add(l)),
      removeEventListener: vi.fn((_tipo: string, l: Listener) => listeners.delete(l)),
      addListener: vi.fn(),
      removeListener: vi.fn(),
      dispatchEvent: vi.fn(),
    } as unknown as MediaQueryList;
  }) as unknown as typeof window.matchMedia;
}

function cambiarAncho(nuevo: number): void {
  ancho = nuevo;
  act(() => {
    for (const { query, listeners } of listas) {
      for (const l of [...listeners]) l({ matches: evaluar(query) });
    }
  });
}

function listenersVivos(): number {
  return listas.reduce((n, l) => n + l.listeners.size, 0);
}

beforeEach(() => {
  ancho = 375;
  listas = [];
  instalarMatchMedia();
});

afterEach(() => {
  window.matchMedia = matchMediaOriginal;
});

describe('useMediaQuery', () => {
  it('el primer render ya trae el valor de matchMedia', () => {
    const { result } = renderHook(() => useMediaQuery(CONSULTA_CELULAR));
    expect(result.current).toBe(true);

    ancho = 1024;
    const { result: escritorio } = renderHook(() => useMediaQuery(CONSULTA_CELULAR));
    expect(escritorio.current).toBe(false);
  });

  it('el evento change lo actualiza en los dos sentidos', () => {
    const { result } = renderHook(() => useMediaQuery(CONSULTA_CELULAR));
    expect(result.current).toBe(true);

    cambiarAncho(1024);
    expect(result.current).toBe(false);

    cambiarAncho(375);
    expect(result.current).toBe(true);
  });

  it('el corte es 640 px, igual que el sm: de Tailwind', () => {
    ancho = 639;
    const { result } = renderHook(() => useMediaQuery(CONSULTA_CELULAR));
    expect(result.current).toBe(true);

    cambiarAncho(640);
    expect(result.current).toBe(false);
  });

  it('al desmontarse se desuscribe', () => {
    const { unmount } = renderHook(() => useMediaQuery(CONSULTA_CELULAR));
    expect(listenersVivos()).toBeGreaterThan(0);

    unmount();
    expect(listenersVivos()).toBe(0);
  });

  it('si cambia la query se suscribe a la nueva', () => {
    const { result, rerender } = renderHook(({ q }) => useMediaQuery(q), {
      initialProps: { q: CONSULTA_CELULAR },
    });
    expect(result.current).toBe(true);

    rerender({ q: '(min-width: 640px)' });
    expect(result.current).toBe(false);

    cambiarAncho(800);
    expect(result.current).toBe(true);
  });

  it('sin matchMedia (servidor, jsdom pelado) es false', () => {
    // @ts-expect-error: se borra a propósito para simular un entorno sin la API.
    window.matchMedia = undefined;
    const { result } = renderHook(() => useMediaQuery(CONSULTA_CELULAR));
    expect(result.current).toBe(false);
  });
});
