import { logger } from './logger'
import { AUTH_RUNTIME_HOTFIX_VERSION } from './pwaAuthHotfix'

interface AuthTrace {
  source: string;
  startedAt: number;
  resourceBaseline: number;
  firstRenderLogged: boolean;
  requestWindowTimer: ReturnType<typeof setTimeout> | null;
}

let currentTrace: AuthTrace | null = null

function emitAuthPerfLog(message: string, context: Record<string, unknown> = {}): void {
  logger.info(message, context)

  if (typeof console !== 'undefined' && typeof console.info === 'function') {
    console.info(message, {
      recoveryVersion: AUTH_RUNTIME_HOTFIX_VERSION,
      ...context
    })
  }
}

function now(): number {
  return typeof performance !== 'undefined' && typeof performance.now === 'function'
    ? performance.now()
    : Date.now()
}

function getResourceCount(): number {
  if (typeof performance === 'undefined' || typeof performance.getEntriesByType !== 'function') {
    return 0
  }

  return performance.getEntriesByType('resource').length
}

export function beginAuthTrace(source: string): void {
  if (currentTrace?.requestWindowTimer) {
    clearTimeout(currentTrace.requestWindowTimer)
  }

  currentTrace = {
    source,
    startedAt: now(),
    resourceBaseline: getResourceCount(),
    firstRenderLogged: false,
    requestWindowTimer: null
  }

  emitAuthPerfLog('[auth-perf] auth transition started', { source })
}

export function logAuthEvent(event: string, context: Record<string, unknown> = {}): void {
  emitAuthPerfLog('[auth-perf] auth event', { event, ...context })
}

export function logAuthTiming(label: string, durationMs: number, context: Record<string, unknown> = {}): void {
  emitAuthPerfLog('[auth-perf] timing', {
    label,
    durationMs: Math.round(durationMs),
    ...context
  })
}

export function trackFirstAuthenticatedRender(route: string): void {
  if (!currentTrace || currentTrace.firstRenderLogged) {
    return
  }

  currentTrace.firstRenderLogged = true

  logAuthTiming('firstRouteRender', now() - currentTrace.startedAt, {
    source: currentTrace.source,
    route
  })

  currentTrace.requestWindowTimer = setTimeout(() => {
    if (!currentTrace) {
      return
    }

    const requestCount = Math.max(0, getResourceCount() - currentTrace.resourceBaseline)

    emitAuthPerfLog('[auth-perf] first window summary', {
      source: currentTrace.source,
      route,
      requestCount5s: requestCount
    })
  }, 5000)
}

export function resetAuthTrace(): void {
  if (currentTrace?.requestWindowTimer) {
    clearTimeout(currentTrace.requestWindowTimer)
  }

  currentTrace = null
}
