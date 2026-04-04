package com.example.hello_app

import android.content.Context
import android.location.LocationManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.example.hello_app/location",
        ).setMethodCallHandler { call, result ->
            if (call.method == "isGpsProviderEnabled") {
                val lm = getSystemService(Context.LOCATION_SERVICE) as LocationManager
                result.success(lm.isProviderEnabled(LocationManager.GPS_PROVIDER))
            } else {
                result.notImplemented()
            }
        }
    }
}
