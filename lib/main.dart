import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'routing/gtfs_data.dart';
import 'routing/raptor_planner.dart';

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

// Häufige, wenig unterscheidungskräftige Bahnhofs-Begriffe.
// Ein exakter Treffer auf ein solches Wort zählt im Scoring
// bewusst weniger als ein Treffer auf einen eindeutigen Orts-
// oder Stadtteilnamen (z.B. "Oberbarmen", "Reichenbach").
const Set<String> _genericStationWords = {
  'bahnhof',
  'hauptbahnhof',
  'bf',
  'hbf',
  'bhf',
  'station',
  'ob',
  'unt',
  'oberer',
  'unterer',
  'busbahnhof',
  'zob',
  'gleis',
  'platz',
};

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
        // Bahnsteig-/Kind-Haltestellen nicht einzeln anbieten: Sie tauchen
        // sonst als identischer zweiter Eintrag (Bus-Symbol) neben ihrem
        // Bahnhof auf. Das Routing loest den Bahnhof selbst zu allen
        // Kind-Haltestellen auf (stopGroups).
        if (station.locationType == 0 &&
            (station.parentStation ?? '').isNotEmpty) {
          continue;
        }
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
      final shortToken = q.length <= 2;
      final generic = _genericStationWords.contains(q);
      final exactWeight = generic ? 250.0 : 1000.0;
      var best = 0.0;
      for (final token in allTokens) {
        if (token == q) {
          best = _max(best, exactWeight);
        } else if (!shortToken && !generic && token.startsWith(q)) {
          best = _max(best, 600);
        } else if (!shortToken && !generic && token.contains(q)) {
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
    result = result.replaceAll(RegExp(r'\bob\b'), 'oberer bahnhof');
    result = result.replaceAll(RegExp(r'\bunt\b'), 'unterer bahnhof');
    result = result.replaceAll(RegExp(r'\bvogtl\b'), 'vogtland');
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

  Future<void> _onFromChanged(
    String value,
  ) async {
    final suggestions =
        await _stationDatabase.search(
      value,
      limit: 20,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _selectedFromStation = null;
      _fromSuggestions =
          suggestions;
    });
  }

  Future<void> _onToChanged(
    String value,
  ) async {
    final suggestions =
        await _stationDatabase.search(
      value,
      limit: 20,
    );

    if (!mounted) {
      return;
    }

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

class SearchResultPage extends StatefulWidget {
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

  @override
  State<SearchResultPage> createState() => _SearchResultPageState();
}

/// Wird beim ersten Aufruf einmalig geladen und danach fuer die
/// Laufzeit der App wiederverwendet (~19 MB Rohdaten, soll nicht bei
/// jeder Suche neu eingelesen werden).
Future<GtfsRoutingData>? _routingDataFuture;

Future<GtfsRoutingData> _loadRoutingData() {
  return _routingDataFuture ??= GtfsRoutingData.loadFromAssets();
}

class _SearchResultPageState extends State<SearchResultPage> {
  late Future<List<Journey>> _journeysFuture;

  @override
  void initState() {
    super.initState();
    _journeysFuture = _planJourneys();
  }

  Future<List<Journey>> _planJourneys() async {
    final fromStation = widget.fromStation;
    final toStation = widget.toStation;
    if (fromStation == null || toStation == null) {
      return const [];
    }
    final data = await _loadRoutingData();
    final planner = RaptorPlanner(data);
    final dateYmd = '${widget.date.year.toString().padLeft(4, '0')}'
        '${widget.date.month.toString().padLeft(2, '0')}'
        '${widget.date.day.toString().padLeft(2, '0')}';
    final departAfter = widget.time.hour * 3600 + widget.time.minute * 60;
    return planner.plan(
      sourceStationId: fromStation.id,
      targetStationId: toStation.id,
      dateYmd: dateYmd,
      departAfter: departAfter,
      // TODO: an die noch zu bauende Umstiegszeit-Auswahl (10-30 Min.)
      // aus den Nutzereinstellungen anbinden, sobald diese existiert.
      minTransfer: const Duration(minutes: 10),
    );
  }

  String _formatDate(DateTime date) {
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    return '$day.$month.${date.year}';
  }

  String _formatClock(int secondsSinceMidnight) {
    final totalMinutes = secondsSinceMidnight ~/ 60;
    final h = (totalMinutes ~/ 60) % 24;
    final m = totalMinutes % 60;
    final dayOffset = totalMinutes ~/ (24 * 60);
    final suffix = dayOffset > 0 ? ' (+$dayOffset Tag${dayOffset > 1 ? 'e' : ''})' : '';
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}$suffix';
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    return h > 0 ? '${h}h ${m}min' : '${m}min';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Verbindung')),
      body: FutureBuilder<List<Journey>>(
        future: _journeysFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Fehler bei der Verbindungssuche: ${snapshot.error}'),
              ),
            );
          }
          final journeys = snapshot.data ?? const [];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${widget.from} \u2192 ${widget.to}',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_formatDate(widget.date)} ab '
                        '${widget.time.hour.toString().padLeft(2, '0')}:'
                        '${widget.time.minute.toString().padLeft(2, '0')}',
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (journeys.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.route_outlined, size: 40),
                        SizedBox(height: 12),
                        Text(
                          'Keine Verbindung gefunden.',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Entweder verkehrt am gewaehlten Tag nichts mehr, '
                          'oder die Strecke ist mit den aktuell geladenen '
                          'D-Ticket-gueltigen Regionalverkehrsdaten nicht '
                          'erreichbar.',
                        ),
                      ],
                    ),
                  ),
                )
              else
                for (final journey in journeys) _JourneyCard(
                  journey: journey,
                  formatClock: _formatClock,
                  formatDuration: _formatDuration,
                ),
            ],
          );
        },
      ),
    );
  }
}

class _JourneyCard extends StatelessWidget {
  final Journey journey;
  final String Function(int) formatClock;
  final String Function(Duration) formatDuration;

  const _JourneyCard({
    required this.journey,
    required this.formatClock,
    required this.formatDuration,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${formatClock(journey.departure)} \u2192 ${formatClock(journey.arrival)}',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                Chip(
                  label: Text(
                    journey.transfers == 0
                        ? 'direkt'
                        : '${journey.transfers} Umstieg${journey.transfers > 1 ? 'e' : ''}',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Reisezeit: ${formatDuration(journey.duration)}',
              style: TextStyle(color: Colors.grey.shade700),
            ),
            const Divider(height: 20),
            for (final leg in journey.legs)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 56,
                      child: Text(formatClock(leg.departure), style: const TextStyle(fontSize: 13)),
                    ),
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(top: 4, right: 8),
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.blueGrey,
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${leg.lineName}  ${leg.fromName} \u2192 ${leg.toName}'),
                          Text(
                            'an ${formatClock(leg.arrival)}',
                            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
