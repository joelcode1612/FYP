import 'dart:convert';
import 'dart:io';
import 'package:sitewise_jaspr_web/features/assessment/data/chart_spec.dart';

void main() {
  final raw = jsonDecode(File('C:/Users/HP/AppData/Local/Temp/q05_spec.json').readAsStringSync()) as Map<String, dynamic>;
  final spec = (raw['spec'] as Map).cast<String, dynamic>();
  try {
    final m = ChartSpecModel.fromJson(spec);
    print('OK ${m.renderState.wire}');
  } catch (e) {
    print('FAIL $e');
  }
}
