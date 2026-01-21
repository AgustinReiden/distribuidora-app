# Arquitectura de Distribuidora App

## Visión General

Distribuidora App es una aplicación web construida con React 19 + Vite para la gestión de una distribuidora de alimentos. La arquitectura sigue principios de separación de concerns y está diseñada para escalabilidad y mantenibilidad.

## Stack Tecnológico

| Capa | Tecnología |
|------|------------|
| Frontend | React 19 + Vite |
| Estilos | Tailwind CSS |
| Backend | Supabase (PostgreSQL + Auth + RLS) |
| Testing | Vitest + Playwright |
| CI/CD | GitHub Actions |

## Estructura de Directorios

```
src/
├── components/          # Componentes React
│   ├── layout/         # Componentes de layout (Header, Sidebar, etc.)
│   ├── modals/         # Modales de la aplicación
│   ├── pedidos/        # Componentes específicos de pedidos
│   └── vistas/         # Vistas principales
├── hooks/              # Custom hooks
│   ├── supabase/       # Hooks de datos (clientes, productos, etc.)
│   └── handlers/       # Hooks de handlers de UI
├── services/           # Capa de servicios
│   ├── api/           # Servicios de API (CRUD)
│   └── business/      # Lógica de negocio
├── lib/               # Utilidades y configuraciones
│   ├── schemas.js     # Esquemas de validación Zod
│   ├── sentry.js      # Integración Sentry
│   └── pdf/           # Generación de PDFs
├── utils/             # Funciones utilitarias
└── App.jsx            # Componente raíz
```

## Capas de la Arquitectura

### 1. Capa de Presentación (Components)

Componentes React organizados por dominio y función.

```
┌─────────────────────────────────────────────┐
│              Componentes UI                  │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐       │
│  │ Vistas  │ │ Modales │ │ Layout  │       │
│  └────┬────┘ └────┬────┘ └────┬────┘       │
│       │           │           │             │
│       └───────────┼───────────┘             │
│                   ▼                         │
│           Handlers Hooks                    │
└─────────────────────────────────────────────┘
```

**Principios:**
- Componentes pequeños y enfocados
- Props tipadas con JSDoc
- Error Boundaries para manejo de errores
- Virtualización para listas largas

### 2. Capa de Estado (Hooks)

Hooks personalizados que manejan estado y lógica de UI.

```javascript
// Hook de datos
const { clientes, loading, agregarCliente } = useClientes()

// Hook de handlers
const { handleNuevoCliente, handleEditarCliente } = useClienteHandlers()

// Hook de servicio
const { data, execute, loading } = useService(() => clienteService.getAll())
```

**Tipos de Hooks:**

| Tipo | Ubicación | Propósito |
|------|-----------|-----------|
| Supabase Hooks | `hooks/supabase/` | CRUD y datos |
| Handler Hooks | `hooks/handlers/` | Lógica de UI |
| Utility Hooks | `hooks/` | Funcionalidad reutilizable |

### 3. Capa de Servicios (Services)

Abstracción de operaciones de datos con lógica de negocio.

```
┌─────────────────────────────────────────────┐
│              Capa de Servicios              │
│                                             │
│  ┌─────────────────────────────────────┐   │
│  │          Business Services          │   │
│  │  ┌──────────────┐ ┌──────────────┐ │   │
│  │  │ StockManager │ │ OrderManager │ │   │
│  │  └──────┬───────┘ └──────┬───────┘ │   │
│  └─────────┼────────────────┼──────────┘   │
│            ▼                ▼              │
│  ┌─────────────────────────────────────┐   │
│  │           API Services              │   │
│  │  ┌────────┐ ┌────────┐ ┌────────┐  │   │
│  │  │Cliente │ │Producto│ │ Pedido │  │   │
│  │  │Service │ │Service │ │Service │  │   │
│  │  └────┬───┘ └────┬───┘ └────┬───┘  │   │
│  └───────┼──────────┼──────────┼───────┘   │
│          └──────────┼──────────┘           │
│                     ▼                      │
│  ┌─────────────────────────────────────┐   │
│  │           BaseService               │   │
│  │  (CRUD genérico + RPC + Cache)      │   │
│  └─────────────────────────────────────┘   │
└─────────────────────────────────────────────┘
```

**BaseService - Operaciones:**
- `getAll(options)` - Obtener todos con filtros
- `getById(id)` - Obtener por ID
- `create(data)` / `createMany(items)` - Crear
- `update(id, data)` / `updateWhere(filters, data)` - Actualizar
- `delete(id)` / `deleteWhere(filters)` - Eliminar
- `rpc(fn, params, fallback)` - Llamadas RPC con fallback
- `count(filters)` / `exists(filters)` - Consultas

### 4. Capa de Datos (Supabase)

Backend serverless con PostgreSQL y Row Level Security.

```
┌─────────────────────────────────────────────┐
│              Supabase                        │
│                                             │
│  ┌─────────────┐  ┌─────────────────────┐  │
│  │    Auth     │  │   Row Level Security │  │
│  │ (JWT + RLS) │  │   (Políticas)       │  │
│  └──────┬──────┘  └──────────┬──────────┘  │
│         │                    │              │
│         ▼                    ▼              │
│  ┌─────────────────────────────────────┐   │
│  │           PostgreSQL                │   │
│  │  ┌─────────┐ ┌─────────┐ ┌───────┐ │   │
│  │  │clientes │ │productos│ │pedidos│ │   │
│  │  └─────────┘ └─────────┘ └───────┘ │   │
│  │  ┌─────────┐ ┌─────────┐ ┌───────┐ │   │
│  │  │perfiles │ │ pagos   │ │compras│ │   │
│  │  └─────────┘ └─────────┘ └───────┘ │   │
│  └─────────────────────────────────────┘   │
│                                             │
│  ┌─────────────────────────────────────┐   │
│  │         RPC Functions               │   │
│  │  • descontar_stock_atomico          │   │
│  │  • restaurar_stock_atomico          │   │
│  │  • crear_pedido_completo            │   │
│  │  • eliminar_pedido_completo         │   │
│  └─────────────────────────────────────┘   │
└─────────────────────────────────────────────┘
```

## Flujo de Datos

```
Usuario → Componente → Handler Hook → Service → Supabase
                                         ↓
                                    RPC/Query
                                         ↓
Usuario ← Componente ← Hook State ← Service ← Response
```

**Ejemplo: Crear Pedido**

```javascript
// 1. Usuario hace clic en "Crear Pedido"
// 2. Handler hook procesa el evento
const handleCrearPedido = async (datos) => {
  // 3. Servicio ejecuta lógica de negocio
  const pedido = await pedidoService.crearPedidoCompleto(
    datos,
    items,
    true // descontar stock
  )

  // 4. Hook actualiza estado
  setPedidos(prev => [...prev, pedido])

  // 5. UI se actualiza automáticamente
}
```

## Manejo de Errores

### Estrategia de Error Boundaries

```
┌─────────────────────────────────────────────┐
│           ErrorBoundary (Root)              │
│  ┌───────────────────────────────────────┐ │
│  │     CompactErrorBoundary (Section)    │ │
│  │  ┌─────────────────────────────────┐ │ │
│  │  │         Componente              │ │ │
│  │  │                                 │ │ │
│  │  │  try {                          │ │ │
│  │  │    await service.operation()    │ │ │
│  │  │  } catch (error) {              │ │ │
│  │  │    // Categorizar error         │ │ │
│  │  │    // Mostrar mensaje apropiado │ │ │
│  │  │  }                              │ │ │
│  │  └─────────────────────────────────┘ │ │
│  └───────────────────────────────────────┘ │
└─────────────────────────────────────────────┘
```

### Categorías de Error

| Categoría | Acción | Reintento |
|-----------|--------|-----------|
| `network` | Verificar conexión | Sí (3x) |
| `auth` | Redirigir a login | No |
| `validation` | Mostrar errores | No |
| `database` | Reintentar | Sí (2x) |
| `unknown` | Error genérico | Sí (1x) |

## Seguridad

### Capas de Seguridad

1. **Frontend**
   - Sanitización con DOMPurify
   - Validación con Zod
   - CSP estricto
   - Encriptación localStorage (AES-GCM)

2. **Backend (Supabase)**
   - Row Level Security
   - JWT Authentication
   - Políticas por rol

3. **DevOps**
   - Pre-commit hooks (secretos)
   - npm audit en CI
   - Dependabot

## Testing

### Pirámide de Tests

```
        ┌─────────┐
        │   E2E   │  Playwright
        │ (Login) │
       ┌┴─────────┴┐
       │Integration│  Vitest + Services
       │  (API)    │
      ┌┴───────────┴┐
      │    Unit     │  Vitest
      │(Logic/Utils)│
      └─────────────┘
```

### Cobertura

| Tipo | Herramienta | Cobertura |
|------|-------------|-----------|
| Unit | Vitest | Schemas, Utils, Services |
| Integration | Vitest | Hooks, Services |
| E2E | Playwright | Login, Accesibilidad |

## CI/CD

### Pipeline

```
Push → Lint → Test → Build → Security → Deploy
         │      │      │        │
         │      │      │        └── npm audit
         │      │      └── Vite build
         │      └── Vitest + Playwright
         └── ESLint
```

### Ambientes

| Branch | Ambiente | URL |
|--------|----------|-----|
| `develop` | Staging | staging.app.com |
| `main` | Production | app.com |

## Patrones de Diseño

### Singleton (Servicios)

```javascript
// Instancia única exportada
export const clienteService = new ClienteService()
```

### Factory (Error Recovery)

```javascript
function getRecoveryInfo(category) {
  return recoveryStrategies[category]
}
```

### Observer (React State)

```javascript
const [state, setState] = useState()
// React re-renderiza automáticamente
```

### Strategy (RPC Fallback)

```javascript
await service.rpc('function', params, fallbackFn)
```

## Guía de Contribución

### Crear nuevo componente

1. Crear archivo en `src/components/[domain]/`
2. Agregar tests en `__tests__/`
3. Exportar desde `index.js`

### Crear nuevo servicio

1. Extender `BaseService` si es CRUD
2. Agregar a `services/index.js`
3. Crear tests en `services/__tests__/`

### Crear nuevo hook

1. Usar `useService` para operaciones async
2. Manejar loading/error states
3. Documentar con JSDoc

## Performance

### Optimizaciones Implementadas

- **Code Splitting**: Rutas lazy-loaded
- **Virtualización**: `react-window` para listas
- **Memoization**: `useMemo`, `useCallback`
- **Caché**: `useService` con TTL

### Métricas Target

| Métrica | Target |
|---------|--------|
| LCP | < 2.5s |
| FID | < 100ms |
| CLS | < 0.1 |
| Bundle Size | < 500KB (gzip) |

---

*Última actualización: 2026-01-21*
