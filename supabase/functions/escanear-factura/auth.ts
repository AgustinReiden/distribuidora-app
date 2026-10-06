// Autorización del caller de escanear-factura.
//
// Mismo patrón que optimizar-ruta/auth.ts: `verify_jwt = true` (la función no
// está en config.toml) sólo garantiza un JWT firmado por el proyecto —la anon
// key lo cumple—, y cada escaneo es una llamada facturable a Gemini. Así que
// se resuelve el usuario real y se le exige rol admin o encargado, el mismo
// gate que /compras en el router y que la RLS del bucket (mig 239).
//
// Multi-rol: `perfil_roles` (mig 155) sólo otorga `transportista` como rol
// extra (CHECK de la tabla), así que no puede dar acceso acá. El rol que vale
// es el EFECTIVO en la sucursal activa, con el mismo criterio que App.tsx:
// `usuario_sucursales.rol` si es propio, y si es 'mismo' (o null), `perfiles.rol`.
//
// Sucursal activa: como `current_sucursal_id()` (mig 061). El header
// X-Sucursal-ID —que el cliente de supabase-js del front pone en todo request,
// incluido `functions.invoke`— si el usuario pertenece a esa sucursal; sin
// header, la sucursal default del usuario.
//
// Inyectable (AutorizarEscaneoDeps) para testear 401/403 sin red.

import { createClient } from "@supabase/supabase-js";
import { getServiceRoleClient } from "../_shared/supabase.ts";

export const ROLES_ESCANEO = ["admin", "encargado"] as const;
export type RolEscaneo = (typeof ROLES_ESCANEO)[number];

export interface PerfilEscaneo {
  rol: string | null;
  activo: boolean | null;
}

export interface SucursalDelUsuario {
  sucursal_id: number;
  es_default: boolean;
  /** Rol propio en esa sucursal; 'mismo' o null = el de `perfiles`. */
  rol: string | null;
}

export interface AutorizarEscaneoDeps {
  /** Usuario detrás del header Authorization crudo. null = inválido/expirado. */
  obtenerUsuario: (authHeader: string) => Promise<{ id: string } | null>;
  obtenerPerfil: (userId: string) => Promise<PerfilEscaneo | null>;
  obtenerSucursales: (userId: string) => Promise<SucursalDelUsuario[]>;
}

export type AutorizacionEscaneo =
  | { ok: true; userId: string; rol: RolEscaneo; sucursalId: number }
  | { ok: false; status: 400 | 401 | 403; mensaje: string };

export async function autorizarEscaneo(
  req: Request,
  deps: AutorizarEscaneoDeps,
): Promise<AutorizacionEscaneo> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return { ok: false, status: 401, mensaje: "Tenés que iniciar sesión para escanear facturas." };
  }
  const usuario = await deps.obtenerUsuario(authHeader);
  if (!usuario) {
    return { ok: false, status: 401, mensaje: "La sesión venció. Volvé a iniciar sesión." };
  }

  const perfil = await deps.obtenerPerfil(usuario.id);
  if (!perfil || perfil.activo === false) {
    return { ok: false, status: 403, mensaje: "Tu usuario no está habilitado." };
  }

  const sucursales = await deps.obtenerSucursales(usuario.id);
  const headerSucursal = req.headers.get("X-Sucursal-ID")?.trim();
  let sucursal: SucursalDelUsuario | undefined;
  if (headerSucursal) {
    if (!/^\d+$/.test(headerSucursal)) {
      return { ok: false, status: 400, mensaje: "La sucursal activa no es válida." };
    }
    sucursal = sucursales.find((s) => s.sucursal_id === Number(headerSucursal));
    if (!sucursal) {
      return { ok: false, status: 403, mensaje: "No tenés acceso a esa sucursal." };
    }
  } else {
    sucursal = sucursales.find((s) => s.es_default) ?? (sucursales.length === 1 ? sucursales[0] : undefined);
    if (!sucursal) {
      return { ok: false, status: 403, mensaje: "No hay una sucursal activa para tu usuario." };
    }
  }

  const rolEfectivo = sucursal.rol && sucursal.rol !== "mismo" ? sucursal.rol : perfil.rol;
  if (!rolEfectivo || !(ROLES_ESCANEO as readonly string[]).includes(rolEfectivo)) {
    return {
      ok: false,
      status: 403,
      mensaje: "Escanear facturas es sólo para admin o encargado.",
    };
  }

  return { ok: true, userId: usuario.id, rol: rolEfectivo as RolEscaneo, sucursalId: sucursal.sucursal_id };
}

/** Deps de producción: JWT vía Supabase Auth (anon key) + perfil y sucursales vía service_role. */
export function crearDepsAutorizacionEscaneo(): AutorizarEscaneoDeps {
  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

  return {
    obtenerUsuario: async (authHeader) => {
      if (!url || !anonKey) return null;
      const client = createClient(url, anonKey, {
        auth: { persistSession: false, autoRefreshToken: false },
        global: { headers: { Authorization: authHeader } },
      });
      const { data, error } = await client.auth.getUser();
      if (error || !data?.user) return null;
      return { id: data.user.id };
    },
    obtenerPerfil: async (userId) => {
      const { data, error } = await getServiceRoleClient()
        .from("perfiles")
        .select("rol, activo")
        .eq("id", userId)
        .maybeSingle();
      if (error || !data) return null;
      const fila = data as { rol?: string | null; activo?: boolean | null };
      return { rol: fila.rol ?? null, activo: fila.activo ?? null };
    },
    obtenerSucursales: async (userId) => {
      const { data, error } = await getServiceRoleClient()
        .from("usuario_sucursales")
        .select("sucursal_id, es_default, rol")
        .eq("usuario_id", userId);
      if (error || !data) return [];
      return (data as Array<{ sucursal_id: number | string; es_default: boolean | null; rol: string | null }>)
        .map((f) => ({ sucursal_id: Number(f.sucursal_id), es_default: f.es_default === true, rol: f.rol }));
    },
  };
}
