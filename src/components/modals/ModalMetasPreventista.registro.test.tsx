/**
 * N5 de la segunda pasada de #1644: el objetivo de una meta es un `NumberInput` sin `commitOnChange`.
 * Sin registro, «1.500.000» tipeado quedaba en rojo, el blur lo devolvía al objetivo de antes y
 * «Guardar cambios» guardaba ESE. Ahora el modal tiene su registro: el Guardar queda frenado.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import type { AvanceMeta } from '../../hooks/queries'

const { guardar } = vi.hoisted(() => ({ guardar: vi.fn() }))

vi.mock('../../hooks/queries', () => ({
  useGuardarMetaPreventistaMutation: () => ({ mutateAsync: guardar, isPending: false }),
  useMarcasQuery: () => ({ data: [] }),
  useCategoriasQuery: () => ({ data: [] }),
  useProductosQuery: () => ({ data: [] }),
  usePreventistasAsignablesQuery: () => ({ data: [{ id: 'p1', nombre: 'Pablo' }] }),
}))
vi.mock('../../contexts/SucursalContext', () => ({ useSucursal: () => ({ currentSucursalId: 1 }) }))

import ModalMetasPreventista from './ModalMetasPreventista'

const META = {
  id: 9,
  tipo_meta: 'facturacion',
  objetivo: 15000,
  marca_id: null,
  categoria_id: null,
  producto_ids: null,
  desde: '2026-11-01',
  hasta: '2026-11-30',
} as unknown as AvanceMeta

describe('ModalMetasPreventista · un objetivo en rojo no se guarda', () => {
  it('«1.500.000» tipeado queda en rojo y «Guardar cambios» no guarda el objetivo de antes', async () => {
    const user = userEvent.setup()
    render(<ModalMetasPreventista periodo="2026-11-01" edicion={{ meta: META, preventistaId: 'p1' }} onClose={vi.fn()} />)
    const objetivo = screen.getByDisplayValue('15.000')
    await user.clear(objetivo)
    await user.type(objetivo, '1.500.000')
    const boton = screen.getByRole('button', { name: /Guardar cambios/ })
    await user.click(boton)
    expect(objetivo).toHaveAttribute('aria-invalid', 'true')
    expect(boton).toBeDisabled()
    expect(guardar).not.toHaveBeenCalled()
    expect(screen.getByText('Hay un campo en rojo para corregir')).toBeInTheDocument()
  })
})
