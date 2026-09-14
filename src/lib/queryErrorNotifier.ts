/**
 * Puente entre `queryClient` (módulo, fuera del árbol de React) y
 * `NotificationContext` (hook). `QueryCache.onError` necesita poder avisar
 * sin depender de un componente, así que `NotificationProvider` registra acá
 * su `error()` al montar.
 */
type QueryErrorNotifier = (message: string) => void

let notifier: QueryErrorNotifier | null = null

export function setQueryErrorNotifier(fn: QueryErrorNotifier | null): void {
  notifier = fn
}

export function notifyQueryError(message: string): void {
  notifier?.(message)
}
