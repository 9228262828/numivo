import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NumivoApp());
}

enum GameMode { classic, timeRush, noMistake }

String modeLabel(GameMode m) => switch (m) {
  GameMode.classic => 'Classic',
  GameMode.timeRush => 'Time Rush',
  GameMode.noMistake => 'No Mistake',
};

String modeSubtitle(GameMode m) => switch (m) {
  GameMode.classic => 'Clear 5 boards as fast as possible.',
  GameMode.timeRush => 'Score as much as you can in 60 seconds.',
  GameMode.noMistake => 'One wrong number ends the run.',
};

IconData modeIcon(GameMode m) => switch (m) {
  GameMode.classic => Icons.grid_view_rounded,
  GameMode.timeRush => Icons.timer_rounded,
  GameMode.noMistake => Icons.warning_amber_rounded,
};

const cPurple = Color(0xFF7C3AED);
const cBlue = Color(0xFF2563EB);
const cCyan = Color(0xFF06B6D4);
const cGreen = Color(0xFF10B981);
const cAmber = Color(0xFFF59E0B);
const cRed = Color(0xFFEF4444);

Color modeColor(GameMode m) => switch (m) {
  GameMode.classic => cBlue,
  GameMode.timeRush => cCyan,
  GameMode.noMistake => cPurple,
};

String formatMs(int ms) {
  final s = max(0, ms);
  final total = s ~/ 1000;
  final min = total ~/ 60;
  final sec = total % 60;
  final tenth = (s % 1000) ~/ 100;
  return '${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}.$tenth';
}

class NumivoStore extends ChangeNotifier {
  bool ready = false, darkMode = false, haptics = true;
  int classicBestTime = 0, classicBestScore = 0, rushBestScore = 0;
  int noMistakeBestScore = 0, noMistakeBestBoards = 0;
  int gamesPlayed = 0, totalCorrect = 0, bestCombo = 0;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    classicBestTime = p.getInt('nbt') ?? 0;
    classicBestScore = p.getInt('nbs_c') ?? 0;
    rushBestScore = p.getInt('nbs_r') ?? 0;
    noMistakeBestScore = p.getInt('nbs_n') ?? 0;
    noMistakeBestBoards = p.getInt('nbb_n') ?? 0;
    gamesPlayed = p.getInt('ng') ?? 0;
    totalCorrect = p.getInt('ntc') ?? 0;
    bestCombo = p.getInt('nbc') ?? 0;
    darkMode = p.getBool('nd') ?? false;
    haptics = p.getBool('nh') ?? true;
    ready = true;
    notifyListeners();
  }

  int bestScore(GameMode m) => switch (m) {
    GameMode.classic => classicBestScore,
    GameMode.timeRush => rushBestScore,
    GameMode.noMistake => noMistakeBestScore,
  };

  Future<void> saveRun({required GameMode mode, required int score, required int elapsedMs, required int correct, required int combo, required int boards}) async {
    gamesPlayed++;
    totalCorrect += correct;
    if (combo > bestCombo) bestCombo = combo;
    switch (mode) {
      case GameMode.classic:
        if (classicBestTime == 0 || elapsedMs < classicBestTime) classicBestTime = elapsedMs;
        if (score > classicBestScore) classicBestScore = score;
        break;
      case GameMode.timeRush:
        if (score > rushBestScore) rushBestScore = score;
        break;
      case GameMode.noMistake:
        if (score > noMistakeBestScore) noMistakeBestScore = score;
        if (boards > noMistakeBestBoards) noMistakeBestBoards = boards;
        break;
    }
    final p = await SharedPreferences.getInstance();
    await p.setInt('nbt', classicBestTime);
    await p.setInt('nbs_c', classicBestScore);
    await p.setInt('nbs_r', rushBestScore);
    await p.setInt('nbs_n', noMistakeBestScore);
    await p.setInt('nbb_n', noMistakeBestBoards);
    await p.setInt('ng', gamesPlayed);
    await p.setInt('ntc', totalCorrect);
    await p.setInt('nbc', bestCombo);
    notifyListeners();
  }

  Future<void> setDark(bool v) async {
    darkMode = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('nd', v);
    notifyListeners();
  }

  Future<void> setHaptics(bool v) async {
    haptics = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('nh', v);
    notifyListeners();
  }

  Future<void> reset() async {
    classicBestTime = classicBestScore = rushBestScore = 0;
    noMistakeBestScore = noMistakeBestBoards = 0;
    gamesPlayed = totalCorrect = bestCombo = 0;
    final p = await SharedPreferences.getInstance();
    for (final k in ['nbt','nbs_c','nbs_r','nbs_n','nbb_n','ng','ntc','nbc']) {
      await p.remove(k);
    }
    notifyListeners();
  }
}

class GameController extends ChangeNotifier {
  static const tickMs = 100, rushMs = 60000, classicBoards = 5;
  final NumivoStore store;
  final GameMode mode;
  final Random random = Random();
  Timer? ticker, boardTimer;
  bool registered = false, paused = false, gameOver = false, success = false, transition = false;
  List<int> board = [], ordered = [];
  final Set<int> cleared = {};
  int next = 0, score = 0, combo = 0, runBestCombo = 0, correct = 0, wrong = 0, boards = 0, elapsed = 0, remaining = rushMs;
  int? wrongValue;

  GameController(this.store, this.mode);

  int get target => next < ordered.length ? ordered[next] : -1;
  int get boardSize => (6 + boards).clamp(6, 12).toInt();
  double get rushProgress => (remaining / rushMs).clamp(0.0, 1.0).toDouble();

  void start() {
    ticker?.cancel(); boardTimer?.cancel();
    registered = paused = gameOver = success = transition = false;
    score = combo = runBestCombo = correct = wrong = boards = elapsed = 0;
    remaining = rushMs; wrongValue = null;
    _newBoard();
    ticker = Timer.periodic(const Duration(milliseconds: tickMs), (_) => _tick());
    notifyListeners();
  }

  void togglePause() {
    if (gameOver || transition) return;
    paused = !paused; notifyListeners();
  }

  void tap(int value) {
    if (paused || gameOver || transition || cleared.contains(value)) return;
    if (value == target) {
      cleared.add(value); next++; correct++; combo++;
      if (combo > runBestCombo) runBestCombo = combo;
      score += 10 + min(combo, 10); wrongValue = null;
      if (next >= ordered.length) _boardDone();
    } else {
      wrong++; combo = 0; wrongValue = value;
      if (mode == GameMode.noMistake) {
        _finish(false); return;
      }
      score = max(0, score - 5);
    }
    notifyListeners();
  }

  void _tick() {
    if (paused || gameOver) return;
    elapsed += tickMs;
    if (mode == GameMode.timeRush) {
      remaining -= tickMs;
      if (remaining <= 0) { remaining = 0; _finish(false); return; }
    }
    notifyListeners();
  }

  void _boardDone() {
    if (gameOver || transition) return;
    boards++; score += 50 + boards * 5; transition = true;
    if (mode == GameMode.classic && boards >= classicBoards) {
      _finish(true); return;
    }
    boardTimer?.cancel();
    boardTimer = Timer(const Duration(milliseconds: 420), () {
      if (gameOver) return;
      _newBoard(); transition = false; notifyListeners();
    });
  }

  void _newBoard() {
    final values = <int>{};
    while (values.length < boardSize) { values.add(random.nextInt(89) + 10); }
    ordered = values.toList()..sort();
    board = List<int>.from(ordered)..shuffle(random);
    cleared.clear(); next = 0; wrongValue = null;
  }

  Future<void> _finish(bool ok) async {
    if (gameOver) return;
    gameOver = true; paused = transition = false; success = ok;
    ticker?.cancel(); boardTimer?.cancel();
    if (!registered) {
      registered = true;
      await store.saveRun(mode: mode, score: score, elapsedMs: elapsed, correct: correct, combo: runBestCombo, boards: boards);
    }
    notifyListeners();
  }

  @override
  void dispose() { ticker?.cancel(); boardTimer?.cancel(); super.dispose(); }
}

class NumivoApp extends StatefulWidget {
  const NumivoApp({super.key});
  @override State<NumivoApp> createState() => _NumivoAppState();
}

class _NumivoAppState extends State<NumivoApp> {
  final store = NumivoStore();
  @override void initState() { super.initState(); store.load(); }
  @override Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (_, __) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'NUMIVO',
      themeMode: store.darkMode ? ThemeMode.dark : ThemeMode.light,
      theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: cPurple), scaffoldBackgroundColor: const Color(0xFFF5F7FC)),
      darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark, colorScheme: ColorScheme.fromSeed(seedColor: cPurple, brightness: Brightness.dark), scaffoldBackgroundColor: const Color(0xFF060A12)),
      home: SplashScreen(store),
    ),
  );
}

class NumivoLogo extends StatelessWidget {
  final double size;
  const NumivoLogo({super.key, this.size = 64});
  @override Widget build(BuildContext context) => Container(
    width: size, height: size,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(size * .28),
      gradient: const LinearGradient(colors: [cPurple, cBlue, cCyan], begin: Alignment.topLeft, end: Alignment.bottomRight),
      boxShadow: [BoxShadow(color: cPurple.withOpacity(.25), blurRadius: size * .3, offset: Offset(0, size * .12))],
    ),
    child: Center(child: Text('123', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: size * .28, letterSpacing: -1))),
  );
}

class SplashScreen extends StatefulWidget {
  final NumivoStore store;
  const SplashScreen(this.store, {super.key});
  @override State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override void initState() { super.initState(); _go(); }
  Future<void> _go() async {
    while (!widget.store.ready) { await Future.delayed(const Duration(milliseconds: 40)); }
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => HomeScreen(widget.store)));
  }
  @override Widget build(BuildContext context) => const Scaffold(
    body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      NumivoLogo(size: 98), SizedBox(height: 20),
      Text('NUMIVO', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900, letterSpacing: 5)),
      SizedBox(height: 7), Text('THINK FAST • TAP RIGHT', style: TextStyle(color: cPurple, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
    ])),
  );
}

class HomeScreen extends StatelessWidget {
  final NumivoStore store;
  const HomeScreen(this.store, {super.key});

  @override Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (_, __) => Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 34),
          children: [
            Row(children: [
              const NumivoLogo(size: 58), const SizedBox(width: 13),
              const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('NUMIVO', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 3)),
                Text('NUMBER RUSH', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
              ])),
              IconButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => StatsScreen(store))), icon: const Icon(Icons.bar_chart_rounded)),
              IconButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen(store))), icon: const Icon(Icons.settings_outlined)),
            ]),
            const SizedBox(height: 30),
            const Text('Choose your number rush', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
            const SizedBox(height: 7),
            Text('Tap every number from smallest to largest.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 24),
            ...GameMode.values.map((m) => Padding(
              padding: const EdgeInsets.only(bottom: 13),
              child: _ModeCard(mode: m, store: store, onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => GameScreen(store: store, mode: m)))),
            )),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(26),
                gradient: const LinearGradient(colors: [Color(0xFF08111F), cPurple, cBlue], begin: Alignment.topLeft, end: Alignment.bottomRight),
              ),
              child: Row(children: [
                const Icon(Icons.calculate_rounded, color: Colors.white, size: 34), const SizedBox(width: 14),
                Expanded(child: Text(
                  store.gamesPlayed == 0 ? 'Your number stats start after the first run.' : '${store.gamesPlayed} games • ${store.totalCorrect} correct taps • Best combo ${store.bestCombo}',
                  style: const TextStyle(color: Colors.white, height: 1.45, fontWeight: FontWeight.w700),
                )),
              ]),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ModeCard extends StatelessWidget {
  final GameMode mode;
  final NumivoStore store;
  final VoidCallback onTap;
  const _ModeCard({required this.mode, required this.store, required this.onTap});

  @override Widget build(BuildContext context) {
    final color = modeColor(mode);
    final best = switch (mode) {
      GameMode.classic => store.classicBestTime == 0 ? 'NO BEST YET' : 'BEST ${formatMs(store.classicBestTime)}',
      GameMode.timeRush => 'BEST SCORE ${store.rushBestScore}',
      GameMode.noMistake => 'BEST ${store.noMistakeBestBoards} BOARDS',
    };
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(24), onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(19),
          child: Row(children: [
            Container(width: 58, height: 58, decoration: BoxDecoration(color: color.withOpacity(.12), borderRadius: BorderRadius.circular(18)), child: Icon(modeIcon(mode), color: color, size: 30)),
            const SizedBox(width: 15),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(modeLabel(mode), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
              const SizedBox(height: 3),
              Text(modeSubtitle(mode), style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 8),
              Text(best, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: .5)),
            ])),
            const Icon(Icons.play_arrow_rounded),
          ]),
        ),
      ),
    );
  }
}

class GameScreen extends StatefulWidget {
  final NumivoStore store;
  final GameMode mode;
  const GameScreen({super.key, required this.store, required this.mode});
  @override State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  late final GameController controller;
  bool navigated = false;

  @override void initState() {
    super.initState();
    controller = GameController(widget.store, widget.mode);
    controller.addListener(_watch);
    controller.start();
  }

  void _watch() {
    if (!mounted || !controller.gameOver || navigated) return;
    navigated = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ResultScreen(
        store: widget.store, mode: widget.mode, score: controller.score, elapsed: controller.elapsed,
        correct: controller.correct, wrong: controller.wrong, combo: controller.runBestCombo,
        boards: controller.boards, success: controller.success,
      )));
    });
  }

  @override void dispose() {
    controller.removeListener(_watch); controller.dispose(); super.dispose();
  }

  void _tap(int value) {
    final right = value == controller.target;
    controller.tap(value);
    if (!widget.store.haptics) return;
    right ? HapticFeedback.selectionClick() : HapticFeedback.mediumImpact();
  }

  @override Widget build(BuildContext context) {
    final color = modeColor(widget.mode);
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) => Scaffold(
        appBar: AppBar(
          title: Text(modeLabel(widget.mode).toUpperCase()),
          actions: [IconButton(onPressed: controller.togglePause, icon: Icon(controller.paused ? Icons.play_arrow_rounded : Icons.pause_rounded))],
        ),
        body: Stack(children: [
          SafeArea(top: false, child: Column(children: [
            Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 12), child: _stats(color)),
            if (widget.mode == GameMode.timeRush)
              Padding(padding: const EdgeInsets.symmetric(horizontal: 18), child: LinearProgressIndicator(minHeight: 8, borderRadius: BorderRadius.circular(99), value: controller.rushProgress, color: cCyan)),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Container(
                width: double.infinity, padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), color: color.withOpacity(.10), border: Border.all(color: color.withOpacity(.18))),
                child: Column(children: [
                  Text(controller.transition ? 'BOARD CLEARED!' : 'NEXT NUMBER', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.4)),
                  const SizedBox(height: 4),
                  Text(controller.transition ? '+${50 + controller.boards * 5}' : '${controller.target}', style: TextStyle(color: color, fontSize: 42, fontWeight: FontWeight.w900)),
                ]),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(18, 0, 18, 18), child: _board())),
          ])),
          if (controller.paused) _pauseOverlay(),
        ]),
      ),
    );
  }

  Widget _stats(Color color) {
    final third = widget.mode == GameMode.timeRush ? '${(controller.remaining / 1000).ceil().clamp(0, 60)}s' : widget.mode == GameMode.classic ? '${controller.boards}/5' : '${controller.boards}';
    return Row(children: [
      Expanded(child: _Stat(value: '${controller.score}', label: 'SCORE', color: color, icon: Icons.bolt_rounded)),
      const SizedBox(width: 8),
      Expanded(child: _Stat(value: '${controller.combo}', label: 'COMBO', color: cAmber, icon: Icons.local_fire_department_rounded)),
      const SizedBox(width: 8),
      Expanded(child: _Stat(value: third, label: widget.mode == GameMode.timeRush ? 'TIME' : 'BOARDS', color: widget.mode == GameMode.timeRush ? cCyan : cGreen, icon: widget.mode == GameMode.timeRush ? Icons.timer_rounded : Icons.layers_rounded)),
    ]);
  }

  Widget _board() {
    final n = controller.board.length;
    final columns = n <= 6 ? 2 : n <= 9 ? 3 : 4;
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(), itemCount: n,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: columns, crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: 1.15),
      itemBuilder: (_, i) {
        final value = controller.board[i];
        final done = controller.cleared.contains(value);
        final bad = controller.wrongValue == value;
        final color = modeColor(widget.mode);
        return GestureDetector(
          onTap: done ? null : () => _tap(value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: done ? cGreen.withOpacity(.12) : bad ? cRed.withOpacity(.15) : Theme.of(context).colorScheme.surface,
              border: Border.all(color: done ? cGreen.withOpacity(.45) : bad ? cRed.withOpacity(.55) : color.withOpacity(.14), width: bad ? 2 : 1),
            ),
            child: Center(child: done ? const Icon(Icons.check_rounded, color: cGreen, size: 30) : Text('$value', style: TextStyle(color: bad ? cRed : Theme.of(context).colorScheme.onSurface, fontSize: 25, fontWeight: FontWeight.w900))),
          ),
        );
      },
    );
  }

  Widget _pauseOverlay() => Positioned.fill(
    child: ColoredBox(
      color: Theme.of(context).colorScheme.surface.withOpacity(.96),
      child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.pause_circle_filled_rounded, size: 74, color: cPurple),
        const SizedBox(height: 16), const Text('PAUSED', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 2)),
        const SizedBox(height: 18),
        SizedBox(width: 220, child: FilledButton.icon(onPressed: controller.togglePause, icon: const Icon(Icons.play_arrow_rounded), label: const Text('RESUME'))),
        const SizedBox(height: 9),
        SizedBox(width: 220, child: OutlinedButton.icon(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.home_outlined), label: const Text('BACK HOME'))),
      ])),
    ),
  );
}

class _Stat extends StatelessWidget {
  final String value, label;
  final Color color;
  final IconData icon;
  const _Stat({required this.value, required this.label, required this.color, required this.icon});
  @override Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: color.withOpacity(.10), border: Border.all(color: color.withOpacity(.18)), borderRadius: BorderRadius.circular(20)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: color), const SizedBox(height: 9),
      Text(value, style: TextStyle(color: color, fontSize: 21, fontWeight: FontWeight.w900)),
      Text(label, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: .8)),
    ]),
  );
}

class ResultScreen extends StatelessWidget {
  final NumivoStore store;
  final GameMode mode;
  final int score, elapsed, correct, wrong, combo, boards;
  final bool success;
  const ResultScreen({super.key, required this.store, required this.mode, required this.score, required this.elapsed, required this.correct, required this.wrong, required this.combo, required this.boards, required this.success});

  @override Widget build(BuildContext context) {
    final color = modeColor(mode);
    final title = mode == GameMode.classic && success ? 'CLASSIC CLEARED!' : mode == GameMode.timeRush ? 'TIME IS UP!' : 'RUN COMPLETE';
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 40, 22, 30),
          children: [
            Center(child: Container(width: 92, height: 92, decoration: BoxDecoration(shape: BoxShape.circle, color: color.withOpacity(.12)), child: Icon(success ? Icons.emoji_events_rounded : Icons.flag_rounded, color: color, size: 48))),
            const SizedBox(height: 20),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 29, fontWeight: FontWeight.w900, letterSpacing: 1.1)),
            const SizedBox(height: 7),
            Text(modeLabel(mode), textAlign: TextAlign.center, style: TextStyle(color: color, fontWeight: FontWeight.w900)),
            const SizedBox(height: 28),
            Row(children: [
              Expanded(child: _Stat(value: '$score', label: 'SCORE', color: color, icon: Icons.bolt_rounded)),
              const SizedBox(width: 10),
              Expanded(child: _Stat(value: '$boards', label: 'BOARDS', color: cGreen, icon: Icons.layers_rounded)),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: _Stat(value: '$correct', label: 'CORRECT', color: cCyan, icon: Icons.check_circle_outline_rounded)),
              const SizedBox(width: 10),
              Expanded(child: _Stat(value: '$combo', label: 'BEST COMBO', color: cAmber, icon: Icons.local_fire_department_rounded)),
            ]),
            if (mode == GameMode.classic) ...[
              const SizedBox(height: 10),
              _Stat(value: formatMs(elapsed), label: 'FINISH TIME', color: cPurple, icon: Icons.timer_outlined),
            ],
            if (wrong > 0) ...[
              const SizedBox(height: 10),
              _Stat(value: '$wrong', label: 'WRONG TAPS', color: cRed, icon: Icons.close_rounded),
            ],
            const SizedBox(height: 26),
            FilledButton.icon(
              onPressed: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => GameScreen(store: store, mode: mode))),
              icon: const Icon(Icons.replay_rounded), label: const Padding(padding: EdgeInsets.all(14), child: Text('PLAY AGAIN')),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.home_outlined), label: const Padding(padding: EdgeInsets.all(14), child: Text('BACK HOME'))),
          ],
        ),
      ),
    );
  }
}

class StatsScreen extends StatelessWidget {
  final NumivoStore store;
  const StatsScreen(this.store, {super.key});
  @override Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (_, __) => Scaffold(
      appBar: AppBar(title: const Text('STATISTICS')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('Number record', style: TextStyle(fontSize: 29, fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          Text('Your games, correct taps, combos, and best results.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(child: _Stat(value: '${store.gamesPlayed}', label: 'GAMES', color: cPurple, icon: Icons.sports_esports_rounded)),
            const SizedBox(width: 10),
            Expanded(child: _Stat(value: '${store.totalCorrect}', label: 'CORRECT TAPS', color: cGreen, icon: Icons.done_all_rounded)),
          ]),
          const SizedBox(height: 10),
          _Stat(value: '${store.bestCombo}', label: 'BEST COMBO', color: cAmber, icon: Icons.local_fire_department_rounded),
          const SizedBox(height: 24),
          _record('Classic', store.classicBestTime == 0 ? 'No completed game yet' : 'Best time ${formatMs(store.classicBestTime)}', '${store.classicBestScore}', cBlue, Icons.grid_view_rounded),
          const SizedBox(height: 10),
          _record('Time Rush', 'Best score in 60 seconds', '${store.rushBestScore}', cCyan, Icons.timer_rounded),
          const SizedBox(height: 10),
          _record('No Mistake', 'Best ${store.noMistakeBestBoards} boards', '${store.noMistakeBestScore}', cPurple, Icons.warning_amber_rounded),
        ],
      ),
    ),
  );

  Widget _record(String title, String subtitle, String value, Color color, IconData icon) => Card(
    child: ListTile(
      contentPadding: const EdgeInsets.all(16),
      leading: CircleAvatar(child: Icon(icon)),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
      subtitle: Text(subtitle),
      trailing: Text(value, style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.w900)),
    ),
  );
}

class SettingsScreen extends StatelessWidget {
  final NumivoStore store;
  const SettingsScreen(this.store, {super.key});

  @override Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (_, __) => Scaffold(
      appBar: AppBar(title: const Text('SETTINGS')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(child: Column(children: [
            SwitchListTile(value: store.darkMode, onChanged: store.setDark, secondary: const Icon(Icons.dark_mode_outlined), title: const Text('Dark mode')),
            const Divider(height: 1),
            SwitchListTile(value: store.haptics, onChanged: store.setHaptics, secondary: const Icon(Icons.vibration_rounded), title: const Text('Haptic feedback')),
          ])),
          const SizedBox(height: 12),
          Card(child: Column(children: [
            ListTile(leading: const Icon(Icons.privacy_tip_outlined), title: const Text('Privacy Policy'), trailing: const Icon(Icons.chevron_right_rounded), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LegalScreen(title: 'Privacy Policy', body: privacyText)))),
            const Divider(height: 1),
            ListTile(leading: const Icon(Icons.description_outlined), title: const Text('Terms & Conditions'), trailing: const Icon(Icons.chevron_right_rounded), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LegalScreen(title: 'Terms & Conditions', body: termsText)))),
          ])),
          const SizedBox(height: 12),
          Card(child: ListTile(textColor: cRed, iconColor: cRed, leading: const Icon(Icons.delete_sweep_outlined), title: const Text('Reset progress'), subtitle: const Text('Delete best results and statistics.'), onTap: () => _reset(context))),
        ],
      ),
    ),
  );

  Future<void> _reset(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Reset all progress?'),
        content: const Text('Best scores, times, and statistics will be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('CANCEL')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('RESET')),
        ],
      ),
    );
    if (ok == true) await store.reset();
  }
}

const privacyText = '''NUMIVO PRIVACY POLICY

NUMIVO is an offline-first number puzzle game. The current core version does not require an account, login, Firebase, backend services, advertising, cloud sync, or behavioral analytics.

The game stores limited gameplay information locally on your device, including best scores, Classic best time, No Mistake best boards, games played, total correct taps, best combo, dark-mode preference, and haptic-feedback preference.

This information is used only to provide local game progress, statistics, preferences, and best-result features.

The current core version does not require access to your location, camera, microphone, contacts, phone, SMS, calendar, photos, files, or payment information.

NUMIVO does not intentionally sell or rent your locally stored gameplay information and does not use gameplay data for personalized advertising.

You can reset gameplay progress from Settings. Clearing application storage or uninstalling the app may also remove locally stored information, subject to operating-system backup and restore behavior.

If future versions add accounts, cloud sync, analytics, crash reporting, advertising, online multiplayer, payments, leaderboards, or additional permissions, this policy should be reviewed and updated before release.''';

const termsText = '''NUMIVO TERMS & CONDITIONS

NUMIVO is a casual number puzzle game intended for entertainment.

Scores, timers, number order, boards, combos, correct taps, wrong taps, and statistics are calculated from gameplay and are provided for entertainment and personal progress tracking.

The current core version stores progress locally. We do not guarantee recovery of scores or settings after uninstalling the app, clearing app data, device loss, storage failure, or operating-system changes.

NUMIVO is provided on an "as available" basis to the extent permitted by applicable law. Features may be improved, changed, added, or removed in future versions.

You are responsible for using the game in a safe and appropriate environment. Do not use the game when doing so could distract you from driving, operating machinery, or another activity requiring attention.''';

class LegalScreen extends StatelessWidget {
  final String title, body;
  const LegalScreen({super.key, required this.title, required this.body});
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: ListView(padding: const EdgeInsets.all(20), children: [SelectableText(body, style: const TextStyle(height: 1.7))]),
  );
}
