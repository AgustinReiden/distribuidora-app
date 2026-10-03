/**
 * Table: lo que se asevera acá es CONTRATO del primitivo —los elementos HTML
 * reales que renderiza (los tests de reportes dependen de `.closest('tr')` y de
 * `getAllByRole('row')`), el `scope` de los encabezados, el nombre accesible, la
 * región enfocable de las tablas anchas y lo que deja pasar el consumidor—. El
 * resto del look no se fija: cambiar un tono de gris no tiene que romper ningún
 * test.
 */
import { createRef } from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import {
  Table,
  TableBody,
  TableCaption,
  TableCell,
  TableFooter,
  TableHead,
  TableHeader,
  TableRow,
} from './Table'

/** Una tabla de compras chica y completa: caption, encabezado, cuerpo y pie. */
function Compras({ etiqueta }: { etiqueta?: string }) {
  return (
    <Table etiqueta={etiqueta}>
      <TableCaption srOnly>Compras de octubre</TableCaption>
      <TableHeader>
        <TableRow>
          <TableHead>Proveedor</TableHead>
          <TableHead numerico>Ítems</TableHead>
          <TableHead numerico>Total</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        <TableRow>
          <TableCell>Molinos del Norte</TableCell>
          <TableCell numerico>12</TableCell>
          <TableCell numerico>$ 1.210.000,00</TableCell>
        </TableRow>
        <TableRow>
          <TableCell>Aceitera Tucumán</TableCell>
          <TableCell numerico>8</TableCell>
          <TableCell numerico>$ 640.000,00</TableCell>
        </TableRow>
      </TableBody>
      <TableFooter>
        <TableRow>
          <TableCell colSpan={2}>Total</TableCell>
          <TableCell numerico>$ 1.850.000,00</TableCell>
        </TableRow>
      </TableFooter>
    </Table>
  )
}

describe('Table · elementos reales', () => {
  it('renderiza un <table> nativo, sin role explícito', () => {
    render(<Compras />)

    const tabla = screen.getByRole('table')
    expect(tabla.tagName).toBe('TABLE')
    expect(tabla).not.toHaveAttribute('role')
  })

  it('encabezado, cuerpo y pie son tres rowgroup; cada fila es un row', () => {
    render(<Compras />)

    const grupos = screen.getAllByRole('rowgroup')
    expect(grupos.map((g) => g.tagName)).toEqual(['THEAD', 'TBODY', 'TFOOT'])

    // 1 de encabezado + 2 del cuerpo + 1 del pie
    const filas = screen.getAllByRole('row')
    expect(filas).toHaveLength(4)
    filas.forEach((fila) => expect(fila.tagName).toBe('TR'))
  })

  it('los encabezados son columnheader y las celdas son cell', () => {
    render(<Compras />)

    const encabezados = screen.getAllByRole('columnheader')
    expect(encabezados.map((e) => e.textContent)).toEqual(['Proveedor', 'Ítems', 'Total'])
    encabezados.forEach((e) => expect(e.tagName).toBe('TH'))

    const celdas = screen.getAllByRole('cell')
    expect(celdas).toHaveLength(8)
    celdas.forEach((c) => expect(c.tagName).toBe('TD'))
  })

  it('`.closest("tr")` desde una celda encuentra su fila (el patrón de los tests de reportes)', () => {
    render(<Compras />)

    const fila = screen.getByText('Aceitera Tucumán').closest('tr')

    expect(fila).not.toBeNull()
    expect(fila).toBe(screen.getAllByRole('row')[2])
    // La fila trae las otras celdas, no sólo la que se buscó.
    expect(within(fila as HTMLElement).getByText('$ 640.000,00')).toBeInTheDocument()
    expect(within(fila as HTMLElement).queryByText('Molinos del Norte')).toBeNull()
  })

  it('`.closest("tr")` también funciona desde una celda del pie', () => {
    render(<Compras />)

    const fila = screen.getByText('Total', { selector: 'td' }).closest('tr')

    expect(fila).toBe(screen.getAllByRole('row')[3])
    expect(within(fila as HTMLElement).getByText('$ 1.850.000,00')).toBeInTheDocument()
  })
})

describe('Table · scope de los encabezados', () => {
  it('`TableHead` trae scope="col" por defecto', () => {
    render(<Compras />)

    for (const encabezado of screen.getAllByRole('columnheader')) {
      expect(encabezado).toHaveAttribute('scope', 'col')
    }
  })

  it('el consumidor puede pisarlo: scope="row" la vuelve cabecera de fila', () => {
    render(
      <Table>
        <TableBody>
          <TableRow>
            <TableHead scope="row">Fideos tirabuzón 500 g</TableHead>
            <TableCell numerico>240</TableCell>
          </TableRow>
        </TableBody>
      </Table>,
    )

    const cabecera = screen.getByRole('rowheader', { name: 'Fideos tirabuzón 500 g' })
    expect(cabecera).toHaveAttribute('scope', 'row')
    expect(screen.queryByRole('columnheader')).toBeNull()
  })
})

describe('Table · variante numérica', () => {
  it('`numerico` alinea a la derecha con tabular-nums, en encabezado y en celda', () => {
    render(<Compras />)

    const [proveedor, items, total] = screen.getAllByRole('columnheader')
    expect(items).toHaveClass('text-right', 'tabular-nums')
    expect(total).toHaveClass('text-right', 'tabular-nums')
    expect(proveedor).toHaveClass('text-left')
    expect(proveedor).not.toHaveClass('text-right')
    expect(proveedor).not.toHaveClass('tabular-nums')

    const celdaNumerica = screen.getByText('$ 1.210.000,00')
    expect(celdaNumerica).toHaveClass('text-right', 'tabular-nums')
    // Un monto no se parte en dos renglones.
    expect(celdaNumerica).toHaveClass('whitespace-nowrap')

    const celdaTexto = screen.getByText('Molinos del Norte')
    expect(celdaTexto).not.toHaveClass('text-right')
    expect(celdaTexto).not.toHaveClass('tabular-nums')
  })

  it('el `className` del consumidor pisa la alineación (una columna centrada)', () => {
    render(
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead className="text-center">Estado</TableHead>
          </TableRow>
        </TableHeader>
      </Table>,
    )

    const encabezado = screen.getByRole('columnheader')
    expect(encabezado).toHaveClass('text-center')
    expect(encabezado).not.toHaveClass('text-left')
  })
})

describe('Table · nombre accesible', () => {
  it('el <caption> le da nombre a la tabla', () => {
    render(<Compras />)

    expect(screen.getByRole('table', { name: 'Compras de octubre' })).toBeInTheDocument()
  })

  it('`srOnly` oculta el caption a la vista; sin `srOnly` se ve', () => {
    const { rerender } = render(
      <Table>
        <TableCaption srOnly>Título oculto</TableCaption>
      </Table>,
    )
    expect(screen.getByText('Título oculto')).toHaveClass('sr-only')
    // Oculto a la vista, no al lector de pantalla: sigue nombrando la tabla.
    expect(screen.getByRole('table', { name: 'Título oculto' })).toBeInTheDocument()

    rerender(
      <Table>
        <TableCaption>Título visible</TableCaption>
      </Table>,
    )
    expect(screen.getByText('Título visible')).not.toHaveClass('sr-only')
    expect(screen.getByText('Título visible').tagName).toBe('CAPTION')
  })
})

describe('Table · región scrolleable', () => {
  it('con `etiqueta` el contenedor es una región con nombre y se puede enfocar', async () => {
    const user = userEvent.setup()
    render(<Compras etiqueta="Compras de octubre (desplazable)" />)

    const region = screen.getByRole('region', { name: 'Compras de octubre (desplazable)' })
    expect(region).toHaveAttribute('tabindex', '0')
    expect(region).toHaveClass('overflow-x-auto')
    // La región envuelve a la tabla, no es la tabla.
    expect(region).toContainElement(screen.getByRole('table'))
    expect(region.tagName).toBe('DIV')

    await user.tab()
    expect(region).toHaveFocus()

    region.blur()
    region.focus()
    expect(region).toHaveFocus()
  })

  it('sin `etiqueta` el contenedor scrollea pero no es región ni toma foco', () => {
    render(<Compras />)

    const contenedor = screen.getByRole('table').parentElement as HTMLElement
    expect(contenedor).toHaveClass('overflow-x-auto')
    expect(contenedor).not.toHaveAttribute('role')
    expect(contenedor).not.toHaveAttribute('tabindex')
    expect(contenedor).not.toHaveAttribute('aria-label')
    expect(screen.queryByRole('region')).toBeNull()
  })

  it('la <table> sigue sin role aunque el contenedor sea una región', () => {
    render(<Compras etiqueta="Compras" />)

    expect(screen.getByRole('table')).not.toHaveAttribute('role')
  })

  it('`contenedorClassName` va al contenedor y `className` a la <table>', () => {
    render(
      <Table etiqueta="Compras" contenedorClassName="max-w-md" className="min-w-[48rem]">
        <TableBody />
      </Table>,
    )

    const region = screen.getByRole('region', { name: 'Compras' })
    const tabla = screen.getByRole('table')
    expect(region).toHaveClass('max-w-md', 'overflow-x-auto')
    expect(region).not.toHaveClass('min-w-[48rem]')
    expect(tabla).toHaveClass('min-w-[48rem]', 'w-full', 'text-sm')
    expect(tabla).not.toHaveClass('max-w-md')
  })

  it('`marco={false}` saca la superficie pero conserva el scroll', () => {
    const { rerender } = render(<Table><TableBody /></Table>)
    const conMarco = screen.getByRole('table').parentElement as HTMLElement
    expect(conMarco).toHaveClass('border', 'rounded-xl', 'overflow-x-auto')

    rerender(<Table marco={false}><TableBody /></Table>)
    const sinMarco = screen.getByRole('table').parentElement as HTMLElement
    expect(sinMarco).toHaveClass('overflow-x-auto')
    expect(sinMarco).not.toHaveClass('border')
    expect(sinMarco).not.toHaveClass('rounded-xl')
  })
})

describe('Table · className, resto de props y ref', () => {
  it('cada componente combina el `className` del consumidor con el suyo', () => {
    render(
      <Table className="t-propia">
        <TableCaption className="cap-propia">Título</TableCaption>
        <TableHeader className="h-propia">
          <TableRow className="rh-propia">
            <TableHead className="th-propia">Col</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody className="b-propia">
          <TableRow className="rb-propia">
            <TableCell className="td-propia">Dato</TableCell>
          </TableRow>
        </TableBody>
        <TableFooter className="f-propia">
          <TableRow className="rf-propia">
            <TableCell className="tf-propia">Pie</TableCell>
          </TableRow>
        </TableFooter>
      </Table>,
    )

    // Pisa, no reemplaza: lo propio sigue estando al lado.
    expect(screen.getByRole('table')).toHaveClass('t-propia', 'w-full')
    expect(screen.getByText('Título')).toHaveClass('cap-propia')
    expect(screen.getByRole('columnheader')).toHaveClass('th-propia', 'uppercase')
    expect(screen.getByText('Dato').closest('tr')).toHaveClass('rb-propia')
    expect(screen.getByText('Dato')).toHaveClass('td-propia', 'px-4')
    expect(screen.getByText('Pie').closest('tfoot')).toHaveClass('f-propia')
    expect(screen.getByText('Pie').closest('tr')).toHaveClass('rf-propia')
    expect(screen.getAllByRole('rowgroup')[0]).toHaveClass('h-propia')
    expect(screen.getAllByRole('rowgroup')[1]).toHaveClass('b-propia')
  })

  it('el `className` del consumidor gana sobre el padding por defecto', () => {
    render(
      <Table>
        <TableBody>
          <TableRow>
            <TableCell className="py-1">Detalle</TableCell>
          </TableRow>
        </TableBody>
      </Table>,
    )

    const celda = screen.getByText('Detalle')
    expect(celda).toHaveClass('py-1')
    expect(celda).not.toHaveClass('py-3')
  })

  it('deja pasar el resto de las props al elemento', async () => {
    const user = userEvent.setup()
    const onClick = vi.fn()
    render(
      <Table id="compras" data-testid="tabla" aria-describedby="ayuda">
        <TableHeader data-testid="thead">
          <TableRow>
            <TableHead id="col-total" aria-sort="descending" data-testid="th">
              Total
            </TableHead>
          </TableRow>
        </TableHeader>
        <TableBody data-testid="tbody">
          <TableRow data-testid="fila" onClick={onClick} aria-selected="true">
            <TableCell colSpan={2} rowSpan={1} headers="col-total" data-testid="td">
              Dato
            </TableCell>
          </TableRow>
        </TableBody>
        <TableFooter data-testid="tfoot" />
      </Table>,
    )

    const tabla = screen.getByTestId('tabla')
    expect(tabla.tagName).toBe('TABLE')
    expect(tabla).toHaveAttribute('id', 'compras')
    expect(tabla).toHaveAttribute('aria-describedby', 'ayuda')
    expect(screen.getByTestId('thead').tagName).toBe('THEAD')
    expect(screen.getByTestId('tbody').tagName).toBe('TBODY')
    expect(screen.getByTestId('tfoot').tagName).toBe('TFOOT')

    expect(screen.getByTestId('th')).toHaveAttribute('aria-sort', 'descending')
    expect(screen.getByTestId('th')).toHaveAttribute('id', 'col-total')

    const celda = screen.getByTestId('td')
    expect(celda).toHaveAttribute('colspan', '2')
    expect(celda).toHaveAttribute('headers', 'col-total')

    await user.click(screen.getByTestId('fila'))
    expect(onClick).toHaveBeenCalledTimes(1)
    expect(screen.getByTestId('fila')).toHaveAttribute('aria-selected', 'true')
  })

  it('`numerico` y `srOnly` no se filtran al DOM como atributos', () => {
    render(
      <Table>
        <TableCaption srOnly>Título</TableCaption>
        <TableHeader>
          <TableRow>
            <TableHead numerico>Monto</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          <TableRow>
            <TableCell numerico>1</TableCell>
          </TableRow>
        </TableBody>
      </Table>,
    )

    for (const el of [
      screen.getByText('Título'),
      screen.getByRole('columnheader'),
      screen.getByRole('cell'),
    ]) {
      expect(el).not.toHaveAttribute('numerico')
      expect(el).not.toHaveAttribute('srOnly')
      expect(el).not.toHaveAttribute('sronly')
    }
  })

  it('el `ref` llega a cada elemento HTML', () => {
    const tabla = createRef<HTMLTableElement>()
    const caption = createRef<HTMLTableCaptionElement>()
    const thead = createRef<HTMLTableSectionElement>()
    const tbody = createRef<HTMLTableSectionElement>()
    const tfoot = createRef<HTMLTableSectionElement>()
    const fila = createRef<HTMLTableRowElement>()
    const th = createRef<HTMLTableCellElement>()
    const td = createRef<HTMLTableCellElement>()

    render(
      <Table ref={tabla}>
        <TableCaption ref={caption}>Título</TableCaption>
        <TableHeader ref={thead}>
          <TableRow>
            <TableHead ref={th}>Col</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody ref={tbody}>
          <TableRow ref={fila}>
            <TableCell ref={td}>Dato</TableCell>
          </TableRow>
        </TableBody>
        <TableFooter ref={tfoot} />
      </Table>,
    )

    expect(tabla.current).toBe(screen.getByRole('table'))
    expect(tabla.current?.tagName).toBe('TABLE')
    expect(caption.current?.tagName).toBe('CAPTION')
    expect(thead.current?.tagName).toBe('THEAD')
    expect(tbody.current?.tagName).toBe('TBODY')
    expect(tfoot.current?.tagName).toBe('TFOOT')
    expect(fila.current?.tagName).toBe('TR')
    expect(th.current?.tagName).toBe('TH')
    expect(td.current?.tagName).toBe('TD')
  })
})

describe('Table · hover de las filas', () => {
  it('las filas del cuerpo reaccionan al hover; las de encabezado y pie no', () => {
    render(<Compras />)

    const [encabezado, cuerpo1, cuerpo2, pie] = screen.getAllByRole('row')
    expect(cuerpo1.className).toMatch(/hover:bg-/)
    expect(cuerpo2.className).toMatch(/hover:bg-/)
    expect(encabezado.className).not.toMatch(/hover:/)
    expect(pie.className).not.toMatch(/hover:/)
  })

  it('el consumidor puede apagar el hover de una fila con su `className`', () => {
    render(
      <Table>
        <TableBody>
          <TableRow className="hover:bg-transparent">
            <TableCell>Detalle</TableCell>
          </TableRow>
        </TableBody>
      </Table>,
    )

    const fila = screen.getByRole('row')
    expect(fila).toHaveClass('hover:bg-transparent')
    expect(fila).not.toHaveClass('hover:bg-gray-50')
  })
})
