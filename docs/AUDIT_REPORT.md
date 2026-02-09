# Auditoría Completa del Código - Distribuidora App

**Fecha:** 9 de Febrero de 2026
**Aplicación:** Distribuidora App - Sistema de gestión para distribuidoras de alimentos
**Stack:** React 19 + TypeScript + Vite + Supabase + TailwindCSS
**Líneas de código:** ~19,500 en 150+ archivos fuente

---

## Resumen Ejecutivo

| Área | Puntuación | Estado |
|------|-----------|--------|
| **Seguridad** | 8.2/10 | Sólida, mejoras menores necesarias |
| **Calidad de código** | 6.5/10 | Deuda técnica acumulada |
| **Rendimiento** | 8.0/10 | Buena base, optimizaciones pendientes |
| **Manejo de errores** | 7.0/10 | Buenas bases, gaps en modales y reportes |
| **Arquitectura** | 7.5/10 | Bien estructurada, complejidad creciente |
| **Testing** | 6.0/10 | Cobertura parcial, faltan tests críticos |
| **Puntuación Global** | **7.2/10** | |

---

## 1. SEGURIDAD

### 1.1 Fortalezas

- **Sin inyección SQL**: Todas las queries usan Supabase client con queries parametrizadas
- **Protección XSS**: DOMPurify integrado en `src/utils/sanitize.ts` con sanitización comprehensiva
- **Autenticación robusta**: JWT via Supabase Auth con auto-logout por inactividad (15 min)
- **Almacenamiento encriptado**: AES-GCM para datos sensibles en localStorage (`src/utils/secureStorage.ts`)
- **Validación de entrada**: Schemas Zod en `src/lib/schemas.ts` para todas las entidades
- **Validación de archivos**: Límites de tamaño, tipos MIME, prevención de inyección de fórmulas (`src/utils/fileValidation.ts`)
- **RLS en base de datos**: Row Level Security configurada por rol (admin, preventista, transportista, deposito)
- **Redacción de datos sensibles**: Logger y Sentry redactan passwords, tokens, CUIT, etc.
- **0 vulnerabilidades conocidas** en npm audit

### 1.2 Problemas Encontrados

#### ALTO - CSP con `unsafe-inline`
- **Archivo:** `index.html:12`
- **Problema:** `script-src 'self' 'unsafe-inline'` reduce la protección contra XSS
- **Recomendación:** Reemplazar con nonces de script o hashes CSP

#### MEDIO - URL de n8n hardcodeada en CSP
- **Archivo:** `index.html:12`
- **Problema:** `https://n8n.shycia.com.ar` está hardcodeada en el meta tag CSP
- **Recomendación:** Mover a variable de entorno exclusivamente

#### MEDIO - Sin rate limiting a nivel de aplicación
- **Problema:** No hay throttling de requests API más allá del debounce de búsqueda
- **Mitigación actual:** Supabase maneja rate limiting del lado del servidor
- **Recomendación:** Agregar throttling para operaciones batch

#### BAJO - Timing attacks en login
- **Archivo:** `src/components/auth/LoginScreen.tsx:19`
- **Recomendación:** Agregar delays consistentes en respuestas de autenticación

---

## 2. CALIDAD DE CÓDIGO

### 2.1 Problemas Críticos

#### Props Drilling Excesivo
- **Archivo:** `src/components/pedidos/VistaPedidos.tsx:24-60`
- **Problema:** Componente recibe **22+ props** incluyendo 15+ callbacks
- **Impacto:** Difícil de mantener, alta acoplamiento
- **Solución:** Usar Context o custom hooks para agrupar props relacionadas

#### Type Assertions Inseguras (`as unknown as`)
- **Archivos afectados:** 10+ archivos incluyendo:
  - `App.tsx:131-153` (6 assertions)
  - `ComprasContainer.tsx` (2 assertions)
  - `ProductosContainer.tsx` (2 assertions)
  - `ProveedoresContainer.tsx` (3 assertions)
  - `VistaPedidos.tsx:179`
- **Problema:** Bypasses de TypeScript que rompen la seguridad de tipos
- **Solución:** Corregir las definiciones de tipos en las interfaces de los hooks

#### Uso de `any`
- **Archivos:** `useClientes.ts:74`, `baseService.ts:242`, `VirtualList.tsx`
- **Solución:** Definir tipos específicos para cada caso

### 2.2 Archivos Demasiado Grandes

| Archivo | Líneas | Problema |
|---------|--------|----------|
| `types/hooks.ts` | 1,230 | Necesita split por dominio |
| `lib/schemas.ts` | 962 | Demasiados schemas en un archivo |
| `ModalCompra.tsx` | 800 | Mezcla lógica, estado y UI |
| `AppModals.tsx` | 668 | 23 modales lazy en un archivo |
| `useAppHandlers.ts` | 649 | Composición de 6+ handlers |
| `ModalGestionRutas.tsx` | 619 | Múltiples concerns |
| `VistaRecorridos.tsx` | 597 | Componentes colapsados |
| `ModalEditarPedido.tsx` | 572 | Debería splitear en sub-componentes |
| `VistaRendiciones.tsx` | 534 | Concerns mezclados |
| `usePedidos.ts` | 532 | Deprecado pero en uso |

### 2.3 Hooks Deprecados Aún en Uso

Los siguientes hooks están marcados `@deprecated` pero siguen siendo la fuente principal de datos:

1. **`usePedidos.ts`** - Usado en `App.tsx:108`, debería migrar a `usePedidosQuery`
2. **`useClientes.ts`** - Sin migración completa a `useClientesQuery`
3. **`useProductos.ts`** - Fuente primaria de datos aún

**Impacto:** Duplicación de lógica de fetching, inconsistencia entre hooks legacy y TanStack Query.

### 2.4 Código Muerto y Comentado

- **`useAppState.ts:395-398`**: Función `createClearer` comentada
- **`ModalGestionRutas.tsx`**: Secciones de implementación vieja comentadas
- **`ModalOptimizarRuta.tsx`**: Código de implementación anterior comentado
- **Solución:** Eliminar código comentado, usar git history para restaurar si es necesario

### 2.5 Duplicación de Código

- **Patrón modal repetido:** ModalCliente, ModalProducto, ModalProveedor (400+ líneas cada uno) comparten estructura idéntica de formulario, validación, y submit
- **Validación de stock:** Duplicada en `useProductos.ts:120-136`, `useOfflineSync.ts`, y `usePedidoHandlers.ts`
- **Formateo de fecha:** `new Date().toISOString().split('T')[0]` repetido en múltiples archivos

---

## 3. RENDIMIENTO

### 3.1 Fortalezas

- **Code splitting excelente**: Chunks manuales en `vite.config.js` (React, Radix, Supabase, PDF, Excel)
- **Lazy loading**: 6 vistas + 23 modales cargados con `React.lazy()`
- **Virtual scrolling**: `react-window` implementado para listas de pedidos
- **React.memo**: 70+ componentes memoizados
- **useCallback/useMemo**: 80+ instancias con dependency arrays correctos
- **TanStack Query**: staleTime 5min, gcTime 30min, retry inteligente
- **Service Worker**: Estrategias de cache apropiadas (Network First para API, Cache First para assets)
- **Imágenes optimizadas**: Lazy loading nativo, WebP con fallback, srcset responsivo

### 3.2 Problemas Encontrados

#### MEDIO - AppDataContext como "mega-context"
- **Archivo:** `src/App.tsx:213-257`
- **Problema:** Un solo context contiene clientes, productos, pedidos, usuarios, etc.
- **Impacto:** Cambio en `isOnline` causa re-render de TODO el árbol de providers
- **Solución:** Remover datos redundantes de AppDataContext (ya tienen sus propios contexts)

#### MEDIO - Recreación del objeto handlers
- **Archivo:** `src/App.tsx:127-154`
- **Problema:** 65+ funciones handler se recrean cuando cualquier dependencia cambia
- **Impacto:** Componentes que consumen handlers via context se re-renderizan innecesariamente
- **Solución:** Dividir handlers en contexts más pequeños y especializados

#### MEDIO - Sin pattern de context selectors
- **Archivos:** Múltiples contexts
- **Problema:** Componentes que usan solo `isAdmin` de AppDataContext se re-renderizan cuando `clientes` cambia
- **Solución:** Implementar hooks selectores: `useIsAdmin()`, `useClientes()`, etc.

#### BAJO - Handlers no memoizados en VirtualizedPedidoList
- **Archivo:** `src/components/pedidos/VirtualizedPedidoList.tsx:227-237`
- **Problema:** Objeto handlers creado fresh cada render
- **Solución:** Envolver en `useMemo`

#### BAJO - Suspense fallback vacío en modales
- **Archivos:** Containers (`ClientesContainer.tsx:136`)
- **Problema:** `fallback={null}` no muestra indicador de carga
- **Solución:** Agregar spinner overlay mientras el modal lazy-loadea

---

## 4. MANEJO DE ERRORES

### 4.1 Fortalezas

- **ErrorBoundary comprehensivo**: `src/components/ErrorBoundary.tsx` con retry exponencial, integración Sentry, y variante compacta para modales
- **useAsync**: `src/hooks/useAsync.ts` con protección contra race conditions
- **Operaciones offline**: `useOfflineQueue` con retry automático y backoff exponencial
- **BaseService**: Manejo de errores consistente con `handleError()` y `notifyError()`
- **Operaciones atómicas**: Stock y pedidos usan RPC de Supabase para transacciones
- **Rollback de stock**: `stockManager.ts:236-243` revierte operaciones parciales

### 4.2 Problemas Encontrados

#### ALTO - Promise rejection sin manejar
- **Archivo:** `src/components/modals/ModalEditarPedido.tsx:198`
- **Código:** `await onSaveItems(items)` sin try-catch
- **Riesgo:** Estado inconsistente del componente si la operación falla

#### ALTO - Null checks faltantes en reportes
- **Archivo:** `src/components/vistas/reportes/ReporteRentabilidad.tsx:77-96`
- **Código:** `p.margenPorcentaje.toFixed(1)` - crash si es undefined
- **Riesgo:** Crash del reporte si los datos calculados tienen valores faltantes

#### MEDIO - Error handling faltante en descarga de plantilla
- **Archivo:** `src/components/modals/ModalImportarPrecios.tsx:239`
- **Código:** `await createTemplate(...)` sin try-catch
- **Riesgo:** Error no comunicado al usuario

#### MEDIO - Validación de stock silenciosa
- **Archivo:** `src/components/modals/ModalEditarPedido.tsx:159-162`
- **Código:** `if (nuevaCantidad > stockDisponible) { return item; }` - falla silenciosa
- **Riesgo:** Usuario no sabe por qué el item no se actualizó

#### MEDIO - Modales sin ErrorBoundary
- **Problema:** La mayoría de modales no usan `CompactErrorBoundary`
- **Archivos afectados:** ModalEditarPedido, ModalImportarPrecios, ModalCompra, ModalGestionRutas, etc.
- **Solución:** Envolver contenido de cada modal en `CompactErrorBoundary`

#### BAJO - Error silenciado en logout
- **Archivo:** `src/App.tsx:186`
- **Código:** `catch { /* error silenciado */ }`
- **Recomendación:** Al menos logear el error

---

## 5. ARQUITECTURA

### 5.1 Fortalezas

- **Separación de concerns**: Services, hooks, components, contexts bien definidos
- **Path aliases**: `@components/`, `@hooks/`, `@services/`, `@utils/`, `@lib/`
- **PWA completo**: Offline, installable, cache strategies
- **CI/CD**: GitHub Actions con lint, tests, typecheck, security audit, deploy
- **Multi-deployment**: Vercel (primario) + Netlify (fallback)
- **Accessibility**: Skip links, high contrast, WCAG compliance

### 5.2 Problemas Encontrados

#### App.tsx como "God Component"
- **494 líneas** con responsabilidades múltiples:
  - Instanciación de todos los hooks de datos
  - Composición de handlers
  - Creación de valores de context
  - Rendering de providers anidados (7+ niveles)
- **Solución:** Extraer a un `AppProviders` component y un `AppDataLoader` hook

#### Migración incompleta a TanStack Query
- Los containers nuevos usan `useClientesQuery`, `usePedidosQuery`, etc.
- Pero `App.tsx` aún usa los hooks legacy (`usePedidos`, `useClientes`)
- Resultado: **dos fuentes de verdad** para los mismos datos
- **Solución:** Completar migración y remover hooks deprecados

#### Complejidad de Context Providers
- `App.tsx:307-340` tiene 7 providers anidados:
  ```
  ThemeProvider > AuthProvider > NotificationProvider > HandlersProvider >
  ClientesProvider > ProductosProvider > PedidosProvider > OperationsProvider >
  AppDataProvider
  ```
- **Solución:** Considerar Zustand o Jotai para reemplazar contexts granulares

---

## 6. TESTING

### 6.1 Estado Actual

- **19 archivos de test** (unit + component + integration)
- **Coverage thresholds:** 50% statements, 40% branches, 45% functions, 50% lines
- **E2E tests:** Login, accessibility, offline-sync, security (Playwright)
- **Testing library:** Vitest + React Testing Library

### 6.2 Gaps de Cobertura

| Área | Tests Existentes | Tests Faltantes |
|------|-----------------|-----------------|
| Modales | ModalConfirmacion, ModalEditarPedido | ModalPedido, ModalCliente, ModalCompra (críticos) |
| Vistas | Ninguno | VistaPedidos, VistaDashboard (principales) |
| Services | baseService, clienteService, stockManager | pedidoService, productoService |
| Hooks | useAuth, useClientes, usePedidos, useProductos | useCompras, useOfflineQueue (offline crítico) |
| Utils | formatters, sanitize | calculations, errorHandling, secureStorage |
| Contexts | Ninguno | AppDataContext, NotificationContext |
| Reportes | Ninguno | ReporteRentabilidad, ReporteVentasClientes |

### 6.3 Recomendaciones

1. **Priorizar:** Tests para flujo de creación de pedidos (camino crítico del negocio)
2. **Agregar:** Tests de integración para offline queue → sync → API
3. **Agregar:** Tests de reportes con datos edge case (vacíos, negativos, undefined)
4. **Subir thresholds** gradualmente a 70%+ cuando la migración a TanStack Query esté completa

---

## 7. PLAN DE REMEDIACIÓN

### Prioridad 1 - Crítica (Esta semana)

| # | Tarea | Archivo(s) | Esfuerzo |
|---|-------|-----------|----------|
| 1 | Agregar try-catch a `onSaveItems` | ModalEditarPedido.tsx:198 | Bajo |
| 2 | Agregar null checks en reportes | ReporteRentabilidad.tsx:77-96 | Bajo |
| 3 | Agregar error handling a `descargarPlantilla` | ModalImportarPrecios.tsx:239 | Bajo |
| 4 | Mostrar feedback cuando stock validation falla | ModalEditarPedido.tsx:159 | Bajo |
| 5 | Remover `unsafe-inline` del CSP | index.html:12 | Medio |

### Prioridad 2 - Alta (Este sprint)

| # | Tarea | Archivo(s) | Esfuerzo |
|---|-------|-----------|----------|
| 6 | Envolver modales en CompactErrorBoundary | 15+ modales | Medio |
| 7 | Resolver type assertions `as unknown as` | 10+ archivos | Medio |
| 8 | Completar migración a TanStack Query | App.tsx, hooks/ | Alto |
| 9 | Agregar tests para flujo de pedidos | tests/ | Alto |
| 10 | Mover URL de n8n a env variable exclusivamente | index.html, useOptimizarRuta.ts | Bajo |

### Prioridad 3 - Media (Próximo sprint)

| # | Tarea | Archivo(s) | Esfuerzo |
|---|-------|-----------|----------|
| 11 | Refactorizar VistaPedidos (reducir props) | VistaPedidos.tsx | Alto |
| 12 | Splitear archivos grandes (hooks.ts, schemas.ts) | types/, lib/ | Medio |
| 13 | Implementar context selectors | contexts/ | Medio |
| 14 | Splitear AppDataContext mega-context | App.tsx, contexts/ | Alto |
| 15 | Crear componente modal genérico (reducir duplicación) | components/modals/ | Alto |

### Prioridad 4 - Baja (Backlog)

| # | Tarea | Archivo(s) | Esfuerzo |
|---|-------|-----------|----------|
| 16 | Refactorizar App.tsx (extraer providers/data loader) | App.tsx | Alto |
| 17 | Eliminar código comentado y dead code | Varios | Bajo |
| 18 | Agregar rate limiting a nivel de aplicación | services/ | Medio |
| 19 | Implementar context selectors o migrar a Zustand | contexts/ | Alto |
| 20 | Subir coverage thresholds a 70% | vitest.config | Medio |

---

## 8. MÉTRICAS DEL PROYECTO

| Métrica | Valor |
|---------|-------|
| Líneas de código fuente | ~19,500 |
| Archivos fuente | 150+ |
| Archivos de test | 19 |
| Dependencias de producción | 32 |
| Dependencias de desarrollo | 30 |
| Componentes React | 87 |
| Custom hooks | 70+ |
| Contexts | 12 |
| Migraciones de DB | 20+ |
| Modales | 23 |
| Vistas principales | 11 |
| Vulnerabilidades npm | 0 |

---

## 9. CONCLUSIÓN

La aplicación Distribuidora App es un sistema de producción maduro con una base sólida en seguridad, arquitectura y prácticas modernas de React. Las principales áreas de mejora son:

1. **Deuda técnica en tipos**: Las 15+ assertions `as unknown as` son el problema más urgente de calidad de código, ya que indican incompatibilidades de tipos que podrían causar bugs en runtime.

2. **Migración incompleta**: La coexistencia de hooks legacy y TanStack Query crea dos fuentes de verdad y duplicación de lógica.

3. **Manejo de errores inconsistente**: Mientras que la base (BaseService, ErrorBoundary, useAsync) es excelente, los modales y reportes tienen gaps que podrían causar crashes en producción.

4. **Archivos grandes**: 10 archivos exceden las 500 líneas, dificultando el mantenimiento y aumentando la probabilidad de conflictos de merge.

5. **Cobertura de tests**: Con 19 archivos de test, la cobertura es parcial. Los flujos críticos de negocio (pedidos, pagos, stock) necesitan mayor cobertura.

La aplicación está bien posicionada para escalar si se abordan estos problemas de forma incremental siguiendo el plan de remediación propuesto.

---

*Auditoría realizada con análisis estático del código fuente. Se recomienda complementar con testing de penetración y profiling de rendimiento en producción.*
