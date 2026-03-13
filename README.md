# LifePulse Test App

Minimal Flutter iOS app for testing the device → backend data flow.

Supports two sync modes:
- **via Open Wearables** – full chain: App → OW backend → Celery adapter → LifePulse
- **Direct** – bypass OW, call LifePulse Partner API directly (good when OW is not running)

---

## Quick Start (Direct Mode – fastest for testing)

### 1. Start LifePulse backend

```bash
cd ..   # project root
docker compose up -d
python scripts/demo_seed.py   # creates demo tenant + users + prints API key
```

### 2. Expose backend externally (for testing on real device)

```bash
brew install ngrok
ngrok http 8000
# Copy the https://xxxx.ngrok-free.app URL
```

Or if deployed to Railway/Render, use that URL directly.

### 3. Open project in Xcode

```bash
open ios/Runner.xcworkspace
```

In Xcode:
- Set your Team under **Signing & Capabilities**
- Add **HealthKit** capability (Signing & Capabilities → + → HealthKit)
- Build and run on a real iPhone (HealthKit requires real device)

### 4. Configure the app

Tap the ⚙️ settings icon → fill in:
- **LifePulse API Base URL**: your ngrok/Railway URL
- **Partner API Key**: from `demo_seed.py` output
- **LifePulse User ID**: from `demo_seed.py` output
- **Sync Mode**: Direct

### 5. Tap "Sync Health Data Now"

Watch the log output. Then check the Management Portal to see the data.

---

## Full Chain Mode (via Open Wearables)

Tests the complete production path:

```bash
cd ..   # project root
docker compose -f open-wearables/docker-compose.yml \
               -f open-wearables/docker-compose.lifepulse.yml up -d

# Edit open-wearables/lifepulse/user_map.json
# Add: { "<ow_user_uuid>": "<lifepulse_user_uuid>" }
```

In the app config:
- **OW API Base URL**: `http://<your-machine-ip>:8000`
- **OW User ID** + **OW Access Token**: from OW admin panel
- **Sync Mode**: via Open Wearables

---

## File Map

| File | Purpose |
|------|---------|
| `lib/main.dart` | App entry point |
| `lib/screens/home_screen.dart` | Main screen: sync button + log output |
| `lib/screens/config_screen.dart` | Config screen: API URLs + keys |
| `lib/services/health_service.dart` | OW SDK + direct HTTP sync logic |
| `ios/Runner/Info.plist` | HealthKit permission descriptions |
| `ios/Runner/Runner.entitlements` | HealthKit entitlement |

---

## Notes

- HealthKit **requires a real iPhone** – simulator has no health data
- Needs an Apple Developer account to sign the app
- `open_wearables_health_sdk` fetched from GitHub on `flutter pub get`
