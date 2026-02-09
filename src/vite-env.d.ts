/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_SENTRY_DSN: string | undefined
  readonly VITE_APP_VERSION: string | undefined
  readonly VITE_GOOGLE_API_KEY: string | undefined
  readonly VITE_N8N_WEBHOOK_URL: string | undefined
  readonly PROD: boolean
  readonly DEV: boolean
  readonly MODE: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}

// =============================================================================
// GOOGLE MAPS TYPES
// =============================================================================

declare namespace google.maps {
  class LatLng {
    constructor(lat: number, lng: number);
    lat(): number;
    lng(): number;
  }

  class Map {
    constructor(mapDiv: Element, opts?: MapOptions);
  }

  interface MapOptions {
    center?: LatLng | LatLngLiteral;
    zoom?: number;
  }

  interface LatLngLiteral {
    lat: number;
    lng: number;
  }

  namespace places {
    class AutocompleteService {
      getPlacePredictions(
        request: AutocompletionRequest,
        callback: (
          results: AutocompletePrediction[] | null,
          status: PlacesServiceStatus
        ) => void
      ): void;
    }

    class PlacesService {
      constructor(attrContainer: HTMLDivElement | Map);
      getDetails(
        request: PlaceDetailsRequest,
        callback: (
          result: PlaceResult | null,
          status: PlacesServiceStatus
        ) => void
      ): void;
    }

    class AutocompleteSessionToken {
      constructor();
    }

    interface AutocompletionRequest {
      input: string;
      componentRestrictions?: ComponentRestrictions;
      types?: string[];
      sessionToken?: AutocompleteSessionToken | null;
      locationBias?: LocationBias;
    }

    interface ComponentRestrictions {
      country: string | string[];
    }

    interface LocationBias {
      center: LatLng | LatLngLiteral;
      radius: number;
    }

    interface AutocompletePrediction {
      place_id: string;
      description: string;
      structured_formatting?: {
        main_text: string;
        secondary_text: string;
      };
    }

    interface PlaceDetailsRequest {
      placeId: string;
      fields?: string[];
      sessionToken?: AutocompleteSessionToken | null;
    }

    interface PlaceResult {
      formatted_address?: string;
      geometry?: PlaceGeometry;
      address_components?: GeocoderAddressComponent[];
    }

    interface PlaceGeometry {
      location?: LatLng;
    }

    interface GeocoderAddressComponent {
      long_name: string;
      short_name: string;
      types: string[];
    }

    enum PlacesServiceStatus {
      OK = 'OK',
      ZERO_RESULTS = 'ZERO_RESULTS',
      INVALID_REQUEST = 'INVALID_REQUEST',
      OVER_QUERY_LIMIT = 'OVER_QUERY_LIMIT',
      REQUEST_DENIED = 'REQUEST_DENIED',
      UNKNOWN_ERROR = 'UNKNOWN_ERROR',
      NOT_FOUND = 'NOT_FOUND'
    }
  }
}

// Extend Window to include google
declare global {
  interface Window {
    google?: {
      maps: typeof google.maps;
    };
  }
}
declare module 'prop-types';
