// lib/routing/gtfs_data.dart
//
// Laedt die von tool/build_routing_index.py erzeugten Routing-Assets
// (assets/data/routing/*.json) und haelt sie fuer die RAPTOR-Planung
// im Speicher. Alle Daten enthalten ausschliesslich Deutschlandticket-
// gueltige Verbindungen (siehe tool/agency_exclude.json).

import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;

/// Ein Fahrplanmuster: eine Route mit einer konkreten, geordneten
/// Haltestellenfolge. Mehrere Fahrten am Tag teilen sich i.d.R. dasselbe
/// Muster (nur die Uhrzeiten unterscheiden sich).
class GtfsPattern {
  final String routeId;
  final List<String> stops;

  const GtfsPattern({required this.routeId, required this.stops});

  factory GtfsPattern.fromJson(Map<String, dynamic> json) => GtfsPattern(
        routeId: json['route_id'] as String,
        stops: List<String>.from(json['stops'] as List),
      );
}

/// Eine einzelne Fahrt: Referenz auf ihr Muster + Uhrzeiten je Halt
/// (Sekunden seit Mitternacht; koennen > 86400 sein bei Fahrten nach
/// Mitternacht, wie im GTFS-Standard ueblich).
class GtfsTrip {
  final int patternId;
  final String serviceId;
  final List<int> departures; // Sekunden seit Mitternacht, je Halt
  final List<int> arrivalOffsets; // Ankunft - Abfahrt je Halt (meist 0)

  const GtfsTrip({
    required this.patternId,
    required this.serviceId,
    required this.departures,
    required this.arrivalOffsets,
  });

  factory GtfsTrip.fromJson(Map<String, dynamic> json) => GtfsTrip(
        patternId: json['p'] as int,
        serviceId: json['s'] as String,
        departures: List<int>.from(json['d'] as List),
        arrivalOffsets: List<int>.from(json['a'] as List),
      );

  int arrivalAt(int stopIndex) => departures[stopIndex] + arrivalOffsets[stopIndex];
}

/// Servicetage einer Fahrt (Wochentags-Bitmaske + Ausnahmen), aus
/// calendar.txt/calendar_dates.txt.
class ServiceCalendar {
  final int weekdayMask; // Bit 0 = Montag ... Bit 6 = Sonntag
  final String startDate; // 'YYYYMMDD'
  final String endDate; // 'YYYYMMDD'
  final Set<String> added; // Ausnahme: faehrt zusaetzlich
  final Set<String> removed; // Ausnahme: faehrt an diesem Tag nicht

  const ServiceCalendar({
    required this.weekdayMask,
    required this.startDate,
    required this.endDate,
    required this.added,
    required this.removed,
  });

  factory ServiceCalendar.fromJson(Map<String, dynamic> json) => ServiceCalendar(
        weekdayMask: json['mask'] as int,
        startDate: json['start'] as String,
        endDate: json['end'] as String,
        added: Set<String>.from(json['added'] as List),
        removed: Set<String>.from(json['removed'] as List),
      );

  /// [dateYmd] im Format 'YYYYMMDD'. [weekdayMondayZero]: Montag=0 .. Sonntag=6.
  bool runsOn(String dateYmd, int weekdayMondayZero) {
    if (removed.contains(dateYmd)) return false;
    if (added.contains(dateYmd)) return true;
    if (dateYmd.compareTo(startDate) < 0 || dateYmd.compareTo(endDate) > 0) {
      return false;
    }
    return (weekdayMask & (1 << weekdayMondayZero)) != 0;
  }
}

class RouteInfo {
  final String name;
  final String agencyId;

  const RouteInfo({required this.name, required this.agencyId});

  factory RouteInfo.fromJson(Map<String, dynamic> json) => RouteInfo(
        name: json['name'] as String? ?? '?',
        agencyId: json['agency'] as String? ?? '',
      );
}

/// Verweis einer Haltestelle auf ihre Position innerhalb eines Musters.
class StopPatternRef {
  final int patternId;
  final int stopIndex;
  const StopPatternRef(this.patternId, this.stopIndex);
}

/// Haelt alle geladenen Routing-Daten + daraus abgeleitete Indizes.
class GtfsRoutingData {
  final List<GtfsPattern> patterns;
  final Map<String, GtfsTrip> trips;
  final Map<String, ServiceCalendar> calendar;
  final Map<String, RouteInfo> routes;

  /// Elternstation (aus der Stationssuche) -> Bahnsteig/Kind-Haltestellen-IDs.
  /// Noetig, weil die Stationssuche i.d.R. die Eltern-ID liefert, die
  /// eigentlichen Fahrten aber an den Kind-IDs haengen.
  final Map<String, List<String>> stopGroups;

  /// Haltestellen-ID -> Anzeigename (aus stop_names.json, wird im CI-Build
  /// erzeugt). Fehlt ein Eintrag oder die Datei, wird die ID angezeigt.
  final Map<String, String> stopNames;

  /// Haltestelle -> Liste der Muster, die sie bedienen (+ Position darin).
  final Map<String, List<StopPatternRef>> stopPatterns;

  const GtfsRoutingData._({
    required this.patterns,
    required this.trips,
    required this.calendar,
    required this.routes,
    required this.stopGroups,
    required this.stopNames,
    required this.stopPatterns,
  });

  String stopName(String stopId) => stopNames[stopId] ?? stopId;

  /// Loest eine von der Stationssuche gelieferte Stations-ID zu den
  /// tatsaechlich fahrplanrelevanten (Kind-)Haltestellen-IDs auf. Falls
  /// keine Kind-Stationen bekannt sind, wird angenommen, dass die ID
  /// selbst bereits eine fahrplanrelevante Haltestelle ist.
  Set<String> resolveBoardableStops(String stationId) {
    final children = stopGroups[stationId];
    if (children != null && children.isNotEmpty) {
      return children.toSet();
    }
    return {stationId};
  }

  static Future<GtfsRoutingData> loadFromAssets({
    String basePath = 'assets/data/routing',
  }) async {
    Future<dynamic> loadJson(String fileName) async {
      final raw = await rootBundle.loadString('$basePath/$fileName');
      try {
        return jsonDecode(raw);
      } on FormatException catch (e) {
        // Haeufigste Ursache: Datei wurde beim Hochladen/Commit
        // abgeschnitten (z.B. Upload ueber die GitHub-Weboberflaeche
        // bei grossen Dateien). raw.length verraten, ob die Datei
        // ueberhaupt vollstaendig ankam.
        throw FormatException(
          'Konnte $fileName nicht lesen (${raw.length} Zeichen geladen). '
          'Vermutlich ist die Datei unvollstaendig/abgeschnitten - bitte '
          'Dateigroesse im Repo mit dem Original vergleichen. '
          'Ursprünglicher Fehler: ${e.message}',
          e.source,
          e.offset,
        );
      }
    }

    final patternsJson = await loadJson('patterns.json') as List;
    final calendarJson = await loadJson('calendar.json') as Map<String, dynamic>;
    final routesJson = await loadJson('routes.json') as Map<String, dynamic>;
    final stopGroupsJson = await loadJson('stop_groups.json') as Map<String, dynamic>;

    // trips.json liegt in mehreren kleineren Teil-Dateien vor (siehe
    // build_routing_index.py) - das manifest listet sie in Reihenfolge.
    final manifest = await loadJson('trips_manifest.json') as List;
    final tripsJson = <String, dynamic>{};
    for (final shardName in manifest) {
      final shard = await loadJson(shardName as String) as Map<String, dynamic>;
      tripsJson.addAll(shard);
    }

    final patterns = patternsJson
        .map((e) => GtfsPattern.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);

    final trips = <String, GtfsTrip>{};
    tripsJson.forEach((tid, v) {
      trips[tid] = GtfsTrip.fromJson(v as Map<String, dynamic>);
    });

    final calendar = <String, ServiceCalendar>{};
    calendarJson.forEach((sid, v) {
      calendar[sid] = ServiceCalendar.fromJson(v as Map<String, dynamic>);
    });

    final routes = <String, RouteInfo>{};
    routesJson.forEach((rid, v) {
      routes[rid] = RouteInfo.fromJson(v as Map<String, dynamic>);
    });

    final stopGroups = <String, List<String>>{};
    stopGroupsJson.forEach((parent, children) {
      stopGroups[parent] = List<String>.from(children as List);
    });

    final stopNames = <String, String>{};
    try {
      final namesJson = await loadJson('stop_names.json') as Map<String, dynamic>;
      namesJson.forEach((id, name) => stopNames[id] = name.toString());
    } catch (_) {
      // Optional: ohne Namensdatei zeigt die App weiterhin die IDs.
    }

    final stopPatterns = <String, List<StopPatternRef>>{};
    for (var pid = 0; pid < patterns.length; pid++) {
      final stops = patterns[pid].stops;
      for (var idx = 0; idx < stops.length; idx++) {
        stopPatterns
            .putIfAbsent(stops[idx], () => <StopPatternRef>[])
            .add(StopPatternRef(pid, idx));
      }
    }

    return GtfsRoutingData._(
      patterns: patterns,
      trips: trips,
      calendar: calendar,
      routes: routes,
      stopGroups: stopGroups,
      stopNames: stopNames,
      stopPatterns: stopPatterns,
    );
  }
}
