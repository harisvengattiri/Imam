import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:intl/intl.dart';
import 'package:adhan/adhan.dart' as adhan;
import 'package:alarm/alarm.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart' hide ServiceStatus;
import 'package:hello_app/thasbeeh_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // alarm uses mobile platform channels; on web it can trip the engine (window.dart assertions).
  if (!kIsWeb) {
    await Alarm.init();
  }
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
  /// True when this column's prayer instant has passed (greyed UI).
  final bool isPast;

  const NextPrayerData({
    required this.name,
    required this.time,
    required this.remainingText,
    this.isPast = false,
  });
}

class NextPrayerComparisonData {
  /// Adhan calculation with your local minute adjustments.
  final NextPrayerData adjusted;
  /// Plain Adhan (MWL + Shafi), no extra adjustments.
  final NextPrayerData standard;

  const NextPrayerComparisonData({
    required this.adjusted,
    required this.standard,
  });
}

class _MyHomePageState extends State<MyHomePage> with WidgetsBindingObserver {
  static const MethodChannel _androidGpsChannel =
      MethodChannel('com.example.hello_app/location');

  static const String _adhanAssetPath = 'assets/audio/adhan.mp3';

  static const String _lastLatKey = 'last_known_prayer_lat';
  static const String _lastLngKey = 'last_known_prayer_lng';
  static const String _backgroundAdhanEnabledKey = 'background_adhan_enabled';

  /// Reference coordinates when user has not saved a device location (same as Qibla default).
  static const double _defaultPrayerLat = 21.4225;
  static const double _defaultPrayerLng = 39.8262;

  double? phoneHeading;
  double? targetBearing;
  late Future<NextPrayerComparisonData> _nextPrayerFuture;
  bool _usingPreviousLocation = false;
  bool _usingDefaultReferenceLocation = false;
  /// Set when the user last tapped the location button while device location was off.
  bool _gpsWasOffOnLastLocationTap = false;
  /// True if that tap used SharedPreferences (saved) coordinates as cache.
  bool _usedSavedCacheOnLastLocationTap = false;
  /// Satellite GPS provider on (FAB green); independent of app permission.
  bool _gpsSatelliteOn = false;
  bool _backgroundAdhanEnabled = true;
  StreamSubscription<ServiceStatus>? _locationServiceSubscription;
  StreamSubscription<dynamic>? _alarmRingingSubscription;
  Timer? _gpsStatusPollTimer;
  bool _isAdhanDialogVisible = false;

  double currentLat = 0;
  double currentLng = 0;

  double targetLat = 21.4225;
  double targetLng = 39.8262;

  /// True only when system Location is on **and** (on Android) the GPS
  /// provider is enabled — not Wi‑Fi/scan‑only. If Location is off entirely,
  /// [Geolocator.isLocationServiceEnabled] is false so the FAB is not green.
  Future<bool> _isGpsSatelliteEnabled() async {
    if (kIsWeb) {
      return Geolocator.isLocationServiceEnabled();
    }
    final locationMasterOn = await Geolocator.isLocationServiceEnabled();
    if (!locationMasterOn) return false;

    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        final gpsEnabled = await _androidGpsChannel
            .invokeMethod<bool>('isGpsProviderEnabled');
        return gpsEnabled ?? false;
      } catch (_) {
        return locationMasterOn;
      }
    }
    return true;
  }

  /// Live GPS read is allowed: satellite GPS on and (already granted or newly granted) permission.
  Future<bool> _canUseLiveGpsNow() async {
    final gpsOn = await _isGpsSatelliteEnabled();
    if (!gpsOn) return false;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  }

  Future<void> _updateLocationAvailability() async {
    final gpsOn = await _isGpsSatelliteEnabled();
    if (!mounted) return;
    final wasOn = _gpsSatelliteOn;
    if (wasOn == gpsOn) return;
    setState(() {
      _gpsSatelliteOn = gpsOn;
      if (wasOn && !gpsOn) {
        _nextPrayerFuture = getNextPrayerTime(fetchFreshGps: false);
      }
    });
  }

  Widget _playAdhanSwitchRow() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Play Adhan'),
        const SizedBox(width: 8),
        Switch.adaptive(
          value: _backgroundAdhanEnabled,
          onChanged: _setBackgroundAdhanEnabled,
        ),
      ],
    );
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

  Future<void> _loadBackgroundAdhanPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_backgroundAdhanEnabledKey) ?? true;
    if (!enabled && !kIsWeb) {
      await Alarm.stopAll();
    }
    if (!mounted) return;
    setState(() {
      _backgroundAdhanEnabled = enabled;
    });
  }

  Future<void> _setBackgroundAdhanEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_backgroundAdhanEnabledKey, enabled);
    if (!mounted) return;
    setState(() {
      _backgroundAdhanEnabled = enabled;
    });
    if (!enabled) {
      if (!kIsWeb) await Alarm.stopAll();
    } else {
      await _ensureAndroidPrayerPermissions();
      if (!mounted) return;
      final fresh = await _canUseLiveGpsNow();
      if (!mounted) return;
      setState(() {
        _nextPrayerFuture = getNextPrayerTime(fetchFreshGps: fresh);
      });
    }
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
    required bool useDeviceGps,
    bool preferFreshLocation = false,
  }) async {
    if (!useDeviceGps) {
      final saved = await _loadLastLocation();
      if (saved != null) {
        _applyCoordinates(saved.lat, saved.lng);
        return (
          lat: saved.lat,
          lng: saved.lng,
          usedPrevious: true,
        );
      }
      _applyCoordinates(_defaultPrayerLat, _defaultPrayerLng);
      return (
        lat: _defaultPrayerLat,
        lng: _defaultPrayerLng,
        usedPrevious: false,
      );
    }

    Future<({double lat, double lng, bool usedPrevious})?> tryPlatformLastKnown() async {
      try {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) {
          _applyCoordinates(last.latitude, last.longitude);
          await _saveLastLocation(last.latitude, last.longitude);
          return (lat: last.latitude, lng: last.longitude, usedPrevious: true);
        }
      } catch (_) {}
      return null;
    }

    Future<({double lat, double lng, bool usedPrevious})?> trySaved() async {
      final saved = await _loadLastLocation();
      if (saved != null) {
        _applyCoordinates(saved.lat, saved.lng);
        return (lat: saved.lat, lng: saved.lng, usedPrevious: true);
      }
      return null;
    }

    final serviceEnabled = await _isGpsSatelliteEnabled();
    if (!serviceEnabled) {
      await _updateLocationAvailability();
      if (preferFreshLocation) {
        throw Exception('Location services are disabled');
      }
      final saved = await trySaved();
      if (saved != null) return saved;
      final platformLastKnown = await tryPlatformLastKnown();
      if (platformLastKnown != null) return platformLastKnown;
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

    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 18),
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
        timeLimit: const Duration(seconds: 12),
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
        desiredAccuracy: LocationAccuracy.low,
        timeLimit: const Duration(seconds: 10),
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

    final cached = await tryPlatformLastKnown();
    if (cached != null) return cached;

    final saved = await trySaved();
    if (saved != null) return saved;

    throw Exception(
      'Could not get your location. Try moving outdoors or tap Retry.',
    );
  }

  /// Location button: confirm when GPS is on; when GPS is off use saved cache (no error UI).
  Future<void> _onLocationFabPressed() async {
    await _updateLocationAvailability();
    final gpsOn = await _isGpsSatelliteEnabled();

    if (!gpsOn) {
      final saved = await _loadLastLocation();
      if (!mounted) return;
      setState(() {
        _gpsWasOffOnLastLocationTap = true;
        _usedSavedCacheOnLastLocationTap = saved != null;
        if (saved != null) {
          _nextPrayerFuture = getNextPrayerTimeFromCoordinates(
            saved.lat,
            saved.lng,
            usedPrevious: true,
            isDefaultReference: false,
          );
        } else {
          _nextPrayerFuture = getNextPrayerTimeFromCoordinates(
            _defaultPrayerLat,
            _defaultPrayerLng,
            usedPrevious: false,
            isDefaultReference: true,
          );
        }
      });
      return;
    }

    if (!mounted) return;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(kIsWeb ? 'Use your location' : 'GPS is on'),
        content: Text(
          kIsWeb
              ? 'Your browser will ask to share your location so prayer times can update.'
              : 'Satellite GPS is turned on. This app will read your current '
                  'position to update prayer times.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;
    setState(() {
      _gpsWasOffOnLastLocationTap = false;
      _usedSavedCacheOnLastLocationTap = false;
      _nextPrayerFuture = getNextPrayerTime(fetchFreshGps: true);
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

  /// MWL + Shafi, same as before; minute tweaks only in [_areaAdjustedAdhanParams].
  adhan.CalculationParameters _standardAdhanParams() {
    final p = adhan.CalculationMethod.muslim_world_league.getParameters();
    p.madhab = adhan.Madhab.shafi;
    return p;
  }

  /// Former local `PrayerAdjustments` values, applied on top of Adhan MWL + Shafi.
  adhan.CalculationParameters _areaAdjustedAdhanParams() {
    final p = adhan.CalculationMethod.muslim_world_league.getParameters();
    p.madhab = adhan.Madhab.shafi;
    p.adjustments = adhan.PrayerAdjustments(
      fajr: -5,
      dhuhr: 3,
      asr: 4,
      maghrib: 5,
      isha: 8,
    );
    return p;
  }

  String _capitalizePrayerName(String name) {
    if (name.isEmpty) return name;
    return name[0].toUpperCase() + name.substring(1).toLowerCase();
  }

  /// One prayer name on both cards; each column muted when its own time has passed.
  /// Advances to the next prayer only after **both** Masjid and standard times have passed.
  NextPrayerComparisonData buildSynchronizedNextPrayerComparison(
    double lat,
    double lon,
  ) {
    final now = DateTime.now();
    final coords = adhan.Coordinates(lat, lon);
    final adjParams = _areaAdjustedAdhanParams();
    final stdParams = _standardAdhanParams();

    final adjPt = adhan.PrayerTimes(
      coords,
      adhan.DateComponents.from(now),
      adjParams,
    );
    final stdPt = adhan.PrayerTimes(
      coords,
      adhan.DateComponents.from(now),
      stdParams,
    );

    final slots = <(String name, DateTime adj, DateTime std)>[
      ('fajr', adjPt.fajr, stdPt.fajr),
      ('dhuhr', adjPt.dhuhr, stdPt.dhuhr),
      ('asr', adjPt.asr, stdPt.asr),
      ('maghrib', adjPt.maghrib, stdPt.maghrib),
      ('isha', adjPt.isha, stdPt.isha),
    ];

    for (final s in slots) {
      final adjPassed = now.isAfter(s.$2);
      final stdPassed = now.isAfter(s.$3);
      if (!adjPassed || !stdPassed) {
        return NextPrayerComparisonData(
          adjusted: NextPrayerData(
            name: s.$1,
            time: s.$2,
            remainingText: adjPassed
                ? 'Masjid time passed'
                : formatRemainingDuration(s.$2.difference(now)),
            isPast: adjPassed,
          ),
          standard: NextPrayerData(
            name: s.$1,
            time: s.$3,
            remainingText: stdPassed
                ? 'Standard time passed'
                : formatRemainingDuration(s.$3.difference(now)),
            isPast: stdPassed,
          ),
        );
      }
    }

    final tomorrow = now.add(const Duration(days: 1));
    final adjTom = adhan.PrayerTimes(
      coords,
      adhan.DateComponents.from(tomorrow),
      adjParams,
    );
    final stdTom = adhan.PrayerTimes(
      coords,
      adhan.DateComponents.from(tomorrow),
      stdParams,
    );
    final af = adjTom.fajr;
    final sf = stdTom.fajr;
    return NextPrayerComparisonData(
      adjusted: NextPrayerData(
        name: 'fajr',
        time: af,
        remainingText: formatRemainingDuration(af.difference(now)),
      ),
      standard: NextPrayerData(
        name: 'fajr',
        time: sf,
        remainingText: formatRemainingDuration(sf.difference(now)),
      ),
    );
  }

  Widget _nextPrayerCard(
    BuildContext context, {
    required String header,
    required NextPrayerData data,
  }) {
    final past = data.isPast;
    return Container(
      width: MediaQuery.of(context).size.width * 0.7,
      height: 120,
      padding: const EdgeInsets.symmetric(
        horizontal: 18,
        vertical: 16,
      ),
      decoration: BoxDecoration(
        color: past ? Colors.grey.shade200 : Colors.deepPurple.shade50,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            header,
            style: TextStyle(
              fontSize: 14,
              color: past ? Colors.black38 : Colors.black54,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${_capitalizePrayerName(data.name)} at ${formatTime(data.time)}',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: past ? Colors.black45 : Colors.deepPurple,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            data.remainingText,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: past ? Colors.black45 : Colors.green,
            ),
          ),
        ],
      ),
    );
  }

  /// Android cannot grant these silently (Play policy / OS security). This runs
  /// automatically so the user only taps system "Allow" dialogs—not hunt in Settings.
  /// OEM extras (Xiaomi autostart, etc.) still have no public API.
  Future<void> _ensureAndroidPrayerPermissions() async {
    if (defaultTargetPlatform != TargetPlatform.android || kIsWeb) return;

    Future<void> gap() =>
        Future<void>.delayed(const Duration(milliseconds: 450));

    try {
      await Permission.notification.request();
      await gap();

      await Permission.scheduleExactAlarm.request();
      await gap();

      await Permission.ignoreBatteryOptimizations.request();
    } catch (_) {}
  }

  List<(String, DateTime)> _prayerScheduleFromAdhan(adhan.PrayerTimes pt) {
    return <(String, DateTime)>[
      ('Fajr', pt.fajr),
      ('Dhuhr', pt.dhuhr),
      ('Asr', pt.asr),
      ('Maghrib', pt.maghrib),
      ('Isha', pt.isha),
    ];
  }

  int _alarmIdForPrayer(DateTime date, int index) {
    return (date.year * 10000 + date.month * 100 + date.day) * 10 + index + 1;
  }

  Future<void> _syncBackgroundAdhanAlarms(double lat, double lon) async {
    if (kIsWeb || !_backgroundAdhanEnabled) return;

    await _ensureAndroidPrayerPermissions();

    final now = DateTime.now();
    final today = adhan.PrayerTimes(
      adhan.Coordinates(lat, lon),
      adhan.DateComponents.from(now),
      _areaAdjustedAdhanParams(),
    );
    final tomorrowDate = now.add(const Duration(days: 1));
    final tomorrow = adhan.PrayerTimes(
      adhan.Coordinates(lat, lon),
      adhan.DateComponents.from(tomorrowDate),
      _areaAdjustedAdhanParams(),
    );

    final existing = await Alarm.getAlarms();
    for (final alarm in existing) {
      if (!await Alarm.isRinging(alarm.id)) {
        await Alarm.stop(alarm.id);
      }
    }

    final schedule = <(String, DateTime)>[
      ..._prayerScheduleFromAdhan(today),
      ..._prayerScheduleFromAdhan(tomorrow),
    ];

    for (var i = 0; i < schedule.length; i++) {
      final item = schedule[i];
      if (!item.$2.isAfter(now)) continue;

      final alarmSettings = AlarmSettings(
        id: _alarmIdForPrayer(item.$2, i),
        dateTime: item.$2,
        assetAudioPath: _adhanAssetPath,
        loopAudio: false,
        vibrate: true,
        warningNotificationOnKill: false,
        androidFullScreenIntent: true,
        // Avoid tying alarm audio to the Flutter task; improves behavior when the app is backgrounded.
        androidStopAlarmOnTermination: false,
        // Full volume immediately — fade-from-zero can be inaudible on some devices until the screen turns on.
        volumeSettings: const VolumeSettings.fixed(volume: 0.85),
        notificationSettings: NotificationSettings(
          title: 'Adhan time',
          body: 'It is time for ${item.$1}',
          stopButton: 'Stop',
        ),
      );
      var ok = await Alarm.set(alarmSettings: alarmSettings);
      if (!ok && defaultTargetPlatform == TargetPlatform.android) {
        await _ensureAndroidPrayerPermissions();
        ok = await Alarm.set(alarmSettings: alarmSettings);
      }
    }
  }

  void _setupAlarmRingingListener() {
    if (kIsWeb) return;
    _alarmRingingSubscription = Alarm.ringing.listen((alarmSet) async {
      if (!mounted || _isAdhanDialogVisible) return;
      if (alarmSet.alarms.isEmpty) return;

      _isAdhanDialogVisible = true;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('Adhan is playing'),
            content: const Text('Tap stop to turn off Adhan.'),
            actions: [
              TextButton(
                onPressed: () async {
                  await Alarm.stopAll();
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                  }
                },
                child: const Text('Stop'),
              ),
            ],
          );
        },
      );
      _isAdhanDialogVisible = false;
    });
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

  void _showAllPrayersDialog(BuildContext context) {
    final now = DateTime.now();
    final coords = adhan.Coordinates(currentLat, currentLng);
    final adjustedPt = adhan.PrayerTimes(
      coords,
      adhan.DateComponents.from(now),
      _areaAdjustedAdhanParams(),
    );
    final standardPt = adhan.PrayerTimes(
      coords,
      adhan.DateComponents.from(now),
      _standardAdhanParams(),
    );
    final adjustedRows = _prayerScheduleFromAdhan(adjustedPt);
    final standardRows = _prayerScheduleFromAdhan(standardPt);

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Today\'s prayers'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                DateFormat.yMMMEd().format(now),
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: Colors.black54,
                    ),
              ),
              const SizedBox(height: 12),
              Text(
                'Masjid time',
                style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: Colors.deepPurple,
                    ),
              ),
              const SizedBox(height: 6),
              ...adjustedRows.map(
                (e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(e.$1),
                      Text(
                        formatTime(e.$2),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 24),
              Text(
                'Standard Adhan',
                style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: Colors.deepPurple,
                    ),
              ),
              const SizedBox(height: 6),
              ...standardRows.map(
                (e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(e.$1),
                      Text(
                        formatTime(e.$2),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<NextPrayerComparisonData> _bootstrapFirstLoad() async {
    await _ensureAndroidPrayerPermissions();
    final fresh = await _canUseLiveGpsNow();
    return getNextPrayerTime(fetchFreshGps: fresh);
  }

  Future<NextPrayerComparisonData> getNextPrayerTimeFromCoordinates(
    double lat,
    double lng, {
    required bool usedPrevious,
    required bool isDefaultReference,
  }) async {
    _applyCoordinates(lat, lng);
    if (mounted) {
      setState(() {
        _usingPreviousLocation = usedPrevious;
        _usingDefaultReferenceLocation = isDefaultReference;
      });
    }
    return _buildPrayerComparisonAndSyncAlarms(lat, lng);
  }

  Future<NextPrayerComparisonData> getNextPrayerTime({
    bool fetchFreshGps = false,
  }) async {
    final location = await getLocation(
      useDeviceGps: fetchFreshGps,
      preferFreshLocation: fetchFreshGps,
    );
    if (mounted) {
      final isDefaultRef = !fetchFreshGps &&
          !location.usedPrevious &&
          (location.lat - _defaultPrayerLat).abs() < 0.0002 &&
          (location.lng - _defaultPrayerLng).abs() < 0.0002;
      setState(() {
        _usingPreviousLocation = location.usedPrevious;
        _usingDefaultReferenceLocation = isDefaultRef;
        if (fetchFreshGps) {
          _gpsWasOffOnLastLocationTap = false;
          _usedSavedCacheOnLastLocationTap = false;
        }
      });
    }

    return _buildPrayerComparisonAndSyncAlarms(location.lat, location.lng);
  }

  Future<NextPrayerComparisonData> _buildPrayerComparisonAndSyncAlarms(
    double lat,
    double lon,
  ) async {
    final data = buildSynchronizedNextPrayerComparison(lat, lon);

    unawaited(
      _syncBackgroundAdhanAlarms(lat, lon).catchError((_) {}),
    );

    return data;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_updateLocationAvailability());
    if (!_backgroundAdhanEnabled) return;
    unawaited(_resyncAlarmsAfterResume().catchError((_) {}));
  }

  Future<void> _resyncAlarmsAfterResume() async {
    final prefs = await SharedPreferences.getInstance();
    final lat = prefs.getDouble(_lastLatKey);
    final lng = prefs.getDouble(_lastLngKey);
    if (lat == null || lng == null) return;
    await _syncBackgroundAdhanAlarms(lat, lng);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _loadBackgroundAdhanPreference();
    _setupAlarmRingingListener();
    _nextPrayerFuture = _bootstrapFirstLoad();
    unawaited(_updateLocationAvailability());
    if (!kIsWeb) {
      _locationServiceSubscription =
          Geolocator.getServiceStatusStream().listen((_) async {
        await _updateLocationAvailability();
      });
    }
    // Quick Settings / satellite toggle often do not emit [getServiceStatusStream].
    _gpsStatusPollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      final life = WidgetsBinding.instance.lifecycleState;
      if (life == AppLifecycleState.paused ||
          life == AppLifecycleState.detached) {
        return;
      }
      unawaited(_updateLocationAvailability());
    });

    FlutterCompass.events?.listen((event) {
      setState(() {
        phoneHeading = event.heading;
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _gpsStatusPollTimer?.cancel();
    _locationServiceSubscription?.cancel();
    _alarmRingingSubscription?.cancel();
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
        toolbarHeight: 100,
        // Here we take the value from the MyHomePage object that was created by
        // the App.build method, and use it to set our appbar title.
        centerTitle: false,
        title: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(40),
            child: Image.asset(
              'assets/icon/imam_logo.jpg',
              height: 80,
              width: 80,
              fit: BoxFit.cover,
            ),
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: PopupMenuButton<String>(
              icon: const Icon(Icons.menu),
              position: PopupMenuPosition.under,
              onSelected: (value) {
                if (value == 'thasbeeh') {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const ThasbeehPage(),
                    ),
                  );
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem<String>(
                  value: 'thasbeeh',
                  child: Text('Thasbeeh'),
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 50),
        child: FloatingActionButton(
          onPressed: () => unawaited(_onLocationFabPressed()),
          backgroundColor: _gpsSatelliteOn ? Colors.green : Colors.red,
          foregroundColor: Colors.white,
          tooltip: 'Update location for prayer times',
          child: const Icon(Icons.my_location),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
            const SizedBox(height: 25),
            const Text(
              'Direction of Namaz',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
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
            const SizedBox(height: 50),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 25),
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Flexible(
                      child: FutureBuilder<NextPrayerComparisonData>(
                    future: _nextPrayerFuture,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Align(
                              alignment: Alignment.centerLeft,
                              child: CircularProgressIndicator(),
                            ),
                            const SizedBox(height: 16),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [_playAdhanSwitchRow()],
                            ),
                          ],
                        );
                      } else if (snapshot.hasError) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: Text(
                                _prayerLoadErrorMessage(snapshot.error),
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: Colors.black87,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            FilledButton.icon(
                              onPressed: () {
                                setState(() {
                                  _nextPrayerFuture =
                                      getNextPrayerTime(fetchFreshGps: true);
                                });
                              },
                              icon: const Icon(Icons.refresh),
                              label: const Text('Retry'),
                            ),
                            const SizedBox(height: 16),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [_playAdhanSwitchRow()],
                            ),
                          ],
                        );
                      } else {
                        final nextPrayer = snapshot.data!;
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_gpsWasOffOnLastLocationTap) ...[
                              const Padding(
                                padding: EdgeInsets.only(bottom: 4),
                                child: Text(
                                  'GPS is off.',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.black87,
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(
                                  _usedSavedCacheOnLastLocationTap
                                      ? 'Prayer times are from your saved location (cache).'
                                      : 'No saved position yet — prayer times use the reference location (Makkah).',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.black54,
                                  ),
                                ),
                              ),
                            ],
                            if (!_gpsWasOffOnLastLocationTap &&
                                _usingDefaultReferenceLocation)
                              const Padding(
                                padding: EdgeInsets.only(bottom: 8),
                                child: Text(
                                  'Prayer times use a reference location (Makkah) until you save a position via the location button.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.black54,
                                  ),
                                ),
                              ),
                            if (!_gpsWasOffOnLastLocationTap &&
                                _usingPreviousLocation &&
                                !_usingDefaultReferenceLocation)
                              const Padding(
                                padding: EdgeInsets.only(bottom: 8),
                                child: Text(
                                  'Showing prayer time from your previous location',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.black54,
                                  ),
                                ),
                              ),
                            Column(
                              children: [
                                _nextPrayerCard(
                                  context,
                                  header: 'Next prayer (Masjid Time)',
                                  data: nextPrayer.adjusted,
                                ),
                                const SizedBox(height: 8),
                                _nextPrayerCard(
                                  context,
                                  header: 'Next prayer (standard Adhan)',
                                  data: nextPrayer.standard,
                                ),
                                const SizedBox(height: 16),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    FilledButton.tonal(
                                      onPressed: () =>
                                          _showAllPrayersDialog(context),
                                      child: const Text('Show all prayers'),
                                    ),
                                    const SizedBox(width: 16),
                                    _playAdhanSwitchRow(),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        );
                      }
                    },
                      ),
                    ),
                  ],
                ),
            ),

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
