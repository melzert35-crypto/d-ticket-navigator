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

  const Station({
    required this.id,
    required this.name,
    this.latitude,
    this.longitude,
    this.parentStation,
    this.locationType = 0,
  });
}

class StationDatabase {
  List<Station> _stations = [];

  bool get isLoaded => _stations.isNotEmpty;

  int get stationCount => _stations.length;

  Future<void> load() async {
    if (isLoaded) {
      return;
    }

    final csv = await rootBundle.loadString(
      'assets/data/stops.txt',
    );

    _stations = _parseStops(csv);
  }

  List<Station> _parseStops(String csv) {
    final lines = const LineSplitter().convert(csv);

    if (lines.isEmpty) {
      return [];
    }

    final header = _parseCsvLine(lines.first);

    final stopIdIndex = _columnIndex(
      header,
      'stop_id',
    );

    final stopNameIndex = _columnIndex(
      header,
      'stop_name',
    );

    final latIndex = _columnIndex(
      header,
      'stop_lat',
    );

    final lonIndex = _columnIndex(
      header,
      'stop_lon',
    );

    final parentIndex = _columnIndex(
      header,
      'parent_station',
    );

    final locationTypeIndex = _columnIndex(
      header,
      'location_type',
    );

    if (stopIdIndex < 0 || stopNameIndex < 0) {
      throw Exception(
        'GTFS stops.txt enthält keine gültigen '
        'stop_id/stop_name-Spalten.',
      );
    }

    final result = <Station>[];
    final seen = <String>{};

    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trim();

      if (line.isEmpty) {
        continue;
      }

      final fields = _parseCsvLine(line);

      if (fields.length <= stopIdIndex ||
          fields.length <= stopNameIndex) {
        continue;
      }

      final id = fields[stopIdIndex].trim();
      final name = fields[stopNameIndex].trim();

      if (id.isEmpty || name.isEmpty) {
        continue;
      }

      var locationType = 0;

      if (locationTypeIndex >= 0 &&
          fields.length > locationTypeIndex) {
        locationType =
            int.tryParse(
              fields[locationTypeIndex].trim(),
            ) ??
            0;
      }

      /*
       * Für die erste Stationssuche berücksichtigen wir
       * Haltestellen und Bahnhöfe.
       *
       * location_type:
       * 0 = Stop/Platform
       * 1 = Station
       *
       * Andere GTFS-Objekte werden zunächst ignoriert.
       */
      if (locationType != 0 &&
          locationType != 1) {
        continue;
      }

      if (!seen.add(id)) {
        continue;
      }

      double? latitude;
      double? longitude;

      if (latIndex >= 0 &&
          fields.length > latIndex) {
        latitude = double.tryParse(
          fields[latIndex].trim(),
        );
      }

      if (lonIndex >= 0 &&
          fields.length > lonIndex) {
        longitude = double.tryParse(
          fields[lonIndex].trim(),
        );
      }

      String? parentStation;

      if (parentIndex >= 0 &&
          fields.length > parentIndex) {
        final value =
            fields[parentIndex].trim();

        if (value.isNotEmpty) {
          parentStation = value;
        }
      }

      result.add(
        Station(
          id: id,
          name: name,
          latitude: latitude,
          longitude: longitude,
          parentStation: parentStation,
          locationType: locationType,
        ),
      );
    }

    return result;
  }

  int _columnIndex(
    List<String> header,
    String column,
  ) {
    return header.indexWhere(
      (value) =>
          value.trim().toLowerCase() ==
          column.toLowerCase(),
    );
  }

  List<Station> search(
    String query, {
    int limit = 20,
  }) {
    final normalizedQuery =
        _normalize(query);

    if (normalizedQuery.isEmpty) {
      return [];
    }

    final queryTokens =
        _tokens(normalizedQuery);

    final scored = <_ScoredStation>[];

    /*
     * Wichtig:
     * Wir laufen bewusst durch ALLE Stationen.
     *
     * Die alte Version hat nach den ersten 12
     * Treffern aufgehört. Das war bei einem
     * deutschlandweiten Datensatz problematisch.
     */
    for (final station in _stations) {
      final normalizedName =
          _normalize(station.name);

      final score = _scoreStation(
        normalizedName,
        queryTokens,
        normalizedQuery,
        station,
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
    String name,
    List<String> queryTokens,
    String query,
    Station station,
  ) {
    var score = 0.0;

    /*
     * Exakter kompletter Name.
     */
    if (name == query) {
      score += 1000;
    }

    /*
     * Der Name beginnt exakt mit der Suche.
     */
    if (name.startsWith(query)) {
      score += 700;
    }

    /*
     * Die Suchphrase kommt komplett im Namen vor.
     */
    if (name.contains(query)) {
      score += 500;
    }

    final nameTokens = _tokens(name);

    if (queryTokens.isEmpty) {
      return score;
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
              _max(bestTokenScore, 180);
        } else if (nameToken.startsWith(
          queryToken,
        )) {
          bestTokenScore =
              _max(bestTokenScore, 140);
        } else if (nameToken.contains(
          queryToken,
        )) {
          bestTokenScore =
              _max(bestTokenScore, 100);
        } else if (_isCloseEnough(
          queryToken,
          nameToken,
        )) {
          bestTokenScore =
              _max(bestTokenScore, 55);
        }
      }

      if (bestTokenScore > 0) {
        matchedTokens++;
        score += bestTokenScore;
      }
    }

    /*
     * Alle Suchbestandteile gefunden:
     * deutlicher Bonus.
     *
     * Dadurch wird z. B.
     *
     * "Reichenbach im Vogtland"
     *
     * gegenüber einem beliebigen
     * "Reichenbach" besser behandelt.
     */
    if (matchedTokens ==
        queryTokens.length) {
      score += 300;
    } else if (matchedTokens > 0) {
      score +=
          matchedTokens * 20;
    } else {
      /*
       * Kein vernünftiger Bestandteil gefunden.
       */
      return 0;
    }

    /*
     * Bahnhöfe und Stationen werden leicht
     * bevorzugt.
     */
    if (station.locationType == 1) {
      score += 25;
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
    var result = value.trim().toLowerCase();

    /*
     * Deutsche Umlaute vereinheitlichen.
     */
    result = result
        .replaceAll('ä', 'ae')
        .replaceAll('ö', 'oe')
        .replaceAll('ü', 'ue')
        .replaceAll('ß', 'ss');

    /*
     * Häufige Bahnhofs-Abkürzungen vereinheitlichen.
     */
    result = result
        .replaceAll(
          RegExp(r'\bbhf\b'),
          'bahnhof',
        )
        .replaceAll(
          RegExp(r'\bbf\b'),
          'bahnhof',
        )
        .replaceAll(
          RegExp(r'\bhbf\b'),
          'hauptbahnhof',
        );

    /*
     * Klammern werden für die Suchnormalisierung
     * wie normale Trennzeichen behandelt.
     */
    result = result.replaceAll(
      RegExp(r'[(),./_-]+'),
      ' ',
    );

    /*
     * Mehrere Leerzeichen zusammenfassen.
     */
    result = result.replaceAll(
      RegExp(r'\s+'),
      ' ',
    );

    return result.trim();
  }

  bool _isCloseEnough(
    String query,
    String candidate,
  ) {
    /*
     * Für sehr kurze Wörter keine aggressive
     * Tippfehlerkorrektur.
     */
    if (query.length < 4) {
      return false;
    }

    /*
     * Nur Kandidaten ähnlicher Länge vergleichen.
     */
    if ((query.length - candidate.length)
            .abs() >
        2) {
      return false;
    }

    return _levenshtein(
          query,
          candidate,
        ) <=
        (query.length >= 7 ? 2 : 1);
  }

  int _levenshtein(
    String a,
    String b,
  ) {
    if (a == b) {
      return 0;
    }

    if (a.isEmpty) {
      return b.length;
    }

    if (b.isEmpty) {
      return a.length;
    }

    var previous = List<int>.generate(
      b.length + 1,
      (index) => index,
    );

    for (var i = 0; i < a.length; i++) {
      final current =
          List<int>.filled(
        b.length + 1,
        0,
      );

      current[0] = i + 1;

      for (var j = 0; j < b.length; j++) {
        final insertCost =
            current[j] + 1;

        final deleteCost =
            previous[j + 1] + 1;

        final replaceCost =
            previous[j] +
                (a[i] == b[j] ? 0 : 1);

        current[j + 1] =
            _min3(
          insertCost,
          deleteCost,
          replaceCost,
        );
      }

      previous = current;
    }

    return previous[b.length];
  }

  int _min3(
    int a,
    int b,
    int c,
  ) {
    var result = a;

    if (b < result) {
      result = b;
    }

    if (c < result) {
      result = c;
    }

    return result;
  }

  double _max(
    double a,
    double b,
  ) {
    return a > b ? a : b;
  }

  List<String> _parseCsvLine(
    String line,
  ) {
    final result = <String>[];
    final buffer = StringBuffer();

    var quoted = false;

    for (var i = 0;
        i < line.length;
        i++) {
      final char = line[i];

      if (char == '"') {
        if (quoted &&
            i + 1 < line.length &&
            line[i + 1] == '"') {
          buffer.write('"');
          i++;
        } else {
          quoted = !quoted;
        }
      } else if (char == ',' && !quoted) {
        result.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(char);
      }
    }

    result.add(buffer.toString());

    return result;
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
                      station.locationType ==
                              1
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
