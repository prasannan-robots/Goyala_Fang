# Goyala Fang Robot

A soil-survey robot and its companion app. Mark a field on the map, send the robot a
grid of survey points, and get NPK (nitrogen / phosphorus / potassium) estimates, crop
suggestions and fertilizer advice for every sample.

| Folder | What it is |
| --- | --- |
| `delta/` | **The app ("Saga")** – Flutter, English + Tamil. Current version. |
| `goyalasrm/` | Earlier version of the app (kept for reference). |
| `sketch_mar11a/` | Arduino firmware: SIM800 GSM, drive motors, sampling servo, pH + moisture sensors. |
| `Goyala Fang PCB/` | KiCad PCB design, plus `custom.*` symbols/footprints. |

## How it works

1. **Connect** – in the app, pick SMS (robot's SIM number) or Bluetooth (paired HC-05-style module).
2. **Mark field** – tap the four corners of the field on the satellite map. Drag corners to adjust.
   The app lays a survey grid over the field (density adjustable) as a serpentine path.
3. **Send to robot** – waypoints go out as `GPS: lat,lng; lat,lng; …` messages (each fits one
   SMS), followed by `Start`.
4. **Readings** – the robot replies per sample; the app runs the bundled TFLite model
   (`[pH, EC, moisture] → [N, P, K]`), colours each sample by soil health, and builds a final
   report when the robot sends `D:`.

### Robot → app messages

```
S:Lat:<lat>,Lng:<lng>,Sensor:<pH>-<EC>-<moisture>   sensor reading
C:Lat:<lat>,Lng:<lng>                               robot position
D:                                                  survey finished
```

Bluetooth messages end with `;`. Sensor values may also be separated by commas or spaces.

> **Known gap:** the NPK model needs **pH, EC and moisture**, but the current board only has pH
> and moisture sensors, and sends raw `analogRead()` values with fixed coordinates. The app shows
> those readings but can't predict NPK until an EC sensor (and GPS + calibration) is added.

## Running the app

```sh
cd delta
flutter pub get
flutter test
flutter run
```

Google Maps needs an API key with **Maps SDK for Android** enabled. Put it on its own line in
`delta/android/local.properties` (gitignored — never commit keys):

```
MAPS_API_KEY=your_key_here
```

Restrict the key in Google Cloud Console to the Maps SDK and this app's package name.
