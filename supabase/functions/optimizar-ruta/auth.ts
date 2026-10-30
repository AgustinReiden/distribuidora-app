// Autorización del caller de optimizar-ruta.
//
// La función no está en config.toml, así que corre con verify_jwt = true —
// eso solo exige un JWT FIRMADO por el proyecto, y la anon key pública lo
// cumple. No alcanza: cada tramo optimizado es una llamada facturable a
// Google (Routes API / Route Optimization), así que hay que resolver el
// usuario real detrás del JWT y exigirle un rol operativo.
//
// El rol se le pregunta a la BASE, con la sesión del usuario y su sucursal
// activa (#1312): `es_transportista()` y `es_encargado_o_admin()`, las mismas
// que usan las policies y las RPCs de rutas. Antes se comparaba
// `perfiles.rol` contra una lista, que no ve el transportista como rol extra
// (`perfil_roles`, mig 155, que vale en la sucursal activa): el preventista
// con el extra recibía 403 al navegar su propio recorrido. El gate
// tests/permisos_rol_pelado.test.ts falla si una edge function vuelve a leer
// `perfiles.rol` para decidir permisos.
//
// Sucursal activa: el header X-Sucursal-ID, que el cliente de supabase-js del
// front pone en todo request (incluido `functions.invoke`) y que
// `current_sucursal_id()` valida contra `usuario_sucursales`. Se reenvía tal
// cual a las dos RPCs; sin header, la base usa la sucursal default.
//
// Diseño inyectable (AutorizarDeps) para poder testear 401/403 sin red: los
// tests de supabase/functions/tests/optimizar_ruta.test.ts pasan fakes en vez
// de crear un cliente real. `deno task test` corre con
// `--allow-net=api.telegram.org`, así que un test que dependiera del cliente
// real de Supabase Auth fallaría igual por la sandbox de red.

import { createClient } from "@supabase/supabase-js";

export type AutorizacionResultado =
  | { ok: true; userId: string }
  | { ok: false; status: 400 | 401 | 403 | 503; error: string; mensaje: string };

/** Lo que contesta la base para la sesión del caller. */
export interface PermisosRuta {
  /** `es_transportista()`: rol base admin/transportista, o el extra en la sucursal activa. */
  transportista: boolean;
  /** `es_encargado_o_admin()`. */
  encargadoOAdmin: boolean;
}

export interface AutorizarDeps {
  /** Resuelve el usuario a partir del header Authorization crudo (incl. "Bearer "). Null = token inválido/expirado/ausente. */
  obtenerUsuario: (authHeader: string) => Promise<{ id: string } | null>;
  /**
   * Pregunta los permisos a la base con la sesión del caller y su sucursal
   * activa (null = sin header). Null = la consulta falló: se rechaza.
   */
  obtenerPermisos: (authHeader: string, sucursalId: string | null) => Promise<PermisosRuta | null>;
}

/**
 * Verifica que el caller tenga un JWT válido de un usuario que la base
 * reconoce como transportista (base o extra en su sucursal activa),
 * encargado o admin. No toca Google — se llama ANTES de cualquier fetch a las
 * APIs de rutas.
 */
export async function autorizarCaller(
  req: Request,
  deps: AutorizarDeps,
): Promise<AutorizacionResultado> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return {
      ok: false,
      status: 401,
      error: "No autenticado",
      mensaje: "Falta el header Authorization",
    };
  }

  const sucursalId = req.headers.get("X-Sucursal-ID")?.trim() || null;
  if (sucursalId !== null && !/^\d+$/.test(sucursalId)) {
    return {
      ok: false,
      status: 400,
      error: "Sucursal inválida",
      mensaje: "La sucursal activa no es válida",
    };
  }

  const usuario = await deps.obtenerUsuario(authHeader);
  if (!usuario) {
    return {
      ok: false,
      status: 401,
      error: "No autenticado",
      mensaje: "Token inválido o expirado",
    };
  }

  const permisos = await deps.obtenerPermisos(authHeader, sucursalId);
  if (!permisos) {
    // Fail-closed, pero sin decirle "no tenés rol" a quien sí lo tiene.
    return {
      ok: false,
      status: 503,
      error: "Permisos no disponibles",
      mensaje: "No se pudo verificar tu rol. Probá de nuevo en un rato",
    };
  }
  if (!(permisos.transportista || permisos.encargadoOAdmin)) {
    return {
      ok: false,
      status: 403,
      error: "Sin permiso",
      mensaje: "Se requiere rol transportista, encargado o admin para optimizar rutas",
    };
  }

  return { ok: true, userId: usuario.id };
}

/** Deps de producción: JWT y permisos vía PostgREST con la sesión del caller (anon key + su JWT). */
export function crearDepsAutorizacion(): AutorizarDeps {
  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

  const clienteDelCaller = (authHeader: string, sucursalId: string | null) => {
    const headers: Record<string, string> = { Authorization: authHeader };
    if (sucursalId !== null) headers["X-Sucursal-ID"] = sucursalId;
    return createClient(url, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers },
    });
  };

  return {
    obtenerUsuario: async (authHeader) => {
      if (!url || !anonKey) return null;
      const { data, error } = await clienteDelCaller(authHeader, null).auth.getUser();
      if (error || !data?.user) return null;
      return { id: data.user.id };
    },
    obtenerPermisos: async (authHeader, sucursalId) => {
      if (!url || !anonKey) return null;
      const cliente = clienteDelCaller(authHeader, sucursalId);
      const [transportista, encargadoOAdmin] = await Promise.all([
        cliente.rpc("es_transportista"),
        cliente.rpc("es_encargado_o_admin"),
      ]);
      if (transportista.error || encargadoOAdmin.error) {
        console.error(
          "[optimizar-ruta] no pude leer los permisos:",
          transportista.error?.message ?? encargadoOAdmin.error?.message,
        );
        return null;
      }
      return {
        transportista: transportista.data === true,
        encargadoOAdmin: encargadoOAdmin.data === true,
      };
    },
  };
}
