import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:adhan/adhan.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hello_app/thasbeeh_page.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Imam',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(title: 'Imam'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class NextPrayerData {
  final String name;
  final DateTime time;
  final String remainingText;

  const NextPrayerData({
    required this.name,
    required this.time,
    required this.remainingText,
  });
}

class _MyHomePageState extends State<MyHomePage> {
  static const String _lastLatKey = 'last_known_prayer_lat';
  static const String _lastLngKey = 'last_known_prayer_lng';

  double? phoneHeading;
  double? targetBearing;
  late Future<NextPrayerData> _nextPrayerFuture;
  bool _usingPreviousLocation = false;
  bool _isLocationAvailable = false;
  StreamSubscription<ServiceStatus>? _locationServiceSubscription;

  double currentLat = 0;
  double currentLng = 0;

  double targetLat = 21.4225;
  double targetLng = 39.8262;

  Future<void> _updateLocationAvailability() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    final permission = await Geolocator.checkPermission();
    final permissionGranted = permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;

    if (!mounted) return;
    setState(() {
      _isLocationAvailable = serviceEnabled && permissionGranted;
    });
  }

  void _applyCoordinates(double lat, double lng) {
    if (!mounted) return;
    setState(() {
      currentLat = lat;
      currentLng = lng;
      targetBearing = calculateBearing(
        currentLat,
        currentLng,
        targetLat,
        targetLng,
      );
    });
  }

  Future<void> _saveLastLocation(double lat, double lng) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_lastLatKey, lat);
    await prefs.setDouble(_lastLngKey, lng);
  }

  Future<({double lat, double lng})?> _loadLastLocation() async {
    final prefs = await SharedPreferences.getInstance();
    final lat = prefs.getDouble(_lastLatKey);
    final lng = prefs.getDouble(_lastLngKey);
    if (lat == null || lng == null) {
      return null;
    }
    return (lat: lat, lng: lng);
  }

  Future<({double lat, double lng, bool usedPrevious})> getLocation({
    bool preferFreshLocation = false,
  }) async {
    Future<({double lat, double lng, bool usedPrevious})?> trySaved() async {
      final saved = await _loadLastLocation();
      if (saved != null) {
        _applyCoordinates(saved.lat, saved.lng);
        return (lat: saved.lat, lng: saved.lng, usedPrevious: true);
      }
      return null;
    }

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      await _updateLocationAvailability();
      if (preferFreshLocation) {
        throw Exception('Location services are disabled');
      }
      final saved = await trySaved();
      if (saved != null) return saved;
      throw Exception('Location services are disabled');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      await _updateLocationAvailability();
      if (preferFreshLocation) {
        throw Exception('Location permission denied');
      }
      final saved = await trySaved();
      if (saved != null) return saved;
      throw Exception('Location permission denied');
    }

    Future<({double lat, double lng, bool usedPrevious})?> tryLastKnown() async {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) {
        _applyCoordinates(last.latitude, last.longitude);
        await _saveLastLocation(last.latitude, last.longitude);
        return (lat: last.latitude, lng: last.longitude, usedPrevious: true);
      }
      return null;
    }

    try {
      // Give GPS enough time first, especially when offline.
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 30),
      );
      _applyCoordinates(position.latitude, position.longitude);
      await _saveLastLocation(position.latitude, position.longitude);
      await _updateLocationAvailability();
      return (
        lat: position.latitude,
        lng: position.longitude,
        usedPrevious: false,
      );
    } catch (_) {}

    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 20),
      );
      _applyCoordinates(position.latitude, position.longitude);
      await _saveLastLocation(position.latitude, position.longitude);
      await _updateLocationAvailability();
      return (
        lat: position.latitude,
        lng: position.longitude,
        usedPrevious: false,
      );
    } catch (_) {}

    if (preferFreshLocation) {
      throw Exception(
        'Could not get your current location yet. Please wait a moment and tap refresh again.',
      );
    }

    final cached = await tryLastKnown();
    if (cached != null) return cached;

    final saved = await trySaved();
    if (saved != null) return saved;

    throw Exception(
      'Could not get your location. Try moving outdoors or tap Retry.',
    );
  }

  void _refreshNextPrayer() {
    setState(() {
      _nextPrayerFuture = getNextPrayerTime(preferFreshLocation: true);
    });
  }

  String _prayerLoadErrorMessage(Object? error) {
    if (error is TimeoutException) {
      return 'Getting your location timed out. Check GPS or tap Retry.';
    }
    if (error is LocationServiceDisabledException) {
      return 'Location is turned off. Enable it in settings and tap Retry.';
    }
    final msg = error.toString();
    if (msg.contains('Location services are disabled')) {
      return 'Location services are disabled. Turn them on and tap Retry.';
    }
    if (msg.contains('permission denied')) {
      return 'Location permission is required. Grant it in settings and tap Retry.';
    }
    if (msg.contains('Could not get your location')) {
      return msg.replaceFirst('Exception: ', '');
    }
    if (msg.contains('Next prayer time unavailable')) {
      return 'Could not determine the next prayer. Tap Retry.';
    }
    return 'Unable to load prayer times. Tap Retry.';
  }

  PrayerTimes getPrayerTimes(double lat, double lon) {
    final coordinates = Coordinates(lat, lon);

    final params = CalculationMethod.muslim_world_league.getParameters();
    params.madhab = Madhab.shafi; // Kerala follows Shafi

    final date = DateComponents.from(DateTime.now());

    return PrayerTimes(coordinates, date, params);
  }

  NextPrayerData getNextPrayer(PrayerTimes prayerTimes) {
    final next = prayerTimes.nextPrayer();
    final time = prayerTimes.timeForPrayer(next);

    if (time == null) {
      throw Exception('Next prayer time unavailable');
    }

    final remaining = time.difference(DateTime.now());
    return NextPrayerData(
      name: next.name,
      time: time,
      remainingText: formatRemainingDuration(remaining),
    );
  }

  String formatTime(DateTime time) {
    return DateFormat('h.mm').format(time);
  }

  String formatRemainingDuration(Duration duration) {
    if (duration.isNegative) {
      return '0 minutes more';
    }

    final totalMinutes = duration.inMinutes;
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;

    if (hours == 0) {
      return '$minutes minute${minutes == 1 ? '' : 's'} more';
    }

    if (minutes == 0) {
      return '$hours hour${hours == 1 ? '' : 's'} more';
    }

    return '$hours hour${hours == 1 ? '' : 's'} and $minutes minute${minutes == 1 ? '' : 's'} more';
  }

  Future<NextPrayerData> getNextPrayerTime({
    bool preferFreshLocation = false,
  }) async {
    final location = await getLocation(preferFreshLocation: preferFreshLocation);
    if (mounted) {
      setState(() {
        _usingPreviousLocation = location.usedPrevious;
      });
    }

    final prayerTimes = getPrayerTimes(
      location.lat,
      location.lng,
    );

    return getNextPrayer(prayerTimes);
  }

  @override
  void initState() {
    super.initState();

    _nextPrayerFuture = getNextPrayerTime();
    _updateLocationAvailability();
    _locationServiceSubscription =
        Geolocator.getServiceStatusStream().listen((_) {
      _updateLocationAvailability();
    });

    FlutterCompass.events?.listen((event) {
      setState(() {
        phoneHeading = event.heading;
      });
    });
  }

  @override
  void dispose() {
    _locationServiceSubscription?.cancel();
    super.dispose();
  }

  double calculateBearing(
    double lat1, double lon1, double lat2, double lon2) {

    var dLon = (lon2 - lon1) * pi / 180;

    lat1 = lat1 * pi / 180;
    lat2 = lat2 * pi / 180;

    var y = sin(dLon) * cos(lat2);
    var x = cos(lat1) * sin(lat2) -
        sin(lat1) * cos(lat2) * cos(dLon);

    var brng = atan2(y, x);

    brng = brng * 180 / pi;
    brng = (brng + 360) % 360;

    return brng;
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    return Scaffold(
      appBar: AppBar(
        // TRY THIS: Try changing the color here to a specific color (to
        // Colors.amber, perhaps?) and trigger a hot reload to see the AppBar
        // change color while the other colors stay the same.
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        // Here we take the value from the MyHomePage object that was created by
        // the App.build method, and use it to set our appbar title.
        title: Text(widget.title),
        actions: [
          IconButton(
            onPressed: _refreshNextPrayer,
            tooltip: 'Refresh location',
            icon: Icon(
              Icons.my_location,
              color: _isLocationAvailable ? Colors.green : Colors.red,
            ),
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FutureBuilder<NextPrayerData>(
              future: _nextPrayerFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const CircularProgressIndicator();
                } else if (snapshot.hasError) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _prayerLoadErrorMessage(snapshot.error),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 15,
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _refreshNextPrayer,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  );
                } else {
                  final nextPrayer = snapshot.data!;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_usingPreviousLocation)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 8),
                          child: Text(
                            'Showing prayer time from your previous location',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.black54,
                            ),
                          ),
                        ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.deepPurple.shade50,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: [
                            const Text(
                              "Next prayer is",
                              style: TextStyle(fontSize: 14, color: Colors.black54),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              "${nextPrayer.name} at ${formatTime(nextPrayer.time)}",
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: Colors.deepPurple,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              nextPrayer.remainingText,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Colors.green,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                }
              },
            ),
            const SizedBox(height: 20),
            const Text(
              'Direction of Namaz is showing below',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            // Compass Needle
            targetBearing == null
                ? const SizedBox(
                    height: 120,
                    child: Center(
                      child: Text(
                        'Direction unavailable',
                        style: TextStyle(color: Colors.black54),
                      ),
                    ),
                  )
                : Transform.rotate(
                    angle:
                        ((targetBearing! - (phoneHeading ?? 0)) * pi / 180),
                    child: const Icon(
                      Icons.navigation,
                      size: 120,
                      color: Colors.red,
                    ),
                  ),

            const SizedBox(height: 40),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ThasbeehPage(),
                  ),
                );
              },
              icon: const Icon(Icons.arrow_forward),
              label: const Text('Go to Thasbeeh'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
