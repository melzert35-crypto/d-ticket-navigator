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
  final double? latitude;
  final double? longitude;
  final String? parentStation;
  final int locationType;
  final int priority;
  final String searchText;

  const Station({
    required this.id,
    required this.name,
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
      latitude: _toDouble(json['lat']),
      longitude: _toDouble(json['lon']),
      parentStation: _toNullableString(json['parent']),
      locationType: _toInt(json['type']),
      priority: _toInt(json['priority']),
      searchText: (json['search'] ?? '').toString(),
    );
  }

  static double? _toDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }

    return double.tryParse(
      value?.toString() ?? '',
    );
  }

  static int _toInt(dynamic value) {
    if (value is num) {
      return value.toInt();
    }

    return int.tryParse(
          value?.toString() ?? '',
        ) ??
        0;
  }

  static String? _toNullableString(dynamic value) {
    final text = value?.toString().trim();

    if (text == null || text.isEmpty) {
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
  final Map<String, List<Station>> _cache = {};

  bool _loading = false;

  Future<void> load() async {
    if (_loading) {
      return;
    }

    _loading = true;

    try {
      /*
       * Wir laden absichtlich NICHT den kompletten
       * Deutschland-Datensatz.
       *
       * Die eigentliche Suche lädt später nur die
       * benötigten Buchstaben-Dateien.
       */
      await _loadBucket('a');
    } finally {
      _loading = false;
    }
  }

  Future<List<Station>> _loadBucket(
    String bucket,
  ) async {
    final key = bucket.toLowerCase();

    if (_cache.containsKey(key)) {
      return _cache[key]!;
    }

    try {
      final jsonText = await rootBundle.loadString(
        'assets/data/stations/$key.json',
      );

      final decoded = jsonDecode(jsonText);

      if (decoded is! List) {
        _cache[key] = [];
        return [];
      }

      final stations = <Station>[];

      for (final item in decoded) {
        if (item is! Map) {
          continue;
        }

        final station = Station.fromJson(
          Map<String, dynamic>.from(item),
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
      /*
       * Ein einzelner nicht vorhandener Bucket darf
       * die komplette Suche nicht zerstören.
       */
      _cache[key] = [];
      return [];
    }
  }

  Future<List<Station>> search(
    String query, {
    int limit = 8,
  }) async {
    final normalizedQuery = _normalize(query);

    if (normalizedQuery.isEmpty) {
      return [];
    }

    final queryTokens = _tokens(normalizedQuery);

    if (queryTokens.isEmpty) {
      return [];
    }

    /*
     * Die Indexdateien sind nach dem ersten Buchstaben
     * eines relevanten Suchwortes aufgebaut.
     *
     * Bei "Wuppertal" wird also nur w.json geladen.
     *
     * Bei "Reichenbach Vogtland" werden r.json und
     * v.json geladen und anschließend zusammengeführt.
     */
    final buckets = <String>{};

    for (final token in queryTokens) {
      if (token.isEmpty) {
        continue;
      }

      final first = token[0];

      if (RegExp(r'^[a-z]$').hasMatch(first)) {
        buckets.add(first);
      }
    }

    if (buckets.isEmpty) {
      return [];
    }

    final stationMap = <String, Station>{};

    for (final bucket in buckets) {
      final stations = await _loadBucket(bucket);

      for (final station in stations) {
        stationMap[station.id] = station;
      }
    }

    final scored = <_ScoredStation>[];

    for (final station in stationMap.values) {
      final score = _scoreStation(
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
            b.score.compareTo(a.score);

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
              b.station.name.toLowerCase(),
            );
      },
    );

    return scored
        .take(limit)
        .map(
          (item) => item.station,
        )
        .toList();
  }

  double _scoreStation(
    Station station,
    String query,
    List<String> queryTokens,
  ) {
    final name = _normalize(station.name);

    if (name.isEmpty) {
      return 0;
    }

    final nameTokens = _tokens(name);

    var score = 0.0;

    /*
     * Sehr starke Treffer:
     *
     * "wuppertal" == kompletter Stationsname
     * "wuppertal hbf" beginnt mit der Suche
     */
    if (name == query) {
      score += 5000;
    }

    if (name.startsWith(query)) {
      score += 2500;
    }

    if (name.contains(query)) {
      score += 1200;
    }

    var matchedTokens = 0;

    for (final queryToken in queryTokens) {
      if (queryToken.length < 2) {
        continue;
      }

      var bestTokenScore = 0.0;

      for (final nameToken in nameTokens) {
        if (nameToken == queryToken) {
          bestTokenScore =
              _max(bestTokenScore, 1000);
        } else if (nameToken.startsWith(
          queryToken,
        )) {
          bestTokenScore =
              _max(bestTokenScore, 600);
        } else if (nameToken.contains(
          queryToken,
        )) {
          bestTokenScore =
              _max(bestTokenScore, 300);
        }
      }

      if (bestTokenScore > 0) {
        matchedTokens++;
        score += bestTokenScore;
      }
    }

    if (matchedTokens == 0) {
      return 0;
    }

    if (matchedTokens == queryTokens.length) {
      score += 1500;
    } else {
      score += matchedTokens * 100;
    }

    /*
     * Ein wichtiger Punkt für die aktuelle Suche:
     *
     * Bei "Wuppertal" soll
     *
     *   Wuppertal
     *   Wuppertal Hbf
     *   Wuppertal Barmen
     *
     * vor langen Namen wie
     *
     *   Wuppertal Hatzfeld Barmen
     *
     * erscheinen.
     *
     * Deshalb werden zusätzliche Wörter leicht abgewertet.
     */
    final extraTokens =
        nameTokens.length - queryTokens.length;

    if (extraTokens > 0) {
      score -= extraTokens * 90;
    }

    /*
     * Kürzere Namen werden bei ansonsten gleichem
     * Treffer bevorzugt.
     */
    score -= name.length * 0.5;

    /*
     * Der vom Python-Indexer berechnete Prioritätswert
     * berücksichtigt u. a. echte Bahnhöfe.
     */
    score += station.priority * 0.5;

    /*
     * Station (location_type 1) leicht bevorzugen.
     */
    if (station.locationType == 1) {
      score += 200;
    }

    return score;
  }

  List<String> _tokens(String value) {
    return value
        .split(RegExp(r'[^a-z0-9]+'))
        .where(
          (token) => token.isNotEmpty,
        )
        .toList();
  }

  String _normalize(String value) {
    var result =
        value.trim().toLowerCase();

    result = result
        .replaceAll('ä', 'ae')
        .replaceAll('ö', 'oe')
        .replaceAll('ü', 'ue')
        .replaceAll('ß', 'ss');

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
      RegExp(r'[\(\),./_-]+'),
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

class HomePage extends StatefulWidget {
  const HomePage({super.key});

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

  Station? _selectedFromStation;
  Station? _selectedToStation;

  List<Station> _fromSuggestions = [];
  List<Station> _toSuggestions = [];

  bool _loadingStations = true;
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

  Future<void> _loadStations() async {
    try {
      await _stationDatabase.load();

      if (!mounted) {
        return;
      }

      setState(() {
        _loadingStations = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _loadingStations = false;
        _stationError =
            error.toString();
      });
    }
  }

  Future<void> _onFromChanged(
    String value,
  ) async {
    final searchNumber =
        ++_fromSearchNumber;

    setState(() {
      _selectedFromStation = null;
      _fromSuggestions = [];
    });

    if (value.trim().length < 2) {
      return;
    }

    try {
      final suggestions =
          await _stationDatabase.search(
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
        _fromSuggestions = [];
        _stationError =
            error.toString();
      });
    }
  }

  Future<void> _onToChanged(
    String value,
  ) async {
    final searchNumber =
        ++_toSearchNumber;

    setState(() {
      _selectedToStation = null;
      _toSuggestions = [];
    });

    if (value.trim().length < 2) {
      return;
    }

    try {
      final suggestions =
          await _stationDatabase.search(
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
        _toSuggestions = [];
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

      _fromSuggestions = [];
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

  Future<void> _selectDate() async {
    final picked =
        await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime.now(),
      lastDate:
          DateTime.now().add(
        const Duration(
          days: 365,
        ),
      ),
    );

    if (picked != null) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  Future<void> _selectTime() async {
    final picked =
        await showTimePicker(
      context: context,
      initialTime:
          _selectedTime,
    );

    if (picked != null) {
      setState(() {
        _selectedTime = picked;
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
      _fromController.text = to;
      _toController.text = from;

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
        _fromController.text.trim();

    final to =
        _toController.text.trim();

    if (from.isEmpty ||
        to.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(
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
          date: _selectedDate,
          time: _selectedTime,
        ),
      ),
    );
  }

  String _formatDate(
    DateTime date,
  ) {
    final day = date.day
        .toString()
        .padLeft(2, '0');

    final month = date.month
        .toString()
        .padLeft(2, '0');

    return '$day.$month.${date.year}';
  }

  String _formatTime(
    TimeOfDay time,
  ) {
    final hour = time.hour
        .toString()
        .padLeft(2, '0');

    final minute = time.minute
        .toString()
        .padLeft(2, '0');

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
      body: IndexedStack(
        index: _currentTab,
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
            _currentTab = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(
              Icons.route,
            ),
            label: 'Verbindung',
          ),
          NavigationDestination(
            icon: Icon(
              Icons.map_outlined,
            ),
            label: 'Karte',
          ),
          NavigationDestination(
            icon: Icon(
              Icons.warning_amber_outlined,
            ),
            label: 'Störungen',
          ),
        ],
      ),
    );
  }

  Widget _buildSearchPage() {
    return SafeArea(
      child: SingleChildScrollView(
        padding:
            const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.stretch,
          children: [
            if (_loadingStations)
              const Card(
                child: Padding(
                  padding:
                      EdgeInsets.all(16),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 22,
                        height: 22,
                        child:
                            CircularProgressIndicator(
                          strokeWidth: 2,
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
            if (_stationError != null)
              Card(
                child: Padding(
                  padding:
                      const EdgeInsets.all(16),
                  child: Text(
                    'GTFS-Fehler:\n'
                    '$_stationError',
                    style:
                        const TextStyle(
                      color: Colors.red,
                    ),
                  ),
                ),
              ),
            Card(
              child: Padding(
                padding:
                    const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Reise planen',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                    const SizedBox(
                      height: 6,
                    ),
                    Text(
                      'Verbindungen mit dem '
                      'Deutschlandticket finden',
                      style: TextStyle(
                        color:
                            Colors.grey.shade700,
                      ),
                    ),
                    const SizedBox(
                      height: 20,
                    ),
                    _buildStationField(
                      controller:
                          _fromController,
                      label: 'Start',
                      hint:
                          'z. B. Wuppertal',
                      icon:
                          Icons.trip_origin,
                      suggestions:
                          _fromSuggestions,
                      onChanged:
                          _onFromChanged,
                      onSelected:
                          _selectFromStation,
                    ),
                    const SizedBox(
                      height: 10,
                    ),
                    Row(
                      children: [
                        const Expanded(
                          child: Divider(),
                        ),
                        IconButton(
                          tooltip:
                              'Start und Ziel tauschen',
                          onPressed:
                              _swapLocations,
                          icon: const Icon(
                            Icons.swap_vert,
                          ),
                        ),
                        const Expanded(
                          child: Divider(),
                        ),
                      ],
                    ),
                    const SizedBox(
                      height: 10,
                    ),
                    _buildStationField(
                      controller:
                          _toController,
                      label: 'Ziel',
                      hint:
                          'z. B. Reichenbach Vogtland',
                      icon:
                          Icons.location_on_outlined,
                      suggestions:
                          _toSuggestions,
                      onChanged:
                          _onToChanged,
                      onSelected:
                          _selectToStation,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(
              height: 16,
            ),
            Card(
              child: Padding(
                padding:
                    const EdgeInsets.all(16),
                child: Column(
                  children: [
                    ListTile(
                      contentPadding:
                          EdgeInsets.zero,
                      leading:
                          const Icon(
                        Icons.calendar_today,
                      ),
                      title:
                          const Text('Datum'),
                      subtitle:
                          Text(
                        _formatDate(
                          _selectedDate,
                        ),
                      ),
                      trailing:
                          const Icon(
                        Icons.chevron_right,
                      ),
                      onTap:
                          _selectDate,
                    ),
                    const Divider(),
                    ListTile(
                      contentPadding:
                          EdgeInsets.zero,
                      leading:
                          const Icon(
                        Icons.access_time,
                      ),
                      title:
                          const Text('Abfahrt'),
                      subtitle:
                          Text(
                        _formatTime(
                          _selectedTime,
                        ),
                      ),
                      trailing:
                          const Icon(
                        Icons.chevron_right,
                      ),
                      onTap:
                          _selectTime,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(
              height: 20,
            ),
            SizedBox(
              height: 54,
              child:
                  FilledButton.icon(
                onPressed:
                    _searchConnection,
                icon:
                    const Icon(
                  Icons.search,
                ),
                label:
                    const Text(
                  'VERBINDUNG SUCHEN',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(
              height: 12,
            ),
            OutlinedButton.icon(
              onPressed: () {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Standortfunktion folgt.',
                    ),
                  ),
                );
              },
              icon: const Icon(
                Icons.my_location,
              ),
              label: const Text(
                'Aktuellen Standort verwenden',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStationField({
    required TextEditingController
        controller,
    required String label,
    required String hint,
    required IconData icon,
    required List<Station>
        suggestions,
    required Future<void> Function(
      String,
    ) onChanged,
    required ValueChanged<Station>
        onSelected,
  }) {
    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller:
              controller,
          onChanged:
              (value) {
            onChanged(value);
            setState(() {});
          },
          decoration:
              InputDecoration(
            labelText: label,
            hintText: hint,
            prefixIcon:
                Icon(icon),
            suffixIcon:
                controller.text.isNotEmpty
                    ? IconButton(
                        tooltip:
                            'Löschen',
                        onPressed: () {
                          controller.clear();

                          onChanged('');

                          setState(() {});
                        },
                        icon:
                            const Icon(
                          Icons.clear,
                        ),
                      )
                    : null,
            border:
                OutlineInputBorder(
              borderRadius:
                  BorderRadius.circular(
                12,
              ),
            ),
          ),
        ),
        if (suggestions.isNotEmpty)
          Container(
            margin:
                const EdgeInsets.only(
              top: 4,
            ),
            constraints:
                const BoxConstraints(
              maxHeight: 320,
            ),
            decoration:
                BoxDecoration(
              color:
                  Theme.of(context)
                      .colorScheme
                      .surface,
              border:
                  Border.all(
                color:
                    Colors.grey.shade300,
              ),
              borderRadius:
                  BorderRadius.circular(
                12,
              ),
            ),
            child:
                ListView.separated(
              shrinkWrap: true,
              itemCount:
                  suggestions.length,
              separatorBuilder:
                  (context, index) =>
                      const Divider(
                height: 1,
              ),
              itemBuilder:
                  (context, index) {
                final station =
                    suggestions[index];

                return ListTile(
                  dense: true,
                  leading: Icon(
                    station.locationType == 1
                        ? Icons.train
                        : Icons
                            .directions_bus_outlined,
                  ),
                  title: Text(
                    station.name,
                    maxLines: 2,
                    overflow:
                        TextOverflow.ellipsis,
                  ),
                  subtitle:
                      station.locationType == 1
                          ? const Text(
                              'Bahnhof / Station',
                            )
                          : null,
                  onTap: () {
                    onSelected(
                      station,
                    );

                    setState(() {});
                  },
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildMapPage() {
    return const Center(
      child: Column(
        mainAxisAlignment:
            MainAxisAlignment.center,
        children: [
          Icon(
            Icons.map_outlined,
            size: 72,
          ),
          SizedBox(
            height: 16,
          ),
          Text(
            'Karte',
            style: TextStyle(
              fontSize: 24,
              fontWeight:
                  FontWeight.bold,
            ),
          ),
          SizedBox(
            height: 8,
          ),
          Text(
            'Kartenansicht folgt.',
          ),
        ],
      ),
    );
  }

  Widget _buildDisruptionPage() {
    return const Center(
      child: Column(
        mainAxisAlignment:
            MainAxisAlignment.center,
        children: [
          Icon(
            Icons.warning_amber_outlined,
            size: 72,
          ),
          SizedBox(
            height: 16,
          ),
          Text(
            'Störungen',
            style: TextStyle(
              fontSize: 24,
              fontWeight:
                  FontWeight.bold,
            ),
          ),
          SizedBox(
            height: 8,
          ),
          Text(
            'Störungsinformationen folgen.',
          ),
        ],
      ),
    );
  }
}

class SearchResultPage
    extends StatelessWidget {
  final String from;
  final String to;
  final Station? fromStation;
  final Station? toStation;
  final DateTime date;
  final TimeOfDay time;

  const SearchResultPage({
    super.key,
    required this.from,
    required this.to,
    required this.fromStation,
    required this.toStation,
    required this.date,
    required this.time,
  });

  String _formatDate(
    DateTime date,
  ) {
    final day = date.day
        .toString()
        .padLeft(2, '0');

    final month = date.month
        .toString()
        .padLeft(2, '0');

    return '$day.$month.${date.year}';
  }

  String _formatTime(
    TimeOfDay time,
  ) {
    final hour = time.hour
        .toString()
        .padLeft(2, '0');

    final minute = time.minute
        .toString()
        .padLeft(2, '0');

    return '$hour:$minute';
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return Scaffold(
      appBar: AppBar(
        title:
            const Text('Verbindung'),
      ),
      body: ListView(
        padding:
            const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding:
                  const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Text(
                    '$from → $to',
                    style:
                        const TextStyle(
                      fontSize: 20,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                  const SizedBox(
                    height: 8,
                  ),
                  Text(
                    '${_formatDate(date)} '
                    'um ${_formatTime(time)}',
                  ),
                  const SizedBox(
                    height: 20,
                  ),
                  const Divider(),
                  const SizedBox(
                    height: 20,
                  ),
                  const Icon(
                    Icons.route,
                    size: 48,
                  ),
                  const SizedBox(
                    height: 12,
                  ),
                  const Text(
                    'Noch keine Verbindung berechnet.',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                  const SizedBox(
                    height: 8,
                  ),
                  Text(
                    'Die ausgewählten '
                    'Haltestellen werden '
                    'bereits mit ihrer '
                    'GTFS-ID übernommen.',
                    style: TextStyle(
                      color:
                          Colors.grey.shade700,
                    ),
                  ),
                  if (fromStation != null) ...[
                    const SizedBox(
                      height: 16,
                    ),
                    Text(
                      'Start-ID: '
                      '${fromStation!.id}',
                      style:
                          const TextStyle(
                        fontSize: 12,
                      ),
                    ),
                    if (fromStation!.latitude !=
                            null &&
                        fromStation!.longitude !=
                            null)
                      Text(
                        'Koordinaten: '
                        '${fromStation!.latitude}, '
                        '${fromStation!.longitude}',
                        style:
                            const TextStyle(
                          fontSize: 12,
                        ),
                      ),
                  ],
                  if (toStation != null) ...[
                    const SizedBox(
                      height: 8,
                    ),
                    Text(
                      'Ziel-ID: '
                      '${toStation!.id}',
                      style:
                          const TextStyle(
                        fontSize: 12,
                      ),
                    ),
                    if (toStation!.latitude !=
                            null &&
                        toStation!.longitude !=
                            null)
                      Text(
                        'Koordinaten: '
                        '${toStation!.latitude}, '
                        '${toStation!.longitude}',
                        style:
                            const TextStyle(
                          fontSize: 12,
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
