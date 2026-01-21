import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { ErrorBoundary, CompactErrorBoundary } from './ErrorBoundary'

// Mock Sentry
vi.mock('../lib/sentry', () => ({
  captureException: vi.fn(),
  addBreadcrumb: vi.fn()
}))

// Mock errorUtils
vi.mock('../utils/errorUtils', () => ({
  categorizeError: vi.fn(() => 'unknown'),
  getRecoveryInfo: vi.fn(() => ({
    title: 'Error',
    message: 'Something went wrong',
    iconName: 'Bug',
    canRetry: true,
    action: 'reload',
    retryDelay: 1000,
    maxRetries: 3
  })),
  ErrorCategory: {
    NETWORK: 'network',
    AUTH: 'auth',
    UNKNOWN: 'unknown'
  }
}))

// Componente que lanza error
const ThrowError = ({ shouldThrow = false }) => {
  if (shouldThrow) {
    throw new Error('Test error')
  }
  return <div>Normal content</div>
}

// Componente que lanza error con mensaje específico
const ThrowCustomError = ({ message }) => {
  throw new Error(message)
}

describe('ErrorBoundary', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    // Suprimir errores de consola durante tests
    vi.spyOn(console, 'error').mockImplementation(() => {})
  })

  it('renders children when no error', () => {
    render(
      <ErrorBoundary>
        <div>Test content</div>
      </ErrorBoundary>
    )

    expect(screen.getByText('Test content')).toBeInTheDocument()
  })

  it('renders error UI when child throws', () => {
    render(
      <ErrorBoundary>
        <ThrowError shouldThrow={true} />
      </ErrorBoundary>
    )

    expect(screen.getByText('Error')).toBeInTheDocument()
    expect(screen.getByText('Something went wrong')).toBeInTheDocument()
  })

  it('shows reload button', () => {
    render(
      <ErrorBoundary>
        <ThrowError shouldThrow={true} />
      </ErrorBoundary>
    )

    expect(screen.getByRole('button', { name: /recargar página/i })).toBeInTheDocument()
  })

  it('shows retry button when canRetry is true', () => {
    render(
      <ErrorBoundary>
        <ThrowError shouldThrow={true} />
      </ErrorBoundary>
    )

    expect(screen.getByRole('button', { name: /reintentar/i })).toBeInTheDocument()
  })

  it('calls onError callback when error occurs', () => {
    const onError = vi.fn()

    render(
      <ErrorBoundary onError={onError}>
        <ThrowError shouldThrow={true} />
      </ErrorBoundary>
    )

    expect(onError).toHaveBeenCalled()
  })

  it('uses custom fallback when provided', () => {
    const fallback = ({ error }) => <div>Custom fallback: {error?.message}</div>

    render(
      <ErrorBoundary fallback={fallback}>
        <ThrowCustomError message="Custom error message" />
      </ErrorBoundary>
    )

    expect(screen.getByText('Custom fallback: Custom error message')).toBeInTheDocument()
  })

  it('reloads page when reload button clicked', () => {
    const reloadMock = vi.fn()
    Object.defineProperty(window, 'location', {
      value: { reload: reloadMock },
      writable: true
    })

    render(
      <ErrorBoundary>
        <ThrowError shouldThrow={true} />
      </ErrorBoundary>
    )

    fireEvent.click(screen.getByRole('button', { name: /recargar página/i }))
    expect(reloadMock).toHaveBeenCalled()
  })
})

describe('CompactErrorBoundary', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.spyOn(console, 'error').mockImplementation(() => {})
  })

  it('renders children when no error', () => {
    render(
      <CompactErrorBoundary>
        <div>Test content</div>
      </CompactErrorBoundary>
    )

    expect(screen.getByText('Test content')).toBeInTheDocument()
  })

  it('renders compact error UI when child throws', () => {
    render(
      <CompactErrorBoundary>
        <ThrowError shouldThrow={true} />
      </CompactErrorBoundary>
    )

    expect(screen.getByText('Error')).toBeInTheDocument()
  })

  it('shows close button when onClose provided', () => {
    const onClose = vi.fn()

    render(
      <CompactErrorBoundary onClose={onClose}>
        <ThrowError shouldThrow={true} />
      </CompactErrorBoundary>
    )

    expect(screen.getByRole('button', { name: /cerrar/i })).toBeInTheDocument()
  })

  it('calls onClose when close button clicked', () => {
    const onClose = vi.fn()

    render(
      <CompactErrorBoundary onClose={onClose}>
        <ThrowError shouldThrow={true} />
      </CompactErrorBoundary>
    )

    fireEvent.click(screen.getByRole('button', { name: /cerrar/i }))
    expect(onClose).toHaveBeenCalled()
  })

  it('uses custom error message when provided', () => {
    render(
      <CompactErrorBoundary errorMessage="Custom error message">
        <ThrowError shouldThrow={true} />
      </CompactErrorBoundary>
    )

    expect(screen.getByText('Custom error message')).toBeInTheDocument()
  })

  it('calls onError callback', () => {
    const onError = vi.fn()

    render(
      <CompactErrorBoundary onError={onError}>
        <ThrowError shouldThrow={true} />
      </CompactErrorBoundary>
    )

    expect(onError).toHaveBeenCalled()
  })

  it('retry button shows loading state', async () => {
    render(
      <CompactErrorBoundary>
        <ThrowError shouldThrow={true} />
      </CompactErrorBoundary>
    )

    const retryButton = screen.getByRole('button', { name: /reintentar/i })
    fireEvent.click(retryButton)

    await waitFor(() => {
      expect(screen.getByText(/reintentando/i)).toBeInTheDocument()
    })
  })
})
