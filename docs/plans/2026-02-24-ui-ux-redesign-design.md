# UI/UX Redesign: Crecer Distribuciones

**Date**: 2026-02-24
**Approach**: B - Component Upgrade (Polish + Component refinement)
**Goal**: Transform the app from generic/amateur look to professional SaaS quality

## Problem

The app is technically well-built (accessibility, dark mode, performance) but visually generic:
- No brand identity (generic "Distribuidora" with a truck icon)
- Flat white cards with gray borders (basic Tailwind starter look)
- System fonts, no typographic hierarchy
- Blue-600 everywhere (default Tailwind primary)
- Native selects, basic inputs, plain buttons
- Dashboard without real visual impact

## Brand: Crecer Distribuciones

- **Name**: Crecer Distribuciones
- **Color concept**: "Crecer" = growth = emerald/teal palette
- **Personality**: Professional, trustworthy, growth-oriented

## Design Decisions

### 1. Color Palette

Replace `blue-600` primary with emerald/teal:

| Role | Old | New |
|------|-----|-----|
| Primary | blue-600 (#2563eb) | emerald-600 (#059669) |
| Primary hover | blue-700 | emerald-700 |
| Primary soft | blue-100 | emerald-50/100 |
| Accent | (none) | teal-500 (#14b8a6) |
| Header | white flat | gradient emerald-700 to teal-600 |
| Neutrals | gray-* | slate-* |
| Success | green-600 | keep |
| Warning | amber-600 | keep |
| Error | red-600 | keep |

Dark mode: emerald-400 text, emerald-900/30 backgrounds.

### 2. Typography

Add Inter via Google Fonts:
- `font-family: 'Inter', system-ui, -apple-system, sans-serif`
- Headings: `font-semibold tracking-tight`
- Body: `font-normal`
- Monospace: keep `font-mono` for CUIT/IDs

### 3. Header / Navigation

- Background: `bg-gradient-to-r from-emerald-700 to-teal-600` (light), `from-gray-900 to-gray-800` (dark)
- All text/icons in white
- Logo: "Crecer" with TrendingUp or Sprout icon instead of Truck
- Active nav item: `bg-white/20 backdrop-blur`
- Dropdown menus: backdrop-blur, shadow-xl, rounded-xl
- User avatar: white ring

### 4. Cards

- Base: `bg-white dark:bg-slate-800 rounded-xl shadow-sm hover:shadow-lg transition-all duration-200`
- Pedido cards: left border colored by status (`border-l-4`)
- Hover: `hover:translate-y-[-1px]` with shadow increase
- Badges: `ring-1 ring-inset` for refinement

### 5. Dashboard Metric Cards

- Icon background: gradient (e.g., `from-emerald-400 to-emerald-600`)
- Number: `text-4xl font-bold`
- Top decorative border: 3px colored line
- Hover: colored shadow (e.g., `shadow-emerald-100`)

### 6. Buttons

- Primary: `bg-gradient-to-r from-emerald-600 to-teal-600 rounded-xl shadow-md hover:shadow-lg`
- Secondary: `bg-white border-2 border-slate-200 rounded-xl hover:border-emerald-300`
- Danger: keep red, match rounded-xl and shadow pattern
- All: `transition-all duration-200`

### 7. Inputs & Forms

- Border: `border-slate-300 rounded-xl`
- Focus: `ring-emerald-500 border-emerald-500`
- Replace native selects with Radix Select (dependency already exists)
- Error: `border-red-400 ring-1 ring-red-100`

### 8. Login Screen

- Background: `bg-gradient-to-br from-emerald-700 via-teal-600 to-emerald-800`
- Decorative pattern (CSS circles/mesh)
- Form card: `backdrop-blur-sm bg-white/95 rounded-2xl shadow-2xl`
- Logo: "Crecer Distribuciones" with Inter bold
- Subtitle: "Sistema de gestion"
- Button: emerald gradient

### 9. Loading & Empty States

- Skeletons: `bg-slate-200 dark:bg-slate-700`
- Spinner: emerald color
- Empty states: larger icon, better text hierarchy

### 10. Micro-interactions

- Dropdowns: scale + fade animations
- Cards hover: translate + shadow
- Badges: transition-colors
- Page transitions: fade-in on load

## Files to Modify

### Core / Config
- `index.html` - Add Inter font link
- `tailwind.config.js` - Add Inter to font family, adjust theme if needed
- `src/index.css` - Update global styles

### Branding & Layout
- `src/components/auth/LoginScreen.tsx` - Full visual refresh
- `src/components/layout/TopNavigation.tsx` - Header gradient, new logo, refined dropdowns

### Dashboard
- `src/components/vistas/VistaDashboard.tsx` - MetricaCard, EstadoCard, BarraProgreso visual upgrade

### Cards & Lists
- `src/components/pedidos/PedidoCard.tsx` - Left border by status, refined badges
- `src/components/vistas/VistaClientes.tsx` - Card refinement
- `src/components/vistas/VistaProductos.tsx` - Card refinement

### Components
- `src/components/modals/ModalBase.tsx` - Refined dialog styling
- `src/components/ui/FormField.tsx` - Input styling
- `src/components/layout/LoadingSpinner.tsx` - Emerald color
- `src/components/ui/Skeleton.tsx` - Slate colors
- `src/components/ui/EmptyState.tsx` - Visual refinement

### Global color replacement
- All files using `blue-600` as primary -> `emerald-600` (systematic find/replace with manual review)
- All files using `gray-*` -> `slate-*` where appropriate

## Out of Scope

- No layout changes (keeping top-nav structure)
- No new pages or routes
- No data model changes
- No new dependencies except Inter font (CSS only)
- No chart library additions (dashboard keeps CSS bars for now)

## Success Criteria

- App feels like a branded product, not a template
- "Crecer Distribuciones" identity is visible throughout
- Cards, buttons, inputs feel polished and premium
- Dark mode still works correctly
- No accessibility regressions
- No functionality changes
