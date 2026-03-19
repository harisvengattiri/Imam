import 'package:flutter/material.dart';
import 'dart:math';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:adhan/adhan.dart';
import 'package:intl/intl.dart';

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
      title: 'Muslim App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(title: 'Muslim App'),
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

  double? phoneHeading;
  double? targetBearing;
  late Future<NextPrayerData> _nextPrayerFuture;

  double currentLat = 0;
  double currentLng = 0;

  double targetLat = 21.4225;
  double targetLng = 39.8262;

  int _counter = 0;

  Future<Position> getLocation() async {

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('Location services are disabled');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw Exception('Location permission denied');
    }

    final position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );

    if (mounted) {
      setState(() {
        currentLat = position.latitude;
        currentLng = position.longitude;

        targetBearing = calculateBearing(
          currentLat,
          currentLng,
          targetLat,
          targetLng,
        );
      });
    }

    return position;
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
    Future<NextPrayerData> getNextPrayerTime() async {
      final position = await getLocation();

      final prayerTimes = getPrayerTimes(
        position.latitude,
        position.longitude,
      );

      return getNextPrayer(prayerTimes);
    }


  @override
  void initState() {
    super.initState();

    _nextPrayerFuture = getNextPrayerTime();

    FlutterCompass.events?.listen((event) {
      setState(() {
        phoneHeading = event.heading;
      });
    });
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

  void _resetCounter() {
    setState(() {
      _counter = 0;
    });
  }

  void _incrementCounter() {
    setState(() {
      // This call to setState tells the Flutter framework that something has
      // changed in this State, which causes it to rerun the build method below
      // so that the display can reflect the updated values. If we changed
      // _counter without calling setState(), then the build method would not be
      // called again, and so nothing would appear to happen.
      _counter++;
    });
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
                  return const Text('Unable to load next prayer');
                } else {
                  final nextPrayer = snapshot.data!;
                  return Container(
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
                ? const CircularProgressIndicator()
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

            const Text('You have done your thasbeeh this many times:'),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 32),
            Center(
              child: ElevatedButton(
                onPressed: _incrementCounter,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.add),
                  SizedBox(width: 8),
                  Text('count thasbeeh'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: ElevatedButton(
                onPressed: _resetCounter,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                  backgroundColor: Colors.red,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.refresh, color: Colors.white),
                    SizedBox(width: 8),
                    Text('Thasbeeh Target Finished', style: TextStyle(color: Colors.white)), 
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
