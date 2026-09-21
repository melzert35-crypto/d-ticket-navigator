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
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('D-Ticket Navigator'),
      ),
      body: const Center(
        child: Text(
          'D-Ticket Navigator\n\n'
          'GTFS/DELFI Routing wird vorbereitet.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
