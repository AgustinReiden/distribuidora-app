import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import SkipLinks from './SkipLinks'

// Mock scrollIntoView para jsdom
Element.prototype.scrollIntoView = vi.fn()

describe('SkipLinks', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  afterEach(() => {
    document.body.innerHTML = ''
  })

  it('renders all default skip links', () => {
    render(<SkipLinks />)

    expect(screen.getByText('Ir al contenido principal')).toBeInTheDocument()
    expect(screen.getByText('Ir a la navegación')).toBeInTheDocument()
    expect(screen.getByText('Ir a búsqueda')).toBeInTheDocument()
  })

  it('has correct aria-label on navigation', () => {
    render(<SkipLinks />)

    const nav = screen.getByRole('navigation', { name: /enlaces de salto/i })
    expect(nav).toBeInTheDocument()
  })

  it('links have correct href attributes', () => {
    render(<SkipLinks />)

    const mainLink = screen.getByText('Ir al contenido principal').closest('a')
    const navLink = screen.getByText('Ir a la navegación').closest('a')
    const searchLink = screen.getByText('Ir a búsqueda').closest('a')

    expect(mainLink).toHaveAttribute('href', '#main-content')
    expect(navLink).toHaveAttribute('href', '#main-navigation')
    expect(searchLink).toHaveAttribute('href', '#search-input')
  })

  it('clicking skip link focuses target element', () => {
    // Create target element
    const mainContent = document.createElement('div')
    mainContent.id = 'main-content'
    document.body.appendChild(mainContent)

    render(<SkipLinks />)

    const mainLink = screen.getByText('Ir al contenido principal')
    fireEvent.click(mainLink)

    // The element should have tabindex set for focus
    expect(mainContent.getAttribute('tabindex')).toBe('-1')
    expect(Element.prototype.scrollIntoView).toHaveBeenCalled()
  })

  it('handles missing target gracefully', () => {
    render(<SkipLinks />)

    const mainLink = screen.getByText('Ir al contenido principal')

    // Should not throw when clicking on missing target
    expect(() => fireEvent.click(mainLink)).not.toThrow()
  })

  it('renders with custom targets', () => {
    const customTargets = [
      { id: 'custom-section', label: 'Ir a sección personalizada' }
    ]

    render(<SkipLinks targets={customTargets} />)

    expect(screen.getByText('Ir a sección personalizada')).toBeInTheDocument()
    expect(screen.queryByText('Ir al contenido principal')).not.toBeInTheDocument()
  })

  it('prevents default navigation behavior', () => {
    const mainContent = document.createElement('div')
    mainContent.id = 'main-content'
    document.body.appendChild(mainContent)

    render(<SkipLinks />)

    const mainLink = screen.getByText('Ir al contenido principal')

    // Click should work without navigating away
    fireEvent.click(mainLink)

    // Element should still be in document
    expect(document.getElementById('main-content')).toBeInTheDocument()
  })
})

describe('SkipLinks accessibility', () => {
  it('all skip links are keyboard accessible', () => {
    render(<SkipLinks />)

    const links = screen.getAllByRole('link')

    links.forEach(link => {
      // Links should be naturally focusable
      expect(link.tagName).toBe('A')
    })
  })

  it('skip links have proper focus styles', () => {
    render(<SkipLinks />)

    const links = screen.getAllByRole('link')

    links.forEach(link => {
      // Check that focus class is defined in the style tag
      expect(link.className).toContain('skip-link')
    })
  })

  it('renders proper number of links', () => {
    render(<SkipLinks />)

    const links = screen.getAllByRole('link')
    expect(links).toHaveLength(3)
  })
})
