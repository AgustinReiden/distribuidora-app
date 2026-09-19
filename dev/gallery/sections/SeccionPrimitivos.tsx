/**
 * Los cinco primitivos nuevos (issue #707): Button, IconBadge, Badge, Card y
 * PageHeader. Ya están mergeados en `main`; acá se ven con datos de fixture,
 * en los cinco roles y en claro / oscuro / alto contraste.
 *
 * Nada se copia: todo se importa de `src/`, igual que en el resto de la galería.
 */
import type { LucideIcon } from 'lucide-react'
import { AlertTriangle, CheckCircle2, Package, Plus, Truck, XCircle } from 'lucide-react'
import { Button } from '../../../src/components/ui/Button'
import { buttonClasses, type ButtonSize, type ButtonVariant } from '../../../src/components/ui/button-variants'
import { IconBadge, type IconBadgeSize, type IconBadgeTone } from '../../../src/components/ui/IconBadge'
import { Badge } from '../../../src/components/ui/Badge'
import { toneDeEstadoPago, toneDeEstadoPedido, toneDeRol, type Tone } from '../../../src/lib/estadoTones'
import Card from '../../../src/components/ui/Card'
import PageHeader from '../../../src/components/layout/PageHeader'
import { Marco, Seccion, Subtitulo } from '../ui/Marco'
import { ETIQUETA_ROL, ROLES_GALERIA } from '../fixtures/auth'

const TONOS: Tone[] = ['neutral', 'brand', 'success', 'warning', 'danger']

const VARIANTES_BOTON: { variant: ButtonVariant; texto: string }[] = [
  { variant: 'primary', texto: 'Guardar' },
  { variant: 'secondary', texto: 'Cancelar' },
  { variant: 'ghost', texto: 'Ver más' },
  { variant: 'danger', texto: 'Eliminar' },
  { variant: 'success', texto: 'Confirmar' },
  { variant: 'hero', texto: 'Nuevo pedido' },
]

const TAMANOS_BOTON: ButtonSize[] = ['sm', 'md', 'lg', 'touch']

function BloqueVariantesBoton() {
  return (
    <div className="space-y-4">
      {VARIANTES_BOTON.map(({ variant, texto }) => (
        <Marco key={variant} etiqueta={`Button · variant="${variant}" · size sm/md/lg/touch`}>
          <div className="flex flex-wrap items-end gap-3">
            {TAMANOS_BOTON.map((size) => (
              <div key={size} className="flex flex-col items-center gap-1">
                <Button variant={variant} size={size}>
                  {texto}
                </Button>
                <span className="font-mono text-[10px] text-stone-500 dark:text-stone-400">
                  size="{size}"
                </span>
              </div>
            ))}
          </div>
        </Marco>
      ))}
    </div>
  )
}

function BloqueIconButtons() {
  return (
    <Marco etiqueta='Button · size="icon" / "iconSm" · sólo ícono, con aria-label'>
      <div className="flex items-center gap-3">
        <Button size="icon" aria-label="Agregar pedido">
          <Plus className="w-4 h-4" />
        </Button>
        <Button size="iconSm" aria-label="Agregar pedido">
          <Plus className="w-4 h-4" />
        </Button>
      </div>
    </Marco>
  )
}

function BloqueEstadosBoton() {
  return (
    <Marco etiqueta="Button · loading / disabled / loading+disabled (loading NO implica disabled)">
      <div className="flex flex-wrap gap-3">
        <Button loading>Guardando…</Button>
        <Button disabled>No disponible</Button>
        <Button loading disabled>
          Guardando…
        </Button>
      </div>
    </Marco>
  )
}

function BloqueButtonClasses() {
  return (
    <Marco etiqueta='buttonClasses() · <a> con pinta de botón (variant="secondary")'>
      <a href="#primitivos" className={buttonClasses({ variant: 'secondary' })}>
        Volver a Primitivos
      </a>
    </Marco>
  )
}

const TONOS_ICONBADGE: { tone: IconBadgeTone; icon: LucideIcon }[] = [
  { tone: 'brand', icon: Package },
  { tone: 'success', icon: CheckCircle2 },
  { tone: 'warning', icon: AlertTriangle },
  { tone: 'danger', icon: XCircle },
  { tone: 'neutral', icon: Truck },
]

const TAMANOS_ICONBADGE: IconBadgeSize[] = ['sm', 'md', 'lg']

function BloqueIconBadge() {
  return (
    <Marco etiqueta="IconBadge · 5 tonos × size sm/md/lg">
      <div className="space-y-3">
        {TONOS_ICONBADGE.map(({ tone, icon }) => (
          <div key={tone} className="flex items-center gap-4">
            <span className="w-16 font-mono text-xs text-stone-500 dark:text-stone-400">{tone}</span>
            {TAMANOS_ICONBADGE.map((size) => (
              <IconBadge key={size} icon={icon} tone={tone} size={size} />
            ))}
          </div>
        ))}
      </div>
    </Marco>
  )
}

function BloqueIconBadgeLabel() {
  return (
    <Marco etiqueta='IconBadge · con label (deja de ser decorativo: role="img" + aria-label)'>
      <IconBadge icon={Truck} tone="warning" size="lg" label="3 pedidos en camino" />
    </Marco>
  )
}

function BloqueBadgeTonos() {
  return (
    <div className="grid gap-4 sm:grid-cols-2">
      <Marco etiqueta='Badge · 5 tonos · fill="soft"'>
        <div className="flex flex-wrap gap-2">
          {TONOS.map((tone) => (
            <Badge key={tone} tone={tone}>
              {tone}
            </Badge>
          ))}
        </div>
      </Marco>
      <Marco etiqueta='Badge · 5 tonos · fill="strong"'>
        <div className="flex flex-wrap gap-2">
          {TONOS.map((tone) => (
            <Badge key={tone} tone={tone} fill="strong">
              {tone}
            </Badge>
          ))}
        </div>
      </Marco>
    </div>
  )
}

function BloqueBadgeIconYMono() {
  return (
    <div className="grid gap-4 sm:grid-cols-2">
      <Marco etiqueta="Badge · icon">
        <Badge tone="success" icon={CheckCircle2}>
          Entregado
        </Badge>
      </Marco>
      <Marco etiqueta='Badge · mono ("FC" / "ZZ")'>
        <div className="flex gap-2">
          <Badge mono tone="neutral">
            FC
          </Badge>
          <Badge mono tone="neutral">
            ZZ
          </Badge>
        </div>
      </Marco>
    </div>
  )
}

const ESTADOS_PEDIDO: { estado: string; etiqueta: string }[] = [
  { estado: 'pendiente', etiqueta: 'Pendiente' },
  { estado: 'en_preparacion', etiqueta: 'En preparación' },
  { estado: 'asignado', etiqueta: 'Asignado' },
  { estado: 'entregado', etiqueta: 'Entregado' },
  { estado: 'cancelado', etiqueta: 'Cancelado' },
]

const ESTADOS_PAGO: { estado: 'pagado' | 'parcial' | 'pendiente' | null; etiqueta: string }[] = [
  { estado: 'pagado', etiqueta: 'Pagado' },
  { estado: 'parcial', etiqueta: 'Parcial' },
  { estado: 'pendiente', etiqueta: 'Pendiente' },
  { estado: null, etiqueta: 'Sin dato' },
]

function BloqueBadgeEstadoTones() {
  return (
    <div className="space-y-3">
      <Marco etiqueta="Badge · tone={toneDeEstadoPedido(estado)}">
        <div className="flex flex-wrap gap-2">
          {ESTADOS_PEDIDO.map(({ estado, etiqueta }) => (
            <Badge key={estado} tone={toneDeEstadoPedido(estado)}>
              {etiqueta}
            </Badge>
          ))}
        </div>
      </Marco>
      <Marco etiqueta="Badge · tone={toneDeEstadoPago(estado)} · sin dato cae en danger, no en neutral">
        <div className="flex flex-wrap gap-2">
          {ESTADOS_PAGO.map(({ estado, etiqueta }) => (
            <Badge key={etiqueta} tone={toneDeEstadoPago(estado)}>
              {etiqueta}
            </Badge>
          ))}
        </div>
      </Marco>
      <Marco etiqueta="Badge · tone={toneDeRol(rol)}">
        <div className="flex flex-wrap gap-2">
          {ROLES_GALERIA.map((rol) => (
            <Badge key={rol} tone={toneDeRol(rol)}>
              {ETIQUETA_ROL[rol]}
            </Badge>
          ))}
        </div>
      </Marco>
    </div>
  )
}

function BloqueCardVariantes() {
  return (
    <div className="space-y-4">
      <Marco etiqueta='Card · variant="section"'>
        <Card variant="section">
          <p className="text-sm font-semibold text-stone-800 dark:text-stone-100">Resumen del día</p>
          <p className="mt-1 text-sm text-stone-600 dark:text-stone-400">
            El panel grande: un bloque completo de la vista.
          </p>
        </Card>
      </Marco>

      <Marco etiqueta='Card · variant="stat" · accent por tono'>
        <div className="grid grid-cols-2 sm:grid-cols-5 gap-3">
          {TONOS.map((tone) => (
            <Card key={tone} variant="stat" accent={tone}>
              <p className="text-[11px] font-mono text-stone-500 dark:text-stone-400">{tone}</p>
              <p className="text-lg font-bold tabular-nums text-stone-900 dark:text-white">128</p>
            </Card>
          ))}
        </div>
      </Marco>

      <Marco etiqueta='Card · variant="row" · con y sin interactive'>
        <div className="space-y-2">
          <Card variant="row">
            <p className="text-sm text-stone-700 dark:text-stone-300">Fila normal, sin hover</p>
          </Card>
          <Card variant="row" interactive>
            <p className="text-sm text-stone-700 dark:text-stone-300">
              Fila interactive: pasale el mouse por arriba
            </p>
          </Card>
        </div>
      </Marco>
    </div>
  )
}

function BloqueCardPadding() {
  return (
    <Marco etiqueta='Card · padding="none" / "sm" / "md" (pisa el padding por defecto de la variante)'>
      <div className="grid grid-cols-3 gap-3">
        <Card padding="none" className="text-xs text-stone-500 dark:text-stone-400">
          padding="none"
        </Card>
        <Card padding="sm" className="text-xs text-stone-500 dark:text-stone-400">
          padding="sm"
        </Card>
        <Card padding="md" className="text-xs text-stone-500 dark:text-stone-400">
          padding="md"
        </Card>
      </div>
    </Marco>
  )
}

function BloquePageHeader() {
  return (
    <div className="space-y-4">
      <Marco etiqueta="PageHeader · ejemplo completo · crumbs + acciones">
        <PageHeader
          titulo="Pedidos"
          periodo="del día"
          crumbs={['OPERACIONES', 'MARTES 21 DE ABRIL', '649 RESULTADOS']}
          acciones={
            <div className="flex justify-end gap-2">
              <Button variant="secondary">Exportar</Button>
              <Button variant="hero">Nuevo pedido</Button>
            </div>
          }
        />
      </Marco>

      <Marco etiqueta='PageHeader · loading · el último crumb pasa a decir "ACTUALIZANDO…"'>
        <PageHeader
          titulo="Pedidos"
          periodo="del día"
          crumbs={['OPERACIONES', 'MARTES 21 DE ABRIL', '649 RESULTADOS']}
          loading
        />
      </Marco>

      <Marco etiqueta="PageHeader · sin período · no hay <em>">
        <PageHeader titulo="Clientes" crumbs={['OPERACIONES', '649 RESULTADOS']} />
      </Marco>
    </div>
  )
}

export default function SeccionPrimitivos() {
  return (
    <Seccion
      id="primitivos"
      titulo="Primitivos"
      descripcion="Button, IconBadge, Badge, Card y PageHeader: los cinco primitivos nuevos, ya mergeados en main."
    >
      <div>
        <Subtitulo>Button</Subtitulo>
        <div className="mt-3 space-y-4">
          <BloqueVariantesBoton />
          <BloqueIconButtons />
          <BloqueEstadosBoton />
          <BloqueButtonClasses />
        </div>
      </div>

      <div>
        <Subtitulo>IconBadge</Subtitulo>
        <div className="mt-3 space-y-4">
          <BloqueIconBadge />
          <BloqueIconBadgeLabel />
        </div>
      </div>

      <div>
        <Subtitulo>Badge</Subtitulo>
        <div className="mt-3 space-y-4">
          <BloqueBadgeTonos />
          <BloqueBadgeIconYMono />
          <BloqueBadgeEstadoTones />
        </div>
      </div>

      <div>
        <Subtitulo>Card</Subtitulo>
        <div className="mt-3 space-y-4">
          <BloqueCardVariantes />
          <BloqueCardPadding />
        </div>
      </div>

      <div>
        <Subtitulo>PageHeader</Subtitulo>
        <div className="mt-3 space-y-4">
          <BloquePageHeader />
        </div>
      </div>
    </Seccion>
  )
}
