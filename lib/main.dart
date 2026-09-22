import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const DTicketNavigatorApp());
}

class DTicketNavigatorApp extends StatelessWidget {
  const DTicketNavigatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'D-Ticket Navigator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
        ),
      ),
      home: const HomePage(),
    );
  }
}

class Station {
  final String id;
  final String name;
  final String location;
  final double? latitude;
  final double? longitude;
  final String? parentStation;
  final int locationType;
  final int priority;
  final String searchText;

  const Station({
    required this.id,
    required this.name,
    this.location = '',
    this.latitude,
    this.longitude,
    this.parentStation,
    this.locationType = 0,
    this.priority = 0,
    this.searchText = '',
  });

  factory Station.fromJson(Map<String, dynamic> json) {
    return Station(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      location: (json['location'] ?? '').toString(),
      latitude: _toDouble(json['lat']),
      longitude: _toDouble(json['lon']),
      parentStation: _nullable(json['parent']),
      locationType: _toInt(json['type']),
      priority: _toInt(json['priority']),
      searchText: (json['search'] ?? '').toString(),
    );
  }

  static double? _toDouble(dynamic value) => value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '');

  static int _toInt(dynamic value) => value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '') ?? 0;

  static String? _nullable(dynamic value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }
}

class _ScoredStation {
  final Station station;
  final double score;

  const _ScoredStation(this.station, this.score);
}

class StationDatabase {
  final Map<String, List<Station>> _cache = {};

  Future<List<Station>> _loadBucket(String letter) async {
    if (_cache.containsKey(letter)) {
      return _cache[letter]!;
    }

    try {
      final text = await rootBundle.loadString(
        'assets/data/stations/$letter.json',
      );

      final decoded = jsonDecode(text);

      if (decoded is! List) {
        _cache[letter] = [];
        return [];
      }

      final result = <Station>[];

      for (final item in decoded) {
        if (item is! Map) {
          continue;
        }

        final station = Station.fromJson(
          Map<String, dynamic>.from(item),
        );

        if (station.id.isNotEmpty &&
            station.name.isNotEmpty) {
          result.add(station);
        }
      }

      _cache[letter] = result;
      return result;
    } catch (_) {
      _cache[letter] = [];
      return [];
    }
  }

  Future<void> load() async {
    // Nur prüfen, ob der Index vorhanden ist.
    // Die eigentlichen Daten werden erst bei der Suche
    // nach Bedarf geladen.
    await _loadBucket('a');
  }

  Future<List<Station>> search(
    String query, {
    int limit = 8,
  }) async {
    final normalized = _normalize(query);

    if (normalized.length < 2) {
      return [];
    }

    final tokens = _tokens(normalized);

    if (tokens.isEmpty) {
      return [];
    }

    final letters = <String>{};

    for (final token in tokens) {
      if (token.isNotEmpty &&
          RegExp(r'^[a-z]$').hasMatch(token[0])) {
        letters.add(token[0]);
      }
    }

    if (letters.isEmpty) {
      return [];
    }

    final all = <String, Station>{};

    for (final letter in letters) {
      for (final station in await _loadBucket(letter)) {
        all[station.id] = station;
      }
    }

    final scored = <_ScoredStation>[];

    for (final station in all.values) {
      final score = _score(
        station,
        normalized,
        tokens,
      );

      if (score > 0) {
        scored.add(
          _ScoredStation(
            station,
            score,
          ),
        );
      }
    }

    scored.sort((a, b) {
      final c = b.score.compareTo(a.score);

      if (c != 0) {
        return c;
      }

      return a.station.name
          .toLowerCase()
          .compareTo(
            b.station.name.toLowerCase(),
          );
    });

    return scored
        .take(limit)
        .map((e) => e.station)
        .toList();
  }

  double _score(
    Station station,
    String query,
    List<String> queryTokens,
  ) {
    final name = _normalize(
      station.name,
    );

    final location = _normalize(
      station.location,
    );

    final combined =
        '$name $location'.trim();

    final nameTokens = _tokens(name);
    final locationTokens =
        _tokens(location);

    final allTokens = [
      ...nameTokens,
      ...locationTokens,
    ];

    double score = 0;

    if (name == query) {
      score += 5000;
    }

    if (name.startsWith(query)) {
      score += 2500;
    }

    if (name.contains(query)) {
      score += 1200;
    }

    if (location == query) {
      score += 3000;
    }

    if (location.startsWith(query)) {
      score += 1600;
    }

    if (location.contains(query)) {
      score += 800;
    }

    if (combined.contains(query)) {
      score += 300;
    }

    var matched = 0;

    for (final q in queryTokens) {
      if (q.length < 2) {
        continue;
      }

      var best = 0.0;

      for (final token in allTokens) {
        if (token == q) {
          best = _max(
            best,
            1000,
          );
        } else if (token.startsWith(q)) {
          best = _max(
            best,
            600,
          );
        } else if (token.contains(q)) {
          best = _max(
            best,
            300,
          );
        }
      }

      if (best > 0) {
        matched++;
        score += best;
      }
    }

    if (matched == 0) {
      return 0;
    }

    if (matched == queryTokens.length) {
      score += 1500;
    }

    final extra =
        allTokens.length - queryTokens.length;

    if (extra > 0) {
      score -= extra * 90;
    }

    score -= name.length * 0.5;
    score += station.priority * 0.5;

    if (station.locationType == 1) {
      score += 200;
    }

    return score;
  }

  List<String> _tokens(String value) {
    return value
        .split(RegExp(r'[^a-z0-9]+'))
        .where(
          (e) => e.isNotEmpty,
        )
        .toList();
  }

  String _normalize(String value) {
    var result = value
        .trim()
        .toLowerCase();

    result = result
        .replaceAll('ä', 'ae')
        .replaceAll('ö', 'oe')
        .replaceAll('ü', 'ue')
        .replaceAll
