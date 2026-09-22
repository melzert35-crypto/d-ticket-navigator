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

  factory Station.fromJson(
    Map<String, dynamic> json,
  ) {
    return Station(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      location:
          (json['location'] ?? '').toString(),
      latitude:
          _toDouble(json['lat']),
      longitude:
          _toDouble(json['lon']),
      parentStation:
          _toNullableString(
        json['parent'],
      ),
      locationType:
          _toInt(json['type']),
      priority:
          _toInt(json['priority']),
      searchText:
          (json['search'] ?? '')
              .toString(),
    );
  }

  static double? _toDouble(
    dynamic value,
  ) {
    if (value is num) {
      return value.toDouble();
    }

    return double.tryParse(
      value?.toString() ?? '',
    );
  }

  static int _toInt(
    dynamic value,
  ) {
    if (value is num) {
      return value.toInt();
    }

    return int.tryParse(
          value?.toString() ?? '',
        ) ??
        0;
  }

  static String? _toNullableString(
    dynamic value,
  ) {
    final text =
        value?.toString().trim();

    if (text == null ||
        text.isEmpty) {
      return null;
    }

    return text;
  }
}

class _ScoredStation {
  final Station station;
  final double score;

  const _ScoredStation({
    required this.station,
    required this.score,
  });
}

class StationDatabase {
  final Map<String, List<Station>>
      _cache = {};

  bool _loading = false;

  Future<void> load() async {
    if (_loading) {
      return;
    }

    _loading = true;

    try {
      await _loadBucket('a');
    } finally {
      _loading = false;
    }
  }

  Future<List<Station>> _loadBucket(
    String bucket,
  ) async {
    final key =
        bucket.toLowerCase();

    if (_cache.containsKey(key)) {
      return _cache[key]!;
    }

    try {
      final jsonText =
          await rootBundle.loadString(
        'assets/data/stations/$key.json',
      );

      final decoded =
          jsonDecode(jsonText);

      if (decoded is! List) {
        _cache[key] = [];
        return [];
      }

      final stations =
          <Station>[];

      for (final item in decoded) {
        if (item is! Map) {
          continue;
        }

        final station =
            Station.fromJson(
          Map<String, dynamic>.from(
            item,
          ),
        );

        if (station.id.isEmpty ||
            station.name.isEmpty) {
          continue;
        }

        stations.add(station);
      }

      _cache[key] = stations;

      return stations;
    } catch (_) {
      _cache[key] = [];
      return [];
    }
  }

  Future<List<Station>> search(
    String query, {
    int limit = 8,
  }) async {
    final normalizedQuery =
        _normalize(query);

    if (normalizedQuery.isEmpty) {
      return [];
    }

    final queryTokens =
        _tokens(normalizedQuery);

    if (queryTokens.isEmpty) {
      return [];
    }

    final buckets = <String>{};

    for (final token
        in queryTokens) {
      if (token.isEmpty) {
        continue;
      }

      final first =
          token[0];

      if (RegExp(
        r'^[a-z]$',
      ).hasMatch(first)) {
        buckets.add(first);
      }
    }

    if (buckets.isEmpty) {
      return [];
    }

    final stationMap =
        <String, Station>{};

    for (final bucket
        in buckets) {
      final stations =
          await _loadBucket(
        bucket,
      );

      for (final station
          in stations) {
        stationMap[
            station.id] = station;
      }
    }

    final scored =
        <_ScoredStation>[];

    for (final station
        in stationMap.values) {
      final score =
          _scoreStation(
        station,
        normalizedQuery,
        queryTokens,
      );

      if (score > 0) {
        scored.add(
          _ScoredStation(
            station: station,
            score: score,
          ),
        );
      }
    }

    scored.sort(
      (a, b) {
        final scoreCompare =
            b.score.compareTo(
          a.score,
        );

        if (scoreCompare != 0) {
          return scoreCompare;
        }

        final nameLengthCompare =
            a.station.name.length
                .compareTo(
          b.station.name.length,
        );

        if (nameLengthCompare != 0) {
          return nameLengthCompare;
        }

        return a.station.name
            .toLowerCase()
            .compareTo(
              b.station.name
                  .toLowerCase(),
            );
      },
    );

    return scored
        .take(limit)
        .map(
          (item) =>
              item.station,
        )
        .toList();
  }

  double _scoreStation(
    Station station,
    String query,
    List<String> queryTokens,
  ) {
    final name =
        _normalize(
      station.name,
    );

    final location =
        _normalize(
      station.location,
    );

    if (name.isEmpty &&
        location.isEmpty) {
      return 0;
    }

    final nameTokens =
        _tokens(name);

    final locationTokens =
        _tokens(location);

    final allTokens = [
      ...nameTokens,
      ...locationTokens,
    ];

    var score = 0.0;

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

    var matchedTokens = 0;

    for (final queryToken
        in queryTokens) {
      if (queryToken.length < 2) {
        continue;
      }

      var bestTokenScore =
          0.0;

      for (final nameToken
          in allTokens) {
        if (nameToken ==
            queryToken) {
          bestTokenScore =
              _max(
            bestTokenScore,
            1000,
          );
        } else if (nameToken
            .startsWith(
          queryToken,
        )) {
          bestTokenScore =
              _max(
            bestTokenScore,
            600,
          );
        } else if (nameToken
            .contains(
          queryToken,
        )) {
          bestTokenScore =
              _max(
            bestTokenScore,
            300,
          );
        }
      }

      if (bestTokenScore > 0) {
        matchedTokens++;
        score +=
            bestTokenScore;
      }
    }

    if (matchedTokens == 0) {
      return 0;
    }

    if (matchedTokens ==
        queryTokens.length) {
      score += 1500;
    } else {
      score +=
          matchedTokens * 100;
    }

    final extraTokens =
        allTokens.length -
            queryTokens.length;

    if (extraTokens > 0) {
      score -=
          extraTokens * 90;
    }

    score -=
        name.length * 0.5;

    score +=
        station.priority * 0.5;

    if (station.locationType ==
        1) {
      score += 200;
    }

    return score;
  }

  List<String> _tokens(
    String value,
  ) {
    return value
        .split(
          RegExp(
            r'[^a-z0-9]+',
          ),
        )
        .where(
          (token) =>
              token.isNotEmpty,
        )
        .toList();
  }

  String _normalize(
    String value,
  ) {
    var result =
        value.trim().toLowerCase();

    result = result
        .replaceAll(
          'ä',
          'ae',
        )
        .replaceAll(
          'ö',
          'oe',
        )
        .replaceAll(
          'ü',
          'ue',
        )
        .replaceAll(
          'ß',
          'ss',
        );

    result = result.replaceAll(
      RegExp(r'\bbhf\b'),
      'bahnhof',
    );

    result = result.replaceAll(
      RegExp(r'\bhbf\b'),
      'hauptbahnhof',
    );

    result = result.replaceAll(
      RegExp(r'\bbf\b'),
      'bahnhof',
    );

    result = result.replaceAll(
      RegExp(
        r'[\(\),./_-]+',
      ),
      ' ',
    );

    result = result.replaceAll(
      RegExp(r'\s+'),
      ' ',
    );

    return result.trim();
  }

  double _max(
    double a,
    double b,
  ) {
    return a > b ? a : b;
  }
}

class HomePage
    extends StatefulWidget {
  const HomePage({
    super.key,
  });

  @override
  State<HomePage> createState() =>
      _HomePageState();
}

class _HomePageState
    extends State<HomePage> {
  final TextEditingController
      _fromController =
      TextEditingController();

  final TextEditingController
      _toController =
      TextEditingController();

  final StationDatabase
      _stationDatabase =
      StationDatabase();

  DateTime _selectedDate =
      DateTime.now();

  TimeOfDay _selectedTime =
      TimeOfDay.now();

  int _currentTab = 0;

  Station?
      _selectedFromStation;

  Station?
      _selectedToStation;

  List<Station>
      _fromSuggestions = [];

  List<Station>
      _toSuggestions = [];

  bool _loadingStations =
      true;

  String? _stationError;

  int _fromSearchNumber = 0;
  int _toSearchNumber = 0;

  @override
  void initState() {
    super.initState();
    _loadStations();
  }

  @override
  void dispose() {
    _fromController.dispose();
    _toController.dispose();
    super.dispose();
  }

  Future<void>
      _loadStations() async {
    try {
      await _stationDatabase
          .load();

      if (!mounted) {
        return;
      }

      setState(() {
        _loadingStations =
            false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _loadingStations =
            false;

        _stationError =
            error.toString();
      });
    }
  }

  Future<void>
      _onFromChanged(
    String value,
  ) async {
    final searchNumber =
        ++_fromSearchNumber;

    setState(() {
      _selectedFromStation =
          null;

      _fromSuggestions = [];
    });

    if (value.trim().length <
        2) {
      return;
    }

    try {
      final suggestions =
          await _stationDatabase
              .search(
        value,
        limit: 8,
      );

      if (!mounted ||
          searchNumber !=
              _fromSearchNumber) {
        return;
      }

      setState(() {
        _fromSuggestions =
            suggestions;
      });
    } catch (error) {
      if (!mounted ||
          searchNumber !=
              _fromSearchNumber) {
        return;
      }

      setState(() {
        _fromSuggestions =
            [];

        _stationError =
            error.toString();
      });
    }
  }

  Future<void>
      _onToChanged(
    String value,
  ) async {
    final searchNumber =
        ++_toSearchNumber;

    setState(() {
      _selectedToStation =
          null;

      _toSuggestions = [];
    });

    if (value.trim().length <
        2) {
      return;
    }

    try {
      final suggestions =
          await _stationDatabase
              .search(
        value,
        limit: 8,
      );

      if (!mounted ||
          searchNumber !=
              _toSearchNumber) {
        return;
      }

      setState(() {
        _toSuggestions =
            suggestions;
      });
    } catch (error) {
      if (!mounted ||
          searchNumber !=
              _toSearchNumber) {
        return;
      }

      setState(() {
        _toSuggestions =
            [];

        _stationError =
            error.toString();
      });
    }
  }

  void _selectFromStation(
    Station station,
  ) {
    _fromSearchNumber++;

    setState(() {
      _selectedFromStation =
          station;

      _fromController.text =
          station.name;

      _fromController.selection =
          TextSelection.collapsed(
        offset:
            station.name.length,
      );

      _fromSuggestions =
          [];
    });
  }

  void _selectToStation(
    Station station,
  ) {
    _toSearchNumber++;

    setState(() {
      _selectedToStation =
          station;

      _toController.text =
          station.name;

      _toController.selection =
          TextSelection.collapsed(
        offset:
            station.name.length,
      );

      _toSuggestions = [];
    });
  }

  Future<void>
      _selectDate() async {
    final picked =
        await showDatePicker(
      context: context,
      initialDate:
          _selectedDate,
      firstDate:
          DateTime.now(),
      lastDate:
          DateTime.now().add(
        const Duration(
          days: 365,
        ),
      ),
    );

    if (picked != null) {
      setState(() {
        _selectedDate =
            picked;
      });
    }
  }

  Future<void>
      _selectTime() async {
    final picked =
        await showTimePicker(
      context: context,
      initialTime:
          _selectedTime,
    );

    if (picked != null) {
      setState(() {
        _selectedTime =
            picked;
      });
    }
  }

  void _swapLocations() {
    final from =
        _fromController.text;

    final to =
        _toController.text;

    final fromStation =
        _selectedFromStation;

    final toStation =
        _selectedToStation;

    setState(() {
      _fromController.text =
          to;

      _toController.text =
          from;

      _selectedFromStation =
          toStation;

      _selectedToStation =
          fromStation;

      _fromSuggestions = [];
      _toSuggestions = [];
    });
  }

  void _searchConnection() {
    final from =
        _fromController.text
            .trim();

    final to =
        _toController.text
            .trim();

    if (from.isEmpty ||
        to.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        const SnackBar(
          content: Text(
            'Bitte Start und Ziel eingeben.',
          ),
        ),
      );

      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            SearchResultPage(
          from: from,
          to: to,
          fromStation:
              _selectedFromStation,
          toStation:
              _selectedToStation,
          date:
              _selectedDate,
          time:
              _selectedTime,
        ),
      ),
    );
  }

  String _formatDate(
    DateTime date,
  ) {
    final day = date.day
        .toString()
        .padLeft(
          2,
          '0',
        );

    final month = date.month
        .toString()
        .padLeft(
          2,
          '0',
        );

    return '$day.$month.${date.year}';
  }

  String _formatTime(
    TimeOfDay time,
  ) {
    final hour = time.hour
        .toString()
        .padLeft(
          2,
          '0',
        );

    final minute =
        time.minute
            .toString()
            .padLeft(
              2,
              '0',
            );

    return '$hour:$minute';
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'D-Ticket Navigator',
          style: TextStyle(
            fontWeight:
                FontWeight.bold,
          ),
        ),
      ),
      body:
          IndexedStack(
        index:
            _currentTab,
        children: [
          _buildSearchPage(),
          _buildMapPage(),
          _buildDisruptionPage(),
        ],
      ),
      bottomNavigationBar:
          NavigationBar(
        selectedIndex:
            _currentTab,
        onDestinationSelected:
            (index) {
          setState(() {
            _currentTab =
                index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon:
                Icon(Icons.route),
            label:
                'Verbindung',
          ),
          NavigationDestination(
            icon: Icon(
              Icons.map_outlined,
            ),
            label: 'Karte',
          ),
          NavigationDestination(
            icon: Icon(
              Icons
                  .warning_amber_outlined,
            ),
            label:
                'Störungen',
          ),
        ],
      ),
    );
  }

  Widget _buildSearchPage() {
    return SafeArea(
      child:
          SingleChildScrollView(
        padding:
            const EdgeInsets.all(
          16,
        ),
        child:
            Column(
          crossAxisAlignment:
              CrossAxisAlignment
                  .stretch,
          children: [
            if (_loadingStations)
              const Card(
                child:
                    Padding(
                  padding:
                      EdgeInsets.all(
                    16,
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 22,
                        height: 22,
                        child:
                            CircularProgressIndicator(
                          strokeWidth:
                              2,
                        ),
                      ),
                      SizedBox(
                        width: 14,
                      ),
                      Expanded(
                        child: Text(
                          'Haltestellen werden vorbereitet …',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (_stationError !=
                null)
              Card(
                child:
                    Padding(
                  padding:
                      const EdgeInsets.all(
                    16,
                  ),
                  child: Text(
                    'GTFS-Fehler:\n'
                    '$_stationError',
                    style:
                        const TextStyle(
                      color:
                          Colors.red,
                    ),
                  ),
                ),
              ),
            Card(
              child:
                  Padding(
                padding:
                    const EdgeInsets.all(
                  16,
                ),
                child:
                    Column(
                  crossAxisAlignment:
                      CrossAxisAlignment
                          .stretch,
                  children: [
                    const Text(
                      'Reise planen',
                      style:
                          TextStyle(
                        fontSize: 22,
                        fontWeight:
                            FontWeight
                                .bold,
                      ),
                    ),
                    const SizedBox(
                      height: 6,
                    ),
                    Text(
                      'Verbindungen mit dem '
                      'Deutschlandticket finden',
                      style:
      
