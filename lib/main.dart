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

  const Station({
    required this.id,
    required this.name,
    this.latitude,
    this.longitude,
  });
}

class StationDatabase {
  List<Station> _stations = [];

  bool get isLoaded => _stations.isNotEmpty;

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

    final stopIdIndex = header.indexOf('stop_id');
    final stopNameIndex = header.indexOf('stop_name');
    final latIndex = header.indexOf('stop_lat');
    final lonIndex = header.indexOf('stop_lon');
    final locationTypeIndex =
        header.indexOf('location_type');

    if (stopIdIndex < 0 || stopNameIndex < 0) {
      throw Exception(
        'GTFS stops.txt enthält keine gültigen stop_id/stop_name-Spalten.',
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

      if (fields.length <= stopNameIndex ||
          fields.length <= stopIdIndex) {
        continue;
      }

      final id = fields[stopIdIndex].trim();
      final name = fields[stopNameIndex].trim();

      if (id.isEmpty || name.isEmpty) {
        continue;
      }

      // Nur echte Haltestellen verwenden.
      // location_type 0 = Haltestelle.
      if (locationTypeIndex >= 0 &&
          fields.length > locationTypeIndex) {
        final locationType =
            fields[locationTypeIndex].trim();

        if (locationType.isNotEmpty &&
            locationType != '0') {
          continue;
        }
      }

      if (!seen.add(id)) {
        continue;
      }

      double? latitude;
      double? longitude;

      if (latIndex >= 0 && fields.length > latIndex) {
        latitude = double.tryParse(
          fields[latIndex].trim(),
        );
      }

      if (lonIndex >= 0 && fields.length > lonIndex) {
        longitude = double.tryParse(
          fields[lonIndex].trim(),
        );
      }

      result.add(
        Station(
          id: id,
          name: name,
          latitude: latitude,
          longitude: longitude,
        ),
      );
    }

    return result;
  }

  List<Station> search(
    String query, {
    int limit = 12,
  }) {
    final normalizedQuery = _normalize(query);

    if (normalizedQuery.isEmpty) {
      return [];
    }

    final exact = <Station>[];
    final startsWith = <Station>[];
    final contains = <Station>[];

    for (final station in _stations) {
      final normalizedName =
          _normalize(station.name);

      if (normalizedName == normalizedQuery) {
        exact.add(station);
      } else if (normalizedName.startsWith(
        normalizedQuery,
      )) {
        startsWith.add(station);
      } else if (normalizedName.contains(
        normalizedQuery,
      )) {
        contains.add(station);
      }

      if (exact.length +
              startsWith.length +
              contains.length >=
          limit) {
        break;
      }
    }

    return [
      ...exact,
      ...startsWith,
      ...contains,
    ].take(limit).toList();
  }

  String _normalize(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll('ä', 'ae')
        .replaceAll('ö', 'oe')
        .replaceAll('ü', 'ue')
        .replaceAll('ß', 'ss');
  }

  List<String> _parseCsvLine(String line) {
    final result = <String>[];
    final buffer = StringBuffer();

    var quoted = false;

    for (var i = 0; i < line.length; i++) {
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

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _fromController =
      TextEditingController();

  final TextEditingController _toController =
      TextEditingController();

  final StationDatabase _stationDatabase =
      StationDatabase();

  DateTime _selectedDate = DateTime.now();
  TimeOfDay _selectedTime = TimeOfDay.now();

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
        _stationError = error.toString();
      });
    }
  }

  void _onFromChanged(String value) {
    final suggestions =
        _stationDatabase.search(value);

    setState(() {
      _selectedFromStation = null;
      _fromSuggestions = suggestions;
    });
  }

  void _onToChanged(String value) {
    final suggestions =
        _stationDatabase.search(value);

    setState(() {
      _selectedToStation = null;
      _toSuggestions = suggestions;
    });
  }

  void _selectFromStation(Station station) {
    setState(() {
      _selectedFromStation = station;
      _fromController.text = station.name;
      _fromController.selection =
          TextSelection.collapsed(
        offset: station.name.length,
      );
      _fromSuggestions = [];
    });
  }

  void _selectToStation(Station station) {
    setState(() {
      _selectedToStation = station;
      _toController.text = station.name;
      _toController.selection =
          TextSelection.collapsed(
        offset: station.name.length,
      );
      _toSuggestions = [];
    });
  }

  Future<void> _selectDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(
        const Duration(days: 365),
      ),
    );

    if (picked != null) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  Future<void> _selectTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _selectedTime,
    );

    if (picked != null) {
      setState(() {
        _selectedTime = picked;
      });
    }
  }

  void _swapLocations() {
    final from = _fromController.text;
    final to = _toController.text;

    final fromStation = _selectedFromStation;
    final toStation = _selectedToStation;

    setState(() {
      _fromController.text = to;
      _toController.text = from;

      _selectedFromStation = toStation;
      _selectedToStation = fromStation;

      _fromSuggestions = [];
      _toSuggestions = [];
    });
  }

  void _searchConnection() {
    final from = _fromController.text.trim();
    final to = _toController.text.trim();

    if (from.isEmpty || to.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
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
        builder: (context) => SearchResultPage(
          from: from,
          to: to,
          fromStation: _selectedFromStation,
          toStation: _selectedToStation,
          date: _selectedDate,
          time: _selectedTime,
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final day =
        date.day.toString().padLeft(2, '0');
    final month =
        date.month.toString().padLeft(2, '0');

    return '$day.$month.${date.year}';
  }

  String _formatTime(TimeOfDay time) {
    final hour =
        time.hour.toString().padLeft(2, '0');
    final minute =
        time.minute.toString().padLeft(2, '0');

    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'D-Ticket Navigator',
          style: TextStyle(
            fontWeight: FontWeight.bold,
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
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentTab,
        onDestinationSelected: (index) {
          setState(() {
            _currentTab = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.route),
            label: 'Verbindung',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
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
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.stretch,
          children: [
            if (_loadingStations)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
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
                      SizedBox(width: 14),
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
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'GTFS-Fehler:\n$_stationError',
                    style: const TextStyle(
                      color: Colors.red,
                    ),
                  ),
                ),
              ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Reise planen',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Verbindungen mit dem '
                      'Deutschlandticket finden',
                      style: TextStyle(
                        color: Colors.grey.shade700,
                      ),
                    ),
                    const SizedBox(height: 20),
                    _buildStationField(
                      controller: _fromController,
                      label: 'Start',
                      hint: 'z. B. Reichen…',
                      icon: Icons.trip_origin,
                      suggestions: _fromSuggestions,
                      onChanged: _onFromChanged,
                      onSelected:
                          _selectFromStation,
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        const Expanded(
                          child: Divider(),
                        ),
                        IconButton(
                          tooltip:
                              'Start und Ziel tauschen',
                          onPressed: _swapLocations,
                          icon: const Icon(
                            Icons.swap_vert,
                          ),
                        ),
                        const Expanded(
                          child: Divider(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _buildStationField(
                      controller: _toController,
                      label: 'Ziel',
                      hint: 'z. B. Berlin Hbf',
                      icon: Icons.location_on_outlined,
                      suggestions: _toSuggestions,
                      onChanged: _onToChanged,
                      onSelected:
                          _selectToStation,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    ListTile(
                      contentPadding:
                          EdgeInsets.zero,
                      leading: const Icon(
                        Icons.calendar_today,
                      ),
                      title: const Text('Datum'),
                      subtitle:
                          Text(_formatDate(
                        _selectedDate,
                      )),
                      trailing: const Icon(
                        Icons.chevron_right,
                      ),
                      onTap: _selectDate,
                    ),
                    const Divider(),
                    ListTile(
                      contentPadding:
                          EdgeInsets.zero,
                      leading: const Icon(
                        Icons.access_time,
                      ),
                      title: const Text('Abfahrt'),
                      subtitle:
                          Text(_formatTime(
                        _selectedTime,
                      )),
                      trailing: const Icon(
                        Icons.chevron_right,
                      ),
                      onTap: _selectTime,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 54,
              child: FilledButton.icon(
                onPressed: _searchConnection,
                icon: const Icon(Icons.search),
                label: const Text(
                  'VERBINDUNG SUCHEN',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                ScaffoldMessenger.of(context)
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
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    required List<Station> suggestions,
    required ValueChanged<String> onChanged,
    required ValueChanged<Station> onSelected,
  }) {
    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: controller,
          onChanged: onChanged,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            prefixIcon: Icon(icon),
            suffixIcon: controller.text.isNotEmpty
                ? IconButton(
                    tooltip: 'Löschen',
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                    icon: const Icon(Icons.clear),
                  )
                : null,
            border: OutlineInputBorder(
              borderRadius:
                  BorderRadius.circular(12),
            ),
          ),
        ),
        if (suggestions.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(
              top: 4,
            ),
            constraints: const BoxConstraints(
              maxHeight: 300,
            ),
            decoration: BoxDecoration(
              border: Border.all(
                color: Colors.grey.shade300,
              ),
              borderRadius:
                  BorderRadius.circular(12),
            ),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: suggestions.length,
              separatorBuilder:
                  (context, index) =>
                      const Divider(height: 1),
              itemBuilder: (context, index) {
                final station =
                    suggestions[index];

                return ListTile(
                  dense: true,
                  leading: const Icon(
                    Icons.train_outlined,
                  ),
                  title: Text(
                    station.name,
                    maxLines: 2,
                    overflow:
                        TextOverflow.ellipsis,
                  ),
                  onTap: () {
                    onSelected(station);
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
          SizedBox(height: 16),
          Text(
            'Karte',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 8),
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
          SizedBox(height: 16),
          Text(
            'Störungen',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Störungsinformationen folgen.',
          ),
        ],
      ),
    );
  }
}

class SearchResultPage extends StatelessWidget {
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

  String _formatDate(DateTime date) {
    final day =
        date.day.toString().padLeft(2, '0');
    final month =
        date.month.toString().padLeft(2, '0');

    return '$day.$month.${date.year}';
  }

  String _formatTime(TimeOfDay time) {
    final hour =
        time.hour.toString().padLeft(2, '0');
    final minute =
        time.minute.toString().padLeft(2, '0');

    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Verbindung'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Text(
                    '$from → $to',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${_formatDate(date)} '
                    'um ${_formatTime(time)}',
                  ),
                  const SizedBox(height: 20),
                  const Divider(),
                  const SizedBox(height: 20),
                  const Icon(
                    Icons.route,
                    size: 48,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Noch keine Verbindung berechnet.',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Die ausgewählten Haltestellen '
                    'sind bereits aus dem GTFS-Datensatz '
                    'bekannt.',
                    style: TextStyle(
                      color: Colors.grey.shade700,
                    ),
                  ),
                  if (fromStation != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      'Start-ID: ${fromStation!.id}',
                      style: const TextStyle(
                        fontSize: 12,
                      ),
                    ),
                  ],
                  if (toStation != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Ziel-ID: ${toStation!.id}',
                      style: const TextStyle(
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
