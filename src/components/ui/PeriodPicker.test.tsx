/**
 * PeriodPicker: lo que se asevera acá es CONTRATO del primitivo —el grupo con
 * nombre, los presets que se anuncian como presionados, qué callback dispara
 * cada gesto, las etiquetas de los campos y que no calcula ni corrige nada—. El
 * look no se fija: cambiar un tono de gris no tiene que romper ningún test.
 *
 * La parte de «no calcula ninguna fecha» es el motivo de #727: si el picker
 * empezara a saber qué es «el último mes», dejaría de ser visual y pasaría a
 * imponerle su semántica a las pantallas.
 */
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { useState } from 'react'
import { describe, it, expect, vi } from 'vitest'
import { fireEvent, render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import { PeriodPicker, type PeriodPickerProps } from './PeriodPicker'

const PRESETS_A = [
  { id: 'mes', label: 'Último mes' },
  { id: 'trimestre', label: 'Último trimestre' },
  { id: 'manual', label: 'A mano' },
]

const PRESETS_B = [
  { id: 'hoy', label: 'Hoy' },
  { id: 'ayer', label: 'Ayer' },
]

function props(overrides: Partial<PeriodPickerProps> = {}): PeriodPickerProps {
  return {
    presets: PRESETS_A,
    activePresetId: 'mes',
    onSelectPreset: vi.fn(),
    desde: '2026-08-21',
    hasta: '2026-09-21',
    onDesdeChange: vi.fn(),
    onHastaChange: vi.fn(),
    etiqueta: 'Período',
    ...overrides,
  }
}

const grupo = () => screen.getByRole('group', { name: 'Período' })
const botones = () => within(grupo()).getAllByRole('button')
const nombres = () => botones().map((b) => b.textContent)
const presionados = () =>
  botones()
    .filter((b) => b.getAttribute('aria-pressed') === 'true')
    .map((b) => b.textContent)

describe('PeriodPicker · grupo de presets', () => {
  it('es un grupo con el nombre que le da la pantalla', () => {
    render(<PeriodPicker {...props({ etiqueta: 'Presets de periodo' })} />)
    expect(screen.getByRole('group', { name: 'Presets de periodo' })).toBeInTheDocument()
  })

  it('muestra los presets que le pasan, en ese orden', () => {
    render(<PeriodPicker {...props()} />)
    expect(nombres()).toEqual(['Último mes', 'Último trimestre', 'A mano'])
  })

  it('con otro juego de presets muestra ESE juego: no impone un vocabulario', () => {
    render(<PeriodPicker {...props({ presets: PRESETS_B, activePresetId: 'hoy' })} />)
    expect(nombres()).toEqual(['Hoy', 'Ayer'])
  })

  it('sin presets el grupo queda vacío y los campos siguen', () => {
    render(<PeriodPicker {...props({ presets: [] })} />)
    expect(within(grupo()).queryAllByRole('button')).toHaveLength(0)
    expect(screen.getByLabelText('Desde')).toBeInTheDocument()
  })
})

describe('PeriodPicker · preset activo', () => {
  it('el activo se anuncia como presionado y los demás no', () => {
    render(<PeriodPicker {...props({ activePresetId: 'trimestre' })} />)

    expect(presionados()).toEqual(['Último trimestre'])
    expect(screen.getByRole('button', { name: 'Último mes' })).toHaveAttribute('aria-pressed', 'false')
    expect(screen.getByRole('button', { name: 'A mano' })).toHaveAttribute('aria-pressed', 'false')
  })

  it('cambia cuando el padre cambia activePresetId', () => {
    const { rerender } = render(<PeriodPicker {...props({ activePresetId: 'mes' })} />)
    expect(presionados()).toEqual(['Último mes'])

    rerender(<PeriodPicker {...props({ activePresetId: 'manual' })} />)
    expect(presionados()).toEqual(['A mano'])
  })

  it.each([
    ['null', null],
    ['un id que no es ninguno de los presets', 'custom'],
  ])('con %s no hay ninguno presionado, pero todos declaran aria-pressed="false"', (_caso, activo) => {
    render(<PeriodPicker {...props({ activePresetId: activo })} />)

    expect(presionados()).toEqual([])
    botones().forEach((b) => expect(b).toHaveAttribute('aria-pressed', 'false'))
  })

  it('sin activePresetId tampoco hay ninguno presionado', () => {
    render(<PeriodPicker {...props({ activePresetId: undefined })} />)
    expect(presionados()).toEqual([])
  })
})

describe('PeriodPicker · elegir un preset', () => {
  it('avisa con el id del preset, una vez, y no toca los campos de fecha', async () => {
    const p = props()
    render(<PeriodPicker {...p} />)

    await userEvent.setup().click(screen.getByRole('button', { name: 'Último trimestre' }))

    expect(p.onSelectPreset).toHaveBeenCalledTimes(1)
    expect(p.onSelectPreset).toHaveBeenCalledWith('trimestre')
    expect(p.onDesdeChange).not.toHaveBeenCalled()
    expect(p.onHastaChange).not.toHaveBeenCalled()
  })

  it('no cambia solo el activo ni las fechas: son del padre', async () => {
    render(<PeriodPicker {...props()} />)

    await userEvent.setup().click(screen.getByRole('button', { name: 'Último trimestre' }))

    expect(presionados()).toEqual(['Último mes'])
    expect(screen.getByLabelText('Desde')).toHaveValue('2026-08-21')
    expect(screen.getByLabelText('Hasta')).toHaveValue('2026-09-21')
  })

  it('volver a tocar el activo también avisa: no decide si eso es un cambio', async () => {
    const p = props()
    render(<PeriodPicker {...p} />)

    await userEvent.setup().click(screen.getByRole('button', { name: 'Último mes' }))

    expect(p.onSelectPreset).toHaveBeenCalledWith('mes')
  })

  it('es type="button": adentro de un formulario no lo manda', async () => {
    const onSubmit = vi.fn((e: { preventDefault: () => void }) => e.preventDefault())
    render(
      <form onSubmit={onSubmit}>
        <PeriodPicker {...props()} />
      </form>,
    )

    for (const b of botones()) {
      expect(b).toHaveAttribute('type', 'button')
    }
    await userEvent.setup().click(screen.getByRole('button', { name: 'A mano' }))
    expect(onSubmit).not.toHaveBeenCalled()
  })

  it('con un padre que lo conecta, el activo sigue al que se eligió', async () => {
    function Conectado() {
      const [activo, setActivo] = useState('mes')
      return (
        <PeriodPicker
          {...props({ activePresetId: activo, onSelectPreset: setActivo })}
        />
      )
    }
    render(<Conectado />)

    await userEvent.setup().click(screen.getByRole('button', { name: 'Último trimestre' }))

    expect(presionados()).toEqual(['Último trimestre'])
  })
})

describe('PeriodPicker · campos de fecha', () => {
  it('son dos campos de fecha con su etiqueta, Desde y Hasta por omisión', () => {
    render(<PeriodPicker {...props()} />)

    const desde = screen.getByLabelText('Desde')
    const hasta = screen.getByLabelText('Hasta')
    expect(desde).toHaveAttribute('type', 'date')
    expect(hasta).toHaveAttribute('type', 'date')
    expect(desde).toHaveValue('2026-08-21')
    expect(hasta).toHaveValue('2026-09-21')
  })

  it('la pantalla puede ponerles otro nombre accesible', () => {
    render(<PeriodPicker {...props({ desdeLabel: 'Fecha desde', hastaLabel: 'Fecha hasta' })} />)

    expect(screen.getByLabelText('Fecha desde')).toHaveValue('2026-08-21')
    expect(screen.getByLabelText('Fecha hasta')).toHaveValue('2026-09-21')
    expect(screen.queryByLabelText('Desde')).toBeNull()
  })

  it('escribir en «Desde» avisa con el valor nuevo y nada más', () => {
    const p = props()
    render(<PeriodPicker {...p} />)

    fireEvent.change(screen.getByLabelText('Desde'), { target: { value: '2026-07-01' } })

    expect(p.onDesdeChange).toHaveBeenCalledTimes(1)
    expect(p.onDesdeChange).toHaveBeenCalledWith('2026-07-01')
    expect(p.onHastaChange).not.toHaveBeenCalled()
    expect(p.onSelectPreset).not.toHaveBeenCalled()
  })

  it('escribir en «Hasta» avisa con el valor nuevo y nada más', () => {
    const p = props()
    render(<PeriodPicker {...p} />)

    fireEvent.change(screen.getByLabelText('Hasta'), { target: { value: '2026-09-10' } })

    expect(p.onHastaChange).toHaveBeenCalledTimes(1)
    expect(p.onHastaChange).toHaveBeenCalledWith('2026-09-10')
    expect(p.onDesdeChange).not.toHaveBeenCalled()
    expect(p.onSelectPreset).not.toHaveBeenCalled()
  })

  it('vaciar un campo avisa con el string vacío', () => {
    const p = props()
    render(<PeriodPicker {...p} />)

    fireEvent.change(screen.getByLabelText('Desde'), { target: { value: '' } })

    expect(p.onDesdeChange).toHaveBeenCalledWith('')
  })

  it('se ven por omisión, con cualquier preset activo', () => {
    render(<PeriodPicker {...props({ activePresetId: 'manual' })} />)
    expect(screen.getByLabelText('Desde')).toBeVisible()
    expect(screen.getByLabelText('Hasta')).toBeVisible()
  })

  it('mostrarFechas={false} los saca, y los presets siguen', () => {
    render(<PeriodPicker {...props({ mostrarFechas: false })} />)

    expect(screen.queryByLabelText('Desde')).toBeNull()
    expect(screen.queryByLabelText('Hasta')).toBeNull()
    expect(nombres()).toEqual(['Último mes', 'Último trimestre', 'A mano'])
  })

  it('NO limita un campo con el otro salvo que se lo pidan', () => {
    render(<PeriodPicker {...props()} />)

    expect(screen.getByLabelText('Desde')).not.toHaveAttribute('max')
    expect(screen.getByLabelText('Hasta')).not.toHaveAttribute('min')
  })

  it('desdeMax y hastaMin llegan tal cual a los inputs', () => {
    render(<PeriodPicker {...props({ desdeMax: '2026-09-21', hastaMin: '2026-08-21' })} />)

    expect(screen.getByLabelText('Desde')).toHaveAttribute('max', '2026-09-21')
    expect(screen.getByLabelText('Hasta')).toHaveAttribute('min', '2026-08-21')
  })

  it('no valida ni corrige el rango: un Desde posterior al Hasta se muestra como llega', () => {
    const p = props({ desde: '2026-12-31', hasta: '2026-01-01' })
    render(<PeriodPicker {...p} />)

    expect(screen.getByLabelText('Desde')).toHaveValue('2026-12-31')
    expect(screen.getByLabelText('Hasta')).toHaveValue('2026-01-01')
    expect(p.onDesdeChange).not.toHaveBeenCalled()
    expect(p.onHastaChange).not.toHaveBeenCalled()
  })

  it('acepta un rango vacío', () => {
    render(<PeriodPicker {...props({ desde: '', hasta: '' })} />)

    expect(screen.getByLabelText('Desde')).toHaveValue('')
    expect(screen.getByLabelText('Hasta')).toHaveValue('')
  })
})

describe('PeriodPicker · dos en la misma pantalla', () => {
  it('cada campo queda atado a su propia etiqueta', () => {
    render(
      <>
        <PeriodPicker {...props({ etiqueta: 'Período A', desde: '2026-01-01', hasta: '2026-01-31' })} />
        <PeriodPicker
          {...props({ etiqueta: 'Período B', presets: PRESETS_B, desde: '2026-02-01', hasta: '2026-02-28' })}
        />
      </>,
    )

    const desdes = screen.getAllByLabelText('Desde')
    const hastas = screen.getAllByLabelText('Hasta')
    expect(desdes.map((i) => (i as HTMLInputElement).value)).toEqual(['2026-01-01', '2026-02-01'])
    expect(hastas.map((i) => (i as HTMLInputElement).value)).toEqual(['2026-01-31', '2026-02-28'])
    expect(new Set([...desdes, ...hastas].map((i) => i.id)).size).toBe(4)
  })
})

describe('PeriodPicker · lo que le deja pasar al consumidor', () => {
  it('className va a la fila que lo contiene', () => {
    render(<PeriodPicker {...props({ className: 'mi-fila' })} />)
    expect(grupo().parentElement).toHaveClass('mi-fila')
  })
})

describe('PeriodPicker · no sabe de fechas', () => {
  // #727 es el cambio de comportamiento que este primitivo NO tiene que hacer: si
  // aprendiera a calcular un rango o a disparar una consulta, estaría eligiendo
  // por las pantallas. Se mira el código fuente porque no hay forma de verlo
  // desde el DOM: una importación de más no se nota hasta que alguien la usa.
  const fuente = fs.readFileSync(path.resolve(path.dirname(fileURLToPath(import.meta.url)), 'PeriodPicker.tsx'), 'utf8')

  it('sólo importa los tipos de React, Button, FormField y cn', () => {
    const importados = [...fuente.matchAll(/^import[^'"]*['"]([^'"]+)['"]/gm)].map((m) => m[1])
    expect(importados.sort()).toEqual(['../../lib/utils', './Button', './FormField', 'react'])
  })

  it('no construye ni lee fechas', () => {
    const sinComentarios = fuente.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')
    expect(sinComentarios).not.toMatch(/\bDate\b|\bIntl\b|setDate|getMonth|getFullYear|toISOString/)
  })
})
