/**
 * El «atrás» que cierra ventanas no rompe al router (decisión 4 del dueño, #1603): con un `BrowserRouter` real
 * sobre el historial de jsdom, el «atrás» con una ventana abierta la cierra y se queda en la ruta; sin ventana
 * navega a la ruta de antes, como siempre; y abrir y cerrar la ventana no cambia la ruta ni la cantidad de
 * «atrás» que hacen falta para llegar a la pantalla anterior.
 */
import '@testing-library/jest-dom/vitest'
import { useState } from 'react'
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { asentar, atras } from '../test/atrasHelpers'
import { render, screen, cleanup } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { BrowserRouter, Link, Route, Routes } from 'react-router-dom'
import ModalBase from '../components/modals/ModalBase'
import { reiniciarAtrasModales } from './atrasModales'


function Pedidos() {
  const [abierto, setAbierto] = useState(false)
  return (
    <div>
      <h1>Pedidos</h1>
      <Link to="/clientes">Ir a clientes</Link>
      <button onClick={() => setAbierto(true)}>Abrir ventana</button>
      {abierto && (
        <ModalBase title="Ventana" onClose={() => setAbierto(false)}><p>contenido</p></ModalBase>
      )}
    </div>
  )
}

function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Link to="/pedidos">Ir a pedidos</Link>} />
        <Route path="/pedidos" element={<Pedidos />} />
        <Route path="/clientes" element={<h1>Clientes</h1>} />
      </Routes>
    </BrowserRouter>
  )
}

beforeEach(() => {
  reiniciarAtrasModales()
  window.history.replaceState(null, '', '/')
})
afterEach(async () => {
  cleanup()
  await asentar()
  reiniciarAtrasModales()
})

describe('«atrás» con el router', () => {
  it('con la ventana abierta el «atrás» la cierra y se queda en la ruta; sin ventana, el «atrás» navega a la anterior', async () => {
    const user = userEvent.setup()
    render(<App />)
    await user.click(screen.getByRole('link', { name: 'Ir a pedidos' }))
    expect(screen.getByRole('heading', { name: 'Pedidos' })).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Abrir ventana' }))
    await asentar()
    expect(screen.getByRole('dialog', { name: 'Ventana' })).toBeInTheDocument()

    await atras()
    expect(screen.queryByRole('dialog', { name: 'Ventana' })).not.toBeInTheDocument()
    expect(window.location.pathname).toBe('/pedidos')
    expect(screen.getByRole('heading', { name: 'Pedidos' })).toBeInTheDocument()

    // Sin ventana, el siguiente «atrás» vuelve a la pantalla de antes, como siempre.
    await atras()
    expect(window.location.pathname).toBe('/')
    expect(screen.getByRole('link', { name: 'Ir a pedidos' })).toBeInTheDocument()
  })

  it('abrir y cerrar la ventana con la X no agrega ningún «atrás» de más', async () => {
    const user = userEvent.setup()
    render(<App />)
    await user.click(screen.getByRole('link', { name: 'Ir a pedidos' }))

    await user.click(screen.getByRole('button', { name: 'Abrir ventana' }))
    await asentar()
    await user.click(screen.getByRole('button', { name: /cerrar/i }))
    await asentar()
    expect(screen.queryByRole('dialog', { name: 'Ventana' })).not.toBeInTheDocument()

    // Un solo «atrás» alcanza para volver a la pantalla anterior.
    await atras()
    expect(window.location.pathname).toBe('/')
  })
})
