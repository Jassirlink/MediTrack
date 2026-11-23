# MediTrack

MediTrack is an offline-first medication reminder app for iPhone. It displays the clinic’s prescriptions, lets patients mark scheduled doses as Taken or Skipped, and uploads saved dose logs after connectivity returns.

## Run in Xcode

1. Open `MediTrack.xcodeproj` and choose the shared **MediTrack** scheme.
2. Select an iPhone simulator running iOS 17 or newer and press **⌘R**. The app uses the bundled clinic mock and needs no credentials, local server, package installation, or third-party frameworks.
3. Launch online once so the app can cache the medication list. Use **Enable Reminders** on Today to grant notification access. For a physical iPhone, select a signing team and use a unique bundle ID if your team requires one.

The fixture includes ongoing Metformin starting November 1, 2026, and Amoxicillin from November 20 through November 27, 2026. Start dates and any end dates are inclusive. The rows displayed depend on the device’s local date. The project uses Swift 5 language mode with Swift 5.9 or newer and complete concurrency checking in Debug and Release.

## Architecture

```text
 SwiftUI Today and medication detail
                  |
                  v
        @MainActor MediTrackModel <-------- NWPathMonitor + scene lifecycle
          |          |          ^
          |          |          |
          |          v          +---------- UserNotifications delegate
          |    LocalReminders                   Taken / Snooze
          |          |
          |          +--------------------> UNUserNotificationCenter
          v
  SwiftData MedicationStore <-------------- DoseSyncQueue (one worker)
          ^                                    |
          |                                    v
          +--- GET refresh <--------------- APIClient
                                               |
                                       HTTPTransport
                                  /                     \
                         Bundled fixture mock     URLSession adapter
```

- **MVVM and injection.** The composition root provides the clinic API, store, connectivity source, reminder service, clock and calendar to the observable view model. Views render values and forward user actions. The model, queue, and SwiftData context share the main actor. The mock transport is an actor, and HTTP requests exchange Sendable values.
- **Dates and statuses.** Doses follow Gregorian dates and local wall-clock times. An unlogged dose is Due now from 30 minutes before through 30 minutes after its scheduled time, then Missed. Taken and Skipped override the clock-based status. Duplicate times collapse into a single slot. In a spring clock change, a nonexistent time is moved forward while preserving its minute. In a fall overlap, the first occurrence is used.
- **Offline persistence.** The app reads SwiftData before refreshing. A successful GET replaces the prescription cache and keeps previous dose logs. A failed fetch leaves cached data in use. A single save records both the chosen status and its pending sync state. The UI updates as soon as that save succeeds. The first decision for a medication, local date and scheduled time wins, including notification actions.
- **Sync and retry.** Reconnecting, foregrounding, logging a dose and pulling to refresh can wake the worker. It serializes submissions and persists each attempt before sending. Retryable transport errors and HTTP 408, 425, 429 and 5xx use a persisted backoff of 2, 4, 8 and 16 seconds. A maximum of five automatic attempts applies per log, including across relaunches. Other HTTP errors move the log to Failed immediately. **Retry failed logs** starts a new attempt budget. The worker only starts network requests while foregrounded and reachable. iOS may suspend it in the background.
- **Idempotency.** Every retry reuses the same `Idempotency-Key` and original body, even after a device time-zone change. A 201 response marks the saved log synced. The mock accepts identical replays and rejects conflicting bodies for a received key while the process is running. A clinic server would need durable idempotency records scoped to the authenticated patient for safe replay across restarts. The mock returns 201 for about 70% of new POSTs and 500 otherwise.
- **Reminders.** One-shot system notifications are planned over the next 14 days, starting with today. At most 60 regular reminders are queued, leaving capacity for snoozes under the 64-request system limit. The app replenishes the window on foregrounding, refresh and significant clock changes. Taken follows the same local save path as the UI and removes the reminder. Snooze schedules another alert ten minutes later and retains the original dose identity. The window needs periodic app opens, and travel-related changes to already queued reminders take effect when the app next reconciles them.

## Tests

Verified with Xcode 26.5 on an iPhone 16 Pro simulator running iOS 18.5. All 18 XCTest cases passed. The Release simulator build passed.

Run **⌘U** in Xcode or use the following command with any installed iPhone simulator name.

```sh
xcodebuild -project MediTrack.xcodeproj -scheme MediTrack \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.5' test
```

The tests cover date boundaries, daylight saving, dose status, reminder planning and actions, POST encoding and idempotency, offline UI state, persistence across store opens, and the five-attempt retry cap. Test cases inject clocks and API outcomes, so they do not depend on the live date, real network, or randomized mock. To check system delivery, enable reminders, keep an unlogged dose near its scheduled time, then expand the delivered notification and choose **Snooze 10 min** or **Taken**. Reopen the app to check the original dose history after choosing Taken.

## Record a 2–3 minute demo

1. In **Product → Scheme → Edit Scheme → Run → Arguments**, add `-demo-controls` and `-demo-success` as separate launch arguments for a Debug run. This adds the **Simulate Offline** switch and makes the mock POST result deterministic for the recording.
2. Launch online and wait for the Today list. Start recording. Show the scheduled dose times and open a medication to show its prescription and dose history.
3. Go back to Today, scroll to **Demo controls**, and enable **Simulate Offline**. Swipe an unlogged row and tap **Taken**, or open its detail and tap **Mark Taken** or **Mark Skipped**. Show that Today and history already reflect the decision, with **Pending sync**.
4. Turn off **Simulate Offline**. When the banner says **All logs synced**, reopen the same medication and show **Synced** in its history. Mention that the offline switch exercises the queue and that normal runs use `NWPathMonitor` and the randomized mock.
5. On the Mac, use **⇧⌘5** to record the Simulator window or run `xcrun simctl io booted recordVideo MediTrack-demo.mov` and stop it with **Ctrl+C**. Use a fresh simulator or another unlogged dose if a previous run already logged the dose.

## Scope

The bundled mock is assessment data. The app holds the current prescription list and dose log snapshots in memory alongside durable SwiftData storage. Paging history, authentication, production patient-data policies and background uploads are outside the assessment implementation.
