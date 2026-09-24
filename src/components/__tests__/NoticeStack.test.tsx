/**
 * Una sola pila para los avisos fijos (#716).
 *
 * Antes cada aviso se anclaba solo en `bottom-4 right-4` y se tapaban entre sí:
 * en el celular "Hay una version nueva" tapaba entero al banner de operaciones
 * fallidas. Ahora los tres avisos de estado se renderizan por portal dentro del
 * mismo `#notice-root`, que es quien los apila. Estos tests fijan que, montados a
 * la vez, todos terminan en esa pila y que se siguen encontrando por su rol, que
 * es como los buscan los tests de cada uno; que ocultos no dejan nada en ella; y
 * que los toasts NO entran (tienen que verse encima de un modal, y la pila va
 * debajo).
 *
 * Mocks: los mismos que usan los tests de cada aviso. `useActualizacionDisponible`
 * se mockea (BannerActualizacion.test.tsx); `SyncStatusBanner` lee la IndexedDB
 * real de fake-indexeddb (SyncStatusBanner.test.tsx). `getNoticeRoot` se envuelve
 * en un `vi.fn` que llama al real, para poder simular un entorno sin pila.
 *
 * Los tests de toques y de tamaño usan el CSS REAL: jsdom no carga Tailwind, y sin
 * CSS `pointer-events-none` / `-auto` no hacen nada, así que un test de toques
 * daría verde con cualquier clase. `inyectarCssDeLaPila` le pasa a Tailwind las
 * clases que de verdad quedaron en la pila y mete lo que genera en un `<style>`
 * (con un solo retoque para jsdom, explicado en `sinAmpersandParaJsdom`).
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { act, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import postcss from 'postcss'
import tailwindcss from 'tailwindcss'

vi.mock('../../hooks/useActualizacionDisponible', () => ({
  useActualizacionDisponible: vi.fn(),
}))

vi.mock('../ui/noticeRoot', async (importOriginal) => {
  const real = await importOriginal<typeof import('../ui/noticeRoot')>()
  return { getNoticeRoot: vi.fn(real.getNoticeRoot) }
})

import { useActualizacionDisponible } from '../../hooks/useActualizacionDisponible'
import { getNoticeRoot } from '../ui/noticeRoot'
import BannerActualizacion from '../BannerActualizacion'
import { SyncStatusBanner } from '../SyncStatusBanner'
import OfflineIndicator from '../layout/OfflineIndicator'
import { NotificationProvider, useNotification } from '../../contexts/NotificationContext'
import { clearAllData, queueOperation, markAsFailed } from '../../lib/offlineDb'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from '../ui/DropdownMenu'

// Lo que Radix DropdownMenu necesita en jsdom, igual que en PedidoActions.test.tsx:
// el ResizeObserver de src/test/setup.js no se puede construir con `new` (y
// @floating-ui lo instancia), y jsdom no trae la Pointer Capture API ni
// `scrollIntoView`. Sin esto el menú ni siquiera abre.
class ObservadorStub {
  observe(): void { /* no-op */ }
  unobserve(): void { /* no-op */ }
  disconnect(): void { /* no-op */ }
  takeRecords(): [] { return [] }
}
globalThis.ResizeObserver = ObservadorStub as unknown as typeof ResizeObserver
if (!Element.prototype.hasPointerCapture) {
  Element.prototype.hasPointerCapture = (): boolean => false
}
if (!Element.prototype.setPointerCapture) {
  Element.prototype.setPointerCapture = (): void => undefined
}
if (!Element.prototype.releasePointerCapture) {
  Element.prototype.releasePointerCapture = (): void => undefined
}
if (!Element.prototype.scrollIntoView) {
  Element.prototype.scrollIntoView = (): void => undefined
}

async function encolarYFallar(): Promise<void> {
  const id = await queueOperation('CREATE_PEDIDO', { n: 1 }, undefined, 1)
  await markAsFailed(id, 'error de red')
}

function mockActualizacion(disponible: boolean): { actualizar: () => void } {
  const actualizar = vi.fn()
  vi.mocked(useActualizacionDisponible).mockReturnValue({
    disponible,
    buildActual: 'test-build',
    actualizar,
    posponer: vi.fn(),
  })
  return { actualizar }
}

function pila(): HTMLElement {
  const root = document.getElementById('notice-root')
  if (!root) throw new Error('no hay #notice-root en el body')
  return root
}

function elementosDeLaPila(): Element[] {
  return [pila(), ...Array.from(pila().querySelectorAll('*'))]
}

const MARCA_JSDOM = 'data-jsdom-clase'

/**
 * jsdom no entiende un `&` en un selector, ni siquiera escapado: lo toma por el `&`
 * de CSS nesting y el selector no matchea nunca (en el navegador sí). Las variantes
 * arbitrarias de Tailwind (`[… _&>*]:…`) generan justo eso, porque la clase lleva el
 * `&` adentro. Así que cada selector de clase con `\&` se cambia por un atributo que
 * marca a los mismos elementos (los que tienen esa clase) y pesa lo mismo que una
 * clase (0,1,0). El resto del selector —la condición sobre el `body`, el `>*`— queda
 * tal cual lo generó Tailwind.
 *
 * Ojo: el cascade de jsdom resuelve por orden, no por especificidad. Tailwind emite
 * las variantes después de las utilidades sueltas, así que el resultado es el mismo,
 * pero esto no prueba que la regla le gane a `pointer-events-auto` por especificidad.
 */
function sinAmpersandParaJsdom(css: string): string {
  const elementos = elementosDeLaPila()
  let n = 0
  return css.replace(/\.((?:\\.|[\w-])*\\&(?:\\.|[\w-])*)/g, (_, escapada: string) => {
    const clase = escapada.replace(/\\(.)/g, '$1')
    const marca = `clase-${n++}`
    for (const el of elementos) {
      if (el.classList.contains(clase)) {
        el.setAttribute(MARCA_JSDOM, `${el.getAttribute(MARCA_JSDOM) ?? ''} ${marca}`.trim())
      }
    }
    return `[${MARCA_JSDOM}~="${marca}"]`
  })
}

/**
 * Genera con Tailwind el CSS de las clases que hay en la pila (la pila misma y todo
 * lo que tiene adentro) y lo inyecta en el documento. Las clases se leen del DOM
 * renderizado, no se copian a mano: si un aviso o la pila cambian de clase, el CSS
 * cambia con ellos.
 */
async function inyectarCssDeLaPila(): Promise<HTMLStyleElement> {
  const clases = elementosDeLaPila()
    .map(el => el.getAttribute('class') ?? '')
    .join('\n')
  const { css } = await postcss([
    tailwindcss({
      content: [{ raw: clases, extension: 'html' }],
      corePlugins: { preflight: false },
    }),
  ]).process('@tailwind utilities;', { from: undefined })

  const estilo = document.createElement('style')
  estilo.textContent = sinAmpersandParaJsdom(css)
  document.head.appendChild(estilo)
  return estilo
}

/** Un menú de Radix como el de acciones de un pedido: modal (el default) y sin overlay. */
function MenuDeAcciones() {
  return (
    <DropdownMenu>
      <DropdownMenuTrigger>Mas acciones</DropdownMenuTrigger>
      <DropdownMenuContent>
        <DropdownMenuItem>Editar</DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

function BotonToast() {
  const { success } = useNotification()
  return (
    <button type="button" onClick={() => success('Pedido creado')}>
      Avisar
    </button>
  )
}

describe('Pila de avisos fijos', () => {
  beforeEach(async () => {
    await clearAllData()
    mockActualizacion(true)
  })

  afterEach(() => {
    // Vuelve a la implementación con la que se creó el vi.fn: la real.
    vi.mocked(getNoticeRoot).mockReset()
  })

  it('BannerActualizacion y SyncStatusBanner a la vez quedan los dos dentro de #notice-root', async () => {
    await encolarYFallar()

    const { container } = render(
      <>
        <BannerActualizacion />
        <SyncStatusBanner pollInterval={100000} />
      </>
    )

    const alerta = await screen.findByRole('alert')
    const estado = screen.getByRole('status')

    expect(estado).toHaveTextContent('Hay una version nueva')
    expect(alerta).toHaveTextContent(/1 operación falló/)

    expect(pila()).toContainElement(estado)
    expect(pila()).toContainElement(alerta)
    // Por portal: ya no viven donde se montaron.
    expect(container).not.toContainElement(estado)
    expect(container).not.toContainElement(alerta)
  })

  it('los tres avisos de estado comparten la misma pila', async () => {
    await encolarYFallar()

    render(
      <>
        <OfflineIndicator isOnline={false} />
        <SyncStatusBanner pollInterval={100000} />
        <BannerActualizacion />
      </>
    )

    const enLaPila = within(pila())
    expect(enLaPila.getByRole('button', { name: /sin conexion/i })).toBeInTheDocument()
    expect(await enLaPila.findByRole('alert')).toBeInTheDocument()
    expect(enLaPila.getByRole('status')).toBeInTheDocument()
    expect(document.querySelectorAll('#notice-root')).toHaveLength(1)
  })

  it('con los tres avisos ocultos, la pila queda vacia', async () => {
    mockActualizacion(false)

    render(
      <>
        <OfflineIndicator isOnline pedidosPendientes={[]} mermasPendientes={[]} />
        <SyncStatusBanner pollInterval={50} />
        <BannerActualizacion />
      </>
    )
    // Deja pasar varios polls de SyncStatusBanner (cola vacía) antes de mirar.
    await act(async () => {
      await new Promise(resolve => setTimeout(resolve, 250))
    })

    expect(document.getElementById('notice-root')?.childElementCount ?? 0).toBe(0)
    expect(screen.queryByRole('button', { name: /sin conexion|pendiente|conectado/i })).toBeNull()
    expect(screen.queryByRole('alert')).toBeNull()
    expect(screen.queryByRole('status')).toBeNull()
  })

  it('sin pila (getNoticeRoot da null) cada aviso se renderiza en el lugar, con su rol', async () => {
    vi.mocked(getNoticeRoot).mockReturnValue(null)
    await encolarYFallar()

    const { container } = render(
      <>
        <OfflineIndicator isOnline={false} />
        <SyncStatusBanner pollInterval={100000} />
        <BannerActualizacion />
      </>
    )

    const alerta = await screen.findByRole('alert')
    expect(container).toContainElement(alerta)
    expect(container).toContainElement(screen.getByRole('status'))
    expect(container).toContainElement(screen.getByRole('button', { name: /sin conexion/i }))
  })

  it('los toasts NO entran en la pila: van en su propio contenedor, encima de los modales', async () => {
    const user = userEvent.setup()

    render(
      <NotificationProvider>
        <BotonToast />
        <OfflineIndicator isOnline={false} />
      </NotificationProvider>
    )

    await user.click(screen.getByRole('button', { name: 'Avisar' }))

    const toast = screen.getByText('Pedido creado')
    // La pila existe (el indicador está adentro) y el toast no es parte de ella.
    expect(within(pila()).getByRole('button', { name: /sin conexion/i })).toBeInTheDocument()
    expect(pila()).not.toContainElement(toast)
  })

  it('al desmontarse, los avisos salen de la pila', async () => {
    await encolarYFallar()

    const { unmount } = render(
      <>
        <BannerActualizacion />
        <SyncStatusBanner pollInterval={100000} />
      </>
    )
    await screen.findByRole('alert')
    // Precondición: estaban en la pila. Sin esto el test pasa aunque los avisos
    // nunca hayan entrado en ella.
    expect(within(pila()).getByRole('status')).toBeInTheDocument()
    expect(within(pila()).getByRole('alert')).toBeInTheDocument()

    unmount()

    expect(within(pila()).queryByRole('status')).not.toBeInTheDocument()
    expect(within(pila()).queryByRole('alert')).not.toBeInTheDocument()
    expect(pila().childElementCount).toBe(0)
  })

  describe('con el CSS real de Tailwind', () => {
    let estilo: HTMLStyleElement | null = null

    afterEach(() => {
      estilo?.remove()
      estilo = null
      // La pila sobrevive entre tests (no vive en el container de RTL).
      document.querySelectorAll(`[${MARCA_JSDOM}]`).forEach(el => el.removeAttribute(MARCA_JSDOM))
      // Radix en modo modal apaga los punteros del body; si queda puesto, el
      // userEvent del test siguiente no puede clickear nada.
      document.body.style.pointerEvents = ''
    })

    it('los avisos toman el toque aunque la pila no: la franja vacia no se come los clicks', async () => {
      const user = userEvent.setup()
      const { actualizar } = mockActualizacion(true)
      await encolarYFallar()

      render(
        <>
          <BannerActualizacion />
          <SyncStatusBanner pollInterval={100000} />
        </>
      )
      await screen.findByRole('alert')
      estilo = await inyectarCssDeLaPila()

      await expect(user.click(pila())).rejects.toThrow(/pointer-events: none/)

      await user.click(within(pila()).getByRole('button', { name: 'Actualizar' }))
      expect(actualizar).toHaveBeenCalledTimes(1)

      await user.click(within(pila()).getByRole('button', { name: 'Expandir detalles' }))
      expect(within(pila()).getByRole('button', { name: 'Contraer detalles' })).toBeInTheDocument()
    })

    it('con un menu modal de Radix abierto los avisos quedan inertes, como el resto de la pantalla, y vuelven al cerrarlo', async () => {
      const user = userEvent.setup()
      const { actualizar } = mockActualizacion(true)
      await encolarYFallar()

      render(
        <>
          <OfflineIndicator isOnline={false} />
          <SyncStatusBanner pollInterval={100000} />
          <BannerActualizacion />
          <MenuDeAcciones />
        </>
      )
      await screen.findByRole('alert')
      estilo = await inyectarCssDeLaPila()

      // Se toman antes de abrir el menú: Radix además marca `aria-hidden` todo lo
      // de afuera, y con eso las consultas por rol ya no los encuentran.
      const enLaPila = within(pila())
      const pastilla = enLaPila.getByRole('button', { name: /sin conexion/i })
      const botonActualizar = enLaPila.getByRole('button', { name: 'Actualizar' })
      const botonEliminar = enLaPila.getByRole('button', { name: 'Eliminar' })

      await user.click(screen.getByRole('button', { name: 'Mas acciones' }))
      await screen.findByRole('menu')
      // Precondición: el menú es modal y apagó los punteros del body.
      expect(document.body.style.pointerEvents).toBe('none')

      // Ninguno de los tres recibe el toque: ni "Actualizar" recarga ni "Eliminar"
      // descarta las operaciones fallidas.
      await expect(user.click(botonActualizar)).rejects.toThrow(/pointer-events: none/)
      await expect(user.click(botonEliminar)).rejects.toThrow(/pointer-events: none/)
      await expect(user.click(pastilla)).rejects.toThrow(/pointer-events: none/)
      expect(actualizar).not.toHaveBeenCalled()

      await user.keyboard('{Escape}')
      await waitFor(() => expect(screen.queryByRole('menu')).not.toBeInTheDocument())
      expect(document.body.style.pointerEvents).toBe('')

      await user.click(botonActualizar)
      expect(actualizar).toHaveBeenCalledTimes(1)
    })

    it('ningun aviso se achica para entrar en la pila: si no entran, la pila scrollea', async () => {
      await encolarYFallar()

      render(
        <>
          <OfflineIndicator isOnline={false} />
          <SyncStatusBanner pollInterval={100000} />
          <BannerActualizacion />
        </>
      )
      await screen.findByRole('alert')
      estilo = await inyectarCssDeLaPila()

      const avisos = Array.from(pila().children)
      expect(avisos).toHaveLength(3)
      for (const aviso of avisos) {
        expect(getComputedStyle(aviso).flexShrink).toBe('0')
      }
    })
  })
})
