Ja, das liegt an der Darstellung meines Schreibblocks auf deinem Handy. Wir brauchen dafür keinen Schreibblock. Ich gebe dir den Inhalt als normalen kopierbaren Codeblock.
Bitte in GitHub lib/main.dart komplett löschen und durch diesen Inhalt ersetzen:
import 'package:flutter/material.dart';

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

  DateTime _selectedDate = DateTime.now();
  TimeOfDay _selectedTime = TimeOfDay.now();

  int _currentTab = 0;

  @override
  void dispose() {
    _fromController.dispose();
    _toController.dispose();
    super.dispose();
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

    setState(() {
      _fromController.text = to;
      _toController.text = from;
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
          date: _selectedDate,
          time: _selectedTime,
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');

    return '$day.$month.${date.year}';
  }

  String _formatTime(TimeOfDay time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');

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
            icon: Icon(Icons.warning_amber_outlined),
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
                    TextField(
                      controller: _fromController,
                      decoration: InputDecoration(
                        labelText: 'Start',
                        hintText: 'z. B. Gera Hbf',
                        prefixIcon:
                            const Icon(Icons.trip_origin),
                        border: OutlineInputBorder(
                          borderRadius:
                              BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        const Expanded(
                          child: Divider(),
                        ),
                        IconButton(
                          tooltip: 'Start und Ziel tauschen',
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
                    TextField(
                      controller: _toController,
                      decoration: InputDecoration(
                        labelText: 'Ziel',
                        hintText: 'z. B. Berlin Hbf',
                        prefixIcon: const Icon(
                          Icons.location_on_outlined,
                        ),
                        border: OutlineInputBorder(
                          borderRadius:
                              BorderRadius.circular(12),
                        ),
                      ),
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
                      contentPadding: EdgeInsets.zero,
                      leading:
                          const Icon(Icons.calendar_today),
                      title: const Text('Datum'),
                      subtitle:
                          Text(_formatDate(_selectedDate)),
                      trailing:
                          const Icon(Icons.chevron_right),
                      onTap: _selectDate,
                    ),
                    const Divider(),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading:
                          const Icon(Icons.access_time),
                      title: const Text('Abfahrt'),
                      subtitle:
                          Text(_formatTime(_selectedTime)),
                      trailing:
                          const Icon(Icons.chevron_right),
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
              icon: const Icon(Icons.my_location),
              label: const Text(
                'Aktuellen Standort verwenden',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMapPage() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
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
        mainAxisAlignment: MainAxisAlignment.center,
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
  final DateTime date;
  final TimeOfDay time;

  const SearchResultPage({
    super.key,
    required this.from,
    required this.to,
    required this.date,
    required this.time,
  });

  String _formatDate(DateTime date) {
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');

    return '$day.$month.${date.year}';
  }

  String _formatTime(TimeOfDay time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');

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
                    'Hier wird später der '
                    'GTFS/DELFI-Routenplaner '
                    'angeschlossen.',
                    style: TextStyle(
                      color: Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
Wichtig: Diesmal wirklich nur lib/main.dart ersetzen. pubspec.yaml und android.yml lassen wir unverändert.
Danach Commit changes und den Build starten lassen. Wenn GitHub einen Fehler meldet, schick mir wieder den roten Abschnitt – dann gehen wir den nächsten Schritt an.
