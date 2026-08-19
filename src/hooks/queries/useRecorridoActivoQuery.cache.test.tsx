/**
 * El chofer abre la app sin señal y su ruta sigue ahí.
 *
 * Es el escenario que motiva todo el cache: iOS descarta la PWA en segundo
 * plano y el cache de react-query vive solo en memoria, así que al volver a
 * abrirla el chofer se quedaba sin paradas, sin direcciones y sin los totales a
 * cobrar, con el camión cargado.
 *
 * Se testea acá y no en el navegador porque supabase-js captura `fetch` al
 * construir el cliente: pisar `window.fetch` después de que la app arrancó no
 * corta nada, y una "prueba offline" así da un falso verde.
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { renderHook, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import React from 'react';

const maybeSingle = vi.fn();

vi.mock('../supabase/base', () => ({
  supabase: {
    from: () => ({
      select: () => ({
        eq: function () { return this; },
        in: function () { return this; },
        order: function () { return this; },
        limit: function () { return this; },
        maybeSingle,
      }),
    }),
  },
}));

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}));

import { useRecorridoActivoQuery } from './useRecorridoActivoQuery';
import { guardarRuta } from '../../lib/rutaOfflineCache';
import { fechaLocalISO } from '../../utils/formatters';

const CHOFER = 'a0adb1f2-5bd7-455d-83a7-a51a857798ab';

function almacenEnMemoria() {
  let store: Record<string, string> = {};
  return {
    get length() { return Object.keys(store).length; },
    getItem: (k: string) => (k in store ? store[k] : null),
    setItem: (k: string, v: string) => { store[k] = String(v); },
    removeItem: (k: string) => { delete store[k]; },
    clear: () => { store = {}; },
    key: (i: number) => Object.keys(store)[i] ?? null,
  };
}

function wrapper({ children }: { children: React.ReactNode }) {
  // `retry: false` para que el fallo de red sea inmediato, como el primer
  // intento real; sin esto el test espera los reintentos con backoff.
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>;
}

const rutaGuardada = {
  id: '95',
  polylines: null,
  fecha: fechaLocalISO(),
  obtenidoEn: Date.now() - 60_000,
  paradas: [
    { id: '1', estado: 'asignado', total: 61600, cliente: { nombre_fantasia: 'Kiosco villa amalia' } },
    { id: '2', estado: 'asignado', total: 12000, cliente: { nombre_fantasia: 'Despensa Mi angel' } },
  ],
};

describe('useRecorridoActivoQuery — la ruta sobrevive sin señal', () => {
  beforeEach(() => {
    Object.defineProperty(globalThis, 'localStorage', {
      value: almacenEnMemoria(), configurable: true, writable: true,
    });
    maybeSingle.mockReset();
  });

  it('sin red y con cache, muestra la ruta guardada y la marca como tal', async () => {
    guardarRuta(1, CHOFER, fechaLocalISO(), rutaGuardada);
    maybeSingle.mockRejectedValue(new TypeError('Failed to fetch'));

    const { result } = renderHook(() => useRecorridoActivoQuery(CHOFER), { wrapper });

    // Lo que importa: hay paradas en pantalla desde el primer render.
    expect(result.current.data?.paradas).toHaveLength(2);
    expect(result.current.data?.paradas[0].cliente?.nombre_fantasia).toBe('Kiosco villa amalia');
    // Y se dice que son viejas, en vez de hacerlas pasar por vivas.
    await waitFor(() => expect(result.current.desdeCache).toBe(true));
    expect(result.current.datosDe).toBeTruthy();
  });

  it('sin red y SIN cache, no inventa una ruta', async () => {
    maybeSingle.mockRejectedValue(new TypeError('Failed to fetch'));

    const { result } = renderHook(() => useRecorridoActivoQuery(CHOFER), { wrapper });

    await waitFor(() => expect(result.current.isError).toBe(true));
    expect(result.current.data).toBeUndefined();
    expect(result.current.desdeCache).toBe(false);
  });

  // Con red, lo fresco gana: el cache no puede dejar la pantalla pegada a una
  // foto vieja mientras el servidor responde.
  //
  // El cache se guarda ENVEJECIDO a proposito. `initialDataUpdatedAt` lleva el
  // sello del guardado, asi que react-query lo compara contra `staleTime` (60 s):
  // una ruta guardada recien se considera fresca y NO se refetchea —correcto,
  // porque se acaba de traer del servidor—, y una guardada hace rato se
  // considera vieja y dispara el refetch. El caso que importa es el segundo: la
  // PWA que se reabre horas despues.
  it('con red, los datos del servidor reemplazan al cache', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date(Date.now() - 10 * 60_000));
    guardarRuta(1, CHOFER, fechaLocalISO(), rutaGuardada);
    vi.useRealTimers();
    maybeSingle.mockResolvedValue({
      data: {
        id: '95', polylines: null, fecha: fechaLocalISO(),
        recorrido_pedidos: [
          { orden_entrega: 1, pedido: { id: '1', estado: 'entregado', cliente: {}, items: [] } },
          { orden_entrega: 2, pedido: { id: '2', estado: 'asignado', cliente: {}, items: [] } },
          { orden_entrega: 3, pedido: { id: '3', estado: 'asignado', cliente: {}, items: [] } },
        ],
      },
      error: null,
    });

    const { result } = renderHook(() => useRecorridoActivoQuery(CHOFER), { wrapper });

    await waitFor(() => expect(result.current.data?.paradas).toHaveLength(3));
    expect(result.current.desdeCache).toBe(false);
  });

  // Multi-tenant: la ruta guardada para la sucursal 1 no puede sembrar a otra.
  it('no siembra con el cache de otra sucursal', async () => {
    guardarRuta(2, CHOFER, fechaLocalISO(), rutaGuardada);
    maybeSingle.mockRejectedValue(new TypeError('Failed to fetch'));

    const { result } = renderHook(() => useRecorridoActivoQuery(CHOFER), { wrapper });

    await waitFor(() => expect(result.current.isError).toBe(true));
    expect(result.current.data).toBeUndefined();
  });
});
