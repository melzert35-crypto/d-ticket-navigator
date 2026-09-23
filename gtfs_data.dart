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

  /// Haltestelle -> Liste der Muster, die sie bedienen (+ Position darin).
  final Map<String, List<StopPatternRef>> stopPatterns;

  const GtfsRoutingData._({
    required this.patterns,
    required this.trips,
    required this.calendar,
    required this.routes,
    required this.stopGroups,
    required this.stopPatterns,
  });

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
    final results = await Future.wait([
      rootBundle.loadString('$basePath/patterns.json'),
      rootBundle.loadString('$basePath/trips.json'),
      rootBundle.loadString('$basePath/calendar.json'),
      rootBundle.loadString('$basePath/routes.json'),
      rootBundle.loadString('$basePath/stop_groups.json'),
    ]);

    final patternsJson = jsonDecode(results[0]) as List;
    final tripsJson = jsonDecode(results[1]) as Map<String, dynamic>;
    final calendarJson = jsonDecode(results[2]) as Map<String, dynamic>;
    final routesJson = jsonDecode(results[3]) as Map<String, dynamic>;
    final stopGroupsJson = jsonDecode(results[4]) as Map<String, dynamic>;

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
      stopPatterns: stopPatterns,
    );
  }
}
