/**
 * Zona ↔ preventista en el formulario del cliente (mig 359).
 *
 * - El preventista con zonas da de alta sólo en las suyas: con una, se completa
 *   sola; con varias y sin coordenada, elige él.
 * - El admin que elige una zona con dueño deja tildado sólo al dueño, igual que
 *   hace la base al guardar.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
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

function renderModal(props: { isAdmin: boolean; cliente?: ClienteDB | null }) {
  return render(
    <ModalCliente
      cliente={props.cliente ?? null}
      onSave={vi.fn()}
      onVerificarDuplicado={vi.fn()}
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
