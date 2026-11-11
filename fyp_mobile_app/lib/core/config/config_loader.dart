import 'dart:convert';
import 'package:flutter/services.dart';

Future<Map<String, dynamic>> loadConfig() async {
  final data = await rootBundle.loadString(
    'assets/config/dev.json',
  );

  return jsonDecode(data) as Map<String, dynamic>;
}