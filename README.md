# Speaker Keep-Alive

A small macOS menu bar app that stops powered speakers from dropping into standby when the Mac goes quiet. It plays a short, near-inaudible tone every few minutes, on a schedule you choose. Each speaker model gets its own profile.

**Website:** https://edmuk.github.io/mac_audio_keep_alive/

## Why speakers fall asleep

Since 9 May 2025, EU [Regulation 2023/826](https://eur-lex.europa.eu/eli/reg/2023/826/oj) has required a wide range of household electronics, speakers included, to switch to a low-power mode after no more than 20 minutes without use. Powered speakers decide "unused" by watching the **level** of the incoming signal. The Mac isn't switching anything off.

For example, the [Majority D70X manual](https://www.richersounds.com/content/product_files/D70X_Active_User_Manual_Collection_NOV_2025.pdf) (p.8) says:

> If there is no activity/signal received from a connected device for up to 19 minutes, then the speakers will automatically switch to Standby Mode to save energy (ERP 2 standard). If the volume level of the audio source … is set to minimum, the D70X might recognise this as 'No Audio Signal'.

Three things follow from this:

- **Digital silence doesn't help.** An optical link that is up but carrying zeros still counts as "no signal". The speaker needs a real signal above its detection threshold.
- **The tone doesn't need to be continuous.** A few seconds of tone every 5 minutes resets a 19-minute timer.
- **A very low frequency is nearly inaudible.** Bookshelf speakers barely reproduce 18 Hz at -50 dBFS, but the speaker's level detector still registers it.

The Mac side matters less. macOS doesn't power down USB or optical ports. When nothing is playing, though, CoreAudio stops sending audio to the device. On a digital link this can clip the first moment of sound while the speaker re-locks. Profiles can keep the stream open between tones to avoid that.

## What it does

- Plays the tone to a **specific output device**, such as a USB optical adapter, whatever the system default output is. It keeps going to the speakers when you switch to AirPods or headphones.
- Runs **always**, **on a schedule** (per-weekday windows, including windows that run past midnight), or **off**. Menu overrides: keep the speakers awake for an hour or until midnight, or pause for an hour.
- Recovers when the device is unplugged and plugged back in, and after sleep and wake.
- Keeps an **event log** of status changes, audio devices (inputs included) disappearing and reappearing, the tone restarting, and sleep and wake. Open it with **Show Event Log** in the menu. It's at `~/Library/Logs/SpeakerKeepAlive/events.log`. If your speakers go off, note the time and check the log to see whether the link dropped then.
- Comes with **built-in profiles** (`Profiles/*.json`). You can duplicate and tune them, create your own, import and export JSON, and **submit a profile on GitHub** from inside the app.

The tone never keeps your Mac awake. Normally any running audio output stops macOS idle-sleeping, but the app opts out of that (`kAudioHardwarePropertySleepingIsAllowed`). When the Mac sleeps, the speakers follow it into standby.

## Install and build

Requires macOS 15 or later. Building needs Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
make run       # generate the project, build Debug, launch
make test      # unit tests (schedule, profiles, tone generator)
make release   # build Release into build/DerivedData/Build/Products/Release/
make install   # build Release, copy to /Applications and launch it
```

Run the app from `/Applications` (`make install`), not from the build folder. If the build folder is on an external drive that disconnects, for example when the Mac sleeps, the running app crashes. Then turn on **Launch at login** in Settings. The build is ad-hoc signed for local use. If you download a build someone else made, you may need to right-click › Open the first time.

On first launch the app picks an output whose name looks digital ("SPDIF", "Optical"…). You can change it in **Settings › General**.

The menu bar icon is a pair of bookshelf speakers: **filled** while it's keeping the speakers awake, **outlined** outside active hours, when paused or when off, and a single speaker with a **warning badge** if the output device is missing or audio couldn't start.

**Can't see the menu bar icon?** A crowded menu bar can hide it. Open the app again from Finder or Spotlight and Settings opens. In recent macOS versions you can also allow the icon under **System Settings › Menu Bar**.

## Tuning a profile

1. In **Settings › Profiles**, duplicate the closest built-in profile.
2. With your speaker volume at its usual setting, click **Test Tone**. You want to hear nothing, or almost nothing.
3. Go 30+ minutes without playing any audio, with the app active and the Mac awake. Does the speaker stay on?
   - If it still sleeps, raise the **level** 3–5 dB at a time. If that's audible before it works, try 30–40 Hz, because some speakers filter out very low frequencies before the level detector.
   - If it stays awake, try lowering the level until it fails, then go back up 5 dB for a safety margin.
4. Keep the **interval** comfortably below the speaker's standby timeout. The app won't save a profile where it isn't.

Avoid high levels at infrasonic frequencies. The tone is meant to sit just above the speaker's detection threshold, not drive the woofer.

## Profile format

```json
{
  "schemaVersion": 1,
  "id": "majority-d70x",
  "name": "Majority D70X",
  "manufacturer": "Majority",
  "model": "D70X",
  "connection": "optical",
  "standbyTimeoutMinutes": 19,
  "tone": {
    "frequencyHz": 18,
    "levelDBFS": -50,
    "burstSeconds": 3,
    "intervalSeconds": 300,
    "fadeMilliseconds": 50
  },
  "keepStreamOpen": true,
  "notes": "…",
  "sourceURL": "https://…",
  "tested": false
}
```

- `connection` is one of `optical`, `usb`, `hdmi`, `analog`, `bluetooth` or `other`.
- `tested` means someone has confirmed the profile keeps that speaker awake.
- Your own profiles are saved in `~/Library/Application Support/SpeakerKeepAlive/Profiles/`, one file per profile.

## Contributing a profile

Got a profile that works? In **Settings › Profiles**, choose **Share › Submit on GitHub…**. This opens a [pre-filled issue](https://github.com/EdMUK/mac_audio_keep_alive/issues/new?template=speaker-profile.yml) with your profile's JSON. Tested profiles get added to `Profiles/` and built into the app.

Pull requests are welcome too. Add the JSON to `Profiles/` and run `make test`, which checks that every built-in profile is valid and formatted exactly as the app exports it.

## Project layout

| Path | What |
| --- | --- |
| `Sources/KeepAliveCore/` | Framework with no UI: profiles and validation, schedule logic, the real-time tone generator |
| `Sources/SpeakerKeepAlive/` | The menu bar app: CoreAudio device handling, the audio engine, coordination, SwiftUI views |
| `Tests/KeepAliveCoreTests/` | Swift Testing suites for the core |
| `Profiles/` | Built-in speaker profiles, bundled into the app |
| `docs/` | GitHub Pages site |

## Licence

[MIT](LICENSE) © 2026 Ed Morley
