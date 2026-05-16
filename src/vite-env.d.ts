/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_SENTRY_DSN: string | undefined
  readonly VITE_APP_VERSION: string | undefined
  readonly VITE_GOOGLE_API_KEY: string | undefined
  readonly VITE_N8N_WEBHOOK_URL: string | undefined
  readonly VITE_N8N_FACTURA_WEBHOOK_URL: string | undefined
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
    fitBounds(bounds: LatLngBounds, padding?: number | Padding): void;
    panTo(latLng: LatLng | LatLngLiteral): void;
    setCenter(latLng: LatLng | LatLngLiteral): void;
    setZoom(zoom: number): void;
    getZoom(): number;
  }

  interface Padding {
    top?: number;
    right?: number;
    bottom?: number;
    left?: number;
  }

  interface MapOptions {
    center?: LatLng | LatLngLiteral;
    zoom?: number;
    disableDefaultUI?: boolean;
    mapTypeControl?: boolean;
    streetViewControl?: boolean;
    fullscreenControl?: boolean;
    zoomControl?: boolean;
    clickableIcons?: boolean;
    styles?: unknown[];
  }

  class LatLngBounds {
    constructor(sw?: LatLng | LatLngLiteral, ne?: LatLng | LatLngLiteral);
    extend(point: LatLng | LatLngLiteral): LatLngBounds;
    isEmpty(): boolean;
    getCenter(): LatLng;
  }

  class Marker {
    constructor(opts?: MarkerOptions);
    setMap(map: Map | null): void;
    setPosition(latLng: LatLng | LatLngLiteral): void;
    setIcon(icon: unknown): void;
    addListener(event: string, handler: (...args: unknown[]) => void): MapsEventListener;
    getPosition(): LatLng | null;
  }

  interface MarkerOptions {
    position?: LatLng | LatLngLiteral;
    map?: Map;
    title?: string;
    label?: string | { text: string; color?: string; fontWeight?: string; fontSize?: string };
    icon?: unknown;
    zIndex?: number;
    opacity?: number;
  }

  interface MapsEventListener {
    remove(): void;
  }

  class Polyline {
    constructor(opts?: PolylineOptions);
    setMap(map: Map | null): void;
    setPath(path: Array<LatLng | LatLngLiteral>): void;
  }

  interface PolylineOptions {
    path?: Array<LatLng | LatLngLiteral>;
    map?: Map;
    geodesic?: boolean;
    strokeColor?: string;
    strokeOpacity?: number;
    strokeWeight?: number;
  }

  class InfoWindow {
    constructor(opts?: InfoWindowOptions);
    open(map?: Map, anchor?: Marker): void;
    close(): void;
    setContent(content: string | HTMLElement): void;
    setPosition(position: LatLng | LatLngLiteral): void;
  }

  interface InfoWindowOptions {
    content?: string | HTMLElement;
    position?: LatLng | LatLngLiteral;
    maxWidth?: number;
  }

  interface Symbol {
    path: string | number;
    fillColor?: string;
    fillOpacity?: number;
    strokeColor?: string;
    strokeWeight?: number;
    scale?: number;
    labelOrigin?: { x: number; y: number };
  }

  const SymbolPath: {
    CIRCLE: number;
    BACKWARD_CLOSED_ARROW: number;
    FORWARD_CLOSED_ARROW: number;
  };

  namespace event {
    function clearInstanceListeners(instance: object): void;
  }

  interface LatLngLiteral {
    lat: number;
    lng: number;
  }

  // Geocoder: usado para reverse geocoding (coords -> direccion) en useReverseGeocoding.
  class Geocoder {
    constructor();
    geocode(request: GeocoderRequest): Promise<GeocoderResponse>;
  }

  interface GeocoderRequest {
    location?: LatLng | LatLngLiteral;
    address?: string;
  }

  interface GeocoderResponse {
    results: GeocoderResult[];
  }

  interface GeocoderResult {
    formatted_address: string;
    geometry?: {
      location?: LatLng;
    };
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
