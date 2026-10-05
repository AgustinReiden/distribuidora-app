/**
 * Los cinco primitivos nuevos (issue #707): Button, IconBadge, Badge, Card y
 * PageHeader. Ya están mergeados en `main`; acá se ven con datos de fixture,
 * en los cinco roles y en claro / oscuro / alto contraste.
 *
 * Nada se copia: todo se importa de `src/`, igual que en el resto de la galería.
 */
import type { LucideIcon } from 'lucide-react'
import { AlertTriangle, CheckCircle2, Package, Plus, Trash2, Truck, XCircle } from 'lucide-react'
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

/**
 * `danger` y `success` con el rótulo en un <span> y un ícono con `text-*`, habilitados y
 * deshabilitados (#888). Es el caso que el bloque de variantes no cubre (ahí el rótulo es
 * texto directo y no hay ícono), y es el que se rompía en alto contraste OSCURO: el
 * <span> y el ícono quedaban blancos sobre el neón del botón. Pasale el mouse por encima
 * a cada uno: el hover también cuenta.
 */
function BloqueBotonesDeEstadoConSpanEIcono() {
  return (
    <Marco etiqueta="Button · danger / success · rótulo en <span> e ícono con text-* · habilitado y disabled">
      <div className="flex flex-wrap gap-3">
        {(['danger', 'success'] as const).flatMap((variant) =>
          [false, true].map((disabled) => (
            <Button
              key={`${variant}-${disabled}`}
              variant={variant}
              disabled={disabled}
              data-caso={`${variant}-${disabled ? 'deshabilitado' : 'habilitado'}`}
            >
              {variant === 'danger' ? (
                <Trash2 className="w-4 h-4 text-white" aria-hidden="true" />
              ) : (
                <CheckCircle2 className="w-4 h-4 text-white" aria-hidden="true" />
              )}
              <span>{variant === 'danger' ? 'Eliminar' : 'Confirmar'}</span>
            </Button>
          )),
        )}
      </div>
    </Marco>
  )
}

/**
 * Lo que #888 dejó afuera (#903), en los dos modos de alto contraste. Cada elemento medible
 * lleva `data-caso`, y sus hijos `data-hijo`, para que un script de Chromium los encuentre
 * sin depender del orden del DOM:
 *  - Primario (`btn-primary` / `bg-brand-600` / `bg-blue-600`) con un ícono `text-white`, un
 *    <div> o un <p> adentro: la hoja invierte el fondo del primario pero les fijaba el color
 *    primario a los hijos, y salía 1:1 (negro sobre negro en claro, blanco sobre blanco en
 *    oscuro). Los dos tiles son los de `TopNavigation` / `VistaRecorridos`: un contenedor que
 *    no es botón.
 *  - Neón que no es botón (`bg-red-600`, `bg-green-600`): el banner de `BannerManiobra` y el
 *    de `RutaActivaTransportista`, y las variantes `strong` de Badge con un <span> adentro.
 *  - `danger` / `success` con un <div> adentro (`ModalRegistrarPago`): en claro era negro
 *    sobre #8b0000 / #006400.
 * Pasale el mouse por encima a los botones: el hover también cuenta.
 */
function BloqueContenedoresConHijosPropios() {
  return (
    <Marco etiqueta="Primario y neón · ícono text-*, <p>/<div>/<span> adentro · botón y contenedor que no es botón (#903)">
      <div className="flex flex-wrap items-start gap-3">
        {[false, true].map((disabled) => (
          <Button
            key={`primario-icono-${disabled}`}
            variant="primary"
            disabled={disabled}
            data-caso={`primario-icono-${disabled ? 'deshabilitado' : 'habilitado'}`}
          >
            <Truck className="w-4 h-4 text-white" aria-hidden="true" data-hijo="icono" />
            <span data-hijo="span">Guardar</span>
          </Button>
        ))}
        <Button variant="primary" data-caso="primario-div-p">
          <div data-hijo="div">Rótulo en div</div>
          <p data-hijo="p">Rótulo en p</p>
        </Button>
        <Button variant="success" data-caso="success-div">
          <CheckCircle2 className="w-4 h-4 text-white" aria-hidden="true" data-hijo="icono" />
          <div data-hijo="div">Registrar</div>
        </Button>
        <Button variant="danger" data-caso="danger-div">
          <div data-hijo="div">Eliminar</div>
        </Button>
        <div className="p-2 bg-brand-600 rounded-lg" data-caso="primario-tile-brand">
          <Truck className="w-5 h-5 text-white" aria-hidden="true" data-hijo="icono" />
        </div>
        <div className="p-2 bg-blue-600 rounded-lg" data-caso="primario-tile-blue">
          <Truck className="w-5 h-5 text-white" aria-hidden="true" data-hijo="icono" />
        </div>
        <div
          className="rounded-2xl bg-red-600 px-4 py-3 text-white shadow-xl"
          data-caso="banner-neon-rojo"
        >
          <p className="text-sm font-semibold" data-hijo="p">No se pudo trazar la ruta</p>
          <p className="text-xs opacity-90" data-hijo="p">Usá “Abrir en Maps”.</p>
        </div>
        <div
          role="alert"
          className="flex items-start gap-3 rounded-2xl bg-red-600 px-4 py-3 text-white shadow-xl"
          data-caso="banner-neon-rojo-alert"
        >
          <AlertTriangle className="mt-0.5 h-5 w-5 flex-shrink-0" aria-hidden="true" data-hijo="icono-alert" />
          <p className="min-w-0 flex-1 text-sm font-medium" data-hijo="p">Parada bloqueada</p>
        </div>
        <Button variant="danger" data-caso="danger-icono-alert">
          <AlertTriangle className="w-4 h-4 text-white" aria-hidden="true" data-hijo="icono-alert" />
          <span data-hijo="span">Reportar</span>
        </Button>
        <Button variant="primary" data-caso="primario-icono-alert">
          <AlertTriangle className="w-4 h-4 text-white" aria-hidden="true" data-hijo="icono-alert" />
          <span data-hijo="span">Reportar</span>
        </Button>
        <div
          className="rounded-2xl bg-green-600 px-4 py-3 text-white shadow-xl"
          data-caso="banner-neon-verde"
        >
          <span data-hijo="span">Entregado</span>
          <p className="text-xs" data-hijo="p">Todo en orden.</p>
        </div>
        {(['danger', 'success', 'brand'] as const).map((tone) => (
          <Badge key={tone} tone={tone} fill="strong" data-caso={`badge-strong-${tone}`}>
            <span data-hijo="span">{tone}</span>
          </Badge>
        ))}
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
          <BloqueBotonesDeEstadoConSpanEIcono />
          <BloqueContenedoresConHijosPropios />
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
