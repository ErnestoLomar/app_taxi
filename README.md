# Taxi SCT SLP (Flutter) — Mapa + Ruta + Taxímetro

Aplicación móvil en **Flutter (Android)** para:

* Autocompletado de direcciones (Google Places)
* Cálculo de rutas (Google Directions)
* Visualización en Google Maps:

    * Ruta planeada (azul)
    * Ruta recorrida en vivo (naranja) con filtros GPS y *snap-to-route*
* Taxímetro conforme a tarifas SCT (San Luis Potosí): banderazo + unidades por tiempo/distancia

---

## Funcionalidades

* Selección de **origen/destino** por:

    * Autocomplete (texto)
    * Tap en el mapa (opcional)
* Botones flotantes:

    * **Fit** (encuadrar ruta)
    * **Follow** (seguimiento cámara durante viaje)
    * **Mi ubicación**
* Resumen previo al viaje:

    * Distancia y tiempo estimado
    * Tarifa estimada
* En viaje:

    * Tiempo, distancia, unidades y tarifa en tiempo real

---

## Requisitos

* Flutter estable
* Android Studio
* Dispositivo Android (recomendado) o emulador
* API Key de Google con:

    * Maps SDK for Android
    * Places API
    * Directions API

---

## Variables de entorno (.env)

La API key se carga desde un archivo `.env` usando `flutter_dotenv`.

### 1) Instalar dependencia

En `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_dotenv: ^6.0.0

flutter:
  assets:
    - .env
```

### 2) Crear `.env` en la raíz del proyecto

```env
GOOGLE_WEB_KEY=TU_GOOGLE_API_KEY
```

### 3) Ignorar `.env` en Git

En `.gitignore`:

```gitignore
.env
```

---

## Configuración de Google Maps (Android)

En `android/app/src/main/AndroidManifest.xml`, dentro de `<application>`:

```xml
<meta-data
  android:name="com.google.android.geo.API_KEY"
  android:value="TU_ANDROID_MAPS_KEY"/>
```

> Nota: Puedes usar la misma key para Android y para web services si así lo defines en Google Cloud, pero lo recomendado es restringir correctamente por tipo de uso.

---

## Ejecutar

```bash
flutter pub get
flutter run
```

---

## Estructura (referencia)

* `lib/main.dart` — UI principal (mapa, bottom sheet, botones)
* `lib/places_service.dart` — Places Autocomplete / Place Details
* `lib/place_autocomplete_field.dart` — Campo con debounce + lista de sugerencias
* `lib/directions_service.dart` — Directions + decode de polyline
* `lib/route_info.dart` — Modelo de ruta (polyline, distancia, duración)
* `lib/fare_config.dart` — Tarifas y cálculo del taxímetro
* `lib/taximeter_controller.dart` — Stream GPS + filtros + snap-to-route + cálculo

---

## Notas de seguridad

Guardar la key en `.env` evita que quede hardcodeada en `main.dart`, pero **no la hace secreta** en builds móviles: al ir como asset, puede extraerse. Para producción:

* Restringe la key por paquete/SHA-1, APIs y cuotas
* Considera proxys/firmas si expones endpoints sensibles

---

## Próximos pasos (si se amplía la app)

* Historial de viajes
* Recibos
* Compartir viaje en tiempo real
* Botón SOS
* Autenticación y roles
* Backend para solicitudes (si aplica)