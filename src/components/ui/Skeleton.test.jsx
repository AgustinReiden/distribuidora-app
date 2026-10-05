import { describe, it, expect } from 'vitest'
import { render, screen as _screen } from '@testing-library/react'
import {
  Skeleton,
  SkeletonText,
  SkeletonTitle,
  SkeletonAvatar,
  SkeletonProductCard,
  SkeletonTableRow,
  SkeletonTable,
  SkeletonPedidoCard,
  SkeletonPedidosList,
  SkeletonStatCard,
  SkeletonDashboard,
  SkeletonForm,
  SkeletonListItem
} from './Skeleton'

describe('Skeleton Components', () => {
  describe('Skeleton base', () => {
    it('renderiza con clases por defecto', () => {
      const { container } = render(<Skeleton />)
      const skeleton = container.firstChild
      expect(skeleton).toHaveClass('bg-gray-200')
      expect(skeleton).toHaveClass('animate-pulse')
    })

    it('aplica width y height personalizados', () => {
      const { container } = render(<Skeleton width={100} height={50} />)
      const skeleton = container.firstChild
      expect(skeleton).toHaveStyle({ width: '100px', height: '50px' })
    })

    it('acepta width como string', () => {
      const { container } = render(<Skeleton width="50%" />)
      const skeleton = container.firstChild
      expect(skeleton).toHaveStyle({ width: '50%' })
    })

    it('puede desactivar animación', () => {
      const { container } = render(<Skeleton animate={false} />)
      const skeleton = container.firstChild
      expect(skeleton).not.toHaveClass('animate-pulse')
    })

    it('aplica className personalizada', () => {
      const { container } = render(<Skeleton className="my-custom-class" />)
      const skeleton = container.firstChild
      expect(skeleton).toHaveClass('my-custom-class')
    })
  })

  describe('SkeletonText', () => {
    it('renderiza con altura de 16px', () => {
      const { container } = render(<SkeletonText />)
      const skeleton = container.firstChild
      expect(skeleton).toHaveStyle({ height: '16px' })
    })

    it('aplica width personalizado', () => {
      const { container } = render(<SkeletonText width="80%" />)
      const skeleton = container.firstChild
      expect(skeleton).toHaveStyle({ width: '80%' })
    })
  })

  describe('SkeletonTitle', () => {
    it('renderiza con altura de 24px', () => {
      const { container } = render(<SkeletonTitle />)
      const skeleton = container.firstChild
      expect(skeleton).toHaveStyle({ height: '24px' })
    })

    it('tiene width por defecto de 60%', () => {
      const { container } = render(<SkeletonTitle />)
      const skeleton = container.firstChild
      expect(skeleton).toHaveStyle({ width: '60%' })
    })
  })

  describe('SkeletonAvatar', () => {
    it('renderiza como círculo', () => {
      const { container } = render(<SkeletonAvatar />)
      const skeleton = container.firstChild
      expect(skeleton).toHaveClass('rounded-full')
    })

    it('aplica tamaño personalizado', () => {
      const { container } = render(<SkeletonAvatar size={60} />)
      const skeleton = container.firstChild
      expect(skeleton).toHaveStyle({ width: '60px', height: '60px' })
    })
  })

  describe('SkeletonProductCard', () => {
    it('renderiza estructura de card de producto', () => {
      const { container } = render(<SkeletonProductCard />)
      const card = container.firstChild
      expect(card).toHaveClass('bg-white')
      expect(card).toHaveClass('rounded-lg')
      expect(card).toHaveClass('shadow')
    })
  })

  describe('SkeletonTableRow', () => {
    it('renderiza número correcto de columnas', () => {
      render(
        <table>
          <tbody>
            <SkeletonTableRow columns={4} />
          </tbody>
        </table>
      )
      const cells = document.querySelectorAll('td')
      expect(cells).toHaveLength(4)
    })

    it('usa 5 columnas por defecto', () => {
      render(
        <table>
          <tbody>
            <SkeletonTableRow />
          </tbody>
        </table>
      )
      const cells = document.querySelectorAll('td')
      expect(cells).toHaveLength(5)
    })
  })

  describe('SkeletonTable', () => {
    it('renderiza tabla con filas y columnas correctas', () => {
      render(<SkeletonTable rows={3} columns={4} />)
      const headerCells = document.querySelectorAll('th')
      const bodyCells = document.querySelectorAll('tbody td')
      expect(headerCells).toHaveLength(4)
      expect(bodyCells).toHaveLength(12) // 3 rows * 4 columns
    })
  })

  describe('SkeletonPedidoCard', () => {
    it('renderiza estructura de card de pedido', () => {
      const { container } = render(<SkeletonPedidoCard />)
      const card = container.firstChild
      expect(card).toHaveClass('bg-white')
      expect(card).toHaveClass('rounded-xl')
    })

    it('tiene la estructura de la PedidoCard cerrada: riel, dos lineas y acciones a la derecha', () => {
      const { container } = render(<SkeletonPedidoCard />)
      const card = container.firstChild
      // Mismo riel de 4 px que la PedidoCard (Card con accent) y sin padding propio
      expect(card).toHaveClass('border-l-4')
      expect(card).not.toHaveClass('p-4')
      const fila = card.firstChild
      expect(fila).toHaveClass('flex', 'flex-wrap', 'px-4', 'py-3')
      const [datos, acciones] = fila.children
      expect(datos).toHaveClass('basis-48', 'space-y-1.5')
      // Dos lineas de datos
      expect(datos.children).toHaveLength(2)
      // Acciones: la visible, el menu y el chevron
      expect(acciones).toHaveClass('ml-auto', 'sm:self-center')
      expect(acciones.children).toHaveLength(3)
    })

    it('la linea 2 incluye el badge FC/ZZ y la accion en linea tiene el ancho de "Marcar en preparacion"', () => {
      const { container } = render(<SkeletonPedidoCard />)
      const [datos, acciones] = container.firstChild.firstChild.children
      // #id, badge FC/ZZ (32x20), direccion, vendedor e items
      const linea2 = datos.children[1]
      expect(linea2.children).toHaveLength(5)
      expect(linea2.children[1]).toHaveStyle({ width: '32px', height: '20px' })
      // Button sm con el texto de la accion mas larga: 193x32
      expect(acciones.children[0]).toHaveStyle({ width: '193px', height: '32px' })
    })

    it('no usa bg-white en los bloques internos (la lista cuenta las cards por esa clase)', () => {
      const { container } = render(<SkeletonPedidoCard />)
      expect(container.querySelectorAll('.bg-white')).toHaveLength(1)
    })
  })

  describe('SkeletonPedidosList', () => {
    it('renderiza cantidad correcta de cards', () => {
      const { container } = render(<SkeletonPedidosList count={3} />)
      const cards = container.querySelectorAll('.bg-white')
      expect(cards).toHaveLength(3)
    })

    it('usa 5 cards por defecto', () => {
      const { container } = render(<SkeletonPedidosList />)
      const cards = container.querySelectorAll('.bg-white')
      expect(cards).toHaveLength(5)
    })
  })

  describe('SkeletonStatCard', () => {
    it('renderiza estructura de card de estadística', () => {
      const { container } = render(<SkeletonStatCard />)
      const card = container.firstChild
      expect(card).toHaveClass('bg-white')
      expect(card).toHaveClass('rounded-lg')
      expect(card).toHaveClass('shadow')
    })
  })

  describe('SkeletonDashboard', () => {
    it('renderiza grid de stats y charts', () => {
      const { container } = render(<SkeletonDashboard />)
      // Debe tener grid de stats (4 items)
      const statCards = container.querySelectorAll('.grid > .bg-white')
      expect(statCards.length).toBeGreaterThanOrEqual(4)
    })

    it('por defecto usa la grilla de metricas de VistaDashboard con 4 tarjetas', () => {
      const { container } = render(<SkeletonDashboard />)
      const grilla = container.querySelector('.grid')
      expect(grilla).toHaveClass('grid-cols-1', 'sm:grid-cols-2', 'lg:grid-cols-4', 'gap-3')
      expect(grilla).not.toHaveClass('min-[375px]:grid-cols-2')
      expect(grilla.children).toHaveLength(4)
    })

    it('con preventistaPuro usa la grilla 2x2 desde 375 px y no pierde tarjetas', () => {
      const { container } = render(<SkeletonDashboard preventistaPuro />)
      const grilla = container.querySelector('.grid')
      expect(grilla).toHaveClass('grid-cols-1', 'min-[375px]:grid-cols-2', 'lg:grid-cols-4', 'gap-3')
      expect(grilla).not.toHaveClass('sm:grid-cols-2')
      // Las 4 metricas de la grilla (Ventas, Pedidos, Ticket, Clientes): la Tasa
      // de entrega que el preventista no ve es un bloque aparte, no de la grilla.
      expect(grilla.children).toHaveLength(4)
    })
  })

  describe('SkeletonForm', () => {
    it('renderiza campos de formulario', () => {
      const { container } = render(<SkeletonForm fields={3} />)
      // Cada campo tiene un label skeleton y un input skeleton
      const skeletons = container.querySelectorAll('.bg-gray-200')
      expect(skeletons.length).toBeGreaterThanOrEqual(6) // 3 fields * 2 (label + input)
    })
  })

  describe('SkeletonListItem', () => {
    it('renderiza estructura de item de lista', () => {
      const { container } = render(<SkeletonListItem />)
      const item = container.firstChild
      expect(item).toHaveClass('flex')
      expect(item).toHaveClass('items-center')
      // Debe tener un avatar circular
      const avatar = container.querySelector('.rounded-full')
      expect(avatar).toBeInTheDocument()
    })
  })
})
