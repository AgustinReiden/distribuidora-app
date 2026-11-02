/**
 * Zona ↔ preventista en el formulario del cliente (mig 359).
 *
 * - El preventista con zonas da de alta sólo en las suyas: con una, se completa
 *   sola; con varias y sin coordenada, elige él.
 * - El admin que elige una zona con dueño deja tildado sólo al dueño, igual que
 *   hace la base al guardar.
 * - El admin que deja a otro que el dueño recibe el aviso antes de guardar
 *   (#1385), y el aviso se ve: vive adentro del modal.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import ModalCliente from './ModalCliente'
import type { ClienteDB } from '../../types'

const m = vi.hoisted(() => ({
  auth: { perfil: { rol: 'admin' }, user: { id: 'u-admin' } } as { perfil: { rol: string }; user: { id: string } },
  zonasPropias: [] as string[],
  duenios: new Map<string, string>(),
}))

vi.mock('../../hooks/queries', () => ({
  usePreventistasQuery: () => ({ data: [{ id: 'p-vic', nombre: 'Víctor' }, { id: 'p-osv', nombre: 'Osvaldo' }] }),
  useZonasEstandarizadasQuery: () => ({
    data: [
      { id: '10', nombre: 'ZONA VIC' },
      { id: '11', nombre: 'ZONA VIC 2' },
      { id: '20', nombre: 'ZONA OTRA' },
    ],
  }),
  useCategoriasQuery: () => ({ data: [] }),
  useProductosQuery: () => ({ data: [] }),
  useClientesQuery: () => ({ data: [] }),
  usePreventistaZonasQuery: (id?: string) => ({ data: id ? m.zonasPropias : [] }),
  useDueniosZonasQuery: () => ({ data: m.duenios }),
}))

vi.mock('../../contexts/AuthDataContext', () => ({
  useAuthData: () => m.auth,
}))

vi.mock('../AddressAutocomplete', () => ({
  AddressAutocomplete: ({ value, onChange }: { value: string; onChange: (v: string) => void }) => (
    <input data-testid="direccion" value={value} onChange={e => onChange(e.target.value)} />
  ),
}))

const onSave = vi.fn()
const onVerificarDuplicado = vi.fn()

function renderModal(props: { isAdmin: boolean; cliente?: ClienteDB | null }) {
  return render(
    <ModalCliente
      cliente={props.cliente ?? null}
      onSave={onSave}
      onVerificarDuplicado={onVerificarDuplicado}
      onClose={vi.fn()}
      guardando={false}
      isAdmin={props.isAdmin}
    />
  )
}

const zonaSelect = () => screen.getByRole('combobox', { name: 'Zona' }) as HTMLSelectElement
const opciones = () => Array.from(zonaSelect().options).map(o => o.textContent)

beforeEach(() => {
  m.auth = { perfil: { rol: 'admin' }, user: { id: 'u-admin' } }
  m.zonasPropias = []
  m.duenios = new Map()
  vi.clearAllMocks()
  onVerificarDuplicado.mockResolvedValue({ bloquea: false, avisa: false })
})

describe('alta de un preventista con zonas', () => {
  it('con una sola zona, el selector la trae elegida y no ofrece otras', () => {
    m.auth = { perfil: { rol: 'preventista' }, user: { id: 'p-vic' } }
    m.zonasPropias = ['10']
    renderModal({ isAdmin: false })

    expect(zonaSelect().value).toBe('10')
    expect(opciones()).toEqual(['ZONA VIC'])
  })

  it('con varias y sin dirección ubicada, no adivina: elige él entre las suyas', () => {
    m.auth = { perfil: { rol: 'preventista' }, user: { id: 'p-vic' } }
    m.zonasPropias = ['10', '11']
    renderModal({ isAdmin: false })

    expect(zonaSelect().value).toBe('')
    expect(opciones()).toEqual(['Elegí una de tus zonas…', 'ZONA VIC', 'ZONA VIC 2'])

    fireEvent.change(zonaSelect(), { target: { value: '11' } })
    expect(zonaSelect().value).toBe('11')
  })

  it('sin zonas, el selector es el de siempre', () => {
    m.auth = { perfil: { rol: 'preventista' }, user: { id: 'p-vic' } }
    renderModal({ isAdmin: false })

    expect(opciones()).toEqual(['(Sin zona)', 'ZONA VIC', 'ZONA VIC 2', 'ZONA OTRA'])
  })

  it('sin zonas, no se le ofrecen las zonas que tienen dueño (#1316: la base las rechaza)', () => {
    m.auth = { perfil: { rol: 'preventista' }, user: { id: 'p-nuevo' } }
    m.duenios = new Map([['10', 'p-vic'], ['11', 'p-vic']])
    renderModal({ isAdmin: false })

    expect(opciones()).toEqual(['(Sin zona)', 'ZONA OTRA'])
  })
})

describe('admin que elige la zona', () => {
  const cliente = {
    id: 7,
    razon_social: 'Kiosco',
    nombre_fantasia: 'Kiosco',
    direccion: 'Calle 1',
    zona_id: '20',
    preventista_ids: ['p-osv'],
  } as unknown as ClienteDB

  it('una zona con dueño deja tildado sólo al dueño', () => {
    m.duenios = new Map([['10', 'p-vic']])
    renderModal({ isAdmin: true, cliente })
    expect((screen.getByLabelText('Osvaldo') as HTMLInputElement).checked).toBe(true)

    fireEvent.change(zonaSelect(), { target: { value: '10' } })

    expect((screen.getByLabelText('Víctor') as HTMLInputElement).checked).toBe(true)
    expect((screen.getByLabelText('Osvaldo') as HTMLInputElement).checked).toBe(false)
    expect(screen.getByText('Zona de Víctor: el cliente queda asignado a Víctor.')).toBeInTheDocument()
  })

  it('una zona sin dueño no toca los preventistas', () => {
    m.duenios = new Map([['10', 'p-vic']])
    renderModal({ isAdmin: true, cliente: { ...cliente, zona_id: '10' } as unknown as ClienteDB })

    fireEvent.change(zonaSelect(), { target: { value: '20' } })

    expect((screen.getByLabelText('Osvaldo') as HTMLInputElement).checked).toBe(true)
    expect((screen.getByLabelText('Víctor') as HTMLInputElement).checked).toBe(false)
  })
})

describe('aviso de asignación fuera de zona (#1385)', () => {
  // El aviso llega por un import lazy (`ModalConfirmacion`): en frío se come el
  // segundo por defecto de `findBy*` y `waitFor` (#821).
  const ESPERA_AVISO = { timeout: 5000 }
  const cliente = {
    id: 7,
    razon_social: 'Kiosco',
    nombre_fantasia: 'Kiosco',
    direccion: 'Calle 1',
    zona_id: '10',
    preventista_ids: ['p-vic'],
  } as unknown as ClienteDB

  const guardar = () => fireEvent.click(screen.getByRole('button', { name: /^guardar$/i }))
  const tocar = (nombre: string) => fireEvent.click(screen.getByLabelText(nombre))

  it('con el dueño guarda directo', async () => {
    m.duenios = new Map([['10', 'p-vic']])
    renderModal({ isAdmin: true, cliente })
    guardar()

    await waitFor(() => expect(onSave).toHaveBeenCalled(), ESPERA_AVISO)
    expect(screen.queryByText('El preventista no es el de la zona')).not.toBeInTheDocument()
  })

  it('con otro avisa ADENTRO del modal y no guarda hasta confirmar', async () => {
    m.duenios = new Map([['10', 'p-vic']])
    renderModal({ isAdmin: true, cliente })
    tocar('Víctor')
    tocar('Osvaldo')
    guardar()

    // Si la confirmación quedara detrás del overlay, este texto no sería visible.
    expect(await screen.findByText('El preventista no es el de la zona', {}, ESPERA_AVISO)).toBeVisible()
    expect(onSave).not.toHaveBeenCalled()
    expect(onVerificarDuplicado).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole('button', { name: 'Guardar igual' }))
    await waitFor(() => expect(onSave).toHaveBeenCalled(), ESPERA_AVISO)
    expect(onVerificarDuplicado).toHaveBeenCalled()
    expect(onSave.mock.calls[0][0].preventista_ids).toEqual(['p-osv'])
  })

  it('ofrece las zonas del elegido, y pasar a una vuelve a la ficha sin guardar', async () => {
    m.duenios = new Map([['10', 'p-vic'], ['20', 'p-osv']])
    renderModal({ isAdmin: true, cliente })
    tocar('Víctor')
    tocar('Osvaldo')
    guardar()

    fireEvent.click(await screen.findByRole('button', { name: 'Pasar a ZONA OTRA' }, ESPERA_AVISO))

    await waitFor(
      () => expect(screen.queryByText('El preventista no es el de la zona')).not.toBeInTheDocument(),
      ESPERA_AVISO,
    )
    expect(zonaSelect().value).toBe('20')
    expect((screen.getByLabelText('Osvaldo') as HTMLInputElement).checked).toBe(true)
    expect(onSave).not.toHaveBeenCalled()

    // Ya no hay nada que avisar: el segundo Guardar pasa.
    guardar()
    await waitFor(() => expect(onSave).toHaveBeenCalled(), ESPERA_AVISO)
    expect(onSave.mock.calls[0][0].zona_id).toBe('20')
  })

  it('volver a la ficha no guarda nada', async () => {
    m.duenios = new Map([['10', 'p-vic']])
    renderModal({ isAdmin: true, cliente })
    tocar('Víctor')
    guardar()

    expect(await screen.findByText('El cliente queda sin preventista', {}, ESPERA_AVISO)).toBeVisible()
    fireEvent.click(screen.getByRole('button', { name: 'Volver a la ficha' }))

    await waitFor(
      () => expect(screen.queryByText('El cliente queda sin preventista')).not.toBeInTheDocument(),
      ESPERA_AVISO,
    )
    expect(onSave).not.toHaveBeenCalled()
  })

  it('reservado a administración guarda sin preguntar', async () => {
    m.duenios = new Map([['10', 'p-vic']])
    renderModal({ isAdmin: true, cliente })
    fireEvent.click(screen.getByLabelText(/Solo administradores/))
    guardar()

    await waitFor(() => expect(onSave).toHaveBeenCalled(), ESPERA_AVISO)
    expect(onSave.mock.calls[0][0].reservado_admin).toBe(true)
  })
})
