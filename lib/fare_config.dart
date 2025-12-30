import 'dart:math';

enum Shift { diurno, nocturno }
enum ServiceChannel { calle, telefonico, app }

class FareConfig {
  // Banderazos
  final double baseDiurnoCalle;
  final double baseNocturnoCalle;
  final double baseDiurnoTelefonico;
  final double baseNocturnoTelefonico;
  final double baseDiurnoApp;
  final double baseNocturnoApp;

  // “Tick” del taxímetro
  final double stepCost;     // $1.825
  final int stepSeconds;     // 39 s
  final double stepMeters;   // 250 m

  // Redondeo final (configurable). Si quieres 0.05, cámbialo a 0.05.
  final double roundingStep;

  const FareConfig({
    required this.baseDiurnoCalle,
    required this.baseNocturnoCalle,
    required this.baseDiurnoTelefonico,
    required this.baseNocturnoTelefonico,
    required this.baseDiurnoApp,
    required this.baseNocturnoApp,
    required this.stepCost,
    required this.stepSeconds,
    required this.stepMeters,
    this.roundingStep = 0.01,
  });

  double baseFare(Shift shift, ServiceChannel channel) {
    switch (shift) {
      case Shift.diurno:
        switch (channel) {
          case ServiceChannel.calle:
            return baseDiurnoCalle;
          case ServiceChannel.telefonico:
            return baseDiurnoTelefonico;
          case ServiceChannel.app:
            return baseDiurnoApp;
        }
      case Shift.nocturno:
        switch (channel) {
          case ServiceChannel.calle:
            return baseNocturnoCalle;
          case ServiceChannel.telefonico:
            return baseNocturnoTelefonico;
          case ServiceChannel.app:
            return baseNocturnoApp;
        }
    }
  }

  int unitsFromTotals({
    required double distanceMeters,
    required Duration elapsed,
  }) {
    final timeUnits = (elapsed.inSeconds / stepSeconds).floor();
    final distUnits = (distanceMeters / stepMeters).floor();
    return max(timeUnits, distUnits);
  }

  double fareFromTotals({
    required Shift shift,
    required ServiceChannel channel,
    required double distanceMeters,
    required Duration elapsed,
  }) {
    final base = baseFare(shift, channel);
    final units = unitsFromTotals(distanceMeters: distanceMeters, elapsed: elapsed);
    final raw = base + (units * stepCost);
    return _roundTo(raw, roundingStep);
  }

  double _roundTo(double value, double step) {
    if (step <= 0) return value;
    return (value / step).round() * step;
  }
}