# Distribuidora App

[![CI](https://github.com/AgustinReiden/distribuidora-app/actions/workflows/ci.yml/badge.svg)](https://github.com/AgustinReiden/distribuidora-app/actions/workflows/ci.yml)
[![Deploy](https://github.com/AgustinReiden/distribuidora-app/actions/workflows/deploy.yml/badge.svg)](https://github.com/AgustinReiden/distribuidora-app/actions/workflows/deploy.yml)

Sistema de gestión integral para distribuidoras de alimentos. Permite gestionar clientes, productos, pedidos, entregas y pagos.

## Stack Tecnológico

- **Frontend:** React 19 + Vite
- **Backend:** Supabase (PostgreSQL + Auth + RLS)
- **Styling:** Tailwind CSS
- **UI Components:** Radix UI
- **Validación:** Zod
- **Testing:** Vitest + Playwright

## Requisitos

- Node.js 20+
- npm 10+
- Cuenta de Supabase

## Instalación

```bash
# Clonar repositorio
git clone https://github.com/AgustinReiden/distribuidora-app.git
cd distribuidora-app

# Instalar dependencias
npm install

# Copiar variables de entorno
cp .env.example .env

# Editar .env con tus credenciales de Supabase
```

## Variables de Entorno

```env
VITE_SUPABASE_URL=https://tu-proyecto.supabase.co
VITE_SUPABASE_ANON_KEY=tu-anon-key
VITE_GOOGLE_API_KEY=tu-google-api-key  # Opcional, para autocompletado de direcciones
VITE_SENTRY_DSN=tu-sentry-dsn          # Opcional, para monitoreo de errores
```

## Scripts Disponibles

```bash
# Desarrollo
npm run dev           # Servidor de desarrollo en http://localhost:5173

# Testing
npm run test          # Tests en modo watch
npm run test:run      # Tests una sola vez
npm run test:coverage # Tests con cobertura
npm run test:e2e      # Tests e2e con Playwright
npm run test:e2e:ui   # Tests e2e con UI interactiva

# Build
npm run build         # Build de producción
npm run preview       # Preview del build

# Calidad
npm run lint          # ESLint
npm run check-secrets # Verificar secretos en código
```

## Estructura del Proyecto

```
src/
├── components/        # Componentes React
│   ├── auth/         # Login, protección de rutas
│   ├── layout/       # Sidebar, header, navigation
│   ├── modals/       # Modales reutilizables
│   ├── pedidos/      # Componentes de pedidos
│   ├── ui/           # Componentes base (Dialog, Dropdown, etc.)
│   └── vistas/       # Vistas principales
├── contexts/         # React Contexts (Theme, Notifications)
├── hooks/            # Custom hooks
│   ├── supabase/     # Hooks de API (useClientes, usePedidos, etc.)
│   └── handlers/     # Handlers de eventos
├── lib/              # Configuraciones y utilidades core
│   ├── pdf/          # Generadores de PDF
│   └── schemas.js    # Schemas de validación Zod
├── utils/            # Utilidades generales
└── test/             # Utilidades de testing
```

## Roles de Usuario

| Rol | Permisos |
|-----|----------|
| **Admin** | Acceso total, gestión de usuarios |
| **Preventista** | Gestión de clientes y pedidos |
| **Transportista** | Ver pedidos asignados, marcar entregas |

## Seguridad

- Row Level Security (RLS) en todas las tablas
- Autenticación via Supabase Auth
- Sanitización XSS con DOMPurify
- Cifrado AES-GCM para datos locales
- CSP configurado
- Pre-commit hooks para prevenir leaks de secretos

## Contribución

1. Crear branch desde `main`
2. Hacer cambios
3. Asegurar que pasen lint y tests
4. Crear Pull Request

## Licencia

Privado - Todos los derechos reservados
