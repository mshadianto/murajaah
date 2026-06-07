import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data/quran_repository.dart';
import 'ui/app_theme.dart';
import 'ui/murojaah_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final repo = await QuranRepository.open();
  runApp(MurojaahRoot(repo: repo));
}

class MurojaahRoot extends StatelessWidget {
  final QuranRepository repo;
  const MurojaahRoot({super.key, required this.repo});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Murojaah',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: MurojaahPage(repo: repo),
    );
  }
}
