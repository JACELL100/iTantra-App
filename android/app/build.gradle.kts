plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "org.itantra.flutterhost"
    // Compile against the highest SDK installed. `compileSdk` only decides which
    // APIs are visible to the compiler - it does not change what the app asks
    // for at runtime, which is `targetSdk` - and three of the plugins are built
    // against 36, so 35 produces a warning on every build and would eventually
    // be a hard failure.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId = "org.itantra.flutterhost"
        // API 26 is the floor because the audio-focus and AudioTrack builder
        // APIs used for non-interruptible alerts are only available from
        // Oreo, and it still covers essentially every phone in service.
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0.0"

        // Only the ABIs that matter for on-device inference. Shipping x86
        // would add tens of megabytes of ONNX Runtime for emulators only,
        // and app size is a scored metric.
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            // Debug signing so a fresh clone can produce a runnable APK.
            // Replace with a real key before any distribution.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // Model packs are side-loaded, never bundled, so nothing here needs to
    // stay uncompressed except the small manifest assets.
    androidResources {
        noCompress += listOf("onnx", "tsv")
    }

    packaging {
        resources {
            excludes += setOf("META-INF/*.kotlin_module")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("org.jetbrains.kotlin:kotlin-stdlib")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    implementation("androidx.core:core-ktx:1.13.1")
}
