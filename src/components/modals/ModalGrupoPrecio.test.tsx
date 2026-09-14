/**
 * El modal concentra todas las validaciones de una condición mayorista y no
 * tenía ningún test. Lo que se cubre acá es sobre todo lo que rompe datos:
 * escalas duplicadas (chocan contra el UNIQUE de la tabla) y reglas de combo
 * imposibles de cumplir.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalGrupoPrecio from './ModalGrupoPrecio'
import type { GrupoPrecioConDetalles, ProductoDB } from '../../types'

const PRODUCTOS = [
  { id: 'p1', nombre: 'CODITO COTELLA 500GRS', precio: 920, stock: 10 },
  { id: 'p2', nombre: 'MOSTACHO COTELLA 500GRS', precio: 920, stock: 10 },
] as unknown as ProductoDB[]

const GRUPO_EXISTENTE = {
  id: 'g1',
  nombre: 'Fideos Cotella',
  descripcion: null,
  productos: [{ id: 'gp1', grupo_precio_id: 'g1', producto_id: 'p1' }],
  escalas: [{ id: 'e1', grupo_precio_id: 'g1', cantidad_minima: 12, precio_unitario: 850, etiqueta: null, min_productos_distintos: 1 }],
} as unknown as GrupoPrecioConDetalles

function renderModal(onSave = vi.fn().mockResolvedValue({ success: true })) {
  const onClose = vi.fn()
  render(
    <ModalGrupoPrecio
      grupo={null}
      productos={PRODUCTOS}
      onSave={onSave}
      onClose={onClose}
    />,
  )
  return { onSave, onClose }
}

function renderModalEditando(
  grupo: GrupoPrecioConDetalles = GRUPO_EXISTENTE,
  onSave = vi.fn().mockResolvedValue({ success: true }),
) {
  const onClose = vi.fn()
  render(
    <ModalGrupoPrecio
      grupo={grupo}
      productos={PRODUCTOS}
      onSave={onSave}
      onClose={onClose}
    />,
  )
  return { onSave, onClose }
}

const guardar = () => screen.getByRole('button', { name: /Crear condición/ })
const guardarCambios = () => screen.getByRole('button', { name: /Guardar cambios/ })

describe('ModalGrupoPrecio', () => {
  it('exige nombre', async () => {
    const { onSave } = renderModal()
    await userEvent.click(guardar())
    expect(await screen.findByRole('alert')).toHaveTextContent(/nombre de la condición es obligatorio/i)
    expect(onSave).not.toHaveBeenCalled()
  })

  it('exige al menos un producto', async () => {
    const { onSave } = renderModal()
    await userEvent.type(screen.getByPlaceholderText('Ej: Papas Fritas'), 'Fideos Cotella')
    await userEvent.click(guardar())
    expect(await screen.findByRole('alert')).toHaveTextContent(/Selecciona al menos un producto/i)
    expect(onSave).not.toHaveBeenCalled()
  })

  it('exige al menos una escala con cantidad y precio', async () => {
    const { onSave } = renderModal()
    await userEvent.type(screen.getByPlaceholderText('Ej: Papas Fritas'), 'Fideos Cotella')
    await userEvent.click(screen.getByText('CODITO COTELLA 500GRS'))
    await userEvent.click(guardar())
    expect(await screen.findByRole('alert')).toHaveTextContent(/Agrega al menos una escala/i)
    expect(onSave).not.toHaveBeenCalled()
  })

  it('guarda una condición surtida con los productos y la escala', async () => {
    const { onSave } = renderModal()
    await userEvent.type(screen.getByPlaceholderText('Ej: Papas Fritas'), 'Fideos Cotella')
    await userEvent.click(screen.getByText('CODITO COTELLA 500GRS'))
    await userEvent.click(screen.getByText('MOSTACHO COTELLA 500GRS'))
    await userEvent.type(screen.getByPlaceholderText('Cant. minima total'), '12')
    await userEvent.type(screen.getByPlaceholderText('Precio c/u'), '850')
    await userEvent.click(guardar())

    expect(onSave).toHaveBeenCalledWith(
      expect.objectContaining({
        nombre: 'Fideos Cotella',
        productoIds: ['p1', 'p2'],
        escalas: [expect.objectContaining({ cantidadMinima: 12, precioUnitario: 850 })],
      }),
    )
  })

  it('rechaza dos escalas con la misma cantidad mínima (choca con el UNIQUE)', async () => {
    const { onSave } = renderModal()
    await userEvent.type(screen.getByPlaceholderText('Ej: Papas Fritas'), 'Fideos Cotella')
    await userEvent.click(screen.getByText('CODITO COTELLA 500GRS'))
    await userEvent.click(screen.getByRole('button', { name: /Agregar escala/ }))

    const cantidades = screen.getAllByPlaceholderText('Cant. minima total')
    const precios = screen.getAllByPlaceholderText('Precio c/u')
    await userEvent.type(cantidades[0], '12')
    await userEvent.type(precios[0], '850')
    await userEvent.type(cantidades[1], '12')
    await userEvent.type(precios[1], '800')
    await userEvent.click(guardar())

    expect(await screen.findByRole('alert')).toHaveTextContent(/dos escalas con la misma cantidad minima/i)
    expect(onSave).not.toHaveBeenCalled()
  })

  it('avisa que la mezcla suma cuando hay más de un producto', async () => {
    renderModal()
    await userEvent.click(screen.getByText('CODITO COTELLA 500GRS'))
    expect(screen.queryByText(/Cualquier mezcla/)).not.toBeInTheDocument()

    await userEvent.click(screen.getByText('MOSTACHO COTELLA 500GRS'))
    expect(screen.getByText(/Cualquier mezcla de estos 2 productos suma/)).toBeInTheDocument()
  })

  it('el piso por producto queda fuera del camino principal', () => {
    renderModal()
    // El toggle existe (no se perdió funcionalidad) pero vive detrás de
    // "Opciones avanzadas": en prod nunca se usó y su nombre viejo hacía creer
    // que era necesario para que la mezcla contara.
    expect(screen.getByText('Opciones avanzadas')).toBeInTheDocument()
    expect(screen.getByLabelText(/Exigir además un mínimo por producto/)).not.toBeChecked()
  })

  it('cierra con Escape (lo da ModalBase)', async () => {
    const { onClose } = renderModal()
    await userEvent.keyboard('{Escape}')
    expect(onClose).toHaveBeenCalled()
  })

  it('una escala con cantidad pero sin precio bloquea el guardado (no se cae en silencio)', async () => {
    const { onSave } = renderModalEditando()
    // La escala ya trae cantidad=12 y precio=850 cargados desde `grupo`.
    // Se borra el precio, como pasaría si alguien lo limpia por error.
    await userEvent.clear(screen.getByPlaceholderText('Precio c/u'))
    await userEvent.click(guardarCambios())

    expect(await screen.findByRole('alert')).toHaveTextContent(/precios deben ser mayores a 0/i)
    expect(onSave).not.toHaveBeenCalled()
  })

  it('una escala con precio pero sin cantidad también bloquea el guardado', async () => {
    const { onSave } = renderModalEditando()
    await userEvent.clear(screen.getByPlaceholderText('Cant. minima total'))
    await userEvent.click(guardarCambios())

    expect(await screen.findByRole('alert')).toHaveTextContent(/falta la cantidad mínima/i)
    expect(onSave).not.toHaveBeenCalled()
  })

  it('una fila totalmente vacía (agregada de más) se ignora en vez de bloquear', async () => {
    const { onSave } = renderModalEditando()
    // Agrega una segunda escala y la deja sin tocar: cantidad y precio vacíos.
    await userEvent.click(screen.getByRole('button', { name: /Agregar escala/ }))
    await userEvent.click(guardarCambios())

    expect(onSave).toHaveBeenCalledWith(
      expect.objectContaining({
        escalas: [expect.objectContaining({ cantidadMinima: 12, precioUnitario: 850 })],
      }),
    )
  })
})
