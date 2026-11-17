/**
 * Borrar una marca avisa cuántas metas de preventistas se borran con ella (#1596, 1596-b11).
 * La FK `metas_preventista.marca_id` es ON DELETE CASCADE: antes el aviso decía que las
 * metas «se quedan sin nada que medir», y en realidad desaparecían.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const mocks = vi.hoisted(() => ({
  metas: { data: undefined as number | undefined, isError: false },
}))

vi.mock('../../hooks/queries', () => {
  const mut = () => ({ mutateAsync: vi.fn(), isPending: false })
  return {
    useMarcasQuery: () => ({
      data: [{ id: 'm1', nombre: 'Marca Uno', sucursal_id: 1, activa: true, created_at: '', updated_at: '' }],
      isLoading: false,
    }),
    useCrearMarcaMutation: mut,
    useRenombrarMarcaMutation: mut,
    useEliminarMarcaMutation: mut,
    useToggleMarcaActivaMutation: mut,
    useAsignarMarcaMasivaMutation: mut,
    useMetasDeMarcaQuery: (id: string | null) => (id ? mocks.metas : { data: undefined, isError: false }),
  }
})

import ModalMarcas from './ModalMarcas'

async function pedirBorrar(metas: { data: number | undefined; isError: boolean }) {
  mocks.metas = metas
  render(<ModalMarcas productos={[]} onClose={() => {}} />)
  await userEvent.setup().click(screen.getByRole('button', { name: 'Eliminar Marca Uno' }))
}

describe('ModalMarcas — aviso de metas al borrar', () => {
  it('con metas dice cuántas se borran y que son de todos los períodos', async () => {
    await pedirBorrar({ data: 3, isError: false })
    expect(screen.getByText(/Se borran también 3 metas de preventistas por esta marca, de todos los períodos/)).toBeInTheDocument()
    expect(screen.queryByText(/se van a quedar sin nada que medir/)).not.toBeInTheDocument()
  })

  it('con una sola meta, en singular', async () => {
    await pedirBorrar({ data: 1, isError: false })
    expect(screen.getByText(/Se borran también 1 meta de preventista por esta marca/)).toBeInTheDocument()
  })

  it('sin metas lo dice', async () => {
    await pedirBorrar({ data: 0, isError: false })
    expect(screen.getByText(/No hay metas de preventistas por esta marca/)).toBeInTheDocument()
  })

  it('si no se pudo contar, avisa que se borrarían igual', async () => {
    await pedirBorrar({ data: undefined, isError: true })
    expect(screen.getByText(/No se pudo ver si hay metas de preventistas.*se borrarían junto con ella/)).toBeInTheDocument()
  })
})
