/**
 * ModalEmpleado — alta y edición del empleado (entrega 3 de gastos).
 *
 * Los datos de la ficha (nombre, puesto, sucursal, CUIL, ingreso, teléfono) y tres vínculos
 * opcionales: el usuario de la app, la ficha de cliente y el vehículo habitual. El alta pide
 * además el primer arreglo (sueldo, frecuencia, si comisiona y desde cuándo se liquida) y,
 * si hace falta, el saldo con que arranca. En la edición el arreglo se ve pero no se toca:
 * se cambia desde la ficha, para que conserve desde cuándo vale. Los permisos y las
 * unicidades las valida el server (`guardar_empleado`); acá se repiten sus mensajes.
 */
import React, { useId, useMemo, useState } from 'react'
import type { FormEvent, ReactNode } from 'react'
import { z } from 'zod'
import { Link2 } from 'lucide-react'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import { Combobox } from '../ui/Combobox'
import { cn } from '../../lib/utils'
import { getErrorMessage } from '../../utils/errorHandling'
import {
  PUESTOS,
  errorDeArreglo,
  inicioDelPeriodo,
  normalizarCuil,
  MENSAJE_MONTO_ILEGIBLE,
  MENSAJE_SIN_SUELDO,
  parseMonto,
  textoArregloLargo,
} from '../../utils/personal'
import type {
  Empleado,
  FrecuenciaSueldo,
  GuardarEmpleadoPayload,
  PuestoEmpleado,
} from '../../types/personal'

const MENSAJE_SIN_ARREGLO = 'Falta el primer arreglo: el sueldo, cada cuánto y desde cuándo se liquida'

// Schema CO-LOCADO a propósito (no en lib/schemas.ts): ver ModalCambioProducto.tsx
// para el incidente de chunk desincronizado que motivó la regla.
// Los ids de cliente y vehículo llegan como number pero el Combobox trabaja con strings:
// `z.string()` tiraría "Invalid input" en runtime. Los mensajes son los del server.
// eslint-disable-next-line react-refresh/only-export-components
export const modalEmpleadoSchema = z
  .object({
    id: z.coerce.number().int().positive().optional(),
    nombre: z.string().trim().min(1, { message: 'Falta el nombre y apellido' }),
    puesto: z.enum(
      PUESTOS.map(p => p.valor) as [PuestoEmpleado, ...PuestoEmpleado[]],
      { error: 'Elegí el puesto' },
    ),
    sucursal_id: z.coerce.number().int().positive({ message: 'Elegí la sucursal' }),
    de_las_dos: z.boolean(),
    cuil: z.string().regex(/^\d{11}$/, { message: 'El CUIL tiene que tener 11 números' }).nullable(),
    fecha_ingreso: z
      .string()
      .regex(/^\d{4}-\d{2}-\d{2}$/, { message: 'Hay un dato del empleado con un formato inválido' })
      .nullable(),
    telefono: z.string().nullable(),
    usuario_id: z.string().nullable(),
    cliente_id: z.coerce.number().int().positive().nullable(),
    vehiculo_id: z.coerce.number().int().positive().nullable(),
    arreglo: z
      .object({
        vigente_desde: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, { message: MENSAJE_SIN_ARREGLO }),
        sueldo: z.number({ error: MENSAJE_SIN_SUELDO }),
        frecuencia: z.enum(['semanal', 'mensual'], { error: 'El sueldo es semanal o mensual' }),
        comisiona: z.boolean(),
      })
      .optional(),
    saldo_inicial: z.number().nullable().optional(),
  })
  .superRefine((p, ctx) => {
    // El arreglo es obligatorio sólo en el alta (sin id).
    if (p.id === undefined && !p.arreglo) {
      ctx.addIssue({ code: 'custom', message: MENSAJE_SIN_ARREGLO, path: ['arreglo'] })
      return
    }
    if (p.arreglo) {
      const error = errorDeArreglo(p.arreglo, null)
      if (error) ctx.addIssue({ code: 'custom', message: error, path: ['arreglo'] })
    }
  })

export interface ModalEmpleadoProps {
  /** `null`: alta. */
  empleado: Empleado | null
  sucursalActual: { id: number; nombre: string }
  sucursalesUsuario: Array<{ id: number; nombre: string }>
  /** Sólo quien tiene todas las sucursales activas elige la sucursal o "Las dos". */
  tieneTodasLasSucursales: boolean
  usuarios: Array<{ id: string; nombre: string }>
  clientes: Array<{ id: number; nombre_fantasia: string; activo: boolean }>
  vehiculos: Array<{ id: number; patente: string; descripcion: string }>
  /** Vinculados a otro empleado: no se ofrecen (el actual sí). */
  ocupados: { usuarios: Set<string>; clientes: Set<number> }
  /** El usuario logueado: en el alta no se ofrece (la cuenta propia la vincula otro admin). */
  usuarioPropioId?: string | null
  hoy: string
  onSave: (p: GuardarEmpleadoPayload) => Promise<void>
  onClose: () => void
}

const CLASE_INPUT =
  'w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-brand-500 dark:bg-gray-700 dark:text-white'
const CLASE_LINK = 'text-sm text-brand-600 dark:text-brand-400 font-medium hover:underline'
const CLASE_ETIQUETA = 'block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1'
const CLASE_AYUDA = 'mt-1 text-xs text-gray-500'
const SIN_VINCULO = 'Sin vínculo'
const AYUDA_OTRA_SUCURSAL = 'Los vínculos se eligen desde esa sucursal: cambiá de sucursal o cargalos después.'

const requerido = <span className="text-red-500">*</span>

function Pastilla({
  activa, onClick, children,
}: { activa: boolean; onClick: () => void; children: ReactNode }) {
  return (
    <button
      type="button"
      aria-pressed={activa}
      onClick={onClick}
      className={cn(
        'p-2 border rounded-lg text-sm transition-colors',
        activa
          ? 'border-brand-500 bg-brand-50 dark:bg-brand-900/20 text-brand-700 dark:text-brand-300 font-medium'
          : 'border-gray-200 dark:border-gray-600 hover:bg-gray-50 dark:hover:bg-gray-700 text-gray-700 dark:text-gray-300',
      )}
    >
      {children}
    </button>
  )
}

interface OpcionVinculo {
  key: string
  label: string
  textos: string[]
}

/** Un combo de vínculo: con valor, la primera opción lo quita ("Sin vínculo"). */
function CampoVinculo({
  id, etiqueta, ayuda, placeholder, opciones, valor, onChange, nombreActual, disabled, nota,
}: {
  id: string
  etiqueta: string
  ayuda?: string
  placeholder: string
  opciones: OpcionVinculo[]
  valor: string
  onChange: (key: string) => void
  /** Cómo se llama lo que ya estaba vinculado, por si hoy no está en la lista. */
  nombreActual: string | null
  disabled?: boolean
  nota?: string
}) {
  const conSinVinculo = useMemo<OpcionVinculo[]>(
    () => (valor ? [{ key: '', label: SIN_VINCULO, textos: [SIN_VINCULO] }, ...opciones] : opciones),
    [opciones, valor],
  )
  const estaEnLista = valor !== '' && opciones.some(o => o.key === valor)
  return (
    <div>
      <label htmlFor={id} className="block text-xs font-medium text-gray-600 dark:text-gray-400 mb-1">
        {etiqueta}
      </label>
      <Combobox
        id={id}
        opciones={conSinVinculo}
        getKey={o => o.key}
        getLabel={o => o.label}
        getTextosBusqueda={o => o.textos}
        valor={valor}
        textoSinOpcion={valor !== '' && !estaEnLista && nombreActual ? nombreActual : SIN_VINCULO}
        onSeleccionar={o => onChange(o.key)}
        placeholder={placeholder}
        textoSinResultados="Sin resultados"
        disabled={disabled}
        inputClassName="py-1.5 text-sm"
      />
      {nota ? <p className={CLASE_AYUDA}>{nota}</p> : null}
      {ayuda ? <p className={CLASE_AYUDA}>{ayuda}</p> : null}
    </div>
  )
}

export default function ModalEmpleado({
  empleado, sucursalActual, sucursalesUsuario, tieneTodasLasSucursales,
  usuarios, clientes, vehiculos, ocupados, usuarioPropioId, hoy, onSave, onClose,
}: ModalEmpleadoProps): React.ReactElement {
  const edicion = empleado !== null
  const id = useId()

  // ---- Datos ---------------------------------------------------------------
  const [nombre, setNombre] = useState(empleado?.nombre ?? '')
  const [puesto, setPuesto] = useState<PuestoEmpleado | ''>(empleado?.puesto ?? '')
  const [sucursalSel, setSucursalSel] = useState<number | 'dos'>(
    empleado ? (empleado.de_las_dos ? 'dos' : empleado.sucursal_id) : sucursalActual.id,
  )
  const [cuil, setCuil] = useState(empleado?.cuil ?? '')
  const [ingreso, setIngreso] = useState(empleado?.fecha_ingreso ?? '')
  const [telefono, setTelefono] = useState(empleado?.telefono ?? '')

  // ---- Vínculos ------------------------------------------------------------
  const [usuarioId, setUsuarioId] = useState(empleado?.usuario?.id ?? '')
  const [clienteId, setClienteId] = useState(empleado?.cliente ? String(empleado.cliente.id) : '')
  const [vehiculoId, setVehiculoId] = useState(empleado?.vehiculo ? String(empleado.vehiculo.id) : '')

  const opcionesUsuario = useMemo<OpcionVinculo[]>(
    () => usuarios
      .filter(u => !ocupados.usuarios.has(u.id) || u.id === empleado?.usuario?.id)
      // En el alta no se ofrece el usuario propio; en la edición sí (otro admin puede vincularlo).
      .filter(u => edicion || u.id !== usuarioPropioId)
      .map(u => ({ key: u.id, label: u.nombre, textos: [u.nombre] })),
    [usuarios, ocupados, empleado, edicion, usuarioPropioId],
  )
  const opcionesCliente = useMemo<OpcionVinculo[]>(
    () => clientes
      .filter(c => !ocupados.clientes.has(c.id) || c.id === empleado?.cliente?.id)
      .map(c => ({
        key: String(c.id),
        label: c.activo ? c.nombre_fantasia : `${c.nombre_fantasia} · inactivo`,
        textos: [c.nombre_fantasia],
      })),
    [clientes, ocupados, empleado],
  )
  const opcionesVehiculo = useMemo<OpcionVinculo[]>(
    () => vehiculos.map(v => ({
      key: String(v.id),
      label: `${v.patente} · ${v.descripcion}`,
      textos: [v.patente, v.descripcion],
    })),
    [vehiculos],
  )

  // ---- Primer arreglo (sólo el alta) ----------------------------------------
  const [sueldoTxt, setSueldoTxt] = useState('')
  const [frecuencia, setFrecuencia] = useState<FrecuenciaSueldo>('semanal')
  const [comisiona, setComisiona] = useState(false)
  // La fecha sigue a la frecuencia hasta que se la toca a mano.
  const [desdeManual, setDesdeManual] = useState<string | null>(null)
  const desde = desdeManual ?? inicioDelPeriodo(hoy, frecuencia)
  const [saldoAbierto, setSaldoAbierto] = useState(false)
  const [saldoTxt, setSaldoTxt] = useState('')
  const [saldoSigno, setSaldoSigno] = useState<'favor' | 'debe'>('favor')

  // ---- Estado ----------------------------------------------------------------
  const [guardando, setGuardando] = useState(false)
  const [error, setError] = useState('')

  // Las listas de vínculos son de la sucursal en la que se está: para un empleado que es de la
  // otra (y no de las dos) sólo pueden fallar, así que no se eligen y se conservan los que tenía.
  const sucursalEfectiva: number | 'dos' = tieneTodasLasSucursales
    ? sucursalSel
    : (empleado ? (empleado.de_las_dos ? 'dos' : empleado.sucursal_id) : sucursalActual.id)
  const vinculosBloqueados = sucursalEfectiva !== 'dos' && sucursalEfectiva !== sucursalActual.id
  const usuarioVisible = vinculosBloqueados ? (empleado?.usuario?.id ?? '') : usuarioId
  const clienteVisible = vinculosBloqueados ? (empleado?.cliente ? String(empleado.cliente.id) : '') : clienteId
  const vehiculoVisible = vinculosBloqueados ? (empleado?.vehiculo ? String(empleado.vehiculo.id) : '') : vehiculoId

  const nombreSucursalFija = (() => {
    const sid = empleado ? empleado.sucursal_id : sucursalActual.id
    const nombreDe = sucursalesUsuario.find(s => s.id === sid)?.nombre
      ?? (sid === sucursalActual.id ? sucursalActual.nombre : `Sucursal ${sid}`)
    return nombreDe
  })()

  const handleEscapeKeyDown = (event: KeyboardEvent) => {
    // Radix escucha Escape en captura, antes que el buscador: con la lista
    // abierta, Escape tiene que cerrar sólo la lista (ver ModalCompra).
    const enfocado = document.activeElement
    const comboboxAbierto = enfocado?.getAttribute('role') === 'combobox' &&
      enfocado.getAttribute('aria-expanded') === 'true'
    if (comboboxAbierto) event.preventDefault()
  }

  const handleSubmit = async (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault()
    setError('')

    // Con todas las sucursales se elige; si no, la ficha queda donde está (o en la actual, en el alta).
    const sucursalId = tieneTodasLasSucursales
      ? (sucursalSel === 'dos'
        ? (empleado?.de_las_dos ? empleado.sucursal_id : sucursalActual.id)
        : sucursalSel)
      : (empleado ? empleado.sucursal_id : sucursalActual.id)
    const deLasDos = tieneTodasLasSucursales ? sucursalSel === 'dos' : (empleado?.de_las_dos ?? false)

    // Un importe que no se entiende nunca se vuelve 0: se avisa. Un sueldo en blanco viaja como
    // null y lo frena el schema ("Falta el sueldo"), así que 0 sólo existe si se lo escribió.
    if (!edicion && sueldoTxt.trim() && parseMonto(sueldoTxt) === null) {
      setError(MENSAJE_MONTO_ILEGIBLE)
      return
    }
    let saldoInicial: number | null = null
    if (!edicion && saldoAbierto && saldoTxt.trim()) {
      const monto = parseMonto(saldoTxt)
      if (monto === null) {
        setError(MENSAJE_MONTO_ILEGIBLE)
        return
      }
      if (!(monto > 0)) {
        setError('El saldo al empezar tiene que ser mayor a cero')
        return
      }
      saldoInicial = saldoSigno === 'debe' ? -monto : monto
    }

    const payload = {
      ...(empleado ? { id: empleado.id } : {}),
      nombre: nombre.trim(),
      puesto,
      sucursal_id: sucursalId,
      de_las_dos: deLasDos,
      cuil: normalizarCuil(cuil),
      fecha_ingreso: ingreso || null,
      telefono: telefono.trim() ? telefono.trim() : null,
      usuario_id: usuarioVisible || null,
      cliente_id: clienteVisible ? clienteVisible : null,
      vehiculo_id: vehiculoVisible ? vehiculoVisible : null,
      ...(edicion
        ? {}
        : {
          arreglo: { vigente_desde: desde, sueldo: sueldoTxt.trim() ? parseMonto(sueldoTxt) : null, frecuencia, comisiona },
          saldo_inicial: saldoInicial,
        }),
    }

    const resultado = modalEmpleadoSchema.safeParse(payload)
    if (!resultado.success) {
      setError(resultado.error.issues[0]?.message ?? 'Revisá los datos del empleado')
      return
    }

    setGuardando(true)
    try {
      // El schema coacciona los ids a number: se manda lo validado, no el crudo.
      await onSave(resultado.data as GuardarEmpleadoPayload)
      onClose()
    } catch (err) {
      // getErrorMessage, no `err instanceof Error`: el error de supabase-js es un
      // objeto plano. Ver src/utils/errorDeSupabase.ts.
      setError(getErrorMessage(err))
    } finally {
      setGuardando(false)
    }
  }

  return (
    <ModalBase
      title={edicion ? 'Editar empleado' : 'Nuevo empleado'}
      onClose={onClose}
      maxWidth="max-w-xl"
      onEscapeKeyDown={handleEscapeKeyDown}
    >
      <form onSubmit={handleSubmit} className="p-4 space-y-4">
        {/* Nombre */}
        <div>
          <label htmlFor={`${id}-nombre`} className={CLASE_ETIQUETA}>
            Nombre y apellido {requerido}
          </label>
          <input
            id={`${id}-nombre`}
            type="text"
            autoComplete="off"
            value={nombre}
            onChange={e => setNombre(e.target.value)}
            className={CLASE_INPUT}
          />
        </div>

        {/* Puesto */}
        <div>
          <span id={`${id}-puesto`} className={CLASE_ETIQUETA}>Puesto {requerido}</span>
          <div role="group" aria-labelledby={`${id}-puesto`} className="grid grid-cols-3 sm:grid-cols-4 gap-1.5">
            {PUESTOS.map(p => (
              <Pastilla key={p.valor} activa={puesto === p.valor} onClick={() => setPuesto(p.valor)}>
                {p.etiqueta}
              </Pastilla>
            ))}
          </div>
        </div>

        {/* Sucursal */}
        {tieneTodasLasSucursales ? (
          <div>
            <span id={`${id}-sucursal`} className={CLASE_ETIQUETA}>Sucursal</span>
            <div role="group" aria-labelledby={`${id}-sucursal`} className="grid grid-cols-3 gap-2">
              {sucursalesUsuario.map(s => (
                <Pastilla key={s.id} activa={sucursalSel === s.id} onClick={() => setSucursalSel(s.id)}>
                  {s.nombre}
                </Pastilla>
              ))}
              <Pastilla activa={sucursalSel === 'dos'} onClick={() => setSucursalSel('dos')}>Las dos</Pastilla>
            </div>
          </div>
        ) : (
          <p className="text-sm text-gray-700 dark:text-gray-300">
            <span className="inline-flex items-center rounded-full px-2 py-0.5 text-xs font-semibold bg-brand-100 text-brand-700 dark:bg-brand-900/30 dark:text-brand-300">
              {`Sucursal ${nombreSucursalFija}`}
            </span>
            {empleado?.de_las_dos ? <span className="ml-2 text-xs text-gray-500">· de las dos sucursales</span> : null}
          </p>
        )}

        {/* CUIL, ingreso y teléfono */}
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
          <div>
            <label htmlFor={`${id}-cuil`} className={CLASE_ETIQUETA}>CUIL</label>
            <input
              id={`${id}-cuil`}
              type="text"
              inputMode="numeric"
              autoComplete="off"
              value={cuil}
              onChange={e => setCuil(e.target.value)}
              className={cn(CLASE_INPUT, 'font-mono text-sm')}
            />
          </div>
          <div>
            <label htmlFor={`${id}-ingreso`} className={CLASE_ETIQUETA}>Ingresó el</label>
            <input
              id={`${id}-ingreso`}
              type="date"
              value={ingreso}
              onChange={e => setIngreso(e.target.value)}
              className={cn(CLASE_INPUT, 'text-sm')}
            />
          </div>
          <div>
            <label htmlFor={`${id}-telefono`} className={CLASE_ETIQUETA}>Teléfono</label>
            <input
              id={`${id}-telefono`}
              type="tel"
              autoComplete="off"
              value={telefono}
              onChange={e => setTelefono(e.target.value)}
              className={cn(CLASE_INPUT, 'text-sm')}
            />
          </div>
        </div>

        {/* Vínculos */}
        <div className="p-3 rounded-xl border border-gray-200 dark:border-gray-700 space-y-3">
          <p className="text-sm font-semibold text-gray-800 dark:text-gray-200 flex items-center gap-1.5">
            <Link2 className="w-4 h-4 text-gray-500" aria-hidden="true" />
            Vínculos <span className="font-normal text-gray-400">(opcionales)</span>
          </p>
          {vinculosBloqueados ? <p className={CLASE_AYUDA}>{AYUDA_OTRA_SUCURSAL}</p> : null}
          <CampoVinculo
            id={`${id}-usuario`}
            etiqueta="Usuario de la app"
            placeholder="Buscá un usuario"
            opciones={opcionesUsuario}
            valor={usuarioVisible}
            onChange={setUsuarioId}
            nombreActual={empleado?.usuario?.nombre ?? null}
            disabled={vinculosBloqueados || empleado?.es_propio === true}
            nota={empleado?.es_propio ? 'Tu vínculo de usuario lo cambia otro admin.' : undefined}
            ayuda="Con usuario, los pedidos que carga comisionan para esta cuenta si su arreglo comisiona."
          />
          <CampoVinculo
            id={`${id}-cliente`}
            etiqueta="Ficha de cliente"
            placeholder="Buscá un cliente"
            opciones={opcionesCliente}
            valor={clienteVisible}
            onChange={setClienteId}
            nombreActual={empleado?.cliente ? empleado.cliente.nombre_fantasia : null}
            disabled={vinculosBloqueados}
            ayuda="Lo que se lleve pagando con “adelanto de sueldo” se le descuenta en esta cuenta."
          />
          <CampoVinculo
            id={`${id}-vehiculo`}
            etiqueta="Vehículo habitual"
            placeholder="Buscá por patente o modelo"
            opciones={opcionesVehiculo}
            valor={vehiculoVisible}
            onChange={setVehiculoId}
            nombreActual={empleado?.vehiculo ? `${empleado.vehiculo.patente} · ${empleado.vehiculo.descripcion}` : null}
            disabled={vinculosBloqueados}
          />
        </div>

        {/* Arreglo */}
        {edicion ? (
          <div className="p-3 rounded-xl bg-gray-50 dark:bg-gray-900 border border-gray-200 dark:border-gray-700">
            <p className="text-xs text-gray-500">Arreglo vigente</p>
            {empleado.arreglo ? (
              <p className="text-sm font-semibold text-gray-900 dark:text-white">{textoArregloLargo(empleado.arreglo)}</p>
            ) : (
              <p className="text-sm text-gray-500">Todavía no tiene arreglo.</p>
            )}
            <p className={CLASE_AYUDA}>Se cambia desde la ficha, para que conserve desde cuándo vale.</p>
          </div>
        ) : (
          <div className="p-3 rounded-xl border border-gray-200 dark:border-gray-700 space-y-3">
            <p className="text-sm font-semibold text-gray-800 dark:text-gray-200">Primer arreglo</p>

            <div>
              <label htmlFor={`${id}-sueldo`} className={CLASE_ETIQUETA}>
                Sueldo fijo {requerido}
              </label>
              <div className="relative">
                <span className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" aria-hidden="true">$</span>
                <input
                  id={`${id}-sueldo`}
                  type="text"
                  inputMode="decimal"
                  autoComplete="off"
                  value={sueldoTxt}
                  onChange={e => setSueldoTxt(e.target.value)}
                  placeholder="0,00"
                  className={cn(CLASE_INPUT, 'pl-7 text-right')}
                />
              </div>
            </div>

            <div role="group" aria-label="Frecuencia del sueldo" className="grid grid-cols-2 gap-2">
              <Pastilla activa={frecuencia === 'semanal'} onClick={() => setFrecuencia('semanal')}>Semanal</Pastilla>
              <Pastilla activa={frecuencia === 'mensual'} onClick={() => setFrecuencia('mensual')}>Mensual</Pastilla>
            </div>

            <div>
              <label className="inline-flex items-center gap-2 text-sm text-gray-700 dark:text-gray-300">
                <input
                  type="checkbox"
                  className="w-4 h-4"
                  checked={comisiona}
                  onChange={e => setComisiona(e.target.checked)}
                />
                Comisiona
              </label>
              <p className={CLASE_AYUDA}>El porcentaje no va acá: sale de las reglas de comisión.</p>
            </div>

            <div>
              <label htmlFor={`${id}-desde`} className={CLASE_ETIQUETA}>
                Se liquida desde {requerido}
              </label>
              <input
                id={`${id}-desde`}
                type="date"
                value={desde}
                onChange={e => setDesdeManual(e.target.value)}
                className={cn(CLASE_INPUT, 'text-sm')}
              />
              <p className={CLASE_AYUDA}>
                Para alguien que ya trabajaba, es el primer día del período que todavía no le pagaste fuera de la app: lo de antes, incluidas las comisiones de lo entregado antes, se da por pagado. Para alguien nuevo, es su primer día.
              </p>
            </div>

            {saldoAbierto ? (
              <div className="space-y-2">
                <div className="grid grid-cols-1 sm:grid-cols-[1fr_auto] gap-2 sm:items-end">
                  <div>
                    <label htmlFor={`${id}-saldo`} className={CLASE_ETIQUETA}>Saldo al empezar</label>
                    <div className="relative">
                      <span className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" aria-hidden="true">$</span>
                      <input
                        id={`${id}-saldo`}
                        type="text"
                        inputMode="decimal"
                        autoComplete="off"
                        value={saldoTxt}
                        onChange={e => setSaldoTxt(e.target.value)}
                        placeholder="0,00"
                        className={cn(CLASE_INPUT, 'pl-7 text-right')}
                      />
                    </div>
                  </div>
                  <div role="group" aria-label="Signo del saldo" className="grid grid-cols-2 gap-2">
                    <Pastilla activa={saldoSigno === 'favor'} onClick={() => setSaldoSigno('favor')}>A su favor</Pastilla>
                    <Pastilla activa={saldoSigno === 'debe'} onClick={() => setSaldoSigno('debe')}>Debe</Pastilla>
                  </div>
                </div>
                <p className="text-xs text-gray-500">Lo que le debían o debía al pasar a la app. Entra como un ajuste.</p>
              </div>
            ) : (
              <button type="button" className={CLASE_LINK} onClick={() => setSaldoAbierto(true)}>
                + Saldo al empezar
              </button>
            )}
          </div>
        )}

        {error && (
          <div role="alert" className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
            <p className="text-sm text-red-600 dark:text-red-400">{error}</p>
          </div>
        )}

        <div className="flex gap-3 pt-2">
          <Button type="button" variant="secondary" size="md" onClick={onClose} className="flex-1">
            Cancelar
          </Button>
          <Button type="submit" variant="primary" size="md" loading={guardando} disabled={guardando} className="flex-1">
            {edicion ? 'Guardar cambios' : 'Dar de alta'}
          </Button>
        </div>
      </form>
    </ModalBase>
  )
}
