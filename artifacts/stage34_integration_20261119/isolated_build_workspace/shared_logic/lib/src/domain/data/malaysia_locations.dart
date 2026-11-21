// GENERATED FILE — do not hand-edit.
//
// Malaysian states, cities/townships and postcodes.
//
// Source: https://github.com/heiswayi/malaysia-postcodes (data/json/postcodes.json),
// licensed CC BY 4.0, derived from Pos Malaysia postcode data.
// Retrieved 2026-11-10. 16 states/territories, 443 localities, 2,932 postcodes.
//
// Regenerate with `tool/generate_malaysia_locations.py` in the repository root.
// This file is intentionally dependency-free so Jaspr (browser) and Flutter
// consume the exact same dataset.

/// One city/township within a state, with every postcode that maps to it.
class MalaysiaCity {
  const MalaysiaCity(this.name, this.postcodes);

  final String name;
  final List<String> postcodes;
}

/// One Malaysian state or federal territory.
class MalaysiaState {
  const MalaysiaState(this.name, this.cities);

  final String name;
  final List<MalaysiaCity> cities;
}

/// Lookup helpers shared by the web and mobile Add Property forms.
abstract final class MalaysiaLocations {
  /// All 16 states and federal territories, in conventional order.
  static const List<MalaysiaState> states = <MalaysiaState>[
    MalaysiaState('Johor', <MalaysiaCity>[
      MalaysiaCity('Ayer Baloi', <String>['82100']),
      MalaysiaCity('Ayer Hitam', <String>['86100']),
      MalaysiaCity('Ayer Tawar 2', <String>['81920']),
      MalaysiaCity('Bandar Penawar', <String>['81930', '81960']),
      MalaysiaCity('Bandar Tenggara', <String>['81440']),
      MalaysiaCity('Batu Anam', <String>['85100']),
      MalaysiaCity('Batu Pahat', <String>['83000', '83010', '83020', '83030', '83040', '83050', '86400']),
      MalaysiaCity('Bekok', <String>['86500']),
      MalaysiaCity('Benut', <String>['82200']),
      MalaysiaCity('Bukit Gambir', <String>['84800']),
      MalaysiaCity('Bukit Pasir', <String>['84300']),
      MalaysiaCity('Chaah', <String>['85400']),
      MalaysiaCity('Endau', <String>['86900', '86999']),
      MalaysiaCity('Gelang Patah', <String>['81550', '81560']),
      MalaysiaCity('Gerisek', <String>['84700', '84710']),
      MalaysiaCity('Gugusan Taib Andak', <String>['81450']),
      MalaysiaCity('Iskandar Puteri', <String>['79000', '79050', '79100', '79150', '79200', '79250', '79502', '79503', '79504', '79505', '79511', '79513', '79514', '79517', '79518', '79520', '79521', '79523', '79532', '79538', '79540', '79546', '79548', '79550', '79552', '79555', '79570', '79575', '79576', '79592', '79601', '79603', '79605', '79606', '79612', '79626', '79630', '79632', '79646', '79658', '79660', '79680', '79681', '79683']),
      MalaysiaCity('Jementah', <String>['85200', '85210']),
      MalaysiaCity('Johor Bahru', <String>['80000', '80050', '80100', '80110', '80150', '80200', '80250', '80300', '80350', '80400', '80500', '80502', '80503', '80504', '80505', '80506', '80508', '80514', '80516', '80517', '80518', '80519', '80520', '80529', '80530', '80532', '80534', '80536', '80538', '80540', '80542', '80546', '80548', '80550', '80552', '80558', '80560', '80564', '80568', '80570', '80576', '80578', '80584', '80586', '80590', '80592', '80594', '80596', '80600', '80604', '80606', '80608', '80610', '80612', '80620', '80622', '80626', '80628', '80630', '80632', '80644', '80646', '80648', '80658', '80660', '80662', '80664', '80668', '80670', '80672', '80673', '80676', '80700', '80710', '80720', '80730', '80750', '80800', '80900', '80902', '80904', '80906', '80908', '80988', '80990', '81100', '81110', '81120', '81200', '81250', '81300', '81310']),
      MalaysiaCity('Kahang', <String>['86700']),
      MalaysiaCity('Kluang', <String>['86000', '86007']),
      MalaysiaCity('Kota Tinggi', <String>['81900', '81907', '81910']),
      MalaysiaCity('Kukup', <String>['82300']),
      MalaysiaCity('Kulai', <String>['81000', '81010', '81020', '81030', '81040', '81050']),
      MalaysiaCity('Labis', <String>['85300']),
      MalaysiaCity('Layang-Layang', <String>['81850']),
      MalaysiaCity('Masai', <String>['81750', '81760']),
      MalaysiaCity('Mersing', <String>['86800', '86810']),
      MalaysiaCity('Muar', <String>['84000', '84007', '84010', '84020', '84030', '84040', '84050', '84100', '84200', '84300', '84410']),
      MalaysiaCity('Pagoh', <String>['84600']),
      MalaysiaCity('Paloh', <String>['86600']),
      MalaysiaCity('Panchor', <String>['84500']),
      MalaysiaCity('Parit Jawa', <String>['84150', '84160']),
      MalaysiaCity('Parit Raja', <String>['86400']),
      MalaysiaCity('Parit Sulong', <String>['83500']),
      MalaysiaCity('Pasir Gudang', <String>['81700']),
      MalaysiaCity('Pekan Nenas', <String>['81500']),
      MalaysiaCity('Pengerang', <String>['81600', '81620', '81650']),
      MalaysiaCity('Pontian', <String>['82000', '82010', '82020', '82030']),
      MalaysiaCity('Rengam', <String>['86300']),
      MalaysiaCity('Rengit', <String>['83100']),
      MalaysiaCity('Segamat', <String>['85000', '85010', '85020', '85030', '85060', '85070', '85080']),
      MalaysiaCity('Semerah', <String>['83600', '83610']),
      MalaysiaCity('Senai', <String>['81400', '81410']),
      MalaysiaCity('Senggarang', <String>['83200']),
      MalaysiaCity('Seri Gading', <String>['83300']),
      MalaysiaCity('Seri Medan', <String>['83400']),
      MalaysiaCity('Simpang Rengam', <String>['86200']),
      MalaysiaCity('Sungai Mati', <String>['84400', '84409']),
      MalaysiaCity('Tangkak', <String>['84900', '84990']),
      MalaysiaCity('Tioman', <String>['86800']),
      MalaysiaCity('Ulu Tiram', <String>['81800', '81810']),
      MalaysiaCity('Yong Peng', <String>['83700', '83710']),
    ]),
    MalaysiaState('Kedah', <MalaysiaCity>[
      MalaysiaCity('Alor Setar', <String>['05000', '05050', '05100', '05150', '05200', '05250', '05300', '05350', '05400', '05450', '05460', '05500', '05502', '05503', '05504', '05505', '05506', '05508', '05512', '05514', '05516', '05517', '05518', '05520', '05532', '05534', '05536', '05538', '05550', '05551', '05552', '05556', '05558', '05560', '05564', '05576', '05578', '05580', '05582', '05586', '05590', '05592', '05594', '05600', '05604', '05610', '05612', '05614', '05620', '05621', '05622', '05626', '05628', '05630', '05632', '05644', '05660', '05661', '05664', '05670', '05672', '05673', '05674', '05675', '05676', '05680', '05690', '05696', '05700', '05710', '05720', '05990', '06250', '06509', '06550', '06570', '06660']),
      MalaysiaCity('Ayer Hitam', <String>['06150']),
      MalaysiaCity('Baling', <String>['09100']),
      MalaysiaCity('Bandar Baharu', <String>['34950']),
      MalaysiaCity('Bandar Bahru', <String>['14290', '14390']),
      MalaysiaCity('Bedong', <String>['08100', '08110']),
      MalaysiaCity('Bukit Kayu Hitam', <String>['06050']),
      MalaysiaCity('Changloon', <String>['06010']),
      MalaysiaCity('Gurun', <String>['08300', '08330', '08800']),
      MalaysiaCity('Jeniang', <String>['08320', '08700']),
      MalaysiaCity('Jitra', <String>['06000', '06007', '06009']),
      MalaysiaCity('Karangan', <String>['09700']),
      MalaysiaCity('Kepala Batas', <String>['06200', '06207', '06209']),
      MalaysiaCity('Kodiang', <String>['06100']),
      MalaysiaCity('Kota Kuala Muda', <String>['08500', '08507', '08509']),
      MalaysiaCity('Kota Sarang Semut', <String>['06800']),
      MalaysiaCity('Kuala Kedah', <String>['06600']),
      MalaysiaCity('Kuala Ketil', <String>['09300', '09310']),
      MalaysiaCity('Kuala Nerang', <String>['06300']),
      MalaysiaCity('Kuala Pegang', <String>['09110']),
      MalaysiaCity('Kulim', <String>['09000', '09007', '09009', '09010', '09020']),
      MalaysiaCity('Kupang', <String>['09200']),
      MalaysiaCity('Langgar', <String>['06500', '06507']),
      MalaysiaCity('Langkawi', <String>['07000', '07007', '07009', '07100']),
      MalaysiaCity('Lunas', <String>['09600']),
      MalaysiaCity('Merbok', <String>['08400', '08407', '08409']),
      MalaysiaCity('Padang Serai', <String>['09400', '09410']),
      MalaysiaCity('Pendang', <String>['06700', '06707', '06709', '06710', '06720', '06750', '06760']),
      MalaysiaCity('Pokok Sena', <String>['06350', '06400']),
      MalaysiaCity('Serdang', <String>['09800', '09810']),
      MalaysiaCity('Sik', <String>['08200', '08210', '08340']),
      MalaysiaCity('Simpang Empat', <String>['06650', '06680']),
      MalaysiaCity('Sungai Petani', <String>['08000', '08007', '08009', '08010', '08600']),
      MalaysiaCity('Yan', <String>['06900', '06910']),
    ]),
    MalaysiaState('Kelantan', <MalaysiaCity>[
      MalaysiaCity('Ayer Lanas', <String>['17700']),
      MalaysiaCity('Bachok', <String>['16020', '16030', '16050', '16060', '16070', '16090', '16300', '16310', '16320', '16350', '16370', '16390']),
      MalaysiaCity('Cherang Ruku', <String>['16700']),
      MalaysiaCity('Dabong', <String>['18200']),
      MalaysiaCity('Gua Musang', <String>['18300']),
      MalaysiaCity('Jeli', <String>['17600']),
      MalaysiaCity('Kem Desa Pahlawan', <String>['16500']),
      MalaysiaCity('Ketereh', <String>['16450']),
      MalaysiaCity('Kota Bharu', <String>['15000', '15050', '15100', '15150', '15159', '15160', '15200', '15300', '15350', '15400', '15500', '15502', '15503', '15504', '15505', '15506', '15508', '15512', '15514', '15516', '15517', '15518', '15519', '15520', '15524', '15529', '15532', '15534', '15536', '15538', '15540', '15546', '15548', '15550', '15551', '15556', '15558', '15560', '15564', '15570', '15572', '15576', '15578', '15582', '15586', '15590', '15592', '15594', '15596', '15600', '15604', '15606', '15608', '15609', '15610', '15612', '15614', '15616', '15620', '15622', '15623', '15624', '15626', '15628', '15630', '15632', '15634', '15644', '15646', '15648', '15658', '15660', '15661', '15662', '15664', '15670', '15672', '15673', '15674', '15676', '15680', '15690', '15700', '15710', '15720', '15730', '15740', '15988', '15990', '16010', '16100', '16109', '16150']),
      MalaysiaCity('Kuala Balah', <String>['17610']),
      MalaysiaCity('Kuala Krai', <String>['18000', '18020', '18050']),
      MalaysiaCity('Machang', <String>['18500']),
      MalaysiaCity('Melor', <String>['16400']),
      MalaysiaCity('Pasir Mas', <String>['17000', '17007', '17009', '17010', '17020', '17030', '17040', '17050', '17060', '17070']),
      MalaysiaCity('Pasir Puteh', <String>['16800']),
      MalaysiaCity('Pulai Chondong', <String>['16600']),
      MalaysiaCity('Rantau Panjang', <String>['17200']),
      MalaysiaCity('Selising', <String>['16810']),
      MalaysiaCity('Tanah Merah', <String>['17500', '17507', '17509', '17510', '17520', '17599']),
      MalaysiaCity('Temangan', <String>['18400']),
      MalaysiaCity('Tumpat', <String>['16080', '16200', '16210']),
      MalaysiaCity('Wakaf Bharu', <String>['16040', '16250', '16266']),
    ]),
    MalaysiaState('Melaka', <MalaysiaCity>[
      MalaysiaCity('Alor Gajah', <String>['78000', '78009']),
      MalaysiaCity('Asahan', <String>['77100', '77109']),
      MalaysiaCity('Ayer Keroh', <String>['75450']),
      MalaysiaCity('Bemban', <String>['77200']),
      MalaysiaCity('Durian Tunggal', <String>['76100', '76109']),
      MalaysiaCity('Jasin', <String>['77000', '77007', '77008', '77009']),
      MalaysiaCity('Kem Trendak', <String>['76200']),
      MalaysiaCity('Kuala Sungai Baru', <String>['78200']),
      MalaysiaCity('Lubok China', <String>['78100']),
      MalaysiaCity('Masjid Tanah', <String>['78300', '78307', '78309']),
      MalaysiaCity('Melaka', <String>['75000', '75050', '75100', '75150', '75200', '75250', '75260', '75300', '75350', '75400', '75430', '75460', '76450']),
      MalaysiaCity('Merlimau', <String>['77300']),
      MalaysiaCity('Selandar', <String>['77500']),
      MalaysiaCity('Sungai Rambai', <String>['77400']),
      MalaysiaCity('Sungai Udang', <String>['76300']),
      MalaysiaCity('Tanjong Kling', <String>['76400', '76409']),
    ]),
    MalaysiaState('Negeri Sembilan', <MalaysiaCity>[
      MalaysiaCity('Bahau', <String>['72100', '72107', '72109']),
      MalaysiaCity('Bandar Baru Enstek', <String>['71760']),
      MalaysiaCity('Bandar Seri Jempol', <String>['72120', '72127', '72129']),
      MalaysiaCity('Batu Kikir', <String>['72200', '72207', '72209']),
      MalaysiaCity('Gemas', <String>['73400', '73409', '73410', '73420', '73480']),
      MalaysiaCity('Gemencheh', <String>['73200', '73207', '73209', '73300', '73309']),
      MalaysiaCity('Johol', <String>['73100', '73109']),
      MalaysiaCity('Kota', <String>['71350', '71359']),
      MalaysiaCity('Kuala Klawang', <String>['71600', '71609', '71650', '71659']),
      MalaysiaCity('Kuala Pilah', <String>['72000', '72007', '72009', '72500', '72507', '72509']),
      MalaysiaCity('Labu', <String>['71900', '71907', '71909']),
      MalaysiaCity('Linggi', <String>['71150', '71159']),
      MalaysiaCity('Mantin', <String>['71700', '71707', '71709', '71750', '71759']),
      MalaysiaCity('Nilai', <String>['71800', '71807', '71809', '71850']),
      MalaysiaCity('Port Dickson', <String>['71000', '71007', '71009', '71010', '71960', '71999']),
      MalaysiaCity('Pusat Bandar Palong', <String>['73430', '73440', '73450', '73460', '73470']),
      MalaysiaCity('Rantau', <String>['71100', '71109', '71200', '71209']),
      MalaysiaCity('Rembau', <String>['71300', '71309', '71400', '71409']),
      MalaysiaCity('Rompin', <String>['73500', '73507', '73509']),
      MalaysiaCity('Seremban', <String>['70000', '70100', '70200', '70300', '70400', '70450', '70500', '70502', '70503', '70504', '70505', '70506', '70508', '70512', '70516', '70517', '70518', '70532', '70534', '70536', '70540', '70546', '70548', '70550', '70551', '70558', '70560', '70564', '70570', '70572', '70576', '70578', '70582', '70586', '70590', '70592', '70594', '70596', '70600', '70604', '70606', '70608', '70609', '70610', '70620', '70626', '70628', '70632', '70634', '70644', '70646', '70648', '70658', '70664', '70670', '70672', '70673', '70674', '70676', '70690', '70700', '70710', '70720', '70730', '70740', '70750', '70990', '71450', '71459', '71770', '71950']),
      MalaysiaCity('Si Rusa', <String>['71050', '71059', '71250', '71259']),
      MalaysiaCity('Simpang Durian', <String>['72400', '72409']),
      MalaysiaCity('Simpang Pertang', <String>['72300', '72307', '72309']),
      MalaysiaCity('Tampin', <String>['73000', '73007', '73009']),
      MalaysiaCity('Tanjong Ipoh', <String>['71500', '71509', '71550', '71559']),
    ]),
    MalaysiaState('Pahang', <MalaysiaCity>[
      MalaysiaCity('Balok', <String>['26080', '26100', '26150', '26190']),
      MalaysiaCity('Bandar Pusat Jengka', <String>['26400', '26410', '26420', '26430', '26440', '26450', '26460', '26485', '26490', '27080']),
      MalaysiaCity('Bandar Tun Abdul Razak', <String>['26900', '26999']),
      MalaysiaCity('Benta', <String>['27300', '27310']),
      MalaysiaCity('Bentong', <String>['28700', '28707', '28709', '28730', '28740', '28750']),
      MalaysiaCity('Brinchang', <String>['39100']),
      MalaysiaCity('Bukit Fraser', <String>['49000']),
      MalaysiaCity('Bukit Goh', <String>['26050', '26090']),
      MalaysiaCity('Chenor', <String>['28100']),
      MalaysiaCity('Chini', <String>['26690']),
      MalaysiaCity('Damak', <String>['27030']),
      MalaysiaCity('Dong', <String>['27400']),
      MalaysiaCity('Gambang', <String>['26300', '26310', '26320', '26330', '26340', '26350', '26360', '26370']),
      MalaysiaCity('Genting Highlands', <String>['69000']),
      MalaysiaCity('Jaya Gading', <String>['26250']),
      MalaysiaCity('Jerantut', <String>['27000', '27010', '27020', '27040', '27050', '27060', '27070', '27090', '27150']),
      MalaysiaCity('Karak', <String>['28600', '28610', '28620']),
      MalaysiaCity('Kemayan', <String>['28340', '28380']),
      MalaysiaCity('Kuala Krau', <String>['28050']),
      MalaysiaCity('Kuala Lipis', <String>['27200', '27207', '27209', '27210']),
      MalaysiaCity('Kuala Rompin', <String>['26800', '26810', '26820']),
      MalaysiaCity('Kuantan', <String>['25000', '25020', '25040', '25050', '25100', '25150', '25200', '25250', '25300', '25320', '25350', '25500', '25502', '25503', '25504', '25505', '25506', '25508', '25509', '25512', '25514', '25516', '25517', '25518', '25520', '25524', '25529', '25532', '25534', '25536', '25538', '25540', '25546', '25548', '25550', '25551', '25552', '25556', '25558', '25560', '25564', '25570', '25576', '25578', '25582', '25584', '25586', '25590', '25592', '25594', '25596', '25598', '25600', '25604', '25606', '25608', '25609', '25610', '25612', '25614', '25620', '25622', '25626', '25628', '25630', '25632', '25644', '25646', '25648', '25656', '25660', '25661', '25662', '25670', '25672', '25673', '25674', '25676', '25690', '25700', '25710', '25720', '25730', '25740', '25750', '25990', '26000', '26010', '26040', '26060', '26070', '26140', '26180']),
      MalaysiaCity('Lanchang', <String>['28500']),
      MalaysiaCity('Lurah Bilut', <String>['28800']),
      MalaysiaCity('Maran', <String>['26500']),
      MalaysiaCity('Mentakab', <String>['28400', '28407', '28409']),
      MalaysiaCity('Muadzam Shah', <String>['26700']),
      MalaysiaCity('Padang Tengku', <String>['27100']),
      MalaysiaCity('Pekan', <String>['26600', '26607', '26609', '26610', '26620', '26630', '26640', '26650', '26660', '26680']),
      MalaysiaCity('Raub', <String>['27600', '27607', '27609', '27610', '27620', '27630', '27670']),
      MalaysiaCity('Ringlet', <String>['39200']),
      MalaysiaCity('Sega', <String>['27660']),
      MalaysiaCity('Sungai Koyan', <String>['27650']),
      MalaysiaCity('Sungai Lembing', <String>['26200']),
      MalaysiaCity('Sungai Ruan', <String>['27500']),
      MalaysiaCity('Tanah Rata', <String>['39000', '39007', '39009', '39010']),
      MalaysiaCity('Temerloh', <String>['28000', '28007', '28009', '28010', '28020', '28030', '28040']),
      MalaysiaCity('Triang', <String>['28200', '28300', '28310', '28320', '28330', '28350']),
    ]),
    MalaysiaState('Perak', <MalaysiaCity>[
      MalaysiaCity('Ayer Tawar', <String>['32400']),
      MalaysiaCity('Bagan Datoh', <String>['36100']),
      MalaysiaCity('Bagan Serai', <String>['34300', '34310']),
      MalaysiaCity('Bandar Seri Iskandar', <String>['32610']),
      MalaysiaCity('Batu Gajah', <String>['31000', '31007', '31009']),
      MalaysiaCity('Batu Kurau', <String>['34500', '34510', '34520']),
      MalaysiaCity('Behrang Stesen', <String>['35950']),
      MalaysiaCity('Bidor', <String>['35500']),
      MalaysiaCity('Bota', <String>['32600']),
      MalaysiaCity('Bruas', <String>['32700']),
      MalaysiaCity('Changkat Jering', <String>['34850']),
      MalaysiaCity('Changkat Keruing', <String>['32500']),
      MalaysiaCity('Chemor', <String>['31200']),
      MalaysiaCity('Chenderiang', <String>['35300']),
      MalaysiaCity('Chenderong Balai', <String>['36600']),
      MalaysiaCity('Chikus', <String>['36750']),
      MalaysiaCity('Enggor', <String>['33600']),
      MalaysiaCity('Gerik', <String>['33300', '33310', '33320']),
      MalaysiaCity('Gopeng', <String>['31600', '31610']),
      MalaysiaCity('Hutan Melintang', <String>['36400']),
      MalaysiaCity('Intan', <String>['33200']),
      MalaysiaCity('Ipoh', <String>['30000', '30010', '30020', '30100', '30200', '30205', '30250', '30300', '30350', '30400', '30450', '30500', '30502', '30503', '30504', '30505', '30506', '30508', '30510', '30512', '30516', '30517', '30518', '30519', '30520', '30524', '30532', '30534', '30536', '30540', '30542', '30546', '30548', '30550', '30551', '30552', '30554', '30556', '30560', '30564', '30570', '30576', '30580', '30582', '30586', '30590', '30592', '30594', '30596', '30600', '30604', '30606', '30609', '30610', '30612', '30614', '30620', '30621', '30622', '30626', '30628', '30630', '30632', '30634', '30644', '30646', '30648', '30656', '30658', '30660', '30661', '30662', '30664', '30668', '30670', '30673', '30674', '30676', '30682', '30690', '30700', '30710', '30720', '30730', '30740', '30750', '30760', '30770', '30780', '30790', '30800', '30810', '30820', '30830', '30840', '30900', '30902', '30904', '30906', '30908', '30910', '30912', '30988', '30990', '31350', '31400', '31407', '31409', '31450', '31500', '31650', '31672']),
      MalaysiaCity('Jeram', <String>['31850']),
      MalaysiaCity('Kampar', <String>['31900', '31907', '31909', '31910', '31920', '31950']),
      MalaysiaCity('Kampung Gajah', <String>['36800', '36810']),
      MalaysiaCity('Kampung Kepayang', <String>['31300']),
      MalaysiaCity('Kamunting', <String>['34600']),
      MalaysiaCity('Kuala Kangsar', <String>['33000', '33007', '33009', '33010', '33020', '33030', '33040']),
      MalaysiaCity('Kuala Kurau', <String>['34350']),
      MalaysiaCity('Kuala Sepetang', <String>['34650']),
      MalaysiaCity('Lambor Kanan', <String>['32900', '32999']),
      MalaysiaCity('Langkap', <String>['36700']),
      MalaysiaCity('Lenggong', <String>['33400', '33410', '33420']),
      MalaysiaCity('Lumut', <String>['32200']),
      MalaysiaCity('Malim Nawar', <String>['31700']),
      MalaysiaCity('Manong', <String>['33800']),
      MalaysiaCity('Matang', <String>['34750']),
      MalaysiaCity('Padang Rengas', <String>['33700']),
      MalaysiaCity('Pangkor', <String>['32300']),
      MalaysiaCity('Pantai Remis', <String>['34900', '34910']),
      MalaysiaCity('Parit', <String>['32800', '32810']),
      MalaysiaCity('Parit Buntar', <String>['34200']),
      MalaysiaCity('Pengkalan Hulu', <String>['33100']),
      MalaysiaCity('Pusing', <String>['31550', '31560']),
      MalaysiaCity('Rantau Panjang', <String>['34140']),
      MalaysiaCity('Sauk', <String>['33500']),
      MalaysiaCity('Selama', <String>['34100', '34120', '34130']),
      MalaysiaCity('Selekoh', <String>['36200', '36207', '36209']),
      MalaysiaCity('Seri Manjung', <String>['32040', '32050']),
      MalaysiaCity('Simpang', <String>['34700']),
      MalaysiaCity('Simpang Ampat Semanggol', <String>['34400']),
      MalaysiaCity('Sitiawan', <String>['32000', '32010', '32020']),
      MalaysiaCity('Slim River', <String>['35800', '35820']),
      MalaysiaCity('Sungai Siput', <String>['31050', '31100', '31120']),
      MalaysiaCity('Sungai Sumun', <String>['36300', '36307', '36309']),
      MalaysiaCity('Sungkai', <String>['35600']),
      MalaysiaCity('TLDM Lumut', <String>['32100']),
      MalaysiaCity('Taiping', <String>['34000', '34007', '34008', '34009', '34010', '34020', '34030']),
      MalaysiaCity('Tanjong Malim', <String>['35900', '35907', '35909', '35910']),
      MalaysiaCity('Tanjong Piandang', <String>['34250']),
      MalaysiaCity('Tanjong Rambutan', <String>['31250']),
      MalaysiaCity('Tanjong Tualang', <String>['31800']),
      MalaysiaCity('Tapah', <String>['35000', '35007', '35009']),
      MalaysiaCity('Tapah Road', <String>['35400']),
      MalaysiaCity('Teluk Intan', <String>['36000', '36007', '36008', '36009', '36010', '36020', '36030', '36110']),
      MalaysiaCity('Temoh', <String>['35350']),
      MalaysiaCity('Trolak', <String>['35700']),
      MalaysiaCity('Trong', <String>['34800']),
      MalaysiaCity('Tronoh', <String>['31750']),
      MalaysiaCity('Ulu Bernam', <String>['36500']),
      MalaysiaCity('Ulu Kinta', <String>['31150', '31199']),
    ]),
    MalaysiaState('Perlis', <MalaysiaCity>[
      MalaysiaCity('Arau', <String>['02600', '02607', '02609']),
      MalaysiaCity('Kaki Bukit', <String>['02200']),
      MalaysiaCity('Kangar', <String>['01000', '01007', '01009', '01500', '01502', '01503', '01504', '01505', '01506', '01508', '01512', '01514', '01516', '01517', '01518', '01524', '01529', '01532', '01538', '01540', '01546', '01550', '01551', '01556', '01560', '01564', '01570', '01572', '01576', '01578', '01582', '01586', '01590', '01592', '01594', '01596', '01598', '01600', '01604', '01606', '01608', '01609', '01610', '01612', '01614', '01620', '01622', '01626', '01628', '01630', '01632', '01634', '01644', '01646', '01648', '01660', '01664', '01670', '01672', '01673', '01674', '01676', '01680', '01694', '02400', '02450', '02500']),
      MalaysiaCity('Kuala Perlis', <String>['02000']),
      MalaysiaCity('Padang Besar', <String>['02100']),
      MalaysiaCity('Simpang Ampat', <String>['02700', '02707', '02709', '02800']),
    ]),
    MalaysiaState('Pulau Pinang', <MalaysiaCity>[
      MalaysiaCity('Ayer Itam', <String>['11500']),
      MalaysiaCity('Balik Pulau', <String>['11000', '11010', '11020']),
      MalaysiaCity('Batu Ferringhi', <String>['11100']),
      MalaysiaCity('Batu Maung', <String>['11960']),
      MalaysiaCity('Bayan Lepas', <String>['11900', '11910', '11920', '11950']),
      MalaysiaCity('Bukit Mertajam', <String>['14000', '14007', '14009', '14020']),
      MalaysiaCity('Butterworth', <String>['12000', '12100', '12200', '12300', '12700', '12710', '12720', '12990', '13000', '13009', '13020', '13050', '13400', '13409', '13800']),
      MalaysiaCity('Gelugor', <String>['11700']),
      MalaysiaCity('Jelutong', <String>['11600', '11609']),
      MalaysiaCity('Kepala Batas', <String>['13200', '13210', '13220']),
      MalaysiaCity('Kubang Semang', <String>['14400']),
      MalaysiaCity('Nibong Tebal', <String>['14300', '14310', '14320']),
      MalaysiaCity('Penaga', <String>['13100', '13110']),
      MalaysiaCity('Penang Hill', <String>['11300']),
      MalaysiaCity('Perai', <String>['13600', '13700']),
      MalaysiaCity('Permatang Pauh', <String>['13500']),
      MalaysiaCity('Pulau Pinang', <String>['10000', '10050', '10100', '10150', '10200', '10250', '10300', '10350', '10400', '10450', '10460', '10470', '10500', '10502', '10503', '10504', '10505', '10506', '10508', '10512', '10514', '10516', '10518', '10524', '10534', '10538', '10540', '10542', '10546', '10550', '10551', '10552', '10558', '10560', '10564', '10566', '10570', '10576', '10578', '10582', '10590', '10592', '10593', '10594', '10596', '10600', '10604', '10609', '10610', '10612', '10620', '10622', '10626', '10628', '10634', '10646', '10648', '10660', '10661', '10662', '10670', '10672', '10673', '10674', '10676', '10690', '10710', '10720', '10730', '10740', '10750', '10760', '10770', '10780', '10790', '10800', '10810', '10820', '10830', '10840', '10850', '10910', '10920', '10990', '11050', '11060', '11400', '11409']),
      MalaysiaCity('Simpang Ampat', <String>['14100', '14101', '14110', '14120']),
      MalaysiaCity('Sungai Jawi', <String>['14200']),
      MalaysiaCity('Tanjong Bungah', <String>['11200']),
      MalaysiaCity('Tasek Gelugor', <String>['13300', '13310']),
      MalaysiaCity('Usm Pulau Pinang', <String>['11800']),
    ]),
    MalaysiaState('Sabah', <MalaysiaCity>[
      MalaysiaCity('Beaufort', <String>['89800', '89807', '89808', '89809']),
      MalaysiaCity('Beluran', <String>['90100', '90107', '90109']),
      MalaysiaCity('Beverly', <String>['88700', '89260']),
      MalaysiaCity('Bongawan', <String>['89700', '89707', '89708', '89709']),
      MalaysiaCity('Inanam', <String>['88857']),
      MalaysiaCity('Keningau', <String>['89000', '89007', '89008', '89009']),
      MalaysiaCity('Kota Belud', <String>['89150', '89157', '89158', '89159']),
      MalaysiaCity('Kota Kinabalu', <String>['88000', '88100', '88110', '88150', '88200', '88220', '88300', '88400', '88450', '88458', '88460', '88500', '88502', '88504', '88505', '88506', '88508', '88510', '88512', '88514', '88516', '88518', '88520', '88526', '88527', '88532', '88534', '88538', '88540', '88546', '88550', '88551', '88552', '88554', '88556', '88558', '88560', '88562', '88564', '88566', '88568', '88570', '88572', '88576', '88580', '88582', '88586', '88590', '88592', '88594', '88596', '88598', '88600', '88602', '88604', '88606', '88608', '88609', '88610', '88612', '88614', '88617', '88618', '88620', '88621', '88622', '88624', '88626', '88628', '88630', '88632', '88634', '88644', '88646', '88648', '88656', '88658', '88660', '88661', '88662', '88670', '88672', '88673', '88675', '88676', '88680', '88690', '88740', '88757', '88758', '88759', '88760', '88761', '88762', '88763', '88764', '88765', '88766', '88767', '88768', '88769', '88770', '88771', '88772', '88773', '88774', '88775', '88776', '88777', '88778', '88779', '88780', '88781', '88782', '88783', '88784', '88785', '88786', '88787', '88788', '88789', '88790', '88800', '88801', '88802', '88803', '88804', '88805', '88806', '88807', '88808', '88809', '88810', '88811', '88812', '88813', '88814', '88815', '88816', '88817', '88818', '88819', '88820', '88821', '88822', '88823', '88824', '88825', '88826', '88827', '88828', '88829', '88830', '88831', '88832', '88833', '88834', '88835', '88836', '88837', '88838', '88839', '88840', '88841', '88842', '88843', '88844', '88845', '88846', '88847', '88848', '88849', '88850', '88851', '88852', '88853', '88854', '88855', '88860', '88861', '88862', '88863', '88865', '88866', '88867', '88868', '88869', '88870', '88871', '88872', '88873', '88874', '88875', '88900', '88901', '88902', '88903', '88904', '88905', '88906', '88988', '88990', '88991', '88992', '88993', '88994', '88995', '88996', '88997', '88998', '88999']),
      MalaysiaCity('Kota Kinabatangan', <String>['90200']),
      MalaysiaCity('Kota Marudu', <String>['89100', '89107', '89108', '89109']),
      MalaysiaCity('Kuala Penyu', <String>['89740', '89747', '89748', '89749']),
      MalaysiaCity('Kudat', <String>['89050', '89057', '89058', '89059']),
      MalaysiaCity('Kunak', <String>['91200', '91207', '91209']),
      MalaysiaCity('Lahad Datu', <String>['91100', '91108', '91109', '91110', '91111', '91112', '91113', '91114', '91115', '91116', '91117', '91118', '91119', '91120', '91121', '91122', '91123', '91124', '91125', '91126', '91127', '91128', '91150']),
      MalaysiaCity('Likas', <String>['88856']),
      MalaysiaCity('Membakut', <String>['89720', '89727', '89728', '89729']),
      MalaysiaCity('Menumbok', <String>['89760', '89767', '89768', '89769']),
      MalaysiaCity('Nabawan', <String>['89950', '89957', '89958', '89959']),
      MalaysiaCity('Pamol', <String>['90400']),
      MalaysiaCity('Papar', <String>['89600', '89607', '89608', '89609']),
      MalaysiaCity('Penampang', <String>['89500', '89507', '89508', '89509']),
      MalaysiaCity('Putatan', <String>['88721', '88722', '88723', '88724', '88725']),
      MalaysiaCity('Ranau', <String>['89300', '89307', '89308', '89309', '89320', '89350', '89357']),
      MalaysiaCity('Sandakan', <String>['90000', '90008', '90009', '90300', '90307', '90700', '90701', '90702', '90703', '90704', '90705', '90706', '90707', '90708', '90709', '90711', '90712', '90713', '90714', '90715', '90716', '90717', '90718', '90719', '90720', '90721', '90722', '90723', '90724', '90725', '90726', '90727', '90728', '90729', '90730', '90731', '90732', '90733', '90734', '90735', '90736', '90737', '90738', '90739', '90740', '90741']),
      MalaysiaCity('Semporna', <String>['91300', '91307', '91308', '91309']),
      MalaysiaCity('Sipitang', <String>['89850', '89857', '89858', '89859']),
      MalaysiaCity('Tambunan', <String>['89650', '89657', '89658', '89659']),
      MalaysiaCity('Tamparuli', <String>['89250', '89257', '89258', '89259']),
      MalaysiaCity('Tanjung Aru', <String>['88858']),
      MalaysiaCity('Tawau', <String>['91000', '91007', '91008', '91009', '91010', '91011', '91012', '91013', '91014', '91015', '91016', '91017', '91018', '91019', '91020', '91021', '91022', '91023', '91024', '91025', '91026', '91027', '91028', '91029', '91030', '91031', '91032', '91033', '91034', '91035', '91045', '91056']),
      MalaysiaCity('Tenghilan', <String>['89260']),
      MalaysiaCity('Tenom', <String>['89900', '89907', '89908', '89909']),
      MalaysiaCity('Tuaran', <String>['89200', '89207', '89208', '89209']),
    ]),
    MalaysiaState('Sarawak', <MalaysiaCity>[
      MalaysiaCity('Asajaya', <String>['94600']),
      MalaysiaCity('Balingian', <String>['96350']),
      MalaysiaCity('Baram', <String>['98050', '98057', '98058', '98059']),
      MalaysiaCity('Bau', <String>['94000', '94007', '94009']),
      MalaysiaCity('Bekenu', <String>['98150', '98157', '98159']),
      MalaysiaCity('Belaga', <String>['96900', '96950', '96999']),
      MalaysiaCity('Belawai', <String>['96150']),
      MalaysiaCity('Betong', <String>['95700', '95707', '95709']),
      MalaysiaCity('Bintangor', <String>['96500', '96507', '96508', '96509', '96510']),
      MalaysiaCity('Bintulu', <String>['97000', '97004', '97007', '97008', '97009', '97010', '97011', '97012', '97013', '97014', '97015', '97300']),
      MalaysiaCity('Dalat', <String>['96300', '96307', '96309']),
      MalaysiaCity('Daro', <String>['96200']),
      MalaysiaCity('Debak', <String>['95500']),
      MalaysiaCity('Engkilili', <String>['95800']),
      MalaysiaCity('Julau', <String>['96600']),
      MalaysiaCity('Kabong', <String>['94650']),
      MalaysiaCity('Kanowit', <String>['96700', '96707', '96709']),
      MalaysiaCity('Kapit', <String>['96800', '96807', '96809']),
      MalaysiaCity('Kota Samarahan', <String>['94300']),
      MalaysiaCity('Kuching', <String>['93000', '93010', '93030', '93050', '93100', '93150', '93200', '93250', '93300', '93350', '93400', '93450', '93500', '93502', '93503', '93504', '93505', '93506', '93507', '93508', '93514', '93516', '93517', '93518', '93519', '93520', '93527', '93529', '93532', '93540', '93550', '93551', '93552', '93554', '93556', '93558', '93560', '93564', '93566', '93570', '93572', '93576', '93578', '93582', '93586', '93590', '93592', '93594', '93596', '93600', '93604', '93606', '93608', '93609', '93610', '93612', '93614', '93618', '93619', '93620', '93626', '93628', '93632', '93634', '93648', '93658', '93660', '93661', '93662', '93668', '93670', '93672', '93677', '93690', '93694', '93700', '93702', '93704', '93706', '93708', '93710', '93712', '93714', '93716', '93718', '93720', '93722', '93724', '93726', '93728', '93730', '93732', '93734', '93736', '93738', '93740', '93742', '93744', '93746', '93748', '93750', '93752', '93754', '93756', '93758', '93760', '93762', '93764', '93900', '93902', '93904', '93906', '93908', '93910', '93912', '93914', '93916', '93990']),
      MalaysiaCity('Lawas', <String>['98850', '98857', '98859']),
      MalaysiaCity('Limbang', <String>['98700', '98707', '98708', '98709']),
      MalaysiaCity('Lingga', <String>['94900']),
      MalaysiaCity('Long Lama', <String>['98300']),
      MalaysiaCity('Lubok Antu', <String>['95900']),
      MalaysiaCity('Lundu', <String>['94500', '94507', '94509']),
      MalaysiaCity('Lutong', <String>['98100', '98107', '98109']),
      MalaysiaCity('Matu', <String>['96250']),
      MalaysiaCity('Miri', <String>['98000', '98007', '98008', '98009']),
      MalaysiaCity('Mukah', <String>['96400', '96410']),
      MalaysiaCity('Nanga Medamit', <String>['98750']),
      MalaysiaCity('Niah', <String>['98200']),
      MalaysiaCity('Pusa', <String>['94950']),
      MalaysiaCity('Pusat Mel Miri', <String>['98070']),
      MalaysiaCity('Roban', <String>['95300']),
      MalaysiaCity('Saratok', <String>['95400', '95407', '95409']),
      MalaysiaCity('Sarikei', <String>['96100', '96107', '96108', '96109']),
      MalaysiaCity('Sebauh', <String>['97100']),
      MalaysiaCity('Sebuyau', <String>['94850']),
      MalaysiaCity('Serian', <String>['94700', '94707', '94709', '94750', '94760']),
      MalaysiaCity('Sibu', <String>['96000', '96007', '96008', '96009']),
      MalaysiaCity('Sibu Jaya', <String>['96010']),
      MalaysiaCity('Siburan', <String>['94200']),
      MalaysiaCity('Simunjan', <String>['94800', '94807', '94809']),
      MalaysiaCity('Song', <String>['96850']),
      MalaysiaCity('Spaoh', <String>['95600']),
      MalaysiaCity('Sri Aman', <String>['95000', '95007', '95008', '95009']),
      MalaysiaCity('Sundar', <String>['98800']),
      MalaysiaCity('Tatau', <String>['97200']),
    ]),
    MalaysiaState('Selangor', <MalaysiaCity>[
      MalaysiaCity('Ampang', <String>['68000']),
      MalaysiaCity('Bandar Baru Bangi', <String>['43650']),
      MalaysiaCity('Bandar Puncak Alam', <String>['42300']),
      MalaysiaCity('Bangi', <String>['43600']),
      MalaysiaCity('Banting', <String>['42700']),
      MalaysiaCity('Batang Berjuntai', <String>['45600', '45607', '45609', '45620', '45630']),
      MalaysiaCity('Batang Kali', <String>['44300', '44309', '44330']),
      MalaysiaCity('Batu Caves', <String>['68100']),
      MalaysiaCity('Beranang', <String>['43700', '43701']),
      MalaysiaCity('Bukit Rotan', <String>['45700']),
      MalaysiaCity('Cheras', <String>['43200', '43207']),
      MalaysiaCity('Cyberjaya', <String>['63000', '63100', '63200', '63300']),
      MalaysiaCity('Dengkil', <String>['43800', '43807']),
      MalaysiaCity('Hulu Langat', <String>['43100']),
      MalaysiaCity('Jenjarom', <String>['42600', '42610', '42619']),
      MalaysiaCity('Jeram', <String>['45800']),
      MalaysiaCity('KLIA', <String>['64000']),
      MalaysiaCity('Kajang', <String>['43000', '43007', '43009', '43558']),
      MalaysiaCity('Kapar', <String>['42200', '42209']),
      MalaysiaCity('Kerling', <String>['44100']),
      MalaysiaCity('Klang', <String>['41000', '41050', '41070', '41100', '41150', '41160', '41200', '41205', '41250', '41299', '41300', '41301', '41400', '41500', '41506', '41560', '41586', '41600', '41670', '41672', '41700', '41710', '41720', '41730', '41750', '41780', '41900', '41902', '41904', '41906', '41908', '41910', '41912', '41914', '41916', '41918', '41990', '42100', '42150']),
      MalaysiaCity('Kuala Kubu Baru', <String>['44000', '44010', '44020', '44110']),
      MalaysiaCity('Kuala Selangor', <String>['45000', '45010']),
      MalaysiaCity('Pelabuhan Klang', <String>['42000', '42007', '42008', '42009']),
      MalaysiaCity('Petaling Jaya', <String>['46000', '46040', '46050', '46080', '46100', '46150', '46160', '46200', '46300', '46350', '46400', '46460', '46500', '46505', '46506', '46510', '46547', '46549', '46551', '46564', '46582', '46598', '46662', '46667', '46668', '46672', '46675', '46692', '46700', '46710', '46720', '46730', '46740', '46750', '46760', '46770', '46780', '46781', '46782', '46783', '46784', '46785', '46786', '46787', '46788', '46789', '46790', '46791', '46792', '46793', '46794', '46795', '46796', '46797', '46798', '46799', '46800', '46801', '46802', '46803', '46804', '46805', '46806', '46860', '46870', '46960', '46962', '46964', '46966', '46968', '46970', '46972', '46974', '46976', '46978', '46990', '47300', '47301', '47304', '47307', '47308', '47309', '47310', '47400', '47410', '47430', '47800', '47801', '47810', '47820', '47829', '47830', '47850']),
      MalaysiaCity('Puchong', <String>['47100', '47110', '47120', '47130', '47140', '47150', '47160', '47170', '47180', '47190']),
      MalaysiaCity('Pulau Carey', <String>['42960', '42999']),
      MalaysiaCity('Pulau Indah', <String>['42900', '42907', '42920']),
      MalaysiaCity('Pulau Ketam', <String>['42940']),
      MalaysiaCity('Rasa', <String>['44200']),
      MalaysiaCity('Rawang', <String>['48000', '48009', '48010', '48020', '48050', '48100', '48300', '48302']),
      MalaysiaCity('Sabak Bernam', <String>['45200', '45207', '45209']),
      MalaysiaCity('Sekinchan', <String>['45400']),
      MalaysiaCity('Semenyih', <String>['43500']),
      MalaysiaCity('Sepang', <String>['43900']),
      MalaysiaCity('Serdang', <String>['43400']),
      MalaysiaCity('Serendah', <String>['48200', '48250']),
      MalaysiaCity('Seri Kembangan', <String>['43300', '43399']),
      MalaysiaCity('Shah Alam', <String>['40000', '40100', '40140', '40150', '40160', '40169', '40170', '40179', '40200', '40250', '40300', '40350', '40400', '40409', '40410', '40440', '40450', '40460', '40470', '40490', '40500', '40502', '40503', '40505', '40512', '40517', '40520', '40529', '40542', '40548', '40550', '40551', '40560', '40564', '40570', '40572', '40576', '40578', '40582', '40590', '40592', '40594', '40596', '40598', '40600', '40604', '40607', '40608', '40610', '40612', '40620', '40622', '40626', '40630', '40632', '40646', '40648', '40650', '40660', '40664', '40670', '40672', '40673', '40674', '40675', '40676', '40680', '40690', '40700', '40702', '40704', '40706', '40708', '40710', '40712', '40714', '40716', '40718', '40720', '40722', '40724', '40726', '40728', '40730', '40732', '40800', '40802', '40804', '40806', '40808', '40810', '40900', '40912', '40915', '40990', '42450']),
      MalaysiaCity('Subang Airport', <String>['47200', '47210']),
      MalaysiaCity('Subang Jaya', <String>['47500', '47507', '47510', '47600', '47601', '47610', '47618', '47620', '47630', '47640', '47650', '55555']),
      MalaysiaCity('Sungai Ayer Tawar', <String>['45100']),
      MalaysiaCity('Sungai Besar', <String>['45300']),
      MalaysiaCity('Sungai Buloh', <String>['47000', '47020', '47031']),
      MalaysiaCity('Sungai Pelek', <String>['43950', '43999']),
      MalaysiaCity('Tanjong Karang', <String>['45500']),
      MalaysiaCity('Tanjong Sepat', <String>['42800']),
      MalaysiaCity('Telok Panglima Garang', <String>['42425', '42500', '42507', '42509']),
    ]),
    MalaysiaState('Terengganu', <MalaysiaCity>[
      MalaysiaCity('Ajil', <String>['21800', '21810', '21820']),
      MalaysiaCity('Al Muktatfi Billah Shah', <String>['23400']),
      MalaysiaCity('Ayer Puteh', <String>['24050']),
      MalaysiaCity('Bukit Besi', <String>['23200']),
      MalaysiaCity('Bukit Payong', <String>['21400']),
      MalaysiaCity('Ceneh', <String>['24060']),
      MalaysiaCity('Chalok', <String>['21450']),
      MalaysiaCity('Cukai', <String>['24000', '24007', '24009', '24010', '24020', '24030', '24040']),
      MalaysiaCity('Dungun', <String>['23000', '23007', '23009', '23050']),
      MalaysiaCity('Jerteh', <String>['22000', '22010', '22020', '22030', '22040']),
      MalaysiaCity('Kampung Raja', <String>['22200']),
      MalaysiaCity('Kemasek', <String>['24200', '24207', '24209', '24210', '24220']),
      MalaysiaCity('Kerteh', <String>['24300']),
      MalaysiaCity('Ketengah Jaya', <String>['23300', '23345']),
      MalaysiaCity('Kijal', <String>['24100', '24107', '24109']),
      MalaysiaCity('Kuala Berang', <String>['21700']),
      MalaysiaCity('Kuala Besut', <String>['22300', '22307', '22309']),
      MalaysiaCity('Kuala Terengganu', <String>['20000', '20050', '20080', '20100', '20200', '20300', '20400', '20500', '20502', '20503', '20504', '20505', '20506', '20508', '20512', '20514', '20516', '20517', '20518', '20519', '20520', '20532', '20534', '20536', '20538', '20540', '20542', '20546', '20548', '20550', '20551', '20552', '20554', '20556', '20560', '20564', '20566', '20568', '20570', '20572', '20576', '20578', '20582', '20586', '20590', '20592', '20596', '20600', '20604', '20606', '20608', '20609', '20610', '20612', '20614', '20618', '20620', '20622', '20626', '20628', '20630', '20632', '20646', '20648', '20656', '20658', '20660', '20661', '20662', '20664', '20668', '20670', '20672', '20673', '20674', '20676', '20680', '20690', '20698', '20700', '20710', '20720', '20900', '20902', '20904', '20906', '20908', '20910', '20912', '20914', '20916', '20918', '20920', '20922', '20924', '20926', '20928', '20930', '20990', '20999', '21000', '21009', '21010', '21020', '21030', '21040', '21050', '21060', '21070', '21080', '21090', '21100', '21109', '21200', '21209', '21210', '21220', '21300', '21309']),
      MalaysiaCity('Marang', <String>['21600', '21610']),
      MalaysiaCity('Paka', <String>['23100']),
      MalaysiaCity('Permaisuri', <String>['22100', '22107', '22109', '22110', '22120']),
      MalaysiaCity('Sungai Tong', <String>['21500']),
    ]),
    MalaysiaState('Kuala Lumpur', <MalaysiaCity>[
      MalaysiaCity('Kuala Lumpur', <String>['50000', '50050', '50088', '50100', '50150', '50200', '50250', '50300', '50350', '50400', '50420', '50450', '50460', '50470', '50480', '50489', '50490', '50500', '50502', '50504', '50505', '50506', '50507', '50508', '50512', '50514', '50515', '50519', '50528', '50529', '50530', '50532', '50534', '50536', '50538', '50540', '50544', '50546', '50548', '50550', '50551', '50552', '50554', '50556', '50560', '50562', '50564', '50566', '50568', '50572', '50576', '50578', '50580', '50582', '50586', '50588', '50590', '50592', '50594', '50596', '50598', '50599', '50600', '50603', '50604', '50605', '50608', '50609', '50610', '50612', '50614', '50620', '50621', '50622', '50623', '50626', '50630', '50632', '50634', '50636', '50638', '50640', '50642', '50644', '50646', '50648', '50650', '50652', '50653', '50656', '50658', '50660', '50661', '50662', '50664', '50666', '50668', '50670', '50672', '50673', '50674', '50676', '50677', '50678', '50680', '50682', '50684', '50688', '50694', '50700', '50702', '50704', '50706', '50708', '50710', '50712', '50714', '50716', '50718', '50720', '50722', '50724', '50726', '50728', '50730', '50732', '50734', '50736', '50738', '50740', '50742', '50744', '50746', '50748', '50750', '50752', '50754', '50758', '50760', '50762', '50764', '50766', '50768', '50770', '50772', '50774', '50776', '50778', '50780', '50782', '50784', '50786', '50788', '50790', '50792', '50794', '50796', '50798', '50800', '50802', '50804', '50806', '50808', '50810', '50812', '50814', '50816', '50818', '50901', '50902', '50903', '50904', '50906', '50907', '50908', '50909', '50910', '50911', '50912', '50913', '50914', '50915', '50916', '50917', '50918', '50919', '50920', '50921', '50922', '50923', '50924', '50925', '50926', '50927', '50928', '50929', '50930', '50931', '50932', '50933', '50934', '50935', '50936', '50937', '50938', '50939', '50940', '50941', '50942', '50943', '50944', '50945', '50946', '50947', '50948', '50949', '50950', '50988', '50989', '50990', '51000', '51100', '51200', '51300', '51640', '51700', '51800', '51900', '51990', '52000', '52100', '52109', '52200', '52210', '52220', '53000', '53100', '53200', '53500', '53700', '53800', '53990', '54000', '54050', '54100', '54200', '54540', '55000', '55100', '55188', '55200', '55220', '55300', '55330', '55700', '55710', '55720', '55900', '55902', '55904', '55906', '55908', '55910', '55912', '55914', '55916', '55918', '55920', '55922', '55924', '55926', '55928', '55930', '55932', '55934', '55990', '56000', '56100', '57000', '57100', '57200', '57700', '57990', '58000', '58100', '58200', '58209', '58700', '58990', '59000', '59001', '59100', '59200', '59206', '59700', '59800', '59990', '60000']),
      MalaysiaCity('Setapak', <String>['53300']),
    ]),
    MalaysiaState('Labuan', <MalaysiaCity>[
      MalaysiaCity('Labuan', <String>['87000', '87007', '87008', '87010', '87011', '87012', '87013', '87014', '87015', '87016', '87017', '87018', '87019', '87020', '87021', '87022', '87023', '87024', '87025', '87026', '87027', '87028', '87029', '87030', '87031', '87032', '87033']),
    ]),
    MalaysiaState('Putrajaya', <MalaysiaCity>[
      MalaysiaCity('Putrajaya', <String>['62000', '62007', '62050', '62052', '62100', '62150', '62200', '62250', '62300', '62500', '62502', '62503', '62504', '62505', '62506', '62510', '62512', '62514', '62516', '62517', '62518', '62519', '62520', '62522', '62524', '62526', '62527', '62529', '62530', '62532', '62536', '62539', '62540', '62542', '62546', '62550', '62551', '62570', '62574', '62576', '62578', '62582', '62584', '62590', '62592', '62594', '62596', '62602', '62604', '62605', '62606', '62616', '62618', '62620', '62623', '62624', '62628', '62630', '62632', '62648', '62652', '62654', '62657', '62662', '62668', '62670', '62674', '62675', '62676', '62677', '62686', '62690', '62692', '62988']),
    ]),
  ];

  /// State names for a dropdown, in the same order as [states].
  static List<String> get stateNames =>
      states.map((state) => state.name).toList(growable: false);

  static final Map<String, MalaysiaState> _byName = <String, MalaysiaState>{
    for (final state in states) state.name: state,
  };

  /// The state record for [stateName], or null when it is not a valid
  /// Malaysian state/federal territory.
  static MalaysiaState? state(String? stateName) =>
      stateName == null ? null : _byName[stateName.trim()];

  /// True when [stateName] is one of the 16 states/territories.
  static bool isKnownState(String? stateName) => state(stateName) != null;

  /// Cities/townships inside [stateName] (empty for an unknown state).
  static List<String> citiesFor(String? stateName) {
    final record = state(stateName);
    if (record == null) return const <String>[];
    return record.cities
        .map((city) => city.name)
        .toList(growable: false);
  }

  /// True when [cityName] belongs to [stateName].
  static bool isKnownCity(String? stateName, String? cityName) {
    if (cityName == null) return false;
    final record = state(stateName);
    if (record == null) return false;
    final needle = cityName.trim().toLowerCase();
    return record.cities.any((city) => city.name.toLowerCase() == needle);
  }

  /// Postcodes valid for one locality. Postcodes stay strings so leading
  /// zeros are preserved (e.g. Perlis `01000`).
  static List<String> postcodesFor(String? stateName, String? cityName) {
    final record = state(stateName);
    if (record == null || cityName == null) return const <String>[];
    final needle = cityName.trim().toLowerCase();
    for (final city in record.cities) {
      if (city.name.toLowerCase() == needle) return city.postcodes;
    }
    return const <String>[];
  }

  /// True when [postcode] is one of the postcodes for that locality.
  static bool isKnownPostcode(
    String? stateName,
    String? cityName,
    String? postcode,
  ) {
    if (postcode == null) return false;
    return postcodesFor(stateName, cityName).contains(postcode.trim());
  }

  /// Every state that publishes [postcode]. A postcode may legitimately be
  /// shared by more than one locality, so this returns a list rather than
  /// guessing a single answer.
  static List<String> statesForPostcode(String? postcode) {
    final needle = (postcode ?? '').trim();
    if (needle.isEmpty) return const <String>[];
    final matches = <String>[];
    for (final state in states) {
      if (state.cities.any((city) => city.postcodes.contains(needle))) {
        matches.add(state.name);
      }
    }
    return List<String>.unmodifiable(matches);
  }

  /// Localities that publish [postcode] (possibly more than one).
  static List<String> citiesForPostcode(String? postcode) {
    final needle = (postcode ?? '').trim();
    if (needle.isEmpty) return const <String>[];
    final matches = <String>[];
    for (final state in states) {
      for (final city in state.cities) {
        if (city.postcodes.contains(needle)) matches.add(city.name);
      }
    }
    return List<String>.unmodifiable(matches);
  }
}
