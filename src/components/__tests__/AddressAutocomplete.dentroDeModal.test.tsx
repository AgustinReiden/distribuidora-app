/**
 * Las sugerencias de dirección se cierran con un click afuera, también dentro
 * de un modal.
 *
 * `ModalBase` corta la propagación de `mousedown` (`onMouseDown` con
 * `stopPropagation`, ver ModalBase.tsx). Con el listener de "click afuera" de
 * `AddressAutocomplete` en fase de burbujeo, ningún click adentro del modal
 * llegaba a `document`: la lista quedaba abierta tapando los campos de abajo
 * (ModalCliente, ModalPedido y el alta de proveedor abierta desde una compra).
 * El caso fuera de un modal es el control: ahí siempre anduvo.
 *
 * Mocks: `useGoogleMaps` se mockea como en ModalPedido.smoke.test.tsx, pero
 * cargado (`isLoaded: true`), y `window.google.maps` es un stub con lo mínimo
 * que el componente construye al iniciar y al buscar.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useState } from 'react'
import type { ReactElement } from 'react'

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
import ModalBase from '../modals/ModalBase'

const PREDICCIONES = [
  {
    place_id: 'place-1',
    description: 'Av. Mate de Luna 1234, San Miguel de Tucumán, Tucumán',
    structured_formatting: {
      main_text: 'Av. Mate de Luna 1234',
      secondary_text: 'San Miguel de Tucumán, Tucumán',
    },
  },
  {
    place_id: 'place-2',
    description: 'Mate de Luna 1234, Yerba Buena, Tucumán',
    structured_formatting: {
      main_text: 'Mate de Luna 1234',
      secondary_text: 'Yerba Buena, Tucumán',
    },
  },
]

function stubGoogleMaps(): void {
  class AutocompleteService {
    getPlacePredictions(
      _request: unknown,
      callback: (resultados: typeof PREDICCIONES, status: string) => void,
    ): void {
      callback(PREDICCIONES, 'OK')
    }
  }
  class PlacesService {
    // Sin detalles (status distinto de OK): el componente cae en su fallback y
    // elige la dirección de la sugerencia tal cual.
    getDetails(_request: unknown, callback: (lugar: null, status: string) => void): void {
      callback(null, 'NOT_FOUND')
    }
  }
  class AutocompleteSessionToken {}
  class LatLng {
    constructor(
      readonly lat: number,
      readonly lng: number,
    ) {}
  }
  class GoogleMap {}

  vi.stubGlobal('google', {
    maps: {
      LatLng,
      Map: GoogleMap,
      places: {
        AutocompleteService,
        PlacesService,
        AutocompleteSessionToken,
        PlacesServiceStatus: { OK: 'OK' },
      },
    },
  })
}

function CampoDireccion({ onSelect = () => {} }: { onSelect?: (r: unknown) => void }): ReactElement {
  const [direccion, setDireccion] = useState('')
  return (
    <>
      <AddressAutocomplete value={direccion} onChange={setDireccion} onSelect={onSelect} />
      <button type="button">Otro campo</button>
    </>
  )
}

async function abrirSugerencias(user: ReturnType<typeof userEvent.setup>): Promise<void> {
  await user.type(screen.getByPlaceholderText('Buscar dirección...'), 'Mate de Luna')
  expect(await screen.findByText('Av. Mate de Luna 1234')).toBeInTheDocument()
  expect(screen.getByText('Mate de Luna 1234')).toBeInTheDocument()
}

describe('AddressAutocomplete: click afuera cierra las sugerencias', () => {
  beforeEach(() => {
    stubGoogleMaps()
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('dentro de ModalBase, que corta la propagación de mousedown', async () => {
    const user = userEvent.setup()
    render(
      <ModalBase title="Alta" onClose={vi.fn()}>
        <CampoDireccion />
      </ModalBase>,
    )
    expect(window.google).toBeDefined()

    await abrirSugerencias(user)

    await user.click(screen.getByRole('button', { name: 'Otro campo' }))

    expect(screen.queryByText('Av. Mate de Luna 1234')).not.toBeInTheDocument()
    expect(screen.queryByText('Mate de Luna 1234')).not.toBeInTheDocument()
    // Sigue abierto el modal: el click cerró la lista, no el diálogo.
    expect(screen.getByRole('dialog', { name: 'Alta' })).toBeInTheDocument()
  })

  it('fuera de un modal (control)', async () => {
    const user = userEvent.setup()
    render(<CampoDireccion />)

    await abrirSugerencias(user)

    await user.click(screen.getByRole('button', { name: 'Otro campo' }))

    expect(screen.queryByText('Av. Mate de Luna 1234')).not.toBeInTheDocument()
    expect(screen.queryByText('Mate de Luna 1234')).not.toBeInTheDocument()
  })

  it('dentro de ModalBase, un click en una sugerencia la elige', async () => {
    // El listener de "click afuera" corre en captura, ANTES que el click de la
    // sugerencia: si tratara a la lista como "afuera", la desmontaría en el
    // mousedown y el click nunca llegaría.
    const user = userEvent.setup()
    const onSelect = vi.fn()
    render(
      <ModalBase title="Alta" onClose={vi.fn()}>
        <CampoDireccion onSelect={onSelect} />
      </ModalBase>,
    )

    await abrirSugerencias(user)

    await user.click(screen.getByText('Av. Mate de Luna 1234'))

    expect(onSelect).toHaveBeenCalledTimes(1)
    expect(onSelect).toHaveBeenCalledWith(expect.objectContaining({ placeId: 'place-1' }))
    expect(screen.getByPlaceholderText('Buscar dirección...')).toHaveValue(
      'Av. Mate de Luna 1234, San Miguel de Tucumán, Tucumán',
    )
    expect(screen.queryByText('Mate de Luna 1234')).not.toBeInTheDocument()
  })

  it('dentro de ModalBase, un click en el propio input no la cierra', async () => {
    const user = userEvent.setup()
    render(
      <ModalBase title="Alta" onClose={vi.fn()}>
        <CampoDireccion />
      </ModalBase>,
    )

    await abrirSugerencias(user)

    // El input es parte del componente: tocarlo no es "afuera". Guarda contra
    // un listener en captura que cierre ante cualquier mousedown.
    await user.click(screen.getByPlaceholderText('Buscar dirección...'))

    expect(screen.getByText('Av. Mate de Luna 1234')).toBeInTheDocument()
  })
})
