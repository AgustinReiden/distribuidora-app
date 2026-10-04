/**
 * El selector de período de `VistaAnalytics` (WP-55, #779), por rol ARIA y por
 * texto: qué presets hay y en qué orden, cuál está activo, qué rango calcula
 * cada uno, cuándo se ven los inputs de fecha y qué pasa al tocarlos.
 *
 * Es CARACTERIZACIÓN: se escribió contra el markup a mano, antes de que la vista
 * pasara a usar `PeriodPicker`, y tiene que seguir verde sin tocarse. Fija lo que
 * esta pantalla hace HOY, que no es lo que haría un selector "ideal":
 *  - los inputs de fecha están a la vista siempre, no sólo con «Personalizado»;
 *  - «Personalizado» es un preset más y NO toca el rango: lo deja como estaba;
 *  - elegir un preset NO exporta: la exportación sale sólo con su botón. Ese
 *    disparo explícito es de esta pantalla (#727 decide si se unifica; este
 *    paquete no).
 *
 * El «hoy» es fijo. Y la zona horaria también: `getPresetDates` arma el «hace un
 * mes» con la medianoche LOCAL y después la pasa a fecha argentina, así que con
 * el reloj en UTC (el de CI) da un día antes que con el de Buenos Aires. Eso es
 * de la vista y no se arregla acá: el test fija la zona de producción.
 */
import process from 'node:process'
import '@testing-library/jest-dom/vitest'
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import VistaAnalytics, { type VistaAnalyticsProps } from '../VistaAnalytics'

// Lunes 21/09/2026 al mediodía, hora de Buenos Aires.
const HOY = new Date(2026, 8, 21, 12, 0, 0)

const RANGO_ULTIMO_MES = { desde: '2026-08-21', hasta: '2026-09-21' }
const RANGO_3_MESES = { desde: '2026-06-21', hasta: '2026-09-21' }
const RANGO_ESTE_ANO = { desde: '2026-01-01', hasta: '2026-09-21' }

const TZ_ORIGINAL = process.env.TZ

beforeAll(() => {
  process.env.TZ = 'America/Argentina/Buenos_Aires'
  // Buenos Aires es UTC-3: 180 minutos. Si el runner no respeta el cambio de
  // zona en caliente, que falle acá y diga por qué, y no en una fecha corrida.
  if (new Date(2026, 8, 21).getTimezoneOffset() !== 180) {
    throw new Error('No se pudo fijar TZ=America/Argentina/Buenos_Aires en este runner')
  }
})

afterAll(() => {
  if (TZ_ORIGINAL === undefined) delete process.env.TZ
  else process.env.TZ = TZ_ORIGINAL
})

beforeEach(() => {
  // Sólo `Date`: los timers reales dejan andar a userEvent y a Testing Library.
  vi.useFakeTimers({ toFake: ['Date'] })
  vi.setSystemTime(HOY)
})

afterEach(() => {
  vi.useRealTimers()
})

function renderVista(overrides: Partial<VistaAnalyticsProps> = {}) {
  const props: VistaAnalyticsProps = {
    onExportBI: vi.fn(async () => {}),
    exportando: false,
    error: null,
    exito: false,
    ...overrides,
  }
  render(<VistaAnalytics {...props} />)
  return props
}

const grupoDePresets = () => screen.getByRole('group', { name: 'Presets de periodo' })
const preset = (nombre: string) => within(grupoDePresets()).getByRole('button', { name: nombre })
const inputDesde = () => screen.getByLabelText('Desde') as HTMLInputElement
const inputHasta = () => screen.getByLabelText('Hasta') as HTMLInputElement
const botonExportar = () => screen.getByRole('button', { name: /Generar Exportacion Completa/ })

function nombresDePresets(): string[] {
  return within(grupoDePresets())
    .getAllByRole('button')
    .map((b) => b.textContent ?? '')
}

function presionados(): string[] {
  return within(grupoDePresets())
    .getAllByRole('button')
    .filter((b) => b.getAttribute('aria-pressed') === 'true')
    .map((b) => b.textContent ?? '')
}

function rangoEnPantalla() {
  return { desde: inputDesde().value, hasta: inputHasta().value }
}

describe('VistaAnalytics · presets de período', () => {
  it('ofrece cuatro presets, en este orden, dentro del grupo "Presets de periodo"', () => {
    renderVista()
    expect(nombresDePresets()).toEqual([
      'Ultimo mes',
      'Ultimos 3 meses',
      'Este año',
      'Personalizado',
    ])
  })

  it('arranca en "Ultimo mes": es el único presionado y los inputs traen ese rango', () => {
    renderVista()
    expect(presionados()).toEqual(['Ultimo mes'])
    for (const otro of ['Ultimos 3 meses', 'Este año', 'Personalizado']) {
      expect(preset(otro)).toHaveAttribute('aria-pressed', 'false')
    }
    expect(rangoEnPantalla()).toEqual(RANGO_ULTIMO_MES)
  })

  it.each([
    ['Ultimos 3 meses', RANGO_3_MESES],
    ['Este año', RANGO_ESTE_ANO],
  ])('"%s" recalcula el rango y pasa a ser el único presionado', async (nombre, rango) => {
    renderVista()
    await userEvent.setup().click(preset(nombre))

    expect(presionados()).toEqual([nombre])
    expect(rangoEnPantalla()).toEqual(rango)
  })

  it('volver a "Ultimo mes" pisa el rango del preset anterior', async () => {
    const user = userEvent.setup()
    renderVista()
    await user.click(preset('Este año'))
    await user.click(preset('Ultimo mes'))

    expect(presionados()).toEqual(['Ultimo mes'])
    expect(rangoEnPantalla()).toEqual(RANGO_ULTIMO_MES)
  })

  it('"Personalizado" no toca el rango: queda el del preset anterior', async () => {
    const user = userEvent.setup()
    renderVista()
    await user.click(preset('Este año'))
    await user.click(preset('Personalizado'))

    expect(presionados()).toEqual(['Personalizado'])
    expect(rangoEnPantalla()).toEqual(RANGO_ESTE_ANO)
  })
})

describe('VistaAnalytics · inputs de fecha', () => {
  it('Desde y Hasta son campos de fecha con su etiqueta', () => {
    renderVista()
    expect(inputDesde()).toHaveAttribute('type', 'date')
    expect(inputHasta()).toHaveAttribute('type', 'date')
  })

  it.each(['Ultimo mes', 'Ultimos 3 meses', 'Este año', 'Personalizado'])(
    'están a la vista con "%s" elegido: no hace falta "Personalizado" para verlos',
    async (nombre) => {
      renderVista()
      await userEvent.setup().click(preset(nombre))

      expect(inputDesde()).toBeVisible()
      expect(inputHasta()).toBeVisible()
    },
  )

  it('no limitan un campo con el otro: no traen min ni max', () => {
    renderVista()
    for (const input of [inputDesde(), inputHasta()]) {
      expect(input).not.toHaveAttribute('min')
      expect(input).not.toHaveAttribute('max')
    }
  })

  it('editar "Desde" cambia el rango y deja "Personalizado" como único presionado', () => {
    renderVista()
    fireEvent.change(inputDesde(), { target: { value: '2026-07-01' } })

    expect(rangoEnPantalla()).toEqual({ desde: '2026-07-01', hasta: '2026-09-21' })
    expect(presionados()).toEqual(['Personalizado'])
  })

  it('editar "Hasta" cambia el rango y deja "Personalizado" como único presionado', () => {
    renderVista()
    fireEvent.change(inputHasta(), { target: { value: '2026-09-10' } })

    expect(rangoEnPantalla()).toEqual({ desde: '2026-08-21', hasta: '2026-09-10' })
    expect(presionados()).toEqual(['Personalizado'])
  })

  it('después de editar, elegir un preset vuelve a pisar las dos fechas', async () => {
    renderVista()
    fireEvent.change(inputDesde(), { target: { value: '2026-07-01' } })
    fireEvent.change(inputHasta(), { target: { value: '2026-09-10' } })
    await userEvent.setup().click(preset('Ultimos 3 meses'))

    expect(presionados()).toEqual(['Ultimos 3 meses'])
    expect(rangoEnPantalla()).toEqual(RANGO_3_MESES)
  })
})

describe('VistaAnalytics · el rango llega a la exportación', () => {
  it('elegir un preset NO exporta: la exportación sale sólo con su botón', async () => {
    const user = userEvent.setup()
    const props = renderVista()
    await user.click(preset('Ultimos 3 meses'))
    await user.click(preset('Este año'))
    fireEvent.change(inputDesde(), { target: { value: '2026-07-01' } })

    expect(props.onExportBI).not.toHaveBeenCalled()
  })

  it('exporta el rango del preset por omisión', async () => {
    const props = renderVista()
    await userEvent.setup().click(botonExportar())

    expect(props.onExportBI).toHaveBeenCalledTimes(1)
    expect(props.onExportBI).toHaveBeenCalledWith(RANGO_ULTIMO_MES.desde, RANGO_ULTIMO_MES.hasta)
  })

  it.each([
    ['Ultimos 3 meses', RANGO_3_MESES],
    ['Este año', RANGO_ESTE_ANO],
  ])('exporta el rango de "%s"', async (nombre, rango) => {
    const user = userEvent.setup()
    const props = renderVista()
    await user.click(preset(nombre))
    await user.click(botonExportar())

    expect(props.onExportBI).toHaveBeenCalledWith(rango.desde, rango.hasta)
  })

  it('exporta el rango que se escribió a mano', async () => {
    const user = userEvent.setup()
    const props = renderVista()
    fireEvent.change(inputDesde(), { target: { value: '2026-07-01' } })
    fireEvent.change(inputHasta(), { target: { value: '2026-09-10' } })
    await user.click(botonExportar())

    expect(props.onExportBI).toHaveBeenCalledWith('2026-07-01', '2026-09-10')
  })

  it('sin una de las dos fechas no se puede exportar', () => {
    renderVista()
    expect(botonExportar()).toBeEnabled()

    fireEvent.change(inputDesde(), { target: { value: '' } })
    expect(botonExportar()).toBeDisabled()

    fireEvent.change(inputDesde(), { target: { value: '2026-07-01' } })
    fireEvent.change(inputHasta(), { target: { value: '' } })
    expect(botonExportar()).toBeDisabled()
  })
})
