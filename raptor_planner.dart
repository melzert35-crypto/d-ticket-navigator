// lib/routing/raptor_planner.dart
//
// Rundenbasierte Verbindungssuche (RAPTOR-Prinzip) auf den von
// GtfsRoutingData geladenen Mustern/Fahrten. Liefert alle Pareto-
// optimalen Verbindungen bezueglich (Umstiege, Ankunftszeit) - also nur
// Optionen, bei denen mehr Umstiege auch tatsaechlich eine fruehere
// Ankunft bringen. Eine Verbindung mit mehr Umstiegen UND spaeterer
// Ankunft als eine andere wird nicht zurueckgegeben.
//
// Wichtige Annahme (Standard bei RAPTOR): Innerhalb eines Musters
// ueberholen sich Fahrten nicht - Trips werden einmal nach ihrer
// Abfahrtszeit am ersten Halt sortiert, diese Reihenfolge gilt dann
// fuer alle weiteren Haltestellen des Musters.

import 'gtfs_data.dart';

const int _kUnreachable = 1 << 30;

class JourneyLeg {
  final String fromStopId;
  final String toStopId;
  final String lineName;
  final int departure; // Sekunden seit Mitternacht
  final int arrival;

  const JourneyLeg({
    required this.fromStopId,
    required this.toStopId,
    required this.lineName,
    required this.departure,
    required this.arrival,
  });
}

class Journey {
  final int transfers;
  final int arrival;
  final List<JourneyLeg> legs;

  const Journey({
    required this.transfers,
    required this.arrival,
    required this.legs,
  });

  int get departure => legs.first.departure;
  Duration get duration => Duration(seconds: arrival - departure);
}

class _ParentRef {
  final String tripId;
  final String boardStop;
  final int boardIdx;
  final int alightIdx;
  const _ParentRef(this.tripId, this.boardStop, this.boardIdx, this.alightIdx);
}

class RaptorPlanner {
  final GtfsRoutingData data;

  const RaptorPlanner(this.data);

  /// Sucht alle Pareto-optimalen Verbindungen von [sourceStationId] nach
  /// [targetStationId] (Stations-IDs wie von der Suche geliefert - werden
  /// intern ueber stopGroups auf die fahrplanrelevanten Haltestellen
  /// aufgeloest).
  ///
  /// [dateYmd]: Reisedatum als 'YYYYMMDD'.
  /// [departAfter]: fruehester Abfahrtszeitpunkt als Sekunden seit
  /// Mitternacht (z.B. TimeOfDay in Sekunden umgerechnet).
  /// [minTransfer]: gewaehlte Mindest-Umstiegszeit (10-30 Minuten gemaess
  /// Nutzereinstellung).
  List<Journey> plan({
    required String sourceStationId,
    required String targetStationId,
    required String dateYmd,
    required int departAfter,
    Duration minTransfer = const Duration(minutes: 10),
    int maxRounds = 10,
  }) {
    final sourceStops = data.resolveBoardableStops(sourceStationId);
    final targetStops = data.resolveBoardableStops(targetStationId);
    final weekday = _weekdayMondayZero(dateYmd);
    final minTransferSec = minTransfer.inSeconds;

    // 1) Fuer das Reisedatum gueltige Fahrten je Muster vorbereiten,
    //    sortiert nach Abfahrt am ersten Halt des Musters.
    final Map<int, List<String>> patternTrips = {};
    data.trips.forEach((tripId, trip) {
      final service = data.calendar[trip.serviceId];
      if (service == null || !service.runsOn(dateYmd, weekday)) return;
      patternTrips.putIfAbsent(trip.patternId, () => <String>[]).add(tripId);
    });
    patternTrips.forEach((patternId, tripIds) {
      tripIds.sort(
        (a, b) => data.trips[a]!.departures[0].compareTo(data.trips[b]!.departures[0]),
      );
    });

    String? earliestTripAt(int patternId, int stopIndex, int notBefore) {
      final tripIds = patternTrips[patternId];
      if (tripIds == null || tripIds.isEmpty) return null;
      var lo = 0, hi = tripIds.length;
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        final dep = data.trips[tripIds[mid]]!.departures[stopIndex];
        if (dep < notBefore) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      return lo < tripIds.length ? tripIds[lo] : null;
    }

    final earliest = <String, int>{for (final s in sourceStops) s: departAfter};
    final parent = <String, _ParentRef>{};
    var marked = Set<String>.from(sourceStops);

    final journeysByTransfers = <int, Journey>{};
    var bestTargetArrival = _kUnreachable;

    for (var round = 0; round < maxRounds; round++) {
      final readEarliest = Map<String, int>.from(earliest);
      final roundUpdates = <String, int>{};
      final roundParent = <String, _ParentRef>{};

      // Welche Muster beruehren markierte Haltestellen? (fruehester Index)
      final scan = <int, int>{};
      for (final stopId in marked) {
        for (final ref in data.stopPatterns[stopId] ?? const <StopPatternRef>[]) {
          final cur = scan[ref.patternId];
          if (cur == null || ref.stopIndex < cur) {
            scan[ref.patternId] = ref.stopIndex;
          }
        }
      }
      if (scan.isEmpty) break;

      scan.forEach((patternId, startIdx) {
        final stops = data.patterns[patternId].stops;
        String? currentTrip;
        var boardIdx = -1;

        for (var i = startIdx; i < stops.length; i++) {
          final stopId = stops[i];

          if (currentTrip != null) {
            final trip = data.trips[currentTrip]!;
            final arr = trip.arrivalAt(i);
            final bestKnown = _min(earliest[stopId], roundUpdates[stopId]);
            if (arr < bestKnown && arr <= bestTargetArrival) {
              roundUpdates[stopId] = arr;
              roundParent[stopId] = _ParentRef(currentTrip, stops[boardIdx], boardIdx, i);
            }
          }

          // Boarding nur anhand des eingefrorenen Standes der Vorrunde
          // pruefen (tau_{k-1}) - verhindert, dass sich innerhalb einer
          // Runde mehr als ein Umstieg "einschleicht".
          final readArrival = readEarliest[stopId];
          if (readArrival != null) {
            final isSourceStart = sourceStops.contains(stopId) && i == startIdx;
            final notBefore = isSourceStart ? readArrival : readArrival + minTransferSec;
            final candidate = earliestTripAt(patternId, i, notBefore);
            if (candidate != null) {
              final candidateDep = data.trips[candidate]!.departures[i];
              if (currentTrip == null || candidateDep < data.trips[currentTrip]!.departures[i]) {
                currentTrip = candidate;
                boardIdx = i;
              }
            }
          }
        }
      });

      final newly = <String>{};
      roundUpdates.forEach((stopId, arr) {
        if (arr < (earliest[stopId] ?? _kUnreachable)) {
          earliest[stopId] = arr;
          parent[stopId] = roundParent[stopId]!;
          newly.add(stopId);
        }
      });
      marked = newly;

      final roundTargetArrival = _minOverStops(earliest, targetStops);
      if (roundTargetArrival != null && roundTargetArrival < bestTargetArrival) {
        bestTargetArrival = roundTargetArrival;
        final reachedTarget = targetStops.firstWhere(
          (t) => earliest[t] == roundTargetArrival,
          orElse: () => targetStops.first,
        );
        final legs = _reconstruct(parent, reachedTarget);
        if (legs.isNotEmpty || sourceStops.contains(reachedTarget)) {
          final journey = Journey(
            transfers: legs.length - 1,
            arrival: roundTargetArrival,
            legs: legs,
          );
          // Pro Umstiegsanzahl nur die fruehste Ankunft behalten.
          final existing = journeysByTransfers[journey.transfers];
          if (existing == null || journey.arrival < existing.arrival) {
            journeysByTransfers[journey.transfers] = journey;
          }
        }
      }

      if (marked.isEmpty) break;
    }

    return _paretoFrontier(journeysByTransfers.values.toList());
  }

  List<JourneyLeg> _reconstruct(Map<String, _ParentRef> parent, String target) {
    final legs = <JourneyLeg>[];
    var cur = target;
    while (parent.containsKey(cur)) {
      final ref = parent[cur]!;
      final trip = data.trips[ref.tripId]!;
      final pattern = data.patterns[trip.patternId];
      final route = data.routes[pattern.routeId];
      legs.add(JourneyLeg(
        fromStopId: ref.boardStop,
        toStopId: cur,
        lineName: route?.name ?? '?',
        departure: trip.departures[ref.boardIdx],
        arrival: trip.arrivalAt(ref.alightIdx),
      ));
      cur = ref.boardStop;
    }
    return legs.reversed.toList();
  }

  /// Entfernt dominierte Verbindungen: bleibt nur, wer bei steigender
  /// Umstiegszahl auch tatsaechlich frueher ankommt als alle Optionen
  /// mit weniger Umstiegen.
  List<Journey> _paretoFrontier(List<Journey> journeys) {
    final ordered = List<Journey>.from(journeys)
      ..sort((a, b) => a.transfers.compareTo(b.transfers));
    final frontier = <Journey>[];
    var bestArrival = _kUnreachable;
    for (final j in ordered) {
      if (j.arrival < bestArrival) {
        frontier.add(j);
        bestArrival = j.arrival;
      }
    }
    return frontier;
  }

  int _min(int? a, int? b) {
    final av = a ?? _kUnreachable;
    final bv = b ?? _kUnreachable;
    return av < bv ? av : bv;
  }

  int? _minOverStops(Map<String, int> earliest, Set<String> stopIds) {
    int? best;
    for (final s in stopIds) {
      final v = earliest[s];
      if (v != null && (best == null || v < best)) best = v;
    }
    return best;
  }

  /// Montag=0 .. Sonntag=6, passend zur Bitmaske aus calendar.json.
  int _weekdayMondayZero(String dateYmd) {
    final year = int.parse(dateYmd.substring(0, 4));
    final month = int.parse(dateYmd.substring(4, 6));
    final day = int.parse(dateYmd.substring(6, 8));
    final date = DateTime(year, month, day);
    return date.weekday - 1; // DateTime.weekday: Montag=1..Sonntag=7
  }
}
