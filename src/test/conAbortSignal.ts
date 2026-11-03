/**
 * Lo que devuelve `supabase.rpc(...)` en producción es un builder que además de
 * ser awaitable tiene `.abortSignal()`. Las escrituras con plazo de red (#1366,
 * `escrituraIdempotente`) lo llaman, así que un mock de `rpc` que devuelve una
 * promesa pelada ya no alcanza.
 */
import type { Mock, MockInstance } from 'vitest'

export type ConAbortSignal<T> = Promise<T> & { abortSignal: (signal: AbortSignal) => Promise<T> }

export function conAbortSignal<T>(valor: T | Promise<T>): ConAbortSignal<T> {
  const promesa = Promise.resolve(valor)
  return Object.assign(promesa, { abortSignal: () => promesa })
}

/**
 * Para un `vi.fn()` de `rpc` que el test configura con `mockResolvedValue(Once)` /
 * `mockRejectedValue(Once)`: lo que devuelve pasa a traer `.abortSignal()`.
 */
export function rpcConAbortSignal(rpc: Mock | MockInstance): void {
  const crear = (resolver: () => Promise<unknown>) => () => conAbortSignal(resolver())
  rpc.mockResolvedValueOnce = (v: unknown) => rpc.mockImplementationOnce(crear(() => Promise.resolve(v)))
  rpc.mockResolvedValue = (v: unknown) => rpc.mockImplementation(crear(() => Promise.resolve(v)))
  rpc.mockRejectedValueOnce = (e: unknown) => rpc.mockImplementationOnce(crear(() => Promise.reject(e)))
  rpc.mockRejectedValue = (e: unknown) => rpc.mockImplementation(crear(() => Promise.reject(e)))
}
