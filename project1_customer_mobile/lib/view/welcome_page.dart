import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../viewmodel/questionnaire_viewmodel.dart';
import 'components.dart';

class WelcomePage extends ConsumerWidget {
  const WelcomePage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(questionnaireProvider);
    final vm = ref.read(questionnaireProvider.notifier);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 16, 16, 12),
          child: Row(
            children: [
              const Icon(Icons.coffee, size: 32, color: Color(0xFF4B3528)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Project1',
                      style: TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -.8,
                      ),
                    ),
                    Text(
                      s.tr(
                        'Café entrepreneur research',
                        'Kajian usahawan kafe',
                      ),
                      style: const TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              ),
              const LanguageSwitch(),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(minHeight: 228),
                  decoration: const BoxDecoration(
                    image: DecorationImage(
                      image: AssetImage('assets/cafe_hero.png'),
                      fit: BoxFit.cover,
                      alignment: Alignment.centerRight,
                    ),
                  ),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(24, 26, 120, 26),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Color(0xF4F3F6F9),
                          Color(0xCCF3F6F9),
                          Color(0x00FFFFFF),
                        ],
                        stops: [0, .55, 1],
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.tr(
                            'Customer\nQuestionnaire',
                            'Soal Selidik\nPelanggan',
                          ),
                          style: const TextStyle(
                            color: navy,
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                            height: 1.12,
                            letterSpacing: -.6,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          s.tr(
                            'Help us understand customer needs and café preferences in your area.',
                            'Bantu kami memahami keperluan pelanggan dan pilihan kafe di kawasan anda.',
                          ),
                          style: const TextStyle(fontSize: 15, height: 1.45),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                  child: Column(
                    children: [
                      SoftCard(
                        child: Column(
                          children: [
                            _Info(
                              Icons.track_changes,
                              s.tr('Purpose', 'Tujuan'),
                              s.tr(
                                'Market research for café business planning. This build is a local UI demonstration.',
                                'Kajian pasaran untuk perancangan perniagaan kafe. Binaan ini ialah demonstrasi UI setempat.',
                              ),
                            ),
                            const Divider(height: 26),
                            _Info(
                              Icons.schedule_outlined,
                              s.tr('Time', 'Masa'),
                              s.tr(
                                'About 5–8 minutes for the longer demo route. Your route may be shorter.',
                                'Kira-kira 5–8 minit bagi laluan contoh yang lebih panjang. Laluan anda mungkin lebih pendek.',
                              ),
                            ),
                            const Divider(height: 26),
                            _Info(
                              Icons.verified_user_outlined,
                              s.tr('Privacy', 'Privasi'),
                              s.tr(
                                'Answers stay in memory on this device. Nothing is uploaded; closing or resetting clears this demo.',
                                'Jawapan kekal dalam memori peranti ini. Tiada data dimuat naik; menutup atau menetapkan semula memadamkan demo ini.',
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      SoftCard(
                        color: const Color(0xFFF7F9FD),
                        padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
                        child: Column(
                          children: [
                            CheckboxListTile(
                              key: const ValueKey('consent'),
                              value: s.consent,
                              onChanged: (value) =>
                                  vm.setConsent(value ?? false),
                              controlAffinity: ListTileControlAffinity.leading,
                              contentPadding: const EdgeInsets.only(right: 4),
                              title: Text(
                                s.tr(
                                  'I have read the demo details and agree to try this questionnaire.',
                                  'Saya telah membaca butiran demo dan bersetuju mencuba soal selidik ini.',
                                ),
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Padding(
                                padding: const EdgeInsets.only(left: 56),
                                child: TextButton(
                                  onPressed: () => showDialog<void>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: Text(
                                        s.tr(
                                          'Demo participation details',
                                          'Butiran penyertaan demo',
                                        ),
                                      ),
                                      content: SingleChildScrollView(
                                        child: Text(
                                          s.tr(
                                            'This prototype is for synthetic walkthroughs only. Participation is voluntary. You can go back, skip optional questions Q11–Q13, select refusal options where offered, or withdraw and clear the session.\n\nNo real café, approved eligibility rule, research consent, or scientific validation is represented. No login, identifiers, location tracking, server, or storage is used. Submission only displays a local confirmation.\n\nEN/BM wording and translations are drafts. Do not use this build to recruit respondents.',
                                            'Prototaip ini hanya untuk ujian rekaan. Penyertaan adalah sukarela. Anda boleh kembali, melangkau soalan pilihan Q11–Q13, memilih tidak mahu menjawab jika tersedia, atau menarik diri dan memadamkan sesi.\n\nTiada kafe sebenar, peraturan kelayakan diluluskan, persetujuan kajian atau pengesahan saintifik diwakili. Tiada log masuk, pengecam, penjejakan lokasi, pelayan atau storan digunakan. Penghantaran hanya memaparkan pengesahan setempat.\n\nTeks dan terjemahan EN/BM ialah draf. Jangan gunakan binaan ini untuk mengambil responden.',
                                          ),
                                        ),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context),
                                          child: Text(s.tr('Close', 'Tutup')),
                                        ),
                                      ],
                                    ),
                                  ),
                                  child: Text(
                                    s.tr(
                                      'View consent details  ›',
                                      'Lihat butiran persetujuan  ›',
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (s.displayed.isEmpty)
                        ExpansionTile(
                          tilePadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                          ),
                          title: Text(
                            s.tr('Demo setup', 'Tetapan demo'),
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          subtitle: Text(
                            s.tr(
                              'Synthetic stimuli · no approval implied',
                              'Rangsangan rekaan · bukan kelulusan',
                            ),
                            style: const TextStyle(fontSize: 11),
                          ),
                          children: [
                            for (final setting in [
                              (
                                s.tr('Demo café concept', 'Konsep kafe contoh'),
                                s.config.concept,
                                (bool v) =>
                                    vm.configure(s.config.copyWith(concept: v)),
                              ),
                              (
                                s.tr('Demo menu', 'Menu contoh'),
                                s.config.menu,
                                (bool v) =>
                                    vm.configure(s.config.copyWith(menu: v)),
                              ),
                              (
                                s.tr(
                                  'Exact demo offer',
                                  'Tawaran contoh khusus',
                                ),
                                s.config.offer,
                                (bool v) =>
                                    vm.configure(s.config.copyWith(offer: v)),
                              ),
                              (
                                s.tr(
                                  'Future-occasion module',
                                  'Modul tujuan lawatan akan datang',
                                ),
                                s.config.occasions,
                                (bool v) => vm.configure(
                                  s.config.copyWith(occasions: v),
                                ),
                              ),
                              (
                                s.tr(
                                  'Synthetic feature rows',
                                  'Baris ciri rekaan',
                                ),
                                s.config.features,
                                (bool v) => vm.configure(
                                  s.config.copyWith(features: v),
                                ),
                              ),
                              (
                                s.tr(
                                  'Optional context Q11–Q13',
                                  'Konteks pilihan Q11–Q13',
                                ),
                                s.config.optionalQuestions,
                                (bool v) => vm.configure(
                                  s.config.copyWith(optionalQuestions: v),
                                ),
                              ),
                            ])
                              SwitchListTile(
                                title: Text(
                                  setting.$1,
                                  style: const TextStyle(fontSize: 14),
                                ),
                                value: setting.$2,
                                onChanged: setting.$3,
                              ),
                          ],
                        ),
                      DemoNotice(s),
                      if (s.language.name == 'bm')
                        Text(
                          s.tr(
                            '',
                            'Terjemahan BM ialah draf yang belum disemak.',
                          ),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF8B5C13),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: BlueButton(
            buttonKey: const ValueKey('start'),
            label: s.tr(
              s.displayed.isEmpty
                  ? 'Start questionnaire'
                  : 'Resume questionnaire',
              s.displayed.isEmpty
                  ? 'Mula soal selidik'
                  : 'Sambung soal selidik',
            ),
            onPressed: s.consent ? vm.start : null,
            icon: Icons.chevron_right,
          ),
        ),
      ],
    );
  }
}

class _Info extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  const _Info(this.icon, this.title, this.body);
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, color: const Color(0xFF20558E), size: 30),
      const SizedBox(width: 16),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
            ),
            const SizedBox(height: 3),
            Text(body, style: const TextStyle(fontSize: 14, height: 1.4)),
          ],
        ),
      ),
    ],
  );
}
