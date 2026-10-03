/**
 * Montar `AddressAutocomplete` no deja nodos huérfanos en `document.body` (#806).
 *
 * Con Google cargado, el efecto de inicialización crea un `<div>` oculto y lo
 * cuelga del body para construir el `PlacesService`. Nunca lo sacaba: abrir y
 * cerrar ModalCliente, ModalPedido o el alta de proveedor dejaba un div más por
 * el resto de la sesión.
 *
 * El contenedor del `render` se crea acá y se pasa a RTL: el `unmount()` de RTL
 * desmonta React pero NO saca su contenedor del body, y ese nodo contaría como
 * "sobrante" en `document.body.childElementCount`.
 *
 * Mocks: igual que AddressAutocomplete.dentroDeModal.test.tsx. `useGoogleMaps`
 * cargado y `window.google.maps` como stub; los constructores se cuentan para
 * que el test no pase en vacío si la inicialización nunca corriera.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen } from '@testing-library/react'

const googleMapsCargado = {
  isLoaded: true,
  isLoading: false,
  error: null,
  load: async (): Promise<void> => {},
}
vi.mock('../../hooks/useGoogleMaps', () => ({
  useGoogleMaps: () => googleMapsCargado,
  default: () => googleMapsCargado,
  loadGoogleMapsAPI: async (): Promise<void> => {},
}))

import AddressAutocomplete from '../AddressAutocomplete'

const construidos = { placesService: 0 }

function stubGoogleMaps({ mapFalla = false }: { mapFalla?: boolean } = {}): void {
  class AutocompleteService {}
  class PlacesService {
    constructor() {
      construidos.placesService += 1
    }
  }
  class AutocompleteSessionToken {}
  class GoogleMap {
    constructor() {
      if (mapFalla) throw new Error('Map no se pudo construir')
    }
  }

  vi.stubGlobal('google', {
    maps: {
      Map: GoogleMap,
      places: { AutocompleteService, PlacesService, AutocompleteSessionToken },
    },
  })
}

function montarYDesmontar(): void {
  const contenedor = document.body.appendChild(document.createElement('div'))
  const { unmount } = render(
    <AddressAutocomplete value="" onChange={() => {}} onSelect={() => {}} />,
    { container: contenedor },
  )
  unmount()
  contenedor.remove()
}

describe('AddressAutocomplete: no deja nodos huérfanos en document.body', () => {
  let hijosIniciales = 0

  beforeEach(() => {
    construidos.placesService = 0
    hijosIniciales = document.body.childElementCount
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('al desmontar, el body vuelve al conteo inicial', () => {
    stubGoogleMaps()

    montarYDesmontar()

    // La inicialización corrió: sin esto, "no hay huérfanos" sería trivial.
    expect(construidos.placesService).toBe(1)
    expect(document.body.childElementCount).toBe(hijosIniciales)
  })

  it('montar y desmontar varias veces no acumula nodos', () => {
    stubGoogleMaps()

    for (let i = 0; i < 5; i++) {
      montarYDesmontar()
      expect(document.body.childElementCount).toBe(hijosIniciales)
    }

    expect(construidos.placesService).toBe(5)
    expect(document.body.childElementCount).toBe(hijosIniciales)
  })

  it('si la inicialización falla a mitad de camino, tampoco queda el div', () => {
    // El div ya está colgado cuando `new Map` tira: la limpieza tiene que
    // sacarlo igual. El componente degrada a input manual.
    stubGoogleMaps({ mapFalla: true })
    const contenedor = document.body.appendChild(document.createElement('div'))
    const { unmount } = render(
      <AddressAutocomplete value="" onChange={() => {}} onSelect={() => {}} />,
      { container: contenedor },
    )

    expect(screen.getByText(/Autocompletado no disponible/)).toBeInTheDocument()
    expect(construidos.placesService).toBe(0)

    unmount()
    contenedor.remove()

    expect(document.body.childElementCount).toBe(hijosIniciales)
  })
})
