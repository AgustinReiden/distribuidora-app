import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'

vi.mock('./logger', () => ({
  logger: {
    info: vi.fn(),
    warn: vi.fn()
  }
}))

import { applyAuthRuntimeHotfix, AUTH_RUNTIME_HOTFIX_VERSION } from './pwaAuthHotfix'

describe('applyAuthRuntimeHotfix', () => {
  const originalLocation = window.location
  const originalLocalStorage = window.localStorage
  const originalSessionStorage = window.sessionStorage
  const originalServiceWorker = navigator.serviceWorker
  const originalCaches = window.caches

  let localStorageMock: Storage
  let sessionStorageMock: Storage
  let getRegistrationsMock: ReturnType<typeof vi.fn>
  let replaceMock: ReturnType<typeof vi.fn>
  let keysMock: ReturnType<typeof vi.fn>
  let deleteMock: ReturnType<typeof vi.fn>

  beforeEach(() => {
    replaceMock = vi.fn()
    getRegistrationsMock = vi.fn().mockResolvedValue([])
    keysMock = vi.fn().mockResolvedValue([])
    deleteMock = vi.fn().mockResolvedValue(true)

    localStorageMock = {
      getItem: vi.fn().mockReturnValue(null),
      setItem: vi.fn(),
      removeItem: vi.fn(),
      clear: vi.fn(),
      key: vi.fn(),
      length: 0
    } as unknown as Storage

    sessionStorageMock = {
      getItem: vi.fn().mockReturnValue(null),
      setItem: vi.fn(),
      removeItem: vi.fn(),
      clear: vi.fn(),
      key: vi.fn(),
      length: 0
    } as unknown as Storage

    Object.defineProperty(window, 'location', {
      configurable: true,
      value: {
        ...originalLocation,
        href: 'https://example.com/pedidos',
        replace: replaceMock
      }
    })

    Object.defineProperty(window, 'localStorage', {
      configurable: true,
      value: localStorageMock
    })

    Object.defineProperty(window, 'sessionStorage', {
      configurable: true,
      value: sessionStorageMock
    })

    Object.defineProperty(navigator, 'serviceWorker', {
      configurable: true,
      value: {
        ...originalServiceWorker,
        getRegistrations: getRegistrationsMock
      }
    })

    Object.defineProperty(window, 'caches', {
      configurable: true,
      value: {
        keys: keysMock,
        delete: deleteMock
      }
    })
  })

  afterEach(() => {
    Object.defineProperty(window, 'location', {
      configurable: true,
      value: originalLocation
    })

    Object.defineProperty(window, 'localStorage', {
      configurable: true,
      value: originalLocalStorage
    })

    Object.defineProperty(window, 'sessionStorage', {
      configurable: true,
      value: originalSessionStorage
    })

    Object.defineProperty(navigator, 'serviceWorker', {
      configurable: true,
      value: originalServiceWorker
    })

    Object.defineProperty(window, 'caches', {
      configurable: true,
      value: originalCaches
    })

    vi.clearAllMocks()
  })

  it('no hace nada si el hotfix ya fue aplicado', async () => {
    vi.mocked(window.localStorage.getItem).mockReturnValue(AUTH_RUNTIME_HOTFIX_VERSION)

    const reloaded = await applyAuthRuntimeHotfix()

    expect(reloaded).toBe(false)
    expect(getRegistrationsMock).not.toHaveBeenCalled()
    expect(keysMock).not.toHaveBeenCalled()
    expect(replaceMock).not.toHaveBeenCalled()
  })

  it('desregistra service workers, limpia caches y recarga una sola vez', async () => {
    const unregisterMock = vi.fn().mockResolvedValue(true)

    getRegistrationsMock.mockResolvedValue([{ unregister: unregisterMock }])
    keysMock.mockResolvedValue(['workbox-precache', 'images-cache'])

    const reloaded = await applyAuthRuntimeHotfix()

    expect(reloaded).toBe(true)
    expect(unregisterMock).toHaveBeenCalledTimes(1)
    expect(deleteMock).toHaveBeenCalledTimes(2)
    expect(window.localStorage.setItem).toHaveBeenCalledWith(
      'auth-runtime-hotfix-version',
      AUTH_RUNTIME_HOTFIX_VERSION
    )
    expect(window.sessionStorage.setItem).toHaveBeenCalledWith(
      `auth-runtime-hotfix-reload:${AUTH_RUNTIME_HOTFIX_VERSION}`,
      '1'
    )
    expect(replaceMock).toHaveBeenCalledWith('https://example.com/pedidos')
  })

  it('marca la version aunque no haya nada que limpiar y evita la recarga', async () => {
    const reloaded = await applyAuthRuntimeHotfix()

    expect(reloaded).toBe(false)
    expect(window.localStorage.setItem).toHaveBeenCalledWith(
      'auth-runtime-hotfix-version',
      AUTH_RUNTIME_HOTFIX_VERSION
    )
    expect(replaceMock).not.toHaveBeenCalled()
  })

  it('no recarga de nuevo si ya hizo el recovery una vez para esta version', async () => {
    const unregisterMock = vi.fn().mockResolvedValue(true)

    getRegistrationsMock.mockResolvedValue([{ unregister: unregisterMock }])
    keysMock.mockResolvedValue(['workbox-precache'])
    vi.mocked(window.sessionStorage.getItem).mockReturnValue('1')

    const reloaded = await applyAuthRuntimeHotfix()

    expect(reloaded).toBe(false)
    expect(unregisterMock).toHaveBeenCalledTimes(1)
    expect(deleteMock).toHaveBeenCalledTimes(1)
    expect(replaceMock).not.toHaveBeenCalled()
  })
})
