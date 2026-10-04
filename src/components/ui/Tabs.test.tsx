/**
 * Tabs: lo que se asevera acá es CONTRATO del primitivo —los roles del patrón
 * de pestañas de WAI-ARIA, el teclado, que sea CONTROLADO (el clic avisa y no
 * cambia nada solo, que es lo que mantiene a `?tab=` de /reportes como única
 * fuente de verdad) y el cableado `aria-controls` / `aria-labelledby`—. El resto
 * del look no se fija.
 */
import { useState } from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import { Users } from 'lucide-react'
import { Tabs, type TabItem } from './Tabs'

type Id = 'preventistas' | 'cuentas' | 'valuacion' | 'stock-red'

const TABS: TabItem<Id>[] = [
  { value: 'preventistas', label: 'Por Preventista', icon: Users },
  { value: 'cuentas', label: 'Cuentas por Cobrar' },
  { value: 'valuacion', label: 'Valuación de Stock' },
  { value: 'stock-red', label: 'Stock de la Red' },
]

/** Sin estado propio: `value` es lo que dice el test. */
function Fijo({
  value,
  onValueChange = () => {},
  tabs = TABS,
}: {
  value: Id | 'otra'
  onValueChange?: (v: Id) => void
  tabs?: readonly TabItem<Id>[]
}) {
  return (
    <Tabs value={value as Id} onValueChange={onValueChange} tabs={tabs} etiqueta="Tipo de reporte">
      <p>contenido de {value}</p>
    </Tabs>
  )
}

/** Un padre que SÍ guarda la pestaña, como lo hace VistaReportes con la URL. */
function ConPadre({ inicial = 'preventistas', onCambio }: { inicial?: Id; onCambio?: (v: Id) => void }) {
  const [activa, setActiva] = useState<Id>(inicial)
  return (
    <Tabs
      value={activa}
      onValueChange={(v) => {
        onCambio?.(v)
        setActiva(v)
      }}
      tabs={TABS}
      etiqueta="Tipo de reporte"
    >
      <p>contenido de {activa}</p>
    </Tabs>
  )
}

const tab = (nombre: string): HTMLElement => screen.getByRole('tab', { name: nombre })

describe('Tabs — roles', () => {
  it('es un tablist con nombre, con una tab por pestaña y un tabpanel', () => {
    render(<Fijo value="cuentas" />)

    expect(screen.getByRole('tablist', { name: 'Tipo de reporte' })).toBeInTheDocument()
    expect(screen.getAllByRole('tab').map((t) => t.textContent)).toEqual(TABS.map((t) => t.label))
    expect(screen.getByRole('tabpanel')).toBeInTheDocument()
  })

  it('cada tab es un botón que no manda formularios', () => {
    render(
      <form onSubmit={(e) => e.preventDefault()}>
        <Fijo value="cuentas" />
      </form>
    )

    for (const t of screen.getAllByRole('tab')) {
      expect(t).toHaveAttribute('type', 'button')
    }
  })

  it('sólo la pestaña activa tiene aria-selected="true"', () => {
    render(<Fijo value="valuacion" />)

    expect(tab('Valuación de Stock')).toHaveAttribute('aria-selected', 'true')
    for (const nombre of ['Por Preventista', 'Cuentas por Cobrar', 'Stock de la Red']) {
      expect(tab(nombre)).toHaveAttribute('aria-selected', 'false')
    }
  })

  it('el nombre de la tab es el rótulo: el ícono es decorativo', () => {
    render(<Fijo value="preventistas" />)

    expect(tab('Por Preventista').querySelector('svg')).toHaveAttribute('aria-hidden', 'true')
  })

  it('el contenido va dentro del tabpanel', () => {
    render(<Fijo value="cuentas" />)

    expect(screen.getByRole('tabpanel')).toHaveTextContent('contenido de cuentas')
  })

  it('la lista scrollea sola en horizontal: la barra no ensancha la página', () => {
    render(<Fijo value="cuentas" />)

    // jsdom no mide layout; lo que se puede fijar es que el contenedor es el
    // que scrollea y que las pestañas no se parten ni se achican.
    expect(screen.getByRole('tablist')).toHaveClass('overflow-x-auto')
    expect(tab('Cuentas por Cobrar')).toHaveClass('shrink-0', 'whitespace-nowrap')
  })

  it('deja pasar el className del consumidor al contenedor, a la lista y al panel', () => {
    render(
      <Tabs
        value="a"
        onValueChange={() => {}}
        tabs={[{ value: 'a', label: 'A' }]}
        etiqueta="x"
        className="mi-contenedor"
        listClassName="mi-lista"
        panelClassName="mi-panel"
      />
    )

    expect(screen.getByRole('tablist').parentElement).toHaveClass('mi-contenedor')
    expect(screen.getByRole('tablist')).toHaveClass('mi-lista')
    expect(screen.getByRole('tabpanel')).toHaveClass('mi-panel')
  })
})

describe('Tabs — cableado aria-controls / aria-labelledby', () => {
  it('cada tab controla el tabpanel, y éste está rotulado por la tab activa', () => {
    render(<Fijo value="stock-red" />)

    const panel = screen.getByRole('tabpanel')
    for (const t of screen.getAllByRole('tab')) {
      expect(t.getAttribute('aria-controls')).toBe(panel.id)
    }
    expect(document.getElementById(panel.id)).toBe(panel)
    // `name` sale de aria-labelledby: si el id no resolviera, el panel quedaría sin nombre.
    expect(screen.getByRole('tabpanel', { name: 'Stock de la Red' })).toBe(panel)
  })

  it('el rótulo del panel acompaña a la pestaña activa', async () => {
    const user = userEvent.setup()
    render(<ConPadre inicial="preventistas" />)
    expect(screen.getByRole('tabpanel', { name: 'Por Preventista' })).toBeInTheDocument()

    await user.click(tab('Cuentas por Cobrar'))

    expect(screen.getByRole('tabpanel', { name: 'Cuentas por Cobrar' })).toBeInTheDocument()
  })

  it('dos Tabs en la misma pantalla no comparten ids', () => {
    render(
      <>
        <Fijo value="cuentas" />
        <Fijo value="cuentas" />
      </>
    )

    const ids = screen.getAllByRole('tab').map((t) => t.id)
    expect(new Set(ids).size).toBe(ids.length)
    const paneles = screen.getAllByRole('tabpanel')
    expect(paneles[0].id).not.toBe(paneles[1].id)
  })
})

describe('Tabs — es controlado', () => {
  it('el clic llama onValueChange con el value y NO cambia la pestaña por su cuenta', async () => {
    const user = userEvent.setup()
    const onValueChange = vi.fn()
    render(<Fijo value="preventistas" onValueChange={onValueChange} />)

    await user.click(tab('Valuación de Stock'))

    expect(onValueChange).toHaveBeenCalledTimes(1)
    expect(onValueChange).toHaveBeenCalledWith('valuacion')
    expect(tab('Por Preventista')).toHaveAttribute('aria-selected', 'true')
    expect(tab('Valuación de Stock')).toHaveAttribute('aria-selected', 'false')
    expect(screen.getByRole('tabpanel')).toHaveTextContent('contenido de preventistas')
  })

  it('cuando el padre cambia value, la pestaña activa cambia', async () => {
    const user = userEvent.setup()
    render(<ConPadre />)

    await user.click(tab('Valuación de Stock'))

    expect(tab('Valuación de Stock')).toHaveAttribute('aria-selected', 'true')
    expect(tab('Por Preventista')).toHaveAttribute('aria-selected', 'false')
    expect(screen.getByRole('tabpanel')).toHaveTextContent('contenido de valuacion')
  })

  it('el clic sobre la pestaña ya activa también avisa', async () => {
    const user = userEvent.setup()
    const onValueChange = vi.fn()
    render(<Fijo value="cuentas" onValueChange={onValueChange} />)

    await user.click(tab('Cuentas por Cobrar'))

    expect(onValueChange).toHaveBeenCalledWith('cuentas')
  })
})

describe('Tabs — teclado', () => {
  it('sólo la activa está en el orden de tabulación (tabIndex móvil)', async () => {
    const user = userEvent.setup()
    render(<Fijo value="valuacion" />)

    expect(tab('Valuación de Stock')).toHaveAttribute('tabindex', '0')
    for (const nombre of ['Por Preventista', 'Cuentas por Cobrar', 'Stock de la Red']) {
      expect(tab(nombre)).toHaveAttribute('tabindex', '-1')
    }

    await user.tab()
    expect(tab('Valuación de Stock')).toHaveFocus()
  })

  it('→ mueve el foco a la siguiente y la activa', async () => {
    const user = userEvent.setup()
    const onCambio = vi.fn()
    render(<ConPadre inicial="preventistas" onCambio={onCambio} />)

    await user.tab()
    await user.keyboard('{ArrowRight}')

    expect(tab('Cuentas por Cobrar')).toHaveFocus()
    expect(tab('Cuentas por Cobrar')).toHaveAttribute('aria-selected', 'true')
    expect(tab('Cuentas por Cobrar')).toHaveAttribute('tabindex', '0')
    expect(tab('Por Preventista')).toHaveAttribute('tabindex', '-1')
    expect(onCambio).toHaveBeenLastCalledWith('cuentas')
  })

  it('← mueve el foco a la anterior y la activa', async () => {
    const user = userEvent.setup()
    const onCambio = vi.fn()
    render(<ConPadre inicial="valuacion" onCambio={onCambio} />)

    await user.tab()
    await user.keyboard('{ArrowLeft}')

    expect(tab('Cuentas por Cobrar')).toHaveFocus()
    expect(onCambio).toHaveBeenLastCalledWith('cuentas')
  })

  it('→ en la última vuelve a la primera, y ← en la primera va a la última', async () => {
    const user = userEvent.setup()
    render(<ConPadre inicial="stock-red" />)

    await user.tab()
    await user.keyboard('{ArrowRight}')
    expect(tab('Por Preventista')).toHaveFocus()
    expect(tab('Por Preventista')).toHaveAttribute('aria-selected', 'true')

    await user.keyboard('{ArrowLeft}')
    expect(tab('Stock de la Red')).toHaveFocus()
    expect(tab('Stock de la Red')).toHaveAttribute('aria-selected', 'true')
  })

  it('Home va a la primera y End a la última, activándolas', async () => {
    const user = userEvent.setup()
    const onCambio = vi.fn()
    render(<ConPadre inicial="cuentas" onCambio={onCambio} />)

    await user.tab()
    await user.keyboard('{End}')
    expect(tab('Stock de la Red')).toHaveFocus()
    expect(onCambio).toHaveBeenLastCalledWith('stock-red')

    await user.keyboard('{Home}')
    expect(tab('Por Preventista')).toHaveFocus()
    expect(onCambio).toHaveBeenLastCalledWith('preventistas')
    expect(tab('Por Preventista')).toHaveAttribute('aria-selected', 'true')
  })

  it('las flechas también avisan al padre cuando es controlado y no actualiza', async () => {
    const user = userEvent.setup()
    const onValueChange = vi.fn()
    render(<Fijo value="preventistas" onValueChange={onValueChange} />)

    await user.tab()
    await user.keyboard('{ArrowRight}')

    expect(onValueChange).toHaveBeenCalledWith('cuentas')
    // El padre no actualizó value: la activa no se movió sola.
    expect(tab('Por Preventista')).toHaveAttribute('aria-selected', 'true')
  })

  it('con una tecla modificadora no interviene (Alt + ← es "volver" del navegador)', async () => {
    const user = userEvent.setup()
    const onValueChange = vi.fn()
    render(<Fijo value="cuentas" onValueChange={onValueChange} />)

    await user.tab()
    await user.keyboard('{Alt>}{ArrowLeft}{/Alt}')
    await user.keyboard('{Control>}{End}{/Control}')

    expect(onValueChange).not.toHaveBeenCalled()
    expect(tab('Cuentas por Cobrar')).toHaveFocus()
  })

  it('Enter sobre la pestaña enfocada la activa, como cualquier botón', async () => {
    const user = userEvent.setup()
    const onValueChange = vi.fn()
    render(<Fijo value="preventistas" onValueChange={onValueChange} />)

    tab('Stock de la Red').focus()
    await user.keyboard('{Enter}')

    expect(onValueChange).toHaveBeenCalledWith('stock-red')
  })

  it('con un value que no es de ninguna pestaña, ninguna queda activa y la primera es tabulable', async () => {
    const user = userEvent.setup()
    render(<Fijo value="otra" />)

    for (const t of screen.getAllByRole('tab')) {
      expect(t).toHaveAttribute('aria-selected', 'false')
    }
    expect(tab('Por Preventista')).toHaveAttribute('tabindex', '0')
    expect(screen.getByRole('tabpanel')).not.toHaveAttribute('aria-labelledby')

    await user.tab()
    expect(tab('Por Preventista')).toHaveFocus()
  })
})
