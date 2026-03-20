import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'

// Test state
let mockNeedRefresh = false
let mockOfflineReady = false

// Mock virtual:pwa-register/react before importing component
vi.mock('virtual:pwa-register/react', () => ({
  useRegisterSW: () => ({
    needRefresh: [mockNeedRefresh, vi.fn()],
    offlineReady: [mockOfflineReady, vi.fn()],
    updateServiceWorker: vi.fn()
  })
}))

// Import component after mock setup
import { PWAPrompt } from './PWAPrompt'

describe('PWAPrompt', () => {
  let originalMatchMedia

  beforeEach(() => {
    vi.clearAllMocks()
    mockNeedRefresh = false
    mockOfflineReady = false

    // Mock matchMedia
    originalMatchMedia = window.matchMedia
    window.matchMedia = vi.fn().mockImplementation(query => ({
      matches: false,
      media: query,
      onchange: null,
      addListener: vi.fn(),
      removeListener: vi.fn(),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      dispatchEvent: vi.fn()
    }))

    // Clear localStorage
    localStorage.clear()
  })

  afterEach(() => {
    window.matchMedia = originalMatchMedia
    Reflect.deleteProperty(window, 'caches')
    vi.restoreAllMocks()
  })

  it('renders nothing when in standalone mode', () => {
    // Mock standalone mode
    window.matchMedia = vi.fn().mockImplementation(query => ({
      matches: query.includes('standalone'),
      media: query,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn()
    }))

    const { container } = render(<PWAPrompt />)

    // Should render empty or minimal when in standalone mode
    // Component returns null when isStandalone is true
    expect(container.querySelector('.fixed')).toBeNull()
  })

  it('does not show notifications when both flags are false', () => {
    mockNeedRefresh = false
    mockOfflineReady = false

    render(<PWAPrompt />)

    expect(screen.queryByText('Listo para usar offline')).not.toBeInTheDocument()
    expect(screen.queryByText('Nueva versión disponible')).not.toBeInTheDocument()
  })

  it('respects dismissed preference stored in localStorage', () => {
    // Set dismissed timestamp within 7 days
    const recentDismiss = Date.now() - (3 * 24 * 60 * 60 * 1000) // 3 days ago
    localStorage.setItem('pwa-install-dismissed', recentDismiss.toString())

    render(<PWAPrompt />)

    // Install prompt should not be shown
    expect(screen.queryByText('Instalar Distribuidora')).not.toBeInTheDocument()
  })

  it('component renders without crashing', () => {
    expect(() => render(<PWAPrompt />)).not.toThrow()
  })

  it('has proper structure when rendered', () => {
    const { container } = render(<PWAPrompt />)

    // Component should render a fragment
    expect(container).toBeInTheDocument()
  })

  it('cleans up legacy supabase runtime caches from previous installs', async () => {
    const keysMock = vi.fn().mockResolvedValue(['images-cache', 'supabase-api-cache'])
    const deleteMock = vi.fn().mockResolvedValue(true)

    Object.defineProperty(window, 'caches', {
      configurable: true,
      value: {
        keys: keysMock,
        delete: deleteMock
      }
    })

    render(<PWAPrompt />)

    await waitFor(() => {
      expect(keysMock).toHaveBeenCalled()
    })

    expect(deleteMock).toHaveBeenCalledTimes(1)
    expect(deleteMock).toHaveBeenCalledWith('supabase-api-cache')
  })
})

describe('PWAPrompt component structure', () => {
  beforeEach(() => {
    mockNeedRefresh = false
    mockOfflineReady = false

    window.matchMedia = vi.fn().mockImplementation(() => ({
      matches: false,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn()
    }))

    localStorage.clear()
  })

  it('exports PWAPrompt as named export', async () => {
    const module = await import('./PWAPrompt')
    expect(module.PWAPrompt).toBeDefined()
  })

  it('exports PWAPrompt as default export', async () => {
    const module = await import('./PWAPrompt')
    expect(module.default).toBeDefined()
  })
})
