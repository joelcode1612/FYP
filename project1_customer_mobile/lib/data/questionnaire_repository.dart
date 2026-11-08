import '../model/question.dart';

/// A bundled UI fixture, not the approved instrument or a production API.
/// Codes trace to the frozen CUST03 excerpt in docs/. Display labels, stimulus,
/// three feature rows, translations and routing are unapproved demo proposals.
class QuestionnaireRepository {
  const QuestionnaireRepository();
  static const area = LocalText(
    'Demo neighbourhood',
    'Kawasan kejiranan contoh',
  );
  static const concept = LocalText(
    'A neighbourhood café in the demo area, serving coffee, tea, cold drinks, pastries, light meals and desserts, with dine-in and takeaway service. Retail coffee is also offered. This is a fictional concept, version DEMO-CONCEPT-1.',
    'Sebuah kafe kejiranan di kawasan contoh yang menyajikan kopi, teh, minuman sejuk, pastri, makanan ringan dan pencuci mulut, untuk makan di kafe atau dibawa pulang. Kopi runcit turut ditawarkan. Konsep rekaan, versi DEMO-CONCEPT-1.',
  );
  static const offer = LocalText(
    'Demo offer: one 250 ml medium hot latte, dine-in, RM12 total including all taxes and service charges. No add-ons. DEMO-OFFER-1.',
    'Tawaran contoh: satu latte panas sederhana 250 ml, makan di kafe, jumlah RM12 termasuk semua cukai dan caj perkhidmatan. Tiada tambahan. DEMO-OFFER-1.',
  );
  static const features = [
    Feature(
      'DEMO_SEATING',
      LocalText('Comfortable seating', 'Tempat duduk yang selesa'),
    ),
    Feature('DEMO_WIFI', LocalText('Wi-Fi access', 'Akses Wi-Fi')),
    Feature(
      'DEMO_TAKEAWAY',
      LocalText('Takeaway service', 'Perkhidmatan bawa pulang'),
    ),
  ];
  static const refuse = AnswerOption(
    'PREFER_NOT_TO_ANSWER',
    LocalText('Prefer not to answer', 'Tidak mahu menjawab'),
  );
  static const cannotJudge = AnswerOption(
    'CANNOT_JUDGE',
    LocalText(
      'Cannot judge from the description',
      'Tidak dapat menilai berdasarkan penerangan',
    ),
  );
  static const notSure = AnswerOption(
    'NOT_SURE',
    LocalText('Not sure', 'Tidak pasti'),
  );
  static const occasions = [
    AnswerOption('WORK_BREAK', LocalText('A work break', 'Rehat kerja')),
    AnswerOption('STUDY', LocalText('Studying', 'Belajar')),
    AnswerOption(
      'SOCIAL',
      LocalText('Meeting friends or family', 'Berjumpa rakan atau keluarga'),
    ),
    AnswerOption(
      'ON_THE_GO',
      LocalText('While on the go', 'Semasa dalam perjalanan'),
    ),
    AnswerOption(
      'UNLISTED_OCCASION_REPORTED',
      LocalText(
        'Another occasion (selection only)',
        'Tujuan lain (pilihan sahaja)',
      ),
    ),
  ];
  static const ratingOptions = [
    AnswerOption(
      'NOT_AT_ALL_IMPORTANT',
      LocalText('Not at all important', 'Langsung tidak penting'),
    ),
    AnswerOption(
      'SLIGHTLY_IMPORTANT',
      LocalText('Slightly important', 'Sedikit penting'),
    ),
    AnswerOption(
      'MODERATELY_IMPORTANT',
      LocalText('Moderately important', 'Sederhana penting'),
    ),
    AnswerOption(
      'VERY_IMPORTANT',
      LocalText('Very important', 'Sangat penting'),
    ),
    AnswerOption(
      'EXTREMELY_IMPORTANT',
      LocalText('Extremely important', 'Amat penting'),
    ),
    AnswerOption(
      'NOT_APPLICABLE',
      LocalText('Not applicable', 'Tidak berkenaan'),
    ),
    cannotJudge,
    refuse,
  ];

  List<Question> get questions => const [
    Question(
      id: 'Q01',
      title: LocalText('Your connection', 'Hubungan anda'),
      stem: LocalText(
        'Which of these describe your connection to the demo neighbourhood?',
        'Antara berikut, yang manakah menerangkan hubungan anda dengan kawasan kejiranan contoh?',
      ),
      help: LocalText(
        'Select all connections that apply. Or choose one of the last three answers. Those choices clear other selections.',
        'Pilih semua hubungan yang berkaitan. Atau pilih satu daripada tiga jawapan terakhir. Pilihan itu memadamkan pilihan lain.',
      ),
      kind: QuestionKind.multiple,
      exclusive: {'RARELY', 'NEVER', 'NOT_SURE'},
      options: [
        AnswerOption(
          'LIVE',
          LocalText('I live in this area', 'Saya tinggal di kawasan ini'),
        ),
        AnswerOption(
          'WORK',
          LocalText('I work in this area', 'Saya bekerja di kawasan ini'),
        ),
        AnswerOption(
          'STUDY',
          LocalText('I study in this area', 'Saya belajar di kawasan ini'),
        ),
        AnswerOption(
          'RUN_BUSINESS',
          LocalText(
            'I run a business here',
            'Saya menjalankan perniagaan di sini',
          ),
        ),
        AnswerOption(
          'VISIT_PURPOSE',
          LocalText(
            'I visit for activities or errands',
            'Saya datang untuk aktiviti atau urusan',
          ),
        ),
        AnswerOption(
          'PASS_THROUGH',
          LocalText('I pass through this area', 'Saya melalui kawasan ini'),
        ),
        AnswerOption(
          'RARELY',
          LocalText(
            'None above; I rarely spend time here',
            'Tiada di atas; saya jarang berada di sini',
          ),
        ),
        AnswerOption(
          'NEVER',
          LocalText(
            'None above; I never visit this area',
            'Tiada di atas; saya tidak pernah datang ke sini',
          ),
        ),
        notSure,
      ],
    ),
    Question(
      id: 'Q02',
      title: LocalText('Days in the area', 'Hari berada di kawasan'),
      stem: LocalText(
        'In the last four weeks, on how many different days were you physically present in the demo neighbourhood?',
        'Dalam empat minggu yang lalu, pada berapa hari yang berbeza anda berada secara fizikal di kawasan kejiranan contoh?',
      ),
      help: LocalText(
        'Count each calendar day only once, even if you visited several times that day. This is not a count of café visits.',
        'Kira setiap hari kalendar sekali sahaja walaupun anda datang beberapa kali pada hari itu. Ini bukan bilangan lawatan ke kafe.',
      ),
      options: [
        AnswerOption('NONE', LocalText('0 days', '0 hari')),
        AnswerOption('DAYS_1_3', LocalText('1–3 days', '1–3 hari')),
        AnswerOption('DAYS_4_10', LocalText('4–10 days', '4–10 hari')),
        AnswerOption('DAYS_11_20', LocalText('11–20 days', '11–20 hari')),
        AnswerOption('DAYS_GT_20', LocalText('21–28 days', '21–28 hari')),
        refuse,
      ],
    ),
    Question(
      id: 'Q03',
      title: LocalText('Journey origin', 'Asal perjalanan'),
      stem: LocalText(
        'If you visited the café described below, where would you most likely begin that journey?',
        'Jika anda melawat kafe yang diterangkan di bawah, dari manakah anda mungkin memulakan perjalanan itu?',
      ),
      help: LocalText(
        'Choose a type of place. No address, GPS or exact location is collected.',
        'Pilih jenis tempat. Tiada alamat, GPS atau lokasi tepat dikumpulkan.',
      ),
      options: [
        AnswerOption('HOME', LocalText('Home', 'Rumah')),
        AnswerOption('WORKPLACE', LocalText('Workplace', 'Tempat kerja')),
        AnswerOption(
          'STUDY_LOCATION',
          LocalText('Study location', 'Tempat belajar'),
        ),
        AnswerOption(
          'OTHER_ACTIVITY',
          LocalText('Another activity location', 'Tempat aktiviti lain'),
        ),
        AnswerOption('VARIES', LocalText('It varies', 'Berbeza-beza')),
        AnswerOption(
          'DECLINE',
          LocalText('Prefer not to answer', 'Tidak mahu menjawab'),
        ),
        notSure,
      ],
    ),
    Question(
      id: 'Q04',
      title: LocalText('Past café purchases', 'Pembelian di kafe sebelum ini'),
      stem: LocalText(
        'In the past 30 days, on how many occasions have you bought food or a drink from an existing café?',
        'Dalam 30 hari yang lalu, berapa kali anda membeli makanan atau minuman daripada kafe sedia ada?',
      ),
      help: LocalText(
        'Think about past purchases at existing cafés, not the proposed café.',
        'Fikirkan pembelian lalu di kafe sedia ada, bukan kafe yang dicadangkan.',
      ),
      options: [
        AnswerOption('ZERO', LocalText('0 occasions', '0 kali')),
        AnswerOption('ONE', LocalText('1 occasion', '1 kali')),
        AnswerOption('TWO_THREE', LocalText('2–3 occasions', '2–3 kali')),
        AnswerOption('FOUR_SEVEN', LocalText('4–7 occasions', '4–7 kali')),
        AnswerOption(
          'EIGHT_PLUS',
          LocalText('8 or more occasions', '8 kali atau lebih'),
        ),
        AnswerOption(
          'CANNOT_REMEMBER',
          LocalText('Cannot remember', 'Tidak ingat'),
        ),
        refuse,
      ],
    ),
    Question(
      id: 'Q05',
      title: LocalText('Visiting interest', 'Minat untuk melawat'),
      stem: LocalText(
        'Based on this description, if this café opened in the demo neighbourhood, how likely would you be to visit at least once during its first three months?',
        'Berdasarkan penerangan ini, jika kafe ini dibuka di kawasan kejiranan contoh, sejauh manakah kemungkinan anda melawat sekurang-kurangnya sekali dalam tiga bulan pertamanya?',
      ),
      help: LocalText(
        'This is hypothetical interest, not a prediction of demand or a commitment to visit.',
        'Ini ialah minat hipotetikal, bukan ramalan permintaan atau janji untuk melawat.',
      ),
      options: [
        AnswerOption(
          'DEF_YES',
          LocalText('Definitely likely', 'Pasti berkemungkinan'),
        ),
        AnswerOption(
          'PROB_YES',
          LocalText('Probably likely', 'Mungkin berkemungkinan'),
        ),
        AnswerOption('UNSURE', LocalText('Unsure', 'Belum pasti')),
        AnswerOption(
          'PROB_NO',
          LocalText('Probably unlikely', 'Mungkin tidak berkemungkinan'),
        ),
        AnswerOption(
          'DEF_NO',
          LocalText('Definitely unlikely', 'Pasti tidak berkemungkinan'),
        ),
        cannotJudge,
        refuse,
      ],
    ),
    Question(
      id: 'Q06',
      title: LocalText('Menu interests', 'Minat menu'),
      stem: LocalText(
        'Which categories from this demo café menu interest you? Select up to three.',
        'Kategori manakah daripada menu kafe contoh ini yang menarik minat anda? Pilih sehingga tiga.',
      ),
      help: LocalText(
        'Demo menu only. “Another category” is a closed selection; there is no write-in field.',
        'Menu contoh sahaja. “Kategori lain” ialah pilihan tertutup; tiada ruangan jawapan bertulis.',
      ),
      kind: QuestionKind.multiple,
      maxSelections: 3,
      exclusive: {'NONE', 'NOT_SURE', 'PREFER_NOT_TO_ANSWER'},
      options: [
        AnswerOption(
          'COFFEE_ESPRESSO',
          LocalText('Coffee / espresso', 'Kopi / espresso'),
        ),
        AnswerOption(
          'NON_COFFEE',
          LocalText('Non-coffee drinks', 'Minuman selain kopi'),
        ),
        AnswerOption(
          'BAKED_PASTRY',
          LocalText('Baked goods / pastries', 'Roti / pastri'),
        ),
        AnswerOption('LIGHT_MEALS', LocalText('Light meals', 'Makanan ringan')),
        AnswerOption('DESSERTS', LocalText('Desserts', 'Pencuci mulut')),
        AnswerOption(
          'RETAIL',
          LocalText('Retail coffee items', 'Barangan kopi runcit'),
        ),
        AnswerOption(
          'UNLISTED_CATEGORY_REPORTED',
          LocalText('Another category', 'Kategori lain'),
        ),
        AnswerOption('NONE', LocalText('None of these', 'Tiada satu pun')),
        notSure,
        refuse,
      ],
    ),
    Question(
      id: 'Q07',
      title: LocalText('Exact-offer price', 'Harga tawaran khusus'),
      stem: LocalText(
        'How acceptable would paying RM12 for the exact demo offer below be to you?',
        'Sejauh manakah anda boleh menerima harga RM12 bagi tawaran contoh khusus di bawah?',
      ),
      help: LocalText(
        'Rate this one defined offer. This does not estimate willingness to pay or an optimum price.',
        'Nilaikan tawaran khusus ini sahaja. Ini tidak menganggarkan kesanggupan membayar atau harga optimum.',
      ),
      options: [
        AnswerOption(
          'VERY_UNACCEPTABLE',
          LocalText('Very unacceptable', 'Sangat tidak boleh diterima'),
        ),
        AnswerOption(
          'SOMEWHAT_UNACCEPTABLE',
          LocalText('Somewhat unacceptable', 'Agak tidak boleh diterima'),
        ),
        AnswerOption(
          'NEITHER',
          LocalText('Neither acceptable nor unacceptable', 'Berkecuali'),
        ),
        AnswerOption(
          'SOMEWHAT_ACCEPTABLE',
          LocalText('Somewhat acceptable', 'Agak boleh diterima'),
        ),
        AnswerOption(
          'VERY_ACCEPTABLE',
          LocalText('Very acceptable', 'Sangat boleh diterima'),
        ),
        cannotJudge,
        refuse,
      ],
    ),
    Question(
      id: 'Q08',
      title: LocalText('Past visiting occasions', 'Tujuan lawatan lalu'),
      stem: LocalText(
        'Thinking only about the existing-café visits you reported in the past 30 days, on which occasions did you visit?',
        'Fikirkan lawatan ke kafe sedia ada yang dilaporkan dalam 30 hari lalu. Untuk tujuan apakah anda melawat?',
      ),
      help: LocalText(
        'Select all that apply. This mock route shows Q08 only after a positive past-purchase band in Q04.',
        'Pilih semua yang berkaitan. Laluan contoh ini memaparkan Q08 hanya selepas julat pembelian lalu yang positif dalam Q04.',
      ),
      kind: QuestionKind.multiple,
      exclusive: {'CANNOT_REMEMBER', 'PREFER_NOT_TO_ANSWER'},
      options: [
        ...occasions,
        AnswerOption(
          'CANNOT_REMEMBER',
          LocalText('Cannot remember', 'Tidak ingat'),
        ),
        refuse,
      ],
    ),
    Question(
      id: 'Q09',
      title: LocalText(
        'Possible future occasions',
        'Kemungkinan tujuan lawatan akan datang',
      ),
      stem: LocalText(
        'Thinking about this proposed café, on which occasions, if any, could you imagine choosing to visit?',
        'Memikirkan kafe yang dicadangkan ini, untuk tujuan apakah anda boleh membayangkan diri anda melawat, jika ada?',
      ),
      help: LocalText(
        'Select all that apply. This hypothetical item does not require a past purchase in Q04.',
        'Pilih semua yang berkaitan. Soalan hipotetikal ini tidak memerlukan pembelian lalu dalam Q04.',
      ),
      kind: QuestionKind.multiple,
      exclusive: {'NONE', 'CANNOT_JUDGE', 'PREFER_NOT_TO_ANSWER'},
      options: [
        ...occasions,
        AnswerOption('NONE', LocalText('No occasions', 'Tiada tujuan')),
        cannotJudge,
        refuse,
      ],
    ),
    Question(
      id: 'Q10',
      title: LocalText('Feature importance', 'Kepentingan ciri'),
      stem: LocalText(
        'How important would each demo feature be to you if you chose to visit?',
        'Sejauh manakah setiap ciri contoh ini penting kepada anda jika anda memilih untuk melawat?',
      ),
      help: LocalText(
        'Synthetic feature bank DEMO-FEATURES-1. Rate each row independently. No composite score is calculated.',
        'Bank ciri rekaan DEMO-FEATURES-1. Nilaikan setiap baris secara berasingan. Tiada skor gabungan dikira.',
      ),
      kind: QuestionKind.matrix,
      options: ratingOptions,
    ),
    Question(
      id: 'Q11',
      optional: true,
      title: LocalText('Service format', 'Format perkhidmatan'),
      stem: LocalText(
        'For the proposed café offer, which service format would you mainly choose?',
        'Bagi tawaran kafe yang dicadangkan, format perkhidmatan manakah yang biasanya anda pilih?',
      ),
      help: LocalText(
        'Optional context. You may skip this question.',
        'Konteks pilihan. Anda boleh melangkau soalan ini.',
      ),
      options: [
        AnswerOption('DINE_IN', LocalText('Dine-in', 'Makan di kafe')),
        AnswerOption('TAKEAWAY', LocalText('Takeaway', 'Bawa pulang')),
        AnswerOption(
          'EITHER_EQUALLY',
          LocalText('Either equally', 'Kedua-duanya sama'),
        ),
        cannotJudge,
        refuse,
      ],
    ),
    Question(
      id: 'Q12',
      optional: true,
      title: LocalText('Transport to the area', 'Pengangkutan ke kawasan'),
      stem: LocalText(
        'What is your usual way of travelling to the demo neighbourhood?',
        'Apakah cara biasa anda pergi ke kawasan kejiranan contoh?',
      ),
      help: LocalText(
        'Optional. Travel to the area, not specifically to the proposed café.',
        'Pilihan. Perjalanan ke kawasan ini, bukan khusus ke kafe yang dicadangkan.',
      ),
      options: [
        AnswerOption('WALK', LocalText('Walking', 'Berjalan kaki')),
        AnswerOption('MOTORCYCLE', LocalText('Motorcycle', 'Motosikal')),
        AnswerOption('CAR', LocalText('Car', 'Kereta')),
        AnswerOption(
          'PUBLIC_TRANSPORT',
          LocalText('Public transport', 'Pengangkutan awam'),
        ),
        AnswerOption('OTHER', LocalText('Other', 'Lain-lain')),
        notSure,
        refuse,
      ],
    ),
    Question(
      id: 'Q13',
      optional: true,
      title: LocalText('Expected product price', 'Jangkaan harga produk'),
      stem: LocalText(
        'What would you expect to pay for one medium hot latte (250 ml), dine-in, including all charges?',
        'Berapakah harga yang anda jangka bayar untuk satu latte panas sederhana (250 ml), makan di kafe, termasuk semua caj?',
      ),
      help: LocalText(
        'Optional, research-only demo. Price expectation is separate from Q07 acceptability.',
        'Pilihan, contoh untuk penyelidikan sahaja. Jangkaan harga berbeza daripada kebolehterimaan dalam Q07.',
      ),
      options: [
        AnswerOption('LT_RM8', LocalText('Below RM8', 'Kurang daripada RM8')),
        AnswerOption('RM8_TO_1199', LocalText('RM8–11.99', 'RM8–11.99')),
        AnswerOption('RM12_TO_1499', LocalText('RM12–14.99', 'RM12–14.99')),
        AnswerOption('RM15_TO_1799', LocalText('RM15–17.99', 'RM15–17.99')),
        AnswerOption('GE_RM18', LocalText('RM18 or more', 'RM18 atau lebih')),
        notSure,
        refuse,
      ],
    ),
  ];
}
