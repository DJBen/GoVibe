# Firebase Analytics

GoVibe uses Firebase Analytics to understand user behavior, identify friction points, and guide product decisions. The implementation follows a "key metrics, not excessive" principle — instrumenting lifecycle boundaries and user decisions rather than every interaction.

## Setup

Firebase Analytics auto-initializes when the `FirebaseAnalytics` SPM product is linked and `FirebaseApp.configure()` is called. No additional configuration is needed beyond what already exists for Firebase Auth/Firestore.

### Debug Mode

To see events in real-time in the Firebase Console DebugView, add the launch argument:

```
-FIRAnalyticsDebugEnabled
```

In Xcode: Edit Scheme > Run > Arguments > Arguments Passed On Launch.

## Architecture

Each app has a thin, stateless analytics helper:

| App | Helper | Location |
|-----|--------|----------|
| iOS | `GoVibeAnalytics` | `GoVibeFeaturePackage/Sources/GoVibeFeature/GoVibeAnalytics.swift` |
| macOS | `HostAnalytics` | `GoVibeHostCorePackage/Sources/GoVibeHostCore/HostAnalytics.swift` |

Both are `enum` types with static methods wrapping `FirebaseAnalytics.Analytics`. No abstraction protocol — single backend, minimal ceremony.

## User Properties

Set on authentication success, cleared on sign-out.

| Property | Values | Description |
|----------|--------|-------------|
| `platform` | `"ios"` / `"macos"` | Which app the user is using |
| `app_version` | e.g. `"0.3.4"` | CFBundleShortVersionString |
| Firebase User ID | `user.uid` | Links events across sessions |

## Event Catalog

### Auth Events (iOS)

| Event | Parameters | When |
|-------|-----------|------|
| `auth_method_chosen` | `method` ("google" \| "apple") | User initiates sign-in |
| `auth_success` | `method` | Firebase auth completes successfully |
| `auth_failure` | `method`, `error_message` | Auth fails (excludes user cancellation) |
| `auth_sign_out` | — | User signs out |

### Auth Events (macOS Host)

| Event | Parameters | When |
|-------|-----------|------|
| `host_auth_method_chosen` | `method` ("google" \| "apple_web") | Host user initiates sign-in |
| `host_auth_success` | `method` | Auth succeeds |
| `host_auth_failure` | `method`, `error_message` | Auth fails (excludes cancellation) |
| `host_sign_out` | — | Host user signs out |
| `host_registered` | — | Host device successfully registered with backend |

### Session Lifecycle (iOS)

| Event | Parameters | When |
|-------|-----------|------|
| `session_created` | `host_id`, `session_id` | New session created via SessionCreateView |
| `session_create_failed` | `error_message` | Session creation fails |
| `session_connected` | `session_id` | First peer joins the relay |
| `session_disconnected` | `session_id`, `reason` | Peer retires or disconnects |
| `session_deleted` | `session_id`, `kill_tmux` | User deletes a session |

### Session Engagement (iOS)

| Event | Parameters | When |
|-------|-----------|------|
| `session_kind_discovered` | `session_id`, `kind` ("terminal" \| "simulator" \| "app_window") | Session type identified |
| `session_ai_detected` | `session_id`, `ai_program` | Pane program matches Claude/Codex/Gemini |
| `plan_viewed` | `session_id`, `assistant` | User opens plan artifact sheet |

### Feature Adoption (iOS)

| Event | Parameters | When |
|-------|-----------|------|
| `notif_permission_granted` | — | User taps "Allow Notifications" |
| `notif_permission_denied` | — | User taps "Not now" |
| `quick_action_used` | `pane_program`, `action` | User selects a quick action |

### Error/Frustration Signals (iOS)

| Event | Parameters | When |
|-------|-----------|------|
| `relay_connect_failed` | `session_id` | All relay endpoints exhausted |
| `relay_error` | `session_id`, `error_message` | WebSocket receive loop failure |
| `peer_timeout` | `session_id` | 120s peer staleness threshold hit |

### Host Session Lifecycle (macOS)

| Event | Parameters | When |
|-------|-----------|------|
| `host_session_created` | `kind`, `session_id` | Terminal/simulator/app-window session created |
| `host_session_started` | `session_id` | Runtime starts successfully |
| `host_session_start_failed` | `session_id`, `error_message` | Runtime start throws |
| `host_session_stopped` | `session_id` | Session stopped |
| `host_session_removed` | `session_id` | Session removed (kills tmux) |

### Screen Views

Tracked via `logScreenView()` on key screens:

| Screen Name | View |
|-------------|------|
| `sign_in` | GoVibeSignInView |
| `session_list` | SessionListView |
| `session_detail` | SessionDetailView |
| `session_create` | SessionCreateView |
| `notification_onboarding` | NotificationOnboardingView |
| `host_sign_in` | HostSignInView |
| `host_dashboard` | HostDashboardView |

## What Questions Do These Events Answer?

| Question | Events |
|----------|--------|
| Which AI assistant do users prefer? | `session_ai_detected` |
| Are users struggling to connect? | `relay_connect_failed`, `relay_error`, `peer_timeout` |
| Terminal vs simulator vs app window usage? | `session_kind_discovered` |
| Is the auth funnel healthy? | `auth_method_chosen` → `auth_success` / `auth_failure` |
| Are push notifications worth the investment? | `notif_permission_granted` / `notif_permission_denied` |
| What quick actions are popular? | `quick_action_used` |
| Are users engaging with AI plans? | `plan_viewed` |
| How reliable is the host? | `host_session_start_failed`, host lifecycle events |

## Automatic Events

Firebase Analytics automatically tracks these without custom code:

- `first_open` — first app launch
- `session_start` — new engagement session
- `app_update` — first launch after update
- `engagement_time_msec` — active usage duration

## Adding New Events

1. Choose a snake_case name (max 40 characters)
2. Add the `GoVibeAnalytics.log()` or `HostAnalytics.log()` call at the appropriate lifecycle boundary
3. Document the event in this file
4. After deployment, mark conversion events in Firebase Console if needed

## Privacy

- No PII is logged in event parameters
- User ID is the Firebase UID (already in Firebase Auth)
- Event parameters contain session/host IDs and error messages only
- Analytics respects the user's iOS App Tracking Transparency settings
