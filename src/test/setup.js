/* eslint-disable no-undef */
import '@testing-library/jest-dom'
import { cleanup } from '@testing-library/react'
import { afterEach, vi } from 'vitest'
import 'fake-indexeddb/auto'

// Cleanup after each test
afterEach(() => {
  cleanup()
  // Sin esto, lo que escribe un test se filtra al siguiente.
  localStorageStore.clear()
})

// localStorage: almacenamiento REAL en memoria, pero espiable.
//
// Antes eran cuatro vi.fn() pelados: getItem devolvia undefined incluso despues
// de un setItem, asi que nada que dependiera de storage se podia testear. Dos
// suites terminaron construyendose su propio localStorage en memoria para
// esquivarlo (useAsync.test.js y rutaOfflineCache.test.ts).
//
// No alcanza con poner un storage funcional a secas: ErrorBoundary.test.jsx
// hace expect(localStorage.removeItem).toHaveBeenCalledWith(...). Por eso cada
// metodo guarda de verdad Y es un vi.fn(): sirve para las dos cosas.
const localStorageStore = new Map()
const localStorageMock = {
  getItem: vi.fn(k => (localStorageStore.has(String(k)) ? localStorageStore.get(String(k)) : null)),
  setItem: vi.fn((k, v) => { localStorageStore.set(String(k), String(v)) }),
  removeItem: vi.fn(k => { localStorageStore.delete(String(k)) }),
  clear: vi.fn(() => { localStorageStore.clear() }),
  key: vi.fn(i => Array.from(localStorageStore.keys())[i] ?? null),
  get length() { return localStorageStore.size },
}
global.localStorage = localStorageMock
globalThis.localStorage = localStorageMock

// Mock matchMedia
Object.defineProperty(window, 'matchMedia', {
  writable: true,
  value: vi.fn().mockImplementation(query => ({
    matches: false,
    media: query,
    onchange: null,
    addListener: vi.fn(),
    removeListener: vi.fn(),
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    dispatchEvent: vi.fn(),
  })),
})

// Mock ResizeObserver
global.ResizeObserver = vi.fn().mockImplementation(() => ({
  observe: vi.fn(),
  unobserve: vi.fn(),
  disconnect: vi.fn(),
}))

// Mock crypto for AES-GCM tests and Dexie.js
Object.defineProperty(global, 'crypto', {
  value: {
    subtle: {
      generateKey: vi.fn(),
      encrypt: vi.fn(),
      decrypt: vi.fn(),
      exportKey: vi.fn(),
      importKey: vi.fn(),
      // Required by Dexie.js for content hashing
      digest: vi.fn().mockImplementation(async (algorithm, data) => {
        // Simple mock that returns a fake hash based on data length
        const hashLength = algorithm === 'SHA-256' ? 32 : 20
        const result = new Uint8Array(hashLength)
        for (let i = 0; i < hashLength; i++) {
          result[i] = (data.length + i) % 256
        }
        return result.buffer
      }),
    },
    getRandomValues: (arr) => {
      for (let i = 0; i < arr.length; i++) {
        arr[i] = Math.floor(Math.random() * 256)
      }
      return arr
    },
  },
})
