import 'package:flutter/material.dart';

import '../core/alignment_service.dart';
import '../core/word_token.dart';
import '../data/quran_repository.dart';
import '../engine/murojaah_engine.dart';
import '../stt/onnx_stt.dart';
import '../stt/simulated_stt.dart';
import 'app_theme.dart';

enum _Mode { idle, mic, sim, manual }

String _arNum(int n) => n.toString().split('').map((c) {
      const d = '٠١٢٣٤٥٦٧٨٩';
      final i = int.tryParse(c);
      return i == null ? c : d[i];
    }).join();

class MurojaahPage extends StatefulWidget {
  final QuranRepository repo;
  const MurojaahPage({super.key, required this.repo});

  @override
  State<MurojaahPage> createState() => _MurojaahPageState();
}

class _MurojaahPageState extends State<MurojaahPage> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  final _manualCtrl = TextEditingController();

  List<SurahMeta> _surahs = [];
  int _surahId = 1;
  int _ayahNumber = 1;
  int _ayahCount = 7;
  bool _strict = false;
  bool _ready = false;
  bool _bannerOpen = true;
  _Mode _mode = _Mode.idle;

  List<String> _words = [];
  MurojaahEngine? _engine;
  SimulatedStt? _sim;
  OnnxStt? _onnx;

  AlignmentConfig get _cfg => AlignmentConfig(strict: _strict);

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 2000))
      ..repeat();
    _init();
  }

  Future<void> _init() async {
    final surahs = await widget.repo.surahs();
    _surahId = surahs.first.id;
    _ayahCount = surahs.first.ayahCount;
    _words = await widget.repo.ayahWords(_surahId, _ayahNumber);
    final engine = MurojaahEngine(_words, cfg: _cfg)..addListener(_onEngine);
    if (!mounted) return;
    setState(() {
      _surahs = surahs;
      _engine = engine;
      _ready = true;
    });
  }

  void _onEngine() {
    if (mounted) setState(() {});
  }

  Future<void> _loadAyah() async {
    await _engine?.detach();
    _words = await widget.repo.ayahWords(_surahId, _ayahNumber);
    _engine?.load(_words, _cfg);
    _manualCtrl.clear();
    if (mounted) setState(() => _mode = _Mode.idle);
  }

  void _onSurahChanged(int? id) {
    if (id == null) return;
    final meta = _surahs.firstWhere((s) => s.id == id);
    setState(() {
      _surahId = id;
      _ayahCount = meta.ayahCount;
      _ayahNumber = 1;
    });
    _loadAyah();
  }

  void _navAyah(int delta) {
    final next = _ayahNumber + delta;
    if (next < 1 || next > _ayahCount) return;
    setState(() => _ayahNumber = next);
    _loadAyah();
  }

  void _toggleStrict() {
    setState(() => _strict = !_strict);
    _engine?.load(_words, _cfg);
    _manualCtrl.clear();
    setState(() => _mode = _Mode.idle);
  }

  Future<void> _simulate() async {
    await _engine?.detach();
    _manualCtrl.clear();
    _sim = SimulatedStt(_words);
    await _engine?.attach(_sim!);
    if (mounted) setState(() => _mode = _Mode.sim);
  }

  Future<void> _toggleMic() async {
    final engine = _engine;
    if (engine == null) return;
    if (engine.isListening) {
      await engine.detach();
      setState(() => _mode = _Mode.idle);
      return;
    }
    try {
      // The model is resolved from a bundled asset in production. Until it's
      // present, OnnxStt's constructor throws (native lib / model missing).
      final modelPath = await _resolveModelPath();
      _onnx = OnnxStt(modelPath: modelPath, accel: true);
      await engine.attach(_onnx!);
      setState(() => _mode = _Mode.mic);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'On-device AI belum aktif: $e\nLihat README → assets/models + native build. Sementara pakai Simulasi / input manual.'),
        duration: const Duration(seconds: 5),
      ));
    }
  }

  Future<String> _resolveModelPath() async {
    // TODO: copy assets/models/quran_ctc_int8.onnx to a file path and return it.
    throw 'model on-device belum dibundle';
  }

  void _onManual(String v) {
    _engine?.setManual(v);
    setState(() => _mode = _Mode.manual);
  }

  Future<void> _reset() async {
    await _engine?.detach();
    _engine?.reset();
    _manualCtrl.clear();
    setState(() => _mode = _Mode.idle);
  }

  @override
  void dispose() {
    _pulse.dispose();
    _manualCtrl.dispose();
    _sim?.dispose();
    _onnx?.dispose();
    _engine?.dispose();
    super.dispose();
  }

  Color _statusColor(WordStatus s) {
    switch (s) {
      case WordStatus.correct:
        return AppColors.correct;
      case WordStatus.wrong:
        return AppColors.wrong;
      case WordStatus.waiting:
        return AppColors.waiting;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready || _engine == null) {
      return const Scaffold(
        backgroundColor: AppColors.bg0,
        body: Center(child: CircularProgressIndicator(color: AppColors.emerald)),
      );
    }
    return Scaffold(
      body: Stack(
        children: [
          const _Backdrop(),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 22, 18, 40),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _header(),
                      if (_bannerOpen) ...[const SizedBox(height: 18), _banner()],
                      const SizedBox(height: 20),
                      _controls(),
                      const SizedBox(height: 22),
                      _roundel(),
                      _mushaf(context),
                      const SizedBox(height: 14),
                      _legend(),
                      const SizedBox(height: 24),
                      _actions(),
                      const SizedBox(height: 22),
                      _manualInput(),
                      const SizedBox(height: 22),
                      _stats(),
                      const SizedBox(height: 26),
                      _footer(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- sections ----------
  Widget _header() {
    final (label, color) = switch (_mode) {
      _Mode.mic => ('● mendengarkan', AppColors.wrongSoft),
      _Mode.sim => ('▶ simulasi', AppColors.goldSoft),
      _Mode.manual => ('✎ manual', AppColors.muted),
      _Mode.idle => ('idle', AppColors.muted),
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('MUROJAAH · مراجعة',
                  style: TextStyle(
                      color: AppColors.goldSoft,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 3.2)),
              const SizedBox(height: 6),
              const Text('Real-Time Recitation Checker',
                  style: TextStyle(
                      color: Color(0xFFF6F1E4),
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      height: 1.05)),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: color.withOpacity(.12),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: color.withOpacity(.4)),
          ),
          child: Text(label,
              style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }

  Widget _banner() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 8, 13),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.emerald.withOpacity(.07), Colors.white.withOpacity(.012)],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, color: AppColors.emeraldSoft, size: 18),
          const SizedBox(width: 11),
          const Expanded(
            child: Text(
              'Engine alignment · normalisasi · stabilizer · coloring di sini versi final. '
              'STT default = Simulasi/Manual. Tombol Mic memakai jalur ONNX on-device — aktif begitu model + native core dipasang (README).',
              style: TextStyle(color: Color(0xFFCFC9B8), fontSize: 12.5, height: 1.5),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18, color: AppColors.muted),
            onPressed: () => setState(() => _bannerOpen = false),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _controls() {
    return Wrap(
      spacing: 14,
      runSpacing: 14,
      crossAxisAlignment: WrapCrossAlignment.end,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const _Label('SURAH'),
            const SizedBox(height: 7),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(.03),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: AppColors.line),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: _surahId,
                  dropdownColor: const Color(0xFF13201A),
                  icon: const Icon(Icons.expand_more, color: AppColors.goldSoft, size: 18),
                  style: const TextStyle(
                      color: AppColors.ink, fontSize: 14, fontWeight: FontWeight.w500),
                  items: _surahs
                      .map((s) => DropdownMenuItem<int>(
                            value: s.id,
                            child: Text('${s.id}. ${s.latin} — ${s.ar}'),
                          ))
                      .toList(),
                  onChanged: _onSurahChanged,
                ),
              ),
            ),
          ],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const _Label('AYAT'),
            const SizedBox(height: 7),
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(.03),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: AppColors.line),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _NavBtn(Icons.chevron_left, _ayahNumber > 1 ? () => _navAyah(-1) : null),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text.rich(TextSpan(children: [
                      TextSpan(
                          text: '$_ayahNumber',
                          style: const TextStyle(
                              color: AppColors.ink, fontWeight: FontWeight.w700, fontSize: 14.5)),
                      TextSpan(
                          text: ' / $_ayahCount',
                          style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                    ])),
                  ),
                  _NavBtn(Icons.chevron_right,
                      _ayahNumber < _ayahCount ? () => _navAyah(1) : null),
                ],
              ),
            ),
          ],
        ),
        _StrictToggle(value: _strict, onTap: _toggleStrict),
      ],
    );
  }

  Widget _roundel() {
    return Center(
      child: Transform.translate(
        offset: const Offset(0, 16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF16261D), Color(0xFF0F1C15)]),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: AppColors.gold.withOpacity(.4)),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(.45), blurRadius: 22, offset: const Offset(0, 6))
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_surahs.firstWhere((s) => s.id == _surahId).ar,
                  style: const TextStyle(
                      fontFamily: kArabicFont, color: AppColors.goldSoft, fontSize: 18)),
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 10),
                width: 1,
                height: 16,
                color: AppColors.gold.withOpacity(.3),
              ),
              Text(_arNum(_ayahNumber),
                  style: const TextStyle(
                      fontFamily: kArabicFont, color: AppColors.emeraldSoft, fontSize: 15)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mushaf(BuildContext context) {
    final engine = _engine!;
    final double fs =
        (MediaQuery.of(context).size.width * 0.072).clamp(24.0, 38.0).toDouble();
    final next = engine.nextIndex;
    final spans = <InlineSpan>[];
    for (var i = 0; i < engine.tokens.length; i++) {
      final t = engine.tokens[i];
      final isNext = _mode != _Mode.idle && i == next;
      spans.add(TextSpan(
        text: t.display + (i < engine.tokens.length - 1 ? ' ' : ''),
        style: TextStyle(
          color: _statusColor(t.status),
          backgroundColor: isNext ? AppColors.gold.withOpacity(.22) : null,
          decoration: t.status == WordStatus.wrong ? TextDecoration.underline : null,
          decorationColor: AppColors.wrong.withOpacity(.7),
          decorationStyle: TextDecorationStyle.wavy,
        ),
      ));
    }
    spans.add(TextSpan(
      text: '  \u06DD${_arNum(_ayahNumber)}',
      style: TextStyle(color: AppColors.gold, fontSize: fs * .8, fontFamily: kArabicFont),
    ));

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.parch, AppColors.parch2]),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.gold.withOpacity(.5), width: 2),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(.5), blurRadius: 44, offset: const Offset(0, 20))
        ],
      ),
      child: Stack(
        children: [
          const Positioned(top: 12, left: 12, child: _Corner(true, true)),
          const Positioned(top: 12, right: 12, child: _Corner(true, false)),
          const Positioned(bottom: 12, left: 12, child: _Corner(false, true)),
          const Positioned(bottom: 12, right: 12, child: _Corner(false, false)),
          Padding(
            padding: const EdgeInsets.fromLTRB(26, 40, 26, 34),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: RichText(
                textAlign: TextAlign.center,
                text: TextSpan(
                  style: TextStyle(
                      fontFamily: kArabicFont,
                      fontSize: fs,
                      height: 2.05,
                      color: AppColors.parchInk),
                  children: spans,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _legend() {
    Widget dot(Color c, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 9, height: 9, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 7),
          Text(t, style: const TextStyle(color: AppColors.muted, fontSize: 12.5)),
        ]);
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 20,
      children: [
        dot(AppColors.emeraldSoft, 'benar'),
        dot(AppColors.wrong, 'salah'),
        dot(AppColors.waiting, 'belum'),
      ],
    );
  }

  Widget _actions() {
    final listening = _engine!.isListening;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
        GestureDetector(
          onTap: _toggleMic,
          child: SizedBox(
            width: 86,
            height: 86,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (listening)
                  AnimatedBuilder(
                    animation: _pulse,
                    builder: (_, __) {
                      final v = _pulse.value;
                      return Container(
                        width: 74 * (1 + v * .7),
                        height: 74 * (1 + v * .7),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: AppColors.wrongSoft.withOpacity(.5 * (1 - v)), width: 2),
                        ),
                      );
                    },
                  ),
                Container(
                  width: 74,
                  height: 74,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      center: const Alignment(-.3, -.4),
                      colors: listening
                          ? const [AppColors.wrongSoft, Color(0xFF9C2A2A)]
                          : const [AppColors.emeraldSoft, AppColors.emeraldDeep],
                    ),
                    border: Border.all(color: AppColors.goldSoft.withOpacity(.6), width: 2),
                    boxShadow: [
                      BoxShadow(
                          color: (listening ? AppColors.wrong : AppColors.emeraldDeep)
                              .withOpacity(.5),
                          blurRadius: 30,
                          offset: const Offset(0, 12)),
                    ],
                  ),
                  child: Icon(listening ? Icons.stop_rounded : Icons.mic_rounded,
                      color: listening ? Colors.white : const Color(0xFF06140D), size: 30),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(listening ? 'Berhenti merekam' : 'Mulai murojaah',
                style: const TextStyle(
                    color: Color(0xFFF4EEDD), fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(listening ? 'ucapkan ayatnya…' : 'mic offline-AI (butuh model)',
                style: const TextStyle(color: AppColors.muted, fontSize: 12.5)),
          ],
        )),
        ]),
        const SizedBox(height: 18),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        _Btn(icon: Icons.auto_awesome, label: 'Simulasi', onTap: _simulate, primary: true),
        const SizedBox(width: 10),
        _Btn(icon: Icons.refresh, label: 'Reset', onTap: _reset, primary: false),
        ]),
      ],
    );
  }

  Widget _manualInput() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(children: [
          Icon(Icons.keyboard_alt_outlined, size: 15, color: AppColors.muted),
          SizedBox(width: 7),
          _Label('UJI MANUAL — KETIK BACAAN (TANPA HARAKAT PUN COCOK)'),
        ]),
        const SizedBox(height: 9),
        TextField(
          controller: _manualCtrl,
          onChanged: _onManual,
          textDirection: TextDirection.rtl,
          style: const TextStyle(fontFamily: kArabicFont, fontSize: 20, color: AppColors.ink),
          decoration: InputDecoration(
            hintText: 'مثال: قل هو الله احد …',
            hintStyle: TextStyle(
                fontFamily: kArabicFont, color: AppColors.muted.withOpacity(.55), fontSize: 20),
            filled: true,
            fillColor: Colors.white.withOpacity(.03),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.line)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: AppColors.emerald.withOpacity(.5))),
          ),
        ),
      ],
    );
  }

  Widget _stats() {
    final e = _engine!;
    Widget stat(String v, String l, Color? c) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.03),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(v,
                  style: TextStyle(
                      color: c ?? AppColors.ink, fontSize: 26, fontWeight: FontWeight.w700, height: 1)),
              const SizedBox(height: 4),
              Text(l,
                  style: const TextStyle(
                      color: AppColors.muted, fontSize: 11, letterSpacing: 1, fontWeight: FontWeight.w600)),
            ],
          ),
        );
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: stat('${e.correct}', 'BENAR', AppColors.emeraldSoft)),
            const SizedBox(width: 12),
            Expanded(child: stat('${e.wrong}', 'SALAH', AppColors.wrongSoft)),
            const SizedBox(width: 12),
            Expanded(child: stat('${e.accuracy}%', 'AKURASI', null)),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.03),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('progres hafalan',
                      style: TextStyle(
                          color: AppColors.muted, fontSize: 12, fontWeight: FontWeight.w600)),
                  Text('${e.progress}%',
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 12, fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 9),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: e.progress / 100,
                  minHeight: 8,
                  backgroundColor: Colors.white.withOpacity(.07),
                  valueColor: const AlwaysStoppedAnimation(AppColors.emerald),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _footer() {
    return const Center(
      child: Text(
        'Prototipe sesuai blueprint · engine ini = AlignmentService di Dart core kamu',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.6),
      ),
    );
  }
}

// ---------- small reusable widgets ----------
class _Backdrop extends StatelessWidget {
  const _Backdrop();
  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -1.1),
                radius: 1.3,
                colors: [AppColors.bgTop, AppColors.bg1, AppColors.bg0],
                stops: [0, .42, 1],
              ),
            ),
          ),
        ),
        Positioned(
          top: -120,
          left: -90,
          child: _glow(360, AppColors.emerald.withOpacity(.22)),
        ),
        Positioned(
          bottom: -150,
          right: -110,
          child: _glow(400, AppColors.gold.withOpacity(.13)),
        ),
      ],
    );
  }

  Widget _glow(double size, Color c) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [c, c.withOpacity(0)], stops: const [0, .72]),
        ),
      );
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(
          color: AppColors.muted, fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w600));
}

class _NavBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _NavBtn(this.icon, this.onTap);
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        child: Icon(icon,
            size: 20, color: onTap == null ? AppColors.muted.withOpacity(.3) : AppColors.ink),
      ),
    );
  }
}

class _StrictToggle extends StatelessWidget {
  final bool value;
  final VoidCallback onTap;
  const _StrictToggle({required this.value, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final c = value ? AppColors.goldSoft : AppColors.muted;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(11),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
        decoration: BoxDecoration(
          color: value ? AppColors.gold.withOpacity(.1) : Colors.white.withOpacity(.03),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: value ? AppColors.gold.withOpacity(.5) : AppColors.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: 34,
              height: 18,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: value ? AppColors.emeraldDeep : Colors.white.withOpacity(.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Align(
                alignment: value ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                      color: value ? AppColors.emeraldSoft : const Color(0xFFCDC6B4),
                      shape: BoxShape.circle),
                ),
              ),
            ),
            const SizedBox(width: 9),
            Text.rich(TextSpan(children: [
              TextSpan(
                  text: 'Mode ketat ',
                  style: TextStyle(color: c, fontSize: 13, fontWeight: FontWeight.w600)),
              TextSpan(
                  text: '(harakat)',
                  style: TextStyle(color: c.withOpacity(.7), fontSize: 13)),
            ])),
          ],
        ),
      ),
    );
  }
}

class _Btn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;
  const _Btn({required this.icon, required this.label, required this.onTap, required this.primary});
  @override
  Widget build(BuildContext context) {
    final fg = primary ? AppColors.goldSoft : AppColors.muted;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(11),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          color: primary ? AppColors.gold.withOpacity(.1) : Colors.white.withOpacity(.03),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: primary ? AppColors.gold.withOpacity(.35) : AppColors.line),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: fg, fontSize: 13.5, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

class _Corner extends StatelessWidget {
  final bool top;
  final bool left;
  const _Corner(this.top, this.left);
  @override
  Widget build(BuildContext context) {
    final side = BorderSide(color: AppColors.gold.withOpacity(.85), width: 2);
    return SizedBox(
      width: 22,
      height: 22,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: top ? side : BorderSide.none,
            bottom: top ? BorderSide.none : side,
            left: left ? side : BorderSide.none,
            right: left ? BorderSide.none : side,
          ),
        ),
      ),
    );
  }
}
