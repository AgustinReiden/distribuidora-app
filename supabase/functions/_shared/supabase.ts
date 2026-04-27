// Cliente Supabase con service_role para uso interno del bot. Singleton para
// evitar reabrir conexiones en cada invocación de la edge function (Supabase
// Functions reusan el isolate de Deno entre requests cuando la función está
// "warm").
//
// IMPORTANTE: SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY las inyecta Supabase
// automáticamente al desplegar la función — NO hay que setearlas manualmente
// como secrets. Si fallan, es problema de runtime, no de config.

import { createClient, SupabaseClient } from "@supabase/supabase-js";

let _client: SupabaseClient | null = null;

export function getServiceRoleClient(): SupabaseClient {
  if (_client) return _client;

  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) {
    throw new Error(
      "SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY not set in Edge Function environment",
    );
  }

  _client = createClient(url, key, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
    },
  });

  return _client;
}

// Test-only helper: permite a los tests inyectar un mock o resetear el
// singleton entre tests. NO usar desde producción.
export function _setServiceRoleClientForTests(client: SupabaseClient | null): void {
  _client = client;
}
