NUMIVO — Number Rush
Tagline: Think fast. Tap right.
Package: com.numivo.numberrush

Add to pubspec.yaml:

shared_preferences: ^2.3.2

Included:
- Splash Screen
- Home Screen
- Classic: clear 5 boards
- Time Rush: 60 seconds
- No Mistake: first wrong tap ends the run
- Random unique number boards
- Tap numbers smallest to largest
- Progressive board size from 6 to 12 numbers
- Score / combo / correct / wrong feedback
- Best Classic time
- Best score per mode
- Best No Mistake boards
- Pause / Resume
- Result Screen / Play Again
- Statistics
- Dark Mode / Haptic feedback
- Privacy Policy / Terms
- Reset Progress
- SharedPreferences persistence

No Flame
No physics engine
No Firebase
No backend
No login
No ads
No analytics
No image or audio assets required

Stability safeguards:
- Entire app is in lib/main.dart to avoid missing local class/import issues.
- Only constant Material Icons are used.
- Main ticker and board transition timers are cancelled in dispose().
- Result navigation is guarded against duplicate pushes.
- Each run is registered only once.
- Board numbers are unique.
- Input is disabled during board transitions.
