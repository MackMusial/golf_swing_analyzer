# Golf Swing Analyzer

A phone app that tracks your joints in a golf swing video and critiques the swing.

## Easy way (Windows): two double-clicks

1. Download the project: on https://github.com/MackMusial/golf_swing_analyzer click **Code → Download ZIP**. Right-click the downloaded zip and choose **Extract All**, then open the extracted folder.
   - Don't run anything from inside the zip window. The scripts need the extracted files.
2. Double-click **`Setup.bat`**. If Windows shows "Windows protected your PC", click **More info → Run anyway**. Click **Yes** when Windows asks for permission. It installs everything (Git, Java, Flutter, the Android SDK and an emulator), which is about 5 GB and 20–60 minutes. Run it only once.
   - If it says **RESTART YOUR PC** at the end, restart.
3. Double-click **`Run.bat`**. A phone window (the emulator) opens and boots, then the app builds and opens on it. The first build takes several minutes. After that it's fast.
   - If an Android phone with USB debugging is plugged in, Run.bat uses the phone instead of the emulator.

**To test with a swing video:** drag an `.mp4` onto the emulator window, then in the app tap **Upload from library**.

If Setup.bat fails, the error and a `setup.log` file say why. Fix the problem and run it again. Finished steps get skipped. If the emulator won't start even after a restart, turn on virtualization (Intel VT-x / AMD-V / SVM) in the PC's BIOS settings.

The manual steps below do the same thing by hand.

---

## Part 1: Install everything by hand (one time)

These steps start from a brand-new Windows 10/11 PC with nothing installed. Setup takes about 30–60 minutes, mostly downloads.

### 1. Install Git and Android Studio
Click Start, type **PowerShell**, open it, and paste:
```
winget install --id Git.Git -e
winget install --id Google.AndroidStudio -e
```
Click **Yes** on any pop-ups. If it asks to agree to terms, type `Y` and press Enter.

### 2. Set up Android Studio
1. Open **Android Studio** from the Start menu.
2. Click through the setup wizard with **Next**, choose **Standard**, accept every license, and click **Finish**. This downloads the Android SDK and takes a while.
3. On the welcome screen, click **More Actions → SDK Manager**.
4. Go to the **SDK Tools** tab, check **Android SDK Command-line Tools (latest)**, then click **Apply** and **OK**.
5. Click **More Actions → Virtual Device Manager**. Click **+** (Create device), pick **Pixel 8** (any Pixel works), click **Next**, then click **Finish**. This is your fake phone (the emulator).

### 3. Install Flutter
1. Download the Flutter SDK zip (Windows, **stable**): https://docs.flutter.dev/install/archive
2. Make a folder `C:\dev` and extract the zip into it, so you end up with `C:\dev\flutter\bin`.
   - Don't put it in `Program Files` or a OneDrive folder.
3. Add Flutter to your PATH:
   - Start menu → type **environment** → open **Edit environment variables for your account**.
   - Under *User variables*, select **Path** → **Edit** → **New** → type `C:\dev\flutter\bin` → **OK** → **OK**.

### 4. Turn on Developer Mode
Start menu → type **developer settings** → open it → turn **Developer Mode** On → **Yes**.
(Flutter needs this. Without it you get "Building with plugins requires symlink support".)

### 5. Finish setup
**Close every PowerShell window**, then open a new one so it picks up the new PATH. Paste:
```
flutter doctor --android-licenses
```
Type `y` and press Enter at every question. Then run:
```
flutter doctor
```
You want green checks next to **Flutter** and **Android toolchain**. Red X's for **Visual Studio** or **Chrome** are fine to ignore.

### 6. Get the project
Git is installed from step 1, so in PowerShell run:
```
cd C:\dev
git clone https://github.com/MackMusial/golf_swing_analyzer.git
```
This puts the project in `C:\dev\golf_swing_analyzer`. Or download the ZIP as in the easy way and extract it there.

---

## Part 2: Run the app

### On the emulator (fake phone on the PC)
1. Open Android Studio → **More Actions → Virtual Device Manager** → click ▶ next to your Pixel. Wait until the phone shows its home screen.
2. In PowerShell:
   ```
   cd C:\dev\golf_swing_analyzer
   flutter run
   ```
   (Use your folder path if you put the project somewhere else. If it asks which device, type the number next to the emulator.)

The first run takes a few minutes. Then the app opens on the emulator.

To test with a swing video, drag an `.mp4` file onto the emulator window. It lands in the emulator's Downloads, and you can pick it with **Upload from library**.

### On a real Android phone
1. On the phone: Settings → About phone → tap **Build number** 7 times. Then Settings → System → Developer options → turn on **USB debugging**.
2. Plug the phone into the PC with a USB cable and tap **Allow** on the phone.
3. In PowerShell:
   ```
   cd C:\dev\golf_swing_analyzer
   flutter run --release
   ```
The app stays on the phone after you unplug it.

**No cable?** Build an install file:
```
cd C:\dev\golf_swing_analyzer
flutter build apk --release
```
Send `build\app\outputs\flutter-apk\app-release.apk` to the phone (Google Drive works). Open it on the phone and tap **Install**. If Android warns about unknown apps, allow it.

### On an iPhone
**You can't do this from Windows.** Apple only allows iPhone apps to be built on a Mac. On a Mac:
1. Install **Xcode** (App Store) and **Flutter** (https://docs.flutter.dev/get-started/install/macos), then run `sudo gem install cocoapods` in Terminal.
2. Copy the project over, open Terminal in the folder, and run:
   ```
   flutter pub get
   cd ios && pod install && cd ..
   ```
3. Open `ios/Runner.xcworkspace` in Xcode → click **Runner** → **Signing & Capabilities** → under **Team**, sign in with your Apple ID. If it says the bundle ID is taken, change it to something unique.
4. Plug in the iPhone, tap **Trust**, and turn on Settings → Privacy & Security → **Developer Mode** (the phone restarts).
5. Run `flutter run --release`
6. On the iPhone: Settings → General → VPN & Device Management → tap your Apple ID → **Trust**.

With a free Apple ID the app stops opening after 7 days. Repeat step 5 to reinstall.

---

## If something breaks

| Problem | Fix |
|---|---|
| `flutter` is not recognized | Close **all** terminals and VS Code, then reopen. Still broken? Check that the PATH entry from step 3 is exactly `C:\dev\flutter\bin`. |
| "requires symlink support" | Turn on Developer Mode (step 4). |
| "No pubspec.yaml file found" | You're in the wrong folder. `cd` into `golf_swing_analyzer`. |
| "Android license status unknown" | Run `flutter doctor --android-licenses` and answer `y` to everything. |
| "cmdline-tools component is missing" | Redo step 2.4. |
| `flutter run` says no devices | Start the emulator first, or check that the phone's USB debugging popup was allowed. |
| App opens then closes right away | Run `flutter clean`, then `flutter run` again. |
