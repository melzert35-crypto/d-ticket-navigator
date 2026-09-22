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
    if (_cache.containsKey(letter)) return _cache[letter]!;

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
        if (item is! Map) continue;
        final station = Station.fromJson(
          Map<String, dynamic>.from(item),
        );
        if (station.id.isNotEmpty && station.name.isNotEmpty) {
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
    // Nur prüfen, ob der Index vorhanden ist. Die eigentlichen Daten
    // werden erst bei der Suche nach Bedarf geladen.
    await _loadBucket('a');
  }

  Future<List<Station>> search(String query, {int limit = 8}) async {
    final normalized = _normalize(query);
    if (normalized.length < 2) return [];

    final tokens = _tokens(normalized);
    if (tokens.isEmpty) return [];

    final letters = <String>{};
    for (final token in tokens) {
      if (token.isNotEmpty && RegExp(r'^[a-z]$').hasMatch(token[0])) {
        letters.add(token[0]);
      }
    }
    if (letters.isEmpty) return [];

    final all = <String, Station>{};
    for (final letter in letters) {
      for (final station in await _loadBucket(letter)) {
        all[station.id] = station;
      }
    }

    final scored = <_ScoredStation>[];
    for (final station in all.values) {
      final score = _score(station, normalized, tokens);
      if (score > 0) scored.add(_ScoredStation(station, score));
    }

    scored.sort((a, b) {
      final c = b.score.compareTo(a.score);
      if (c != 0) return c;
      return a.station.name.toLowerCase().compareTo(
            b.station.name.toLowerCase(),
          );
    });

    return scored.take(limit).map((e) => e.station).toList();
  }

  double _score(Station station, String query, List<String> queryTokens) {
    final name = _normalize(station.name);
    final location = _normalize(station.location);
    final combined = '$name $location'.trim();
    final nameTokens = _tokens(name);
    final locationTokens = _tokens(location);
    final allTokens = [...nameTokens, ...locationTokens];

    double score = 0;

    if (name == query) score += 5000;
    if (name.startsWith(query)) score += 2500;
    if (name.contains(query)) score += 1200;
    if (location == query) score += 3000;
    if (location.startsWith(query)) score += 1600;
    if (location.contains(query)) score += 800;
    if (combined.contains(query)) score += 300;

    var matched = 0;
    for (final q in queryTokens) {
      if (q.length < 2) continue;
      var best = 0.0;
      for (final token in allTokens) {
        if (token == q) {
          best = _max(best, 1000);
        } else if (token.startsWith(q)) {
          best = _max(best, 600);
        } else if (token.contains(q)) {
          best = _max(best, 300);
        }
      }
      if (best > 0) {
        matched++;
        score += best;
      }
    }

    if (matched == 0) return 0;
    if (matched == queryTokens.length) score += 1500;

    final extra = allTokens.length - queryTokens.length;
    if (extra > 0) score -= extra * 90;

    score -= name.length * 0.5;
    score += station.priority * 0.5;
    if (station.locationType == 1) score += 200;

    return score;
  }

  List<String> _tokens(String value) => value
      .split(RegExp(r'[^a-z0-9]+'))
      .where((e) => e.isNotEmpty)
      .toList();

  String _normalize(String value) {
    var result = value.trim().toLowerCase();
    result = result
        .replaceAll('ä', 'ae')
        .replaceAll('ö', 'oe')
        .replaceAll('ü', 'ue')
        .replaceAll('ß', 'ss');
    result = result.replaceAll(RegExp(r'\bbhf\b'), 'bahnhof');
    result = result.replaceAll(RegExp(r'\bhbf\b'), 'hauptbahnhof');
    result = result.replaceAll(RegExp(r'\bbf\b'), 'bahnhof');
    result = result.replaceAll(RegExp(r'[(),./_-]+'), ' ');
    result = result.replaceAll(RegExp(r'\s+'), ' ');
    return result.trim();
  }

  double _max(double a, double b) => a > b ? a : b;
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

  void _onFromChanged(
    String value,
  ) {
    final suggestions =
        _stationDatabase.search(
      value,
      limit: 20,
    );

    setState(() {
      _selectedFromStation = null;
      _fromSuggestions =
          suggestions;
    });
  }

  void _onToChanged(
    String value,
  ) {
    final suggestions =
        _stationDatabase.search(
      value,
      limit: 20,
    );

    setState(() {
      _selectedToStation = null;
      _toSuggestions =
          suggestions;
    });
  }

  void _selectFromStation(
    Station station,
  ) {
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
              Icons
                  .warning_amber_outlined,
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
              CrossAxisAlignment
                  .stretch,
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
                          'Haltestellen werden geladen …',
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
                      CrossAxisAlignment
                          .stretch,
                  children: [
                    const Text(
                      'Reise planen',
                      style:
                          TextStyle(
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
                        color: Colors
                            .grey
                            .shade700,
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
                          'z. B. Reichen…',
                      icon: Icons
                          .trip_origin,
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
                          icon:
                              const Icon(
                            Icons
                                .swap_vert,
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
                          'z. B. Berlin Hbf',
                      icon: Icons
                          .location_on_outlined,
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
                        Icons
                            .calendar_today,
                      ),
                      title:
                          const Text(
                        'Datum',
                      ),
                      subtitle:
                          Text(
                        _formatDate(
                          _selectedDate,
                        ),
                      ),
                      trailing:
                          const Icon(
                        Icons
                            .chevron_right,
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
                        Icons
                            .access_time,
                      ),
                      title:
                          const Text(
                        'Abfahrt',
                      ),
                      subtitle:
                          Text(
                        _formatTime(
                          _selectedTime,
                        ),
                      ),
                      trailing:
                          const Icon(
                        Icons
                            .chevron_right,
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
                  style:
                      TextStyle(
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
                ScaffoldMessenger
                    .of(context)
                    .showSnackBar(
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
    required ValueChanged<String>
        onChanged,
    required ValueChanged<Station>
        onSelected,
  }) {
    return Column(
      crossAxisAlignment:
          CrossAxisAlignment
              .stretch,
      children: [
        TextField(
          controller:
              controller,
          onChanged:
              onChanged,
          decoration:
              InputDecoration(
            labelText: label,
            hintText: hint,
            prefixIcon:
                Icon(icon),
            suffixIcon:
                controller.text
                        .isNotEmpty
                    ? IconButton(
                        tooltip:
                            'Löschen',
                        onPressed:
                            () {
                          controller
                              .clear();
                          onChanged(
                            '',
                          );
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
                  BorderRadius
                      .circular(
                12,
              ),
            ),
          ),
        ),
        if (suggestions
            .isNotEmpty)
          Container(
            margin:
                const EdgeInsets
                    .only(
              top: 4,
            ),
            constraints:
                const BoxConstraints(
              maxHeight: 360,
            ),
            decoration:
                BoxDecoration(
              border:
                  Border.all(
                color: Colors
                    .grey
                    .shade300,
              ),
              borderRadius:
                  BorderRadius
                      .circular(
                12,
              ),
            ),
            child:
                ListView.separated(
              shrinkWrap:
                  true,
              itemCount:
                  suggestions
                      .length,
              separatorBuilder:
                  (
                context,
                index,
              ) =>
                      const Divider(
                height: 1,
              ),
              itemBuilder:
                  (
                context,
                index,
              ) {
                final station =
                    suggestions[
                        index];

                return ListTile(
                  dense: true,
                  leading:
                      Icon(
                    station.locationType ==
                            1
                        ? Icons
                            .train
                        : Icons
                            .directions_bus_outlined,
                  ),
                  title:
                      Text(
                    station.name,
                    maxLines: 2,
                    overflow:
                        TextOverflow
                            .ellipsis,
                  ),
                  subtitle:
                      station.location.isNotEmpty
                          ? Text(
                              station.location,
                              maxLines: 2,
                              overflow:
                                  TextOverflow.ellipsis,
                            )
                          : station.locationType == 1
                              ? const Text(
                                  'Bahnhof / Station',
                                )
                              : null,
                  onTap: () {
                    onSelected(
                      station,
                    );
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
            MainAxisAlignment
                .center,
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
            MainAxisAlignment
                .center,
        children: [
          Icon(
            Icons
                .warning_amber_outlined,
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
            const Text(
          'Verbindung',
        ),
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
                    CrossAxisAlignment
                        .start,
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
                    style:
                        TextStyle(
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
                    style:
                        TextStyle(
                      color: Colors
                          .grey
                          .shade700,
                    ),
                  ),
                  if (fromStation !=
                      null) ...[
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
                    if (fromStation!
                            .latitude !=
                        null &&
                        fromStation!
                                .longitude !=
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
                  if (toStation !=
                      null) ...[
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
                    if (toStation!
                            .latitude !=
                        null &&
                        toStation!
                                .longitude !=
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
