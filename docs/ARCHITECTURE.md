# Arquitectura

> Describe lo que hay **hoy**. Todo lo que dice acá se puede verificar con `ls`, `grep`
> o corriendo los comandos. Si algo no se puede verificar, no está escrito.
>
> Última verificación contra el código: 2026-08-26.

## Stack

| Capa | Qué |
|---|---|
| Front | React 19 + Vite 7, TypeScript |
| Estado servidor | TanStack Query 5 |
| Estilos | Tailwind 3 + Radix UI |
| Validación | Zod 4 |
| Back | Supabase — Postgres + Auth + RLS |
| Edge | Deno (`supabase/functions/`) |
| Offline | Dexie (IndexedDB) |
| Tests | Vitest 4 (unit) + Playwright (e2e) |
| Deploy | push a `main` → webhook de Coolify |

## Árbol de `src/`

Conteos reales de archivos, para dar idea de dónde está el peso:

```
src/
├── components/
│   ├── modals/          78   el grueso de la UI
│   ├── vistas/          23   pantallas
│   ├── containers/      20   estado + handlers de cada dominio
│   ├── ui/              15   primitivas
│   ├── pedidos/         12
│   ├── productos/       12
│   ├── layout/           6
│   ├── rutaActiva/       6
│   ├── geolocalizacion/  5
│   └── dashboard, clientes, misEntregas, a11y, auth, metas, perfil, recorridos
├── hooks/
│   ├── queries/         51   capa de datos real (TanStack Query)
│   ├── supabase/        19   acceso directo y auth
│   └── state/            3
├── utils/               96   lógica pura, es donde viven los cálculos testeables
├── lib/                 16   supabase.ts, schemas.ts, offlineDb.ts, permisos.ts, pdf/
├── contexts/            11
├── services/
│   ├── api/              3   clientes y productos (ver abajo)
│   └── business/         1
├── constants/            5
└── types/                4
```

## Cómo fluyen los datos

```
Componente
   ↓  hook de src/hooks/queries/   ← la capa de datos
TanStack Query  (cache, invalidación, reintentos)
   ↓
supabase-js  →  RPC SECURITY DEFINER  o  PostgREST con RLS
   ↓
Postgres
```

Las escrituras van por dos caminos, y la división es deliberada:

- **Operaciones transaccionales** —pedidos, pagos, stock, recorridos— pasan por una
  **RPC `SECURITY DEFINER`**, para que la regla de negocio y la transacción vivan en un
  solo lugar. En `usePedidosQuery.ts`, por ejemplo, hay 10 `.rpc()` contra 4 escrituras
  directas.
- **ABM de catálogo** —clientes, productos, proveedores, zonas, marcas, categorías,
  promociones, usuarios— escribe directo contra PostgREST, apoyado en RLS.

En total: 72 llamadas `.rpc()` y 73 escrituras directas en `src/hooks/queries/`.

Consecuencia importante: **una RPC `SECURITY DEFINER` saltea RLS**, así que el aislamiento
por sucursal no puede depender sólo de las policies. Se ata además con FKs compuestas
`(columna, sucursal)`. Hay un gate de CI que lo verifica.

Sin conexión, el alta de pedido se encola en IndexedDB (`src/lib/offlineDb.ts`) y se
replaya después contra `crear_pedido_idempotente`, que es idempotente por diseño.

## Los containers

`src/components/containers/` es donde vive el estado y los handlers de cada dominio
(`ClientesContainer`, `PedidosContainer`, `ProductosContainer`, …). Un container arma
los datos, define qué pasa al confirmar cada acción, y monta los modales de su dominio.

Los modales se montan **dentro** del container que los usa. Una confirmación disparada
desde un modal Radix tiene que renderizarse dentro de ese modal: como hermano en el
container queda detrás del overlay y falla en silencio.

## Contextos que realmente se montan

`ThemeProvider`, `AuthProvider`, `NotificationProvider` (en `App.tsx`),
`AuthDataProvider`, `SucursalProvider`, y `QueryClientProvider` (en `main.tsx`).

Todos los que `src/contexts/` exporta se montan. No siempre fue así.

## La capa que no existe

Si encontrás documentación, comentarios o ramas que hablen de **handlers de UI en hooks
propios** (`src/hooks/handlers/`, `HandlersContext`, `useHandlerActions`) o de un
**`pedidoService`**, están hablando de arquitecturas que se intentaron y no se
terminaron. Se retiraron en agosto de 2026 (#495, #496, #503).

Los handlers viven en `src/components/containers/`. Los pedidos se leen y escriben por
`src/hooks/queries/`. `src/services/api/` quedó con `clienteService` y `productoService`,
que sí se usan.

Se deja escrito porque la versión anterior de este archivo describía esos handlers como
la capa central de la app, con diagrama incluido: la arquitectura escrita mandaba a leer
una capa que ya no ejecutaba nadie.

## Seguridad

- **RLS** en las tablas, con helpers de rol (`es_preventista()`, `es_transportista()`,
  `tiene_rol_extra()`). Ojo: `es_preventista()` devuelve `true` también para `admin` y
  `encargado` — ver `CLAUDE.md`.
- **`perfiles.rol`** es la identidad; **`perfil_roles`** agrega capacidades extra.
- Toda función `SECURITY DEFINER` nueva nace con `EXECUTE` para `PUBLIC` y hay que
  revocarlo en la misma migración. Gate de CI en `.github/workflows/integridad.yml`.
- El aislamiento por sucursal se ata con FKs compuestas, no sólo con RLS.

## Migraciones

`migrations/` es una **vista curada**, no un espejo de producción. La fuente de verdad es
el ledger de prod. El número se elige al final, justo antes de aplicar. Todo el detalle
—incluidas las tres veces que esto falló— está en `migrations/MANIFEST.md`.

## Edge functions

```
supabase/functions/
├── telegram-webhook/   bot (agente Gemini con tools por rol)
├── telegram-digest/    resumen programado
├── optimizar-ruta/     optimización de recorridos (Google Routes)
├── _shared/            utils compartidos con el front — ver abajo
└── tests/
```

Algunos utils están **duplicados a propósito** entre `src/utils/` y
`supabase/functions/_shared/utils/`, porque Deno no puede importar del árbol de Vite.
Llevan una cabecera `⚠ AUTO-SYNCED ... NO EDITAR ACÁ` y hay un test
(`tests/sync_utils.test.ts`) que verifica que no se desincronicen. Si tocás uno, tocá el
otro.

## Testing

- **Unit** (Vitest): del orden de 100 archivos y 1400 tests. Corren sin `.env` — así se detectan fallos
  de import que un `.env` local enmascara.
- **E2E** (Playwright, chromium): `e2e/`.
- **Edge** (Deno): `deno task test` desde `supabase/functions/`.
- **Integridad de datos**: `.github/workflows/integridad.yml` corre a diario una batería
  de invariantes contra prod, más el drift-check de migraciones, el aislamiento por
  sucursal y los permisos `EXECUTE`.

La lógica de negocio se escribe en `src/utils/` justamente para poder testearla sin
montar componentes.
