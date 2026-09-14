// Autorización del caller de optimizar-ruta.
//
// La función no está en config.toml, así que corre con verify_jwt = true —
// eso solo exige un JWT FIRMADO por el proyecto, y la anon key pública lo
// cumple. No alcanza: cada tramo optimizado es una llamada facturable a
// Google (Routes API / Route Optimization), así que hay que resolver el
// usuario real detrás del JWT y exigirle un rol operativo.
//
// Diseño inyectable (AutorizarDeps) para poder testear 401/403 sin red: los
// tests de supabase/functions/tests/optimizar_ruta.test.ts pasan fakes en vez
// de crear un cliente real. `deno task test` corre con
// `--allow-net=api.telegram.org`, así que un test que dependiera del cliente
// real de Supabase Auth fallaría igual por la sandbox de red.

import { createClient } from "@supabase/supabase-js";
import { getServiceRoleClient } from "../_shared/supabase.ts";

export const ROLES_PERMITIDOS = ["transportista", "encargado", "admin"] as const;
export type RolPermitido = (typeof ROLES_PERMITIDOS)[number];

export type AutorizacionResultado =
  | { ok: true; userId: string; rol: RolPermitido }
  | { ok: false; status: 401 | 403; error: string; mensaje: string };

export interface AutorizarDeps {
  /** Resuelve el usuario a partir del header Authorization crudo (incl. "Bearer "). Null = token inválido/expirado/ausente. */
  obtenerUsuario: (authHeader: string) => Promise<{ id: string } | null>;
  /** Lee perfiles.rol para el usuario. Null = perfil inexistente. */
  obtenerRol: (userId: string) => Promise<string | null>;
}

/**
 * Verifica que el caller tenga un JWT válido de un usuario con rol
 * transportista, encargado o admin. No toca Google — se llama ANTES de
 * cualquier fetch a las APIs de rutas.
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

  const usuario = await deps.obtenerUsuario(authHeader);
  if (!usuario) {
    return {
      ok: false,
      status: 401,
      error: "No autenticado",
      mensaje: "Token inválido o expirado",
    };
  }

  const rolCrudo = await deps.obtenerRol(usuario.id);
  if (!rolCrudo || !(ROLES_PERMITIDOS as readonly string[]).includes(rolCrudo)) {
    return {
      ok: false,
      status: 403,
      error: "Sin permiso",
      mensaje: "Se requiere rol transportista, encargado o admin para optimizar rutas",
    };
  }

  return { ok: true, userId: usuario.id, rol: rolCrudo as RolPermitido };
}

/** Deps de producción: JWT vía Supabase Auth (anon key) + rol vía service_role. */
export function crearDepsAutorizacion(): AutorizarDeps {
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
    obtenerRol: async (userId) => {
      const { data, error } = await getServiceRoleClient()
        .from("perfiles")
        .select("rol")
        .eq("id", userId)
        .maybeSingle();
      if (error || !data) return null;
      return (data as { rol?: string }).rol ?? null;
    },
  };
}
