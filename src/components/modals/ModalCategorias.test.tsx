/**
 * Caracteriza el campo "Nueva categoría" de ModalCategorias: se ubica por su
 * label (getByLabelText), conserva el id estable `nueva-categoria` y crea la
 * categoría recortada, con Enter o con el botón. Escrito contra el label +
 * input crudos y vuelto a correr sin cambios después de pasar el campo a
 * `FormField` (#777): el test no mira la estructura del JSX, mira lo que el
 * usuario y un lector de pantalla ven.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import ModalCategorias from './ModalCategorias'
import type { ProductoDB } from '../../types'

const crearMutateAsync = vi.fn()
let crearPending = false

const mutacionInerte = { mutateAsync: vi.fn(), isPending: false }

vi.mock('../../hooks/queries', () => ({
  useCategoriasQuery: () => ({ data: [], isLoading: false }),
  useSubcategoriasQuery: () => ({ data: [] }),
  useCrearCategoriaMutation: () => ({ mutateAsync: crearMutateAsync, isPending: crearPending }),
  useRenombrarCategoriaMutation: () => mutacionInerte,
  useEliminarCategoriaMutation: () => mutacionInerte,
  useToggleCategoriaActivaMutation: () => mutacionInerte,
  useCrearSubcategoriaMutation: () => mutacionInerte,
  useRenombrarSubcategoriaMutation: () => mutacionInerte,
  useEliminarSubcategoriaMutation: () => mutacionInerte,
}))

const productos = [
  { id: 'p1', nombre: 'Coca 2L', categoria: 'Gaseosas' },
] as unknown as ProductoDB[]

function renderModal() {
  return render(<ModalCategorias productos={productos} onClose={vi.fn()} />)
}

function campo() {
  return screen.getByLabelText('Nueva categoría') as HTMLInputElement
}

beforeEach(() => {
  crearMutateAsync.mockReset()
  crearMutateAsync.mockResolvedValue(undefined)
  crearPending = false
})

describe('ModalCategorias — campo "Nueva categoría"', () => {
  it('se encuentra por su label y es un input de texto con id estable y placeholder', () => {
    renderModal()
    const input = campo()
    expect(input.tagName).toBe('INPUT')
    expect(input).toHaveAttribute('type', 'text')
    expect(input).toHaveAttribute('id', 'nueva-categoria')
    expect(input).toHaveAttribute('placeholder', 'Ej.: AGUAS SABORIZADAS')
    expect(input).toHaveValue('')
    expect(input).toBeEnabled()
  })

  it('el label está asociado al input (clic en el label lo enfoca)', async () => {
    renderModal()
    await userEvent.click(screen.getByText('Nueva categoría'))
    expect(campo()).toHaveFocus()
  })

  it('"Agregar" está deshabilitado con el campo vacío o en blanco y se habilita con texto', () => {
    renderModal()
    const agregar = screen.getByRole('button', { name: /^agregar$/i })
    expect(agregar).toBeDisabled()

    fireEvent.change(campo(), { target: { value: '   ' } })
    expect(agregar).toBeDisabled()

    fireEvent.change(campo(), { target: { value: 'Aguas' } })
    expect(agregar).toBeEnabled()
  })

  it('al hacer clic en "Agregar" crea la categoría recortada y limpia el campo', async () => {
    renderModal()
    fireEvent.change(campo(), { target: { value: '  Aguas saborizadas  ' } })
    fireEvent.click(screen.getByRole('button', { name: /^agregar$/i }))

    await waitFor(() => expect(crearMutateAsync).toHaveBeenCalledTimes(1))
    expect(crearMutateAsync).toHaveBeenCalledWith('Aguas saborizadas')
    await waitFor(() => expect(campo()).toHaveValue(''))
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })

  it('Enter en el campo crea la categoría (sin enviar ningún formulario)', async () => {
    renderModal()
    fireEvent.change(campo(), { target: { value: 'Lácteos' } })
    const prevenido = !fireEvent.keyDown(campo(), { key: 'Enter' })

    expect(prevenido).toBe(true)
    await waitFor(() => expect(crearMutateAsync).toHaveBeenCalledWith('Lácteos'))
    await waitFor(() => expect(campo()).toHaveValue(''))
  })

  it('Enter con el campo vacío avisa "Ingresá un nombre" y no crea nada', () => {
    renderModal()
    fireEvent.keyDown(campo(), { key: 'Enter' })

    expect(screen.getByRole('alert')).toHaveTextContent('Ingresá un nombre')
    expect(crearMutateAsync).not.toHaveBeenCalled()
  })

  it('rechaza un nombre que ya existe (sin distinguir mayúsculas) y no crea nada', () => {
    renderModal()
    fireEvent.change(campo(), { target: { value: 'gaseosas' } })
    fireEvent.click(screen.getByRole('button', { name: /^agregar$/i }))

    expect(screen.getByRole('alert')).toHaveTextContent('Ya existe una categoría "gaseosas"')
    expect(crearMutateAsync).not.toHaveBeenCalled()
    expect(campo()).toHaveValue('gaseosas')
  })

  it('si la creación falla muestra el mensaje y conserva lo escrito', async () => {
    crearMutateAsync.mockRejectedValue(new Error('Sin permisos'))
    renderModal()
    fireEvent.change(campo(), { target: { value: 'Snacks' } })
    fireEvent.click(screen.getByRole('button', { name: /^agregar$/i }))

    expect(await screen.findByRole('alert')).toHaveTextContent('Sin permisos')
    expect(campo()).toHaveValue('Snacks')
  })

  it('mientras la creación está en curso el campo queda deshabilitado', () => {
    crearPending = true
    renderModal()
    expect(campo()).toBeDisabled()
  })
})
